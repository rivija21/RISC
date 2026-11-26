// =============================================================================
// control_rom.sv  -  MICROPROGRAMMED control unit            (s3 slides 17, 71)
// -----------------------------------------------------------------------------
// Structure exactly as on s3 slide 71:
//
//     instruction bits ──► Address Decoder ──► CONTROL STORE (ROM) ──► control word
//                         (rv_decoder.sv)      one row per instruction
//
// Each row of the table below is one pre-computed control word ("Control Word
// for ADD", "Control Word for SUB", ...).  Nothing is computed at run time: the
// instruction only selects which stored row comes out.  That is the defining
// property of microprogrammed control (s3 slide 15): "control signals are
// pre-determined and stored in a control store".
//
// In the single-cycle core every instruction needs exactly ONE control word
// (one microinstruction), so there is no micro-sequencer here.  The
// multi-cycle core (core_mc) shows the full Mic-1 style sequencer with MPC,
// MIR, next-address field and JAM bits.
//
// Implementation note: a combinational ROM is a case table.  Quartus stores
// it in LUTs (a LUT *is* a small ROM).  Compare with control_hardwired.sv,
// which produces the same words from Boolean equations on opcode/funct bits.
// tb/tb_control_equiv.sv proves both units give identical outputs.
// =============================================================================
module control_rom
  import rv_pkg::*;
