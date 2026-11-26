// =============================================================================
// sc_core.sv  -  SINGLE-CYCLE RV32I core                (s3 slides 47-72)
// -----------------------------------------------------------------------------
// Every instruction completes in ONE clock cycle (CPI = 1).  The whole path
//
//   PC -> instruction memory -> decode/control -> register file -> ALU
//      -> data memory -> write-back mux -> register file
//
// is combinational between two clock edges, so the clock period must cover
// the slowest instruction (the load: s3 slide 72, s3-II slide 2).  The
// Timing Analyzer in Quartus shows you this critical path.
//
// Separate instruction and data ports are needed because one memory cannot
// be read twice in one cycle (s3 slide 63).  Here both ports look into the
// same RAM array (mem_dp_async), so code and data share one address space.
//
// CTRL_ROM selects the control unit:
//   1 = microprogrammed ROM (control_rom.sv, s3 slide 71)
//   0 = hardwired logic     (control_hardwired.sv)
// The datapath is identical in both cases.
//
// Supported: RV32I + Zicsr + M-mode traps and the timer interrupt.
// RV32M is NOT in this core: the Booth/restoring units need ~33 cycles,
// which contradicts "one instruction per cycle".  (MUL/DIV here raise an
// illegal-instruction exception; the compiler targets rv32i for this core.)
// =============================================================================
module sc_core
  import rv_pkg::*;
