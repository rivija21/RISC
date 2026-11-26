// =============================================================================
// mc_core.sv  -  MULTI-CYCLE MICROPROGRAMMED RV32IM core   (s3: Mic-1 style)
// -----------------------------------------------------------------------------
// Datapath (compare with Mic-1, s3 slide 22):
//
//              ┌──────────── C bus (write-back) ─────────────┐
//              ▼                                             │
//   +----+ +----+ +---+ +---+ +---+                          │
//   | PC | | IR | | A | | B | | T |   registers               │
//   +----+ +----+ +---+ +---+ +---+                          │
//     │               │     │   │                            │
//     └──► A bus mux ─┘     └─► B bus mux (B / imm / 4)       │
//              │                    │                        │
//              └────────► ALU ◄─────┘ ───────────────────────┘
//
//   PC   program counter          IR  instruction register
//   A, B operands read from the register file (rs1, rs2)
//   T    temporary: ALU result, effective address, jump target
//   The memory latches address and data at the request (its MAR / MDR),
//   so one single-port memory holds both code and data (von Neumann).
//
// Control: mc_control_store (MIR, 128 x 36-bit microinstructions) +
// this module's micro-sequencer (MPC logic, JAM, JMPC dispatch).
//
// Typical cycles per instruction (memory LATENCY = L):
//   ADD 5+L   LW 9+2L   SW 9+2L   branch 5..6+L   MUL/DIV ~37+L
// Different instructions take different numbers of cycles - the point of a
// multi-cycle design (s3 slide 47 vs single-cycle).
// =============================================================================

import rv_pkg::*;
import mc_pkg::*;