#(
  parameter bit HAS_M = 1'b1
)(
  input  logic [31:0] instr,
  output ctrl_t       ctrl,
  output instr_id_e   id              // exported for debugging / waveforms
);

  // ---------------- 1. Address decoder ---------------------------------------
  rv_decoder #(.HAS_M(HAS_M)) u_dec (.instr(instr), .id(id));

  // ---------------- 2. Control store ------------------------------------------
  // Column order = field order of ctrl_t (see rv_pkg.sv):
  //  ill rw  a_sel  b_sel  alu_op    imm   mr  mw  wb_sel  br  jal jalr csr ec  eb  mret md
  localparam logic Y = 1'b1, N = 1'b0;

  always_comb begin
    case (id)
      //                ill rw  a_sel   b_sel  alu_op    imm    mr mw wb_sel  br jal jr csr ec eb mr md
      I_LUI   : ctrl = {N,  Y,  A_ZERO, B_IMM, ALU_ADD,  IMM_U, N, N, WB_ALU, N, N,  N, N,  N, N, N, N};
      I_AUIPC : ctrl = {N,  Y,  A_PC,   B_IMM, ALU_ADD,  IMM_U, N, N, WB_ALU, N, N,  N, N,  N, N, N, N};
      I_JAL   : ctrl = {N,  Y,  A_PC,   B_IMM, ALU_ADD,  IMM_J, N, N, WB_PC4, N, Y,  N, N,  N, N, N, N};
      I_JALR  : ctrl = {N,  Y,  A_RS1,  B_IMM, ALU_ADD,  IMM_I, N, N, WB_PC4, N, N,  Y, N,  N, N, N, N};

      I_BEQ, I_BNE, I_BLT, I_BGE, I_BLTU, I_BGEU
              : ctrl = {N,  N,  A_PC,   B_IMM, ALU_ADD,  IMM_B, N, N, WB_ALU, Y, N,  N, N,  N, N, N, N};

      I_LB, I_LH, I_LW, I_LBU, I_LHU
              : ctrl = {N,  Y,  A_RS1,  B_IMM, ALU_ADD,  IMM_I, Y, N, WB_MEM, N, N,  N, N,  N, N, N, N};
      I_SB, I_SH, I_SW
              : ctrl = {N,  N,  A_RS1,  B_IMM, ALU_ADD,  IMM_S, N, Y, WB_ALU, N, N,  N, N,  N, N, N, N};

      I_ADDI  : ctrl = {N,  Y,  A_RS1,  B_IMM, ALU_ADD,  IMM_I, N, N, WB_ALU, N, N,  N, N,  N, N, N, N};
      I_SLTI  : ctrl = {N,  Y,  A_RS1,  B_IMM, ALU_SLT,  IMM_I, N, N, WB_ALU, N, N,  N, N,  N, N, N, N};
      I_SLTIU : ctrl = {N,  Y,  A_RS1,  B_IMM, ALU_SLTU, IMM_I, N, N, WB_ALU, N, N,  N, N,  N, N, N, N};
      I_XORI  : ctrl = {N,  Y,  A_RS1,  B_IMM, ALU_XOR,  IMM_I, N, N, WB_ALU, N, N,  N, N,  N, N, N, N};
      I_ORI   : ctrl = {N,  Y,  A_RS1,  B_IMM, ALU_OR,   IMM_I, N, N, WB_ALU, N, N,  N, N,  N, N, N, N};
      I_ANDI  : ctrl = {N,  Y,  A_RS1,  B_IMM, ALU_AND,  IMM_I, N, N, WB_ALU, N, N,  N, N,  N, N, N, N};
      I_SLLI  : ctrl = {N,  Y,  A_RS1,  B_IMM, ALU_SLL,  IMM_I, N, N, WB_ALU, N, N,  N, N,  N, N, N, N};
      I_SRLI  : ctrl = {N,  Y,  A_RS1,  B_IMM, ALU_SRL,  IMM_I, N, N, WB_ALU, N, N,  N, N,  N, N, N, N};
      I_SRAI  : ctrl = {N,  Y,  A_RS1,  B_IMM, ALU_SRA,  IMM_I, N, N, WB_ALU, N, N,  N, N,  N, N, N, N};

      I_ADD   : ctrl = {N,  Y,  A_RS1,  B_RS2, ALU_ADD,  IMM_I, N, N, WB_ALU, N, N,  N, N,  N, N, N, N};
      I_SUB   : ctrl = {N,  Y,  A_RS1,  B_RS2, ALU_SUB,  IMM_I, N, N, WB_ALU, N, N,  N, N,  N, N, N, N};
      I_SLL   : ctrl = {N,  Y,  A_RS1,  B_RS2, ALU_SLL,  IMM_I, N, N, WB_ALU, N, N,  N, N,  N, N, N, N};
      I_SLT   : ctrl = {N,  Y,  A_RS1,  B_RS2, ALU_SLT,  IMM_I, N, N, WB_ALU, N, N,  N, N,  N, N, N, N};
      I_SLTU  : ctrl = {N,  Y,  A_RS1,  B_RS2, ALU_SLTU, IMM_I, N, N, WB_ALU, N, N,  N, N,  N, N, N, N};
      I_XOR   : ctrl = {N,  Y,  A_RS1,  B_RS2, ALU_XOR,  IMM_I, N, N, WB_ALU, N, N,  N, N,  N, N, N, N};
      I_SRL   : ctrl = {N,  Y,  A_RS1,  B_RS2, ALU_SRL,  IMM_I, N, N, WB_ALU, N, N,  N, N,  N, N, N, N};
      I_SRA   : ctrl = {N,  Y,  A_RS1,  B_RS2, ALU_SRA,  IMM_I, N, N, WB_ALU, N, N,  N, N,  N, N, N, N};
      I_OR    : ctrl = {N,  Y,  A_RS1,  B_RS2, ALU_OR,   IMM_I, N, N, WB_ALU, N, N,  N, N,  N, N, N, N};
      I_AND   : ctrl = {N,  Y,  A_RS1,  B_RS2, ALU_AND,  IMM_I, N, N, WB_ALU, N, N,  N, N,  N, N, N, N};

      I_MUL, I_MULH, I_MULHSU, I_MULHU, I_DIV, I_DIVU, I_REM, I_REMU
              : ctrl = {N,  Y,  A_RS1,  B_RS2, ALU_ADD,  IMM_I, N, N, WB_MD,  N, N,  N, N,  N, N, N, Y};

      // FENCE, FENCE.I and WFI are legal but do nothing in these simple
      // in-order cores (a NOP control word: every enable is 0).
      I_FENCE, I_FENCE_I, I_WFI
              : ctrl = {N,  N,  A_RS1,  B_RS2, ALU_ADD,  IMM_I, N, N, WB_ALU, N, N,  N, N,  N, N, N, N};

      I_ECALL : ctrl = {N,  N,  A_RS1,  B_RS2, ALU_ADD,  IMM_I, N, N, WB_ALU, N, N,  N, N,  Y, N, N, N};
      I_EBREAK: ctrl = {N,  N,  A_RS1,  B_RS2, ALU_ADD,  IMM_I, N, N, WB_ALU, N, N,  N, N,  N, Y, N, N};
      I_MRET  : ctrl = {N,  N,  A_RS1,  B_RS2, ALU_ADD,  IMM_I, N, N, WB_ALU, N, N,  N, N,  N, N, Y, N};

      I_CSRRW, I_CSRRS, I_CSRRC, I_CSRRWI, I_CSRRSI, I_CSRRCI
              : ctrl = {N,  Y,  A_RS1,  B_RS2, ALU_ADD,  IMM_I, N, N, WB_CSR, N, N,  N, Y,  N, N, N, N};

      default : ctrl = {Y,  N,  A_RS1,  B_RS2, ALU_ADD,  IMM_I, N, N, WB_ALU, N, N,  N, N,  N, N, N, N};
    endcase
  end

endmodule
