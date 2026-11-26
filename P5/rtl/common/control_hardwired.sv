// =============================================================================
// control_hardwired.sv  -  HARDWIRED control unit          (s3 slides 15, 18, 70)
// -----------------------------------------------------------------------------
// "Control signals are generated in real time with the opcode and the
//  different elements of the instruction as inputs." (s3 slide 15)
//
// There is no table of stored words.  Each control signal is a Boolean
// function of opcode / funct3 / funct7, written here as case statements.
// Quartus reduces them to gates (LUTs), exactly the "truth table -> K-map ->
// gates" route of s3 slide 16.
//
// The output is the same ctrl_t word that control_rom.sv produces, bit for
// bit, for every possible 32-bit instruction.  tb_control_equiv.sv checks it.
//
// Why the pipeline uses this one: in a pipeline each stage holds a different
// instruction, so the control word is generated once in ID and then travels
// down the pipeline registers with its instruction.  A combinational decoder
// is the natural fit for that.
// =============================================================================
module control_hardwired
  import rv_pkg::*;
#(
  parameter bit HAS_M = 1'b1
)(
  input  logic [31:0] instr,
  output ctrl_t       ctrl
);
  logic [6:0] opc;
  logic [2:0] f3;
  logic [6:0] f7;
  assign opc = instr[6:0];
  assign f3  = instr[14:12];
  assign f7  = instr[31:25];

  always_comb begin
    // Default = the NOP word with every enable at 0.  Individual signals are
    // then switched on per instruction class.
    ctrl          = '0;
    ctrl.a_sel    = A_RS1;
    ctrl.b_sel    = B_RS2;
    ctrl.alu_op   = ALU_ADD;
    ctrl.imm_type = IMM_I;
    ctrl.wb_sel   = WB_ALU;

    case (opc)
      // ---------------------------------------------------------------- U type
      OPC_LUI: begin                          // rd = 0 + imm
        ctrl.reg_write = 1'b1;
        ctrl.a_sel = A_ZERO;  ctrl.b_sel = B_IMM;  ctrl.imm_type = IMM_U;
      end
      OPC_AUIPC: begin                        // rd = PC + imm
        ctrl.reg_write = 1'b1;
        ctrl.a_sel = A_PC;    ctrl.b_sel = B_IMM;  ctrl.imm_type = IMM_U;
      end
      // ---------------------------------------------------------------- jumps
      OPC_JAL: begin                          // rd = PC+4 ; PC = PC + imm
        ctrl.reg_write = 1'b1; ctrl.jal = 1'b1;  ctrl.wb_sel = WB_PC4;
        ctrl.a_sel = A_PC;     ctrl.b_sel = B_IMM; ctrl.imm_type = IMM_J;
      end
      OPC_JALR: begin                         // rd = PC+4 ; PC = (rs1+imm)&~1
        if (f3 == 3'b000) begin
          ctrl.reg_write = 1'b1; ctrl.jalr = 1'b1; ctrl.wb_sel = WB_PC4;
          ctrl.b_sel = B_IMM;
        end else ctrl.illegal = 1'b1;
      end
      // -------------------------------------------------------------- branches
      OPC_BRANCH: begin                       // ALU computes the target PC+imm
        if (f3 == 3'b010 || f3 == 3'b011) ctrl.illegal = 1'b1;
        else begin
          ctrl.branch = 1'b1;
          ctrl.a_sel = A_PC;  ctrl.b_sel = B_IMM;  ctrl.imm_type = IMM_B;
        end
      end
      // ---------------------------------------------------------- loads/stores
      OPC_LOAD: begin                         // address = rs1 + imm
        if (f3 == 3'b011 || f3 == 3'b110 || f3 == 3'b111) ctrl.illegal = 1'b1;
        else begin
          ctrl.reg_write = 1'b1; ctrl.mem_read = 1'b1; ctrl.wb_sel = WB_MEM;
          ctrl.b_sel = B_IMM;
        end
      end
      OPC_STORE: begin
        if (f3[2] || f3 == 3'b011) ctrl.illegal = 1'b1;
        else begin
          ctrl.mem_write = 1'b1;
          ctrl.b_sel = B_IMM;  ctrl.imm_type = IMM_S;
        end
      end
      // ------------------------------------------------------------ ALU + imm
      OPC_OP_IMM: begin
        // shifts need funct7 = 0000000 (SLLI, SRLI) or 0100000 (SRAI)
        if ((f3 == 3'b001 && f7 != 7'b0000000) ||
            (f3 == 3'b101 && f7 != 7'b0000000 && f7 != 7'b0100000))
          ctrl.illegal = 1'b1;
        else begin
          ctrl.reg_write = 1'b1;
          ctrl.b_sel  = B_IMM;
          ctrl.alu_op = alu_op_from_ir(instr);
        end
      end
      // ----------------------------------------------------------- ALU reg-reg
      OPC_OP: begin
        if (f7 == 7'b0000000 ||
            (f7 == 7'b0100000 && (f3 == 3'b000 || f3 == 3'b101))) begin
          ctrl.reg_write = 1'b1;
          ctrl.alu_op    = alu_op_from_ir(instr);
        end else if (f7 == 7'b0000001 && HAS_M) begin     // RV32M
          ctrl.reg_write = 1'b1;
          ctrl.muldiv    = 1'b1;
          ctrl.wb_sel    = WB_MD;
        end else ctrl.illegal = 1'b1;
      end
      // ------------------------------------------------------------ FENCE(.I)
      OPC_MISC_MEM: begin
        if (f3[2:1] != 2'b00) ctrl.illegal = 1'b1;   // only 000 and 001 legal
        // else: NOP control word
      end
      // --------------------------------------------------------------- SYSTEM
      OPC_SYSTEM: begin
        if (f3 == 3'b000) begin
          if      (instr == 32'h0000_0073) ctrl.ecall  = 1'b1;
          else if (instr == 32'h0010_0073) ctrl.ebreak = 1'b1;
          else if (instr == 32'h3020_0073) ctrl.mret   = 1'b1;
          else if (instr == 32'h1050_0073) ;           // WFI: NOP
          else ctrl.illegal = 1'b1;
        end else if (f3 == 3'b100) begin
          ctrl.illegal = 1'b1;
        end else begin                                 // CSRRW/S/C(I)
          ctrl.reg_write = 1'b1;
          ctrl.csr       = 1'b1;
          ctrl.wb_sel    = WB_CSR;
        end
      end
      default: ctrl.illegal = 1'b1;
    endcase

    // An illegal instruction must not enable anything.
    if (instr[1:0] != 2'b11) ctrl.illegal = 1'b1;
    if (ctrl.illegal) begin
      ctrl          = '0;
      ctrl.illegal  = 1'b1;
      ctrl.a_sel    = A_RS1;
      ctrl.b_sel    = B_RS2;
      ctrl.alu_op   = ALU_ADD;
      ctrl.imm_type = IMM_I;
      ctrl.wb_sel   = WB_ALU;
    end
  end

endmodule
