// =============================================================================
// mc_control_store.sv  -  microinstruction format + CONTROL STORE (microcode)
//                         for the multi-cycle microprogrammed core
//                         (s3 slides 17, 19-46: IJVM Mic-1 / Mic-2)
// -----------------------------------------------------------------------------
// This is the Mic-1 idea applied to RISC-V:
//
//   * Every RV32 instruction is executed as a short sequence of
//     MICROINSTRUCTIONS, one per clock cycle.
//   * The microinstructions are stored in a CONTROL STORE (a ROM) of
//     128 words x 36 bits.  (Mic-1: 512 x 36.)
//   * MPC (micro program counter) holds the address of the next
//     microinstruction; MIR holds the current one.
//   * Every microinstruction has a NEXT_ADDRESS field.
//   * JAM (s3 slides 43-45): a conditional micro-branch.  If the selected
//     condition is true, the MSB of MPC is ORed with 1:
//            MPC = { NEXT_ADDRESS[6] | condition , NEXT_ADDRESS[5:0] }
//     so the "false" path is at address N and the "true" path at N + 64.
//     This is exactly the "high-bit logic" of the notes (F = JAMZ&Z | ...).
//   * JMPC ("goto MBR", s3 slide 41): MPC is loaded from a DISPATCH table
//     indexed by the instruction - a multi-way branch to the first
//     microinstruction of that instruction's routine.
// =============================================================================
package mc_pkg;

  // ---------------- microinstruction field types ------------------------------
  typedef enum logic [2:0] {           // JAM condition
    J_NONE     = 3'd0,
    J_IRQ      = 3'd1,                 // an enabled interrupt is pending
    J_MEM      = 3'd2,                 // memory access finished (wait loops)
    J_BR       = 3'd3,                 // branch condition true
    J_MD       = 3'd4,                 // multiplier/divider finished
    J_TGT_MIS  = 3'd5,                 // jump target in T is not 4-aligned
    J_ADDR_MIS = 3'd6,                 // load/store address in T misaligned
    J_CSR_ILL  = 3'd7                  // CSR does not exist / is read-only
  } jam_e;

  typedef enum logic [1:0] {UA_PC = 2'd0, UA_A = 2'd1, UA_ZERO = 2'd2} ua_e;   // ALU A bus
  typedef enum logic [1:0] {UB_B = 2'd0, UB_IMM = 2'd1, UB_FOUR = 2'd2} ub_e;  // ALU B bus
  typedef enum logic [0:0] {UF_ADD = 1'b0, UF_IR = 1'b1} uf_e;  // ADD, or from funct3/7

  typedef enum logic [1:0] {           // new PC source
    PCS_ALU   = 2'd0,                  // ALU output (PC + 4)
    PCS_T     = 2'd1,                  // T register (jump/branch target)
    PCS_MTVEC = 2'd2,                  // trap handler
    PCS_MEPC  = 2'd3                   // return from trap
  } pcs_e;

  typedef enum logic [1:0] {           // memory operation started this cycle
    MOP_NONE  = 2'd0,
    MOP_FETCH = 2'd1,                  // read word at PC
    MOP_LOAD  = 2'd2,                  // read word at T
    MOP_STORE = 2'd3                   // write B to address T
  } mop_e;

  typedef enum logic [2:0] {           // register-file write data
    WBS_T   = 3'd0,
    WBS_ALU = 3'd1,
    WBS_MEM = 3'd2,                    // memory data register, extended
    WBS_CSR = 3'd3,
    WBS_MD  = 3'd4
  } wbs_e;

  typedef enum logic [2:0] {           // trap cause
    C_NONE = 3'd0, C_IMIS = 3'd1, C_ILL = 3'd2, C_BRK = 3'd3,
    C_LMIS = 3'd4, C_SMIS = 3'd5, C_ECALL = 3'd6, C_IRQ = 3'd7
  } cause_e;

  // ---------------- the 36-bit microinstruction -------------------------------
  typedef struct packed {
    logic [6:0] next;      // NEXT_ADDRESS
    jam_e       jam;       // JAM condition select
    logic       jmpc;      // MPC <- dispatch(instruction)
    ua_e        alu_a;     // ALU A input
    ub_e        alu_b;     // ALU B input
    uf_e        alu_fn;    // ALU function
    logic       t_we;      // T   <- ALU
    logic       ab_we;     // A,B <- register file [rs1], [rs2]
    logic       ir_we;     // IR  <- memory data
    logic       pc_we;     // PC  <- pc_src
    pcs_e       pc_src;
    mop_e       mem_op;    // start a memory read/write
    logic       rf_we;     // register file [rd] <- wb_src
    wbs_e       wb_src;
    logic       md_start;  // start the Booth multiplier / divider
    logic       csr_exec;  // perform the CSR read-modify-write
    logic       mret;      // return from trap
    logic       retire;    // this instruction is complete (count it)
    logic       trap;      // take a trap (PC <- mtvec, save mepc/mcause)
    cause_e     cause;
  } uinstr_t;

  // ---------------- microcode labels (control store addresses) ----------------
  // Lower half (0..63): normal flow and "false" JAM targets.
  localparam logic [6:0]
    FETCH0 = 7'd0,   FETCH1 = 7'd1,  FETCH2 = 7'd2,  DECODE = 7'd3,
    OP_R   = 7'd4,   WB_T   = 7'd5,  OP_I   = 7'd6,  LUI0   = 7'd7,
    JAL0   = 7'd8,   JAL1   = 7'd9,  JALR0  = 7'd10,
    BR0    = 7'd11,  BR_NT  = 7'd12, BR_T2  = 7'd13,
    LD0    = 7'd14,  LD1    = 7'd15, LD2    = 7'd16, LD3    = 7'd17,
    ST0    = 7'd18,  ST1    = 7'd19, ST2    = 7'd20, ST3    = 7'd21,
    MD0    = 7'd22,  MD1    = 7'd23,
    CSR0   = 7'd24,  CSR1   = 7'd25,
    ECALL0 = 7'd26,  EBRK0  = 7'd27, MRET0  = 7'd28, NOP0   = 7'd29,
    ILL0   = 7'd30;
  // Upper half (64..127): "true" JAM targets.  The JAM rule ORs 64 into the
  // NEXT_ADDRESS field, so a true target is always (false target) + 64.
  localparam logic [6:0]
    IRQ0     = FETCH1 | 7'd64,   //  65  FETCH0 : interrupt pending
    FETCH3   = FETCH2 | 7'd64,   //  66  FETCH2 : memory done
    JAL_MIS  = JAL1   | 7'd64,   //  73  JAL0   : target misaligned
    BR_T     = BR_NT  | 7'd64,   //  76  BR0    : branch taken
    BR_MIS   = BR_T2  | 7'd64,   //  77  BR_T   : target misaligned
    LD_MIS   = LD2    | 7'd64,   //  80  LD1    : address misaligned
    LD4      = LD3    | 7'd64,   //  81  LD3    : memory done
    ST_MIS   = ST2    | 7'd64,   //  84  ST1    : address misaligned
    ST4      = ST3    | 7'd64,   //  85  ST3    : memory done
    MD2      = MD1    | 7'd64,   //  87  MD1    : mul/div done
    CSR_ILL  = CSR1   | 7'd64;   //  89  CSR0   : CSR illegal

endpackage


// =============================================================================
// Control store (ROM).  Registered output = MIR, as in Mic-1: the address
// (next MPC) is presented during the cycle, the word appears in MIR after the
// clock edge.  Quartus infers a ROM (M10K) from a case table in a clocked
// block.
//
// Micro-assembly notation in the comments (Mic-1 "MAL" style):
//     T = PC + imm;  rd = T;  PC = PC + 4;  rd_mem;  wr_mem;  goto X;
//     if (cond) goto X+64 else goto X     (JAM)
//     goto dispatch                       (JMPC)
// Unused fields are 0 (= no operation).
// =============================================================================

import rv_pkg::*;
import mc_pkg::*;

module mc_control_store
(
  input  logic       clk,
  input  logic [6:0] addr,           // next MPC
  output uinstr_t    mir             // microinstruction register
);
  uinstr_t w;

  always_comb begin
    w = '0;
    case (addr)
      // ======================= instruction fetch ==============================
      // FETCH0:  if (interrupt pending) goto IRQ0 else goto FETCH1
      FETCH0: begin w.jam = J_IRQ;  w.next = FETCH1; end
      // FETCH1:  MAR = PC; rd_mem                    (start the fetch)
      FETCH1: begin w.mem_op = MOP_FETCH; w.next = FETCH2; end
      // FETCH2:  wait: if (mem done) goto FETCH3 else goto FETCH2
      FETCH2: begin w.jam = J_MEM;  w.next = FETCH2; end
      // FETCH3:  IR = MDR
      FETCH3: begin w.ir_we = 1'b1; w.next = DECODE; end
      // DECODE:  A = R[rs1]; B = R[rs2]; T = PC + imm; goto dispatch
      //          T is the branch/jump/AUIPC target, computed "just in case"
      //          while the dispatch happens (a classic multi-cycle trick).
      DECODE: begin
        w.ab_we = 1'b1;
        w.alu_a = UA_PC; w.alu_b = UB_IMM; w.alu_fn = UF_ADD; w.t_we = 1'b1;
        w.jmpc  = 1'b1;
      end

      // ======================= ALU instructions ===============================
      // OP_R:  T = A op B                         (ADD, SUB, AND, ... )
      OP_R: begin
        w.alu_a = UA_A; w.alu_b = UB_B; w.alu_fn = UF_IR; w.t_we = 1'b1;
        w.next  = WB_T;
      end
      // OP_I:  T = A op imm                       (ADDI, ANDI, SLLI, ...)
      OP_I: begin
        w.alu_a = UA_A; w.alu_b = UB_IMM; w.alu_fn = UF_IR; w.t_we = 1'b1;
        w.next  = WB_T;
      end
      // LUI0:  T = 0 + imm
      LUI0: begin
        w.alu_a = UA_ZERO; w.alu_b = UB_IMM; w.t_we = 1'b1;
        w.next  = WB_T;
      end
      // WB_T:  R[rd] = T; PC = PC + 4; retire; goto FETCH0
      //        (AUIPC dispatches here directly: T = PC + imm from DECODE)
      WB_T: begin
        w.rf_we = 1'b1; w.wb_src = WBS_T;
        w.alu_a = UA_PC; w.alu_b = UB_FOUR; w.pc_we = 1'b1; w.pc_src = PCS_ALU;
        w.retire = 1'b1; w.next = FETCH0;
      end

      // ======================= jumps =========================================
      // JALR0: T = A + imm                        (then shares JAL's code)
      JALR0: begin
        w.alu_a = UA_A; w.alu_b = UB_IMM; w.t_we = 1'b1;
        w.next  = JAL0;
      end
      // JAL0:  if (T misaligned) goto JAL_MIS else goto JAL1
      JAL0: begin w.jam = J_TGT_MIS; w.next = JAL1; end
      // JAL1:  R[rd] = PC + 4; PC = T; retire; goto FETCH0
      JAL1: begin
        w.alu_a = UA_PC; w.alu_b = UB_FOUR; w.rf_we = 1'b1; w.wb_src = WBS_ALU;
        w.pc_we = 1'b1;  w.pc_src = PCS_T;
        w.retire = 1'b1; w.next = FETCH0;
      end
      JAL_MIS: begin w.trap = 1'b1; w.cause = C_IMIS; w.pc_we = 1'b1; w.pc_src = PCS_MTVEC; w.next = FETCH0; end

      // ======================= branches ======================================
      // BR0:   if (A cond B) goto BR_T else goto BR_NT
      BR0:   begin w.jam = J_BR; w.next = BR_NT; end
      // BR_NT: PC = PC + 4; retire
      BR_NT: begin
        w.alu_a = UA_PC; w.alu_b = UB_FOUR; w.pc_we = 1'b1; w.pc_src = PCS_ALU;
        w.retire = 1'b1; w.next = FETCH0;
      end
      // BR_T:  if (T misaligned) goto BR_MIS else goto BR_T2
      BR_T:  begin w.jam = J_TGT_MIS; w.next = BR_T2; end
      // BR_T2: PC = T; retire
      BR_T2: begin w.pc_we = 1'b1; w.pc_src = PCS_T; w.retire = 1'b1; w.next = FETCH0; end
      BR_MIS: begin w.trap = 1'b1; w.cause = C_IMIS; w.pc_we = 1'b1; w.pc_src = PCS_MTVEC; w.next = FETCH0; end

      // ======================= loads =========================================
      // LD0:  T = A + imm                          (effective address)
      LD0: begin w.alu_a = UA_A; w.alu_b = UB_IMM; w.t_we = 1'b1; w.next = LD1; end
      // LD1:  if (T misaligned) goto LD_MIS else goto LD2
      LD1: begin w.jam = J_ADDR_MIS; w.next = LD2; end
      // LD2:  MAR = T; rd_mem
      LD2: begin w.mem_op = MOP_LOAD; w.next = LD3; end
      // LD3:  wait: if (mem done) goto LD4 else goto LD3
      LD3: begin w.jam = J_MEM; w.next = LD3; end
      // LD4:  R[rd] = extend(MDR); PC = PC + 4; retire
      LD4: begin
        w.rf_we = 1'b1; w.wb_src = WBS_MEM;
        w.alu_a = UA_PC; w.alu_b = UB_FOUR; w.pc_we = 1'b1; w.pc_src = PCS_ALU;
        w.retire = 1'b1; w.next = FETCH0;
      end
      LD_MIS: begin w.trap = 1'b1; w.cause = C_LMIS; w.pc_we = 1'b1; w.pc_src = PCS_MTVEC; w.next = FETCH0; end

      // ======================= stores ========================================
      ST0: begin w.alu_a = UA_A; w.alu_b = UB_IMM; w.t_we = 1'b1; w.next = ST1; end
      ST1: begin w.jam = J_ADDR_MIS; w.next = ST2; end
      // ST2:  MAR = T; MDR = B; wr_mem
      ST2: begin w.mem_op = MOP_STORE; w.next = ST3; end
      ST3: begin w.jam = J_MEM; w.next = ST3; end
      ST4: begin
        w.alu_a = UA_PC; w.alu_b = UB_FOUR; w.pc_we = 1'b1; w.pc_src = PCS_ALU;
        w.retire = 1'b1; w.next = FETCH0;
      end
      ST_MIS: begin w.trap = 1'b1; w.cause = C_SMIS; w.pc_we = 1'b1; w.pc_src = PCS_MTVEC; w.next = FETCH0; end

      // ======================= RV32M =========================================
      // MD0:  start Booth multiplier / restoring divider with A, B
      MD0: begin w.md_start = 1'b1; w.next = MD1; end
      // MD1:  wait: if (done) goto MD2 else goto MD1    (~33 cycles)
      MD1: begin w.jam = J_MD; w.next = MD1; end
      // MD2:  R[rd] = result; PC = PC + 4; retire
      MD2: begin
        w.rf_we = 1'b1; w.wb_src = WBS_MD;
        w.alu_a = UA_PC; w.alu_b = UB_FOUR; w.pc_we = 1'b1; w.pc_src = PCS_ALU;
        w.retire = 1'b1; w.next = FETCH0;
      end

      // ======================= CSR and SYSTEM ================================
      // CSR0: if (CSR illegal) goto CSR_ILL else goto CSR1
      CSR0: begin w.jam = J_CSR_ILL; w.next = CSR1; end
      // CSR1: R[rd] = CSR; CSR = new value; PC = PC + 4; retire
      CSR1: begin
        w.csr_exec = 1'b1; w.rf_we = 1'b1; w.wb_src = WBS_CSR;
        w.alu_a = UA_PC; w.alu_b = UB_FOUR; w.pc_we = 1'b1; w.pc_src = PCS_ALU;
        w.retire = 1'b1; w.next = FETCH0;
      end
      CSR_ILL: begin w.trap = 1'b1; w.cause = C_ILL; w.pc_we = 1'b1; w.pc_src = PCS_MTVEC; w.next = FETCH0; end

      ECALL0: begin w.trap = 1'b1; w.cause = C_ECALL; w.pc_we = 1'b1; w.pc_src = PCS_MTVEC; w.next = FETCH0; end
      EBRK0:  begin w.trap = 1'b1; w.cause = C_BRK;   w.pc_we = 1'b1; w.pc_src = PCS_MTVEC; w.next = FETCH0; end
      ILL0:   begin w.trap = 1'b1; w.cause = C_ILL;   w.pc_we = 1'b1; w.pc_src = PCS_MTVEC; w.next = FETCH0; end
      // MRET0: PC = mepc; re-enable interrupts; retire
      MRET0:  begin w.mret = 1'b1; w.pc_we = 1'b1; w.pc_src = PCS_MEPC; w.retire = 1'b1; w.next = FETCH0; end
      // NOP0:  FENCE, FENCE.I, WFI:  PC = PC + 4; retire
      NOP0: begin
        w.alu_a = UA_PC; w.alu_b = UB_FOUR; w.pc_we = 1'b1; w.pc_src = PCS_ALU;
        w.retire = 1'b1; w.next = FETCH0;
      end

      // ======================= interrupt entry ===============================
      // IRQ0: the instruction at PC has NOT started; mepc = PC; PC = mtvec
      IRQ0: begin w.trap = 1'b1; w.cause = C_IRQ; w.pc_we = 1'b1; w.pc_src = PCS_MTVEC; w.next = FETCH0; end

      default: begin w.next = FETCH0; end    // unused words: restart fetch
    endcase
  end

  always_ff @(posedge clk) mir <= w;

endmodule


// =============================================================================
// Dispatch table ("goto MBR" / JMPC, s3 slide 41): instruction -> first
// microinstruction of its routine.
// =============================================================================
 
import rv_pkg::*;
import mc_pkg::*;

module mc_dispatch
(
  input  instr_id_e  id,
  output logic [6:0] addr
);
  always_comb begin
    case (id)
      I_LUI:                                      addr = LUI0;
      I_AUIPC:                                    addr = WB_T;  // T = PC+imm already
      I_JAL:                                      addr = JAL0;
      I_JALR:                                     addr = JALR0;
      I_BEQ, I_BNE, I_BLT, I_BGE, I_BLTU, I_BGEU: addr = BR0;
      I_LB, I_LH, I_LW, I_LBU, I_LHU:             addr = LD0;
      I_SB, I_SH, I_SW:                           addr = ST0;
      I_ADDI, I_SLTI, I_SLTIU, I_XORI, I_ORI, I_ANDI,
      I_SLLI, I_SRLI, I_SRAI:                     addr = OP_I;
      I_ADD, I_SUB, I_SLL, I_SLT, I_SLTU, I_XOR,
      I_SRL, I_SRA, I_OR, I_AND:                  addr = OP_R;
      I_MUL, I_MULH, I_MULHSU, I_MULHU,
      I_DIV, I_DIVU, I_REM, I_REMU:               addr = MD0;
      I_CSRRW, I_CSRRS, I_CSRRC,
      I_CSRRWI, I_CSRRSI, I_CSRRCI:               addr = CSR0;
      I_ECALL:                                    addr = ECALL0;
      I_EBREAK:                                   addr = EBRK0;
      I_MRET:                                     addr = MRET0;
      I_FENCE, I_FENCE_I, I_WFI:                  addr = NOP0;
      default:                                    addr = ILL0;
    endcase
  end
endmodule