module mc_core
#(
  parameter logic [31:0] RESET_PC = 32'h0000_0000
)(
  input  logic        clk,
  input  logic        rst,
  // single memory port (instructions and data)
  output logic        mem_req,          // 1-cycle request
  output logic        mem_we,
  output logic [3:0]  mem_be,
  output logic [31:0] mem_addr,
  output logic [31:0] mem_wdata,
  input  logic [31:0] mem_rdata,        // valid while mem_done = 1
  input  logic        mem_done,         // level: last request finished
  // interrupts and time
  input  logic        mtip,
  input  logic        meip,
  input  logic [63:0] mtime,
  // debug
  output logic        retire_o,
  output logic [31:0] pc_o,
  output logic [6:0]  mpc_o             // current micro-PC (for waveforms)
);

  // ===========================================================================
  // Micro-sequencer: MPC, control store (MIR), JAM, JMPC
  // ===========================================================================
  uinstr_t    mir;                        // current microinstruction
  logic [6:0] mpc, mpc_next;
  logic [6:0] dispatch_addr;
  logic       cond;                       // selected JAM condition

  mc_control_store u_cs (.clk(clk), .addr(mpc_next), .mir(mir));

  always_comb begin
    if (rst)            mpc_next = FETCH0;
    else if (mir.jmpc)  mpc_next = dispatch_addr;                     // goto MBR
    else                mpc_next = {mir.next[6] | cond, mir.next[5:0]}; // JAM
  end

  always_ff @(posedge clk) mpc <= mpc_next;   // mir == control_store[mpc]

  // ===========================================================================
  // Datapath registers
  // ===========================================================================
  logic [31:0] PC, IR, A, B, T;

  // ---------------- decode helpers (from IR) ---------------------------------
  instr_id_e id;
  rv_decoder #(.HAS_M(1'b1)) u_dec (.instr(IR), .id(id));
  mc_dispatch u_disp (.id(id), .addr(dispatch_addr));

  logic [2:0] funct3;
  logic [4:0] rs1, rs2, rd;
  assign funct3 = IR[14:12];
  assign rs1    = IR[19:15];
  assign rs2    = IR[24:20];
  assign rd     = IR[11:7];

  // immediate format follows from the opcode
  imm_e        imm_sel;
  logic [31:0] imm;
  always_comb begin
    case (IR[6:0])
      OPC_STORE:            imm_sel = IMM_S;
      OPC_BRANCH:           imm_sel = IMM_B;
      OPC_LUI, OPC_AUIPC:   imm_sel = IMM_U;
      OPC_JAL:              imm_sel = IMM_J;
      default:              imm_sel = IMM_I;
    endcase
  end
  imm_gen u_imm (.instr(IR), .sel(imm_sel), .imm(imm));

  // ---------------- register file --------------------------------------------
  logic [31:0] rf_rd1, rf_rd2, rf_wd;
  regfile #(.BYPASS(1'b0)) u_rf (
    .clk, .ra1(rs1), .ra2(rs2), .rd1(rf_rd1), .rd2(rf_rd2),
    .we(mir.rf_we && !rst), .wa(rd), .wd(rf_wd)
  );

  // ---------------- ALU with its two input buses ------------------------------
  logic [31:0] alu_a, alu_b, alu_y;
  alu_op_e     alu_op;
  logic        z_unused, n_unused, v_unused;

  always_comb begin
    case (mir.alu_a)
      UA_A:    alu_a = A;
      UA_ZERO: alu_a = 32'b0;
      default: alu_a = PC;
    endcase
    case (mir.alu_b)
      UB_IMM:  alu_b = imm;
      UB_FOUR: alu_b = 32'd4;
      default: alu_b = B;
    endcase
    if (mir.alu_fn == UF_IR) alu_op = alu_op_from_ir(IR);
    else                     alu_op = ALU_ADD;
  end

  alu u_alu (.a(alu_a), .b(alu_b), .op(alu_op), .y(alu_y),
             .zero(z_unused), .negative(n_unused), .overflow(v_unused));

  // ---------------- branch comparator ------------------------------------------
  logic br_taken;
  branch_unit u_br (.funct3(funct3), .a(A), .b(B), .taken(br_taken));

  // ---------------- multiplier / divider ---------------------------------------
  logic        md_busy, md_valid;
  logic [31:0] md_result;
  muldiv u_md (
    .clk, .rst, .start(mir.md_start && !rst), .abort(1'b0),
    .funct3(funct3), .a(A), .b(B),
    .busy(md_busy), .valid(md_valid), .result(md_result)
  );

  // ---------------- CSR unit (traps, counters, interrupts) ----------------------
  logic [31:0] csr_rdata, mtvec, mepc, irq_cause;
  logic        csr_illegal, irq_pending, csr_wr_intent;
  logic [31:0] trap_cause, trap_tval;

  assign csr_wr_intent = (funct3[1:0] == 2'b01) || (rs1 != 5'd0);

  always_comb begin
    trap_tval = 32'b0;
    case (mir.cause)
      C_IMIS:  begin trap_cause = CAUSE_INSTR_MISALIGNED; trap_tval = {T[31:1], 1'b0}; end
      C_ILL:   begin trap_cause = CAUSE_ILLEGAL_INSTR;    trap_tval = IR; end
      C_BRK:         trap_cause = CAUSE_BREAKPOINT;
      C_LMIS:  begin trap_cause = CAUSE_LOAD_MISALIGNED;  trap_tval = T; end
      C_SMIS:  begin trap_cause = CAUSE_STORE_MISALIGNED; trap_tval = T; end
      C_ECALL:       trap_cause = CAUSE_ECALL_M;
      C_IRQ:         trap_cause = irq_cause;
      default:       trap_cause = 32'b0;
    endcase
  end

  csr_unit #(.HAS_M(1'b1)) u_csr (
    .clk, .rst,
    .csr_addr(IR[31:20]), .csr_cmd(funct3[1:0]),
    .csr_src(funct3[2] ? {27'b0, rs1} : A),
    .csr_wr_intent(csr_wr_intent), .csr_commit(mir.csr_exec && !rst),
    .csr_rdata(csr_rdata), .csr_illegal(csr_illegal),
    .trap_take(mir.trap && !rst), .trap_cause(trap_cause), .trap_epc(PC),
    .trap_tval(trap_tval),
    .mret_take(mir.mret && !rst),
    .mtvec_o(mtvec), .mepc_o(mepc),
    .retire(mir.retire && !rst), .mtime(mtime), .mtip(mtip), .meip(meip),
    .irq_pending(irq_pending), .irq_cause(irq_cause)
  );

  // ---------------- JAM condition select ------------------------------------------
  always_comb begin
    case (mir.jam)
      J_IRQ:      cond = irq_pending;
      J_MEM:      cond = mem_done;
      J_BR:       cond = br_taken;
      J_MD:       cond = md_valid;
      J_TGT_MIS:  cond = T[1];                              // bit 0 is ignored
      J_ADDR_MIS: cond = lsu_misaligned(T[1:0], funct3);
      J_CSR_ILL:  cond = csr_illegal;
      default:    cond = 1'b0;
    endcase
  end

  // ---------------- memory interface ------------------------------------------------
  logic [35:0] st;
  assign st        = lsu_store(B, T[1:0], funct3);
  assign mem_req   = (mir.mem_op != MOP_NONE) && !rst;
  assign mem_we    = (mir.mem_op == MOP_STORE);
  assign mem_addr  = (mir.mem_op == MOP_FETCH) ? PC : T;
  assign mem_wdata = st[31:0];
  assign mem_be    = (mir.mem_op == MOP_STORE) ? st[35:32] : 4'b0000;

  // ---------------- register-file write data (C bus) ----------------------------------
  always_comb begin
    case (mir.wb_src)
      WBS_ALU: rf_wd = alu_y;
      WBS_MEM: rf_wd = lsu_load(mem_rdata, T[1:0], funct3);
      WBS_CSR: rf_wd = csr_rdata;
      WBS_MD:  rf_wd = md_result;
      default: rf_wd = T;
    endcase
  end

  // ---------------- register updates ---------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst) begin
      PC <= RESET_PC;
      IR <= 32'h0000_0013;                // NOP (addi x0, x0, 0)
    end else begin
      if (mir.ir_we) IR <= mem_rdata;
      if (mir.ab_we) begin A <= rf_rd1; B <= rf_rd2; end
      if (mir.t_we)  T  <= alu_y;
      if (mir.pc_we) begin
        case (mir.pc_src)
          PCS_T:     PC <= {T[31:1], 1'b0};
          PCS_MTVEC: PC <= mtvec;
          PCS_MEPC:  PC <= mepc;
          default:   PC <= alu_y;
        endcase
      end
    end
  end

  assign retire_o = mir.retire && !rst;
  assign pc_o     = PC;
  assign mpc_o    = mpc;

endmodule