#(
  parameter bit          CTRL_ROM = 1'b1,
  parameter logic [31:0] RESET_PC = 32'h0000_0000
)(
  input  logic        clk,
  input  logic        rst,
  // instruction memory port (read only, asynchronous)
  output logic [31:0] imem_addr,
  input  logic [31:0] imem_rdata,
  // data memory port
  output logic [31:0] dmem_addr,
  output logic        dmem_we,
  output logic [3:0]  dmem_be,
  output logic [31:0] dmem_wdata,
  input  logic [31:0] dmem_rdata,
  // interrupts and time
  input  logic        mtip,
  input  logic        meip,
  input  logic [63:0] mtime,
  // debug
  output logic        retire_o,          // 1 when an instruction completes
  output logic [31:0] pc_o
);

  // ===========================================================================
  // 1. FETCH : PC register and instruction memory
  // ===========================================================================
  logic [31:0] pc, pc_next, pc_plus4;
  logic [31:0] instr;

  always_ff @(posedge clk)
    if (rst) pc <= RESET_PC;
    else     pc <= pc_next;

  assign imem_addr = pc;
  assign instr     = imem_rdata;
  assign pc_plus4  = pc + 32'd4;          // "increment by 4" (s3 slide 56)

  // ===========================================================================
  // 2. DECODE : control unit, register file, immediate
  // ===========================================================================
  ctrl_t ctrl;

  generate
    if (CTRL_ROM) begin : g_ctrl_rom
      instr_id_e id_unused;
      control_rom #(.HAS_M(1'b0)) u_ctrl (.instr(instr), .ctrl(ctrl), .id(id_unused));
    end else begin : g_ctrl_hw
      control_hardwired #(.HAS_M(1'b0)) u_ctrl (.instr(instr), .ctrl(ctrl));
    end
  endgenerate

  logic [4:0]  rs1, rs2, rd;
  logic [2:0]  funct3;
  assign rs1    = instr[19:15];
  assign rs2    = instr[24:20];
  assign rd     = instr[11:7];
  assign funct3 = instr[14:12];

  logic [31:0] rs1_val, rs2_val, wb_data, imm;
  logic        rf_we;

  regfile #(.BYPASS(1'b0)) u_rf (
    .clk, .ra1(rs1), .ra2(rs2), .rd1(rs1_val), .rd2(rs2_val),
    .we(rf_we), .wa(rd), .wd(wb_data)
  );

  imm_gen u_imm (.instr(instr), .sel(ctrl.imm_type), .imm(imm));

  // ===========================================================================
  // 3. EXECUTE : ALU and branch comparator
  // ===========================================================================
  logic [31:0] alu_a, alu_b, alu_y;
  logic        z_unused, n_unused, v_unused;

  always_comb begin
    case (ctrl.a_sel)
      A_PC:    alu_a = pc;
      A_ZERO:  alu_a = 32'b0;
      default: alu_a = rs1_val;
    endcase
    alu_b = (ctrl.b_sel == B_IMM) ? imm : rs2_val;
  end

  alu u_alu (.a(alu_a), .b(alu_b), .op(ctrl.alu_op), .y(alu_y),
             .zero(z_unused), .negative(n_unused), .overflow(v_unused));

  logic br_cond;
  branch_unit u_br (.funct3(funct3), .a(rs1_val), .b(rs2_val), .taken(br_cond));

  // The ALU computes every jump/branch target:
  //   JAL, branches : PC + imm      JALR : rs1 + imm, then bit 0 cleared
  logic        take_jump;
  logic [31:0] target;
  assign take_jump = ctrl.jal || ctrl.jalr || (ctrl.branch && br_cond);
  assign target    = {alu_y[31:1], 1'b0};

  // ===========================================================================
  // 4. MEMORY : load / store through the data port
  // ===========================================================================
  logic [35:0] st;                         // {byte enables, aligned data}
  assign st = lsu_store(rs2_val, alu_y[1:0], funct3);

  assign dmem_addr  = alu_y;
  assign dmem_wdata = st[31:0];
  assign dmem_be    = st[35:32];

  logic [31:0] load_val;
  assign load_val = lsu_load(dmem_rdata, alu_y[1:0], funct3);

  // ===========================================================================
  // 5. CSRs, EXCEPTIONS and INTERRUPTS  (s6: the CPU side of the OS)
  // ===========================================================================
  logic [31:0] csr_rdata, mtvec, mepc, irq_cause;
  logic        csr_illegal, irq_pending;
  logic        csr_wr_intent;
  logic [31:0] csr_src;

  // CSRRW(I) always writes; CSRRS/C(I) only if the rs1 field / uimm != 0
  assign csr_wr_intent = (funct3[1:0] == 2'b01) || (rs1 != 5'd0);
  assign csr_src       = funct3[2] ? {27'b0, rs1} : rs1_val;   // uimm or rs1

  // --- synchronous exceptions caused by THIS instruction ---
  logic        exc;
  logic [31:0] exc_cause, exc_tval;
  always_comb begin
    exc       = 1'b1;
    exc_tval  = 32'b0;
    if (ctrl.illegal || (ctrl.csr && csr_illegal)) begin
      exc_cause = CAUSE_ILLEGAL_INSTR;    exc_tval = instr;
    end else if (ctrl.ecall) begin
      exc_cause = CAUSE_ECALL_M;
    end else if (ctrl.ebreak) begin
      exc_cause = CAUSE_BREAKPOINT;
    end else if (take_jump && target[1]) begin      // target not 4-aligned
      exc_cause = CAUSE_INSTR_MISALIGNED; exc_tval = target;
    end else if (ctrl.mem_read && lsu_misaligned(alu_y[1:0], funct3)) begin
      exc_cause = CAUSE_LOAD_MISALIGNED;  exc_tval = alu_y;
    end else if (ctrl.mem_write && lsu_misaligned(alu_y[1:0], funct3)) begin
      exc_cause = CAUSE_STORE_MISALIGNED; exc_tval = alu_y;
    end else begin
      exc       = 1'b0;
      exc_cause = 32'b0;
    end
  end

  // --- trap = interrupt (checked before the instruction runs) or exception
  //     An interrupted instruction is simply not executed; mepc = its PC,
  //     and MRET later re-executes it.
  logic        trap;
  logic [31:0] trap_cause, trap_tval;
  assign trap       = irq_pending || exc;
  assign trap_cause = irq_pending ? irq_cause : exc_cause;
  assign trap_tval  = irq_pending ? 32'b0     : exc_tval;

  // --- an instruction COMMITS (changes state) only if there is no trap ---
  logic commit;
  assign commit = !trap;

  csr_unit #(.HAS_M(1'b0)) u_csr (
    .clk, .rst,
    .csr_addr(instr[31:20]), .csr_cmd(funct3[1:0]), .csr_src(csr_src),
    .csr_wr_intent(csr_wr_intent), .csr_commit(ctrl.csr && commit),
    .csr_rdata(csr_rdata), .csr_illegal(csr_illegal),
    .trap_take(trap), .trap_cause(trap_cause), .trap_epc(pc), .trap_tval(trap_tval),
    .mret_take(ctrl.mret && commit),
    .mtvec_o(mtvec), .mepc_o(mepc),
    .retire(commit), .mtime(mtime), .mtip(mtip), .meip(meip),
    .irq_pending(irq_pending), .irq_cause(irq_cause)
  );

  // ===========================================================================
  // 6. WRITE BACK and NEXT PC
  // ===========================================================================
  always_comb begin
    case (ctrl.wb_sel)
      WB_MEM:  wb_data = load_val;
      WB_PC4:  wb_data = pc_plus4;
      WB_CSR:  wb_data = csr_rdata;
      default: wb_data = alu_y;
    endcase
  end

  assign rf_we   = ctrl.reg_write && commit;
  assign dmem_we = ctrl.mem_write && commit;

  always_comb begin
    if (trap)                       pc_next = mtvec;       // enter the handler
    else if (ctrl.mret)             pc_next = mepc;        // return from it
    else if (take_jump)             pc_next = target;
    else                            pc_next = pc_plus4;
  end

  assign retire_o = commit;
  assign pc_o     = pc;

endmodule
