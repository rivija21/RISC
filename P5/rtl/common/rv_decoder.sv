// =============================================================================
// rv_decoder.sv  -  instruction word  ->  instruction ID      (s2, s3 slide 71)
// -----------------------------------------------------------------------------
// This is the "Address Decoder" box of s3 slide 71 (microprogrammed control
// for the single-cycle RISC-V).  It recognises which instruction the 32-bit
// word is and outputs a small number (instr_id_e).  That number is then used
//   * as the ROM address of the control store      (control_rom.sv)
//   * as the input of the dispatch table            (core_mc, "goto MBR")
//
// It also performs the full legality check.  Anything that is not a legal
// RV32I (+ RV32M if HAS_M) encoding becomes I_ILLEGAL, which later raises an
// "illegal instruction" exception (cause 2).
// =============================================================================
module rv_decoder
  import rv_pkg::*;
#(
  parameter bit HAS_M = 1'b1           // accept the RV32M instructions?
)(
  input  logic [31:0] instr,
  output instr_id_e   id
);
  logic [6:0] opc;
  logic [2:0] f3;
  logic [6:0] f7;

  assign opc = instr[6:0];
  assign f3  = instr[14:12];
  assign f7  = instr[31:25];

  always_comb begin
    id = I_ILLEGAL;                    // default: not recognised
    case (opc)
      OPC_LUI:   id = I_LUI;
      OPC_AUIPC: id = I_AUIPC;
      OPC_JAL:   id = I_JAL;
      OPC_JALR:  if (f3 == 3'b000) id = I_JALR;

      OPC_BRANCH:
        case (f3)
          3'b000: id = I_BEQ;   3'b001: id = I_BNE;
          3'b100: id = I_BLT;   3'b101: id = I_BGE;
          3'b110: id = I_BLTU;  3'b111: id = I_BGEU;
          default: id = I_ILLEGAL;
        endcase

      OPC_LOAD:
        case (f3)
          3'b000: id = I_LB;    3'b001: id = I_LH;   3'b010: id = I_LW;
          3'b100: id = I_LBU;   3'b101: id = I_LHU;
          default: id = I_ILLEGAL;
        endcase

      OPC_STORE:
        case (f3)
          3'b000: id = I_SB;    3'b001: id = I_SH;   3'b010: id = I_SW;
          default: id = I_ILLEGAL;
        endcase

      OPC_OP_IMM:
        case (f3)
          3'b000: id = I_ADDI;  3'b010: id = I_SLTI;  3'b011: id = I_SLTIU;
          3'b100: id = I_XORI;  3'b110: id = I_ORI;   3'b111: id = I_ANDI;
          // shifts by an immediate: shamt = instr[24:20], funct7 must match
          3'b001: if (f7 == 7'b0000000) id = I_SLLI;
          3'b101: if (f7 == 7'b0000000) id = I_SRLI;
                  else if (f7 == 7'b0100000) id = I_SRAI;
          default: id = I_ILLEGAL;
        endcase

      OPC_OP:
        if (f7 == 7'b0000000)
          case (f3)
            3'b000: id = I_ADD;  3'b001: id = I_SLL;  3'b010: id = I_SLT;
            3'b011: id = I_SLTU; 3'b100: id = I_XOR;  3'b101: id = I_SRL;
            3'b110: id = I_OR;   default: id = I_AND;
          endcase
        else if (f7 == 7'b0100000) begin
          if (f3 == 3'b000) id = I_SUB;
          else if (f3 == 3'b101) id = I_SRA;
        end
        else if (f7 == 7'b0000001 && HAS_M)          // RV32M
          case (f3)
            3'b000: id = I_MUL;  3'b001: id = I_MULH;
            3'b010: id = I_MULHSU; 3'b011: id = I_MULHU;
            3'b100: id = I_DIV;  3'b101: id = I_DIVU;
            3'b110: id = I_REM;  default: id = I_REMU;
          endcase

      OPC_MISC_MEM:
        if (f3 == 3'b000) id = I_FENCE;
        else if (f3 == 3'b001) id = I_FENCE_I;

      OPC_SYSTEM:
        case (f3)
          3'b000:                                      // exact encodings only
            if      (instr == 32'h0000_0073) id = I_ECALL;
            else if (instr == 32'h0010_0073) id = I_EBREAK;
            else if (instr == 32'h3020_0073) id = I_MRET;
            else if (instr == 32'h1050_0073) id = I_WFI;
          3'b001: id = I_CSRRW;   3'b010: id = I_CSRRS;   3'b011: id = I_CSRRC;
          3'b101: id = I_CSRRWI;  3'b110: id = I_CSRRSI;  3'b111: id = I_CSRRCI;
          default: id = I_ILLEGAL;
        endcase

      default: id = I_ILLEGAL;
    endcase

    // Base ISA: the two lowest opcode bits must be 11 (s3 slide 51)
    if (instr[1:0] != 2'b11) id = I_ILLEGAL;
  end

endmodule
