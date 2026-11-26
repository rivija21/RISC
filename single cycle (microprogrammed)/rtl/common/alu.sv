// =============================================================================
// alu.sv  -  32-bit Arithmetic Logic Unit                  (lectures s3, s4)
// -----------------------------------------------------------------------------
// ADD, SUB, SLT and SLTU all use ONE adder:
//   SUB  : a - b = a + ~b + 1     (two's complement, s4)
//   SLTU : a < b (unsigned)  <=>  the subtraction produces NO carry out
//   SLT  : a < b (signed)    <=>  sign(a-b) XOR overflow
//          overflow of a-b happens when a and b have different signs and the
//          result's sign differs from a's sign (s4 "overflow rule").
// Flags (s4 slide "ALU"): zero, negative, overflow are also produced.  The
// RISC-V ISA has no flag register, so the cores do not use them, but they
// are here to match the ALU symbol in the notes.
// =============================================================================
module alu
  import rv_pkg::*;
#(
  parameter bit USE_CLA = 1'b1        // 1: s4 CLA adder, 0: Quartus "+" operator
)(
  input  logic [31:0] a,
  input  logic [31:0] b,
  input  alu_op_e     op,
  output logic [31:0] y,
  output logic        zero,           // y == 0
  output logic        negative,       // y[31]
  output logic        overflow        // signed overflow of the add/sub
);

  // ---- shared adder / subtractor -------------------------------------------
  logic        is_sub;                // subtract for SUB, SLT, SLTU
  logic [31:0] b_in, sum;
  logic        cout;

  assign is_sub = (op == ALU_SUB) || (op == ALU_SLT) || (op == ALU_SLTU);
  assign b_in   = is_sub ? ~b : b;    // invert B, and carry-in = 1 below

  generate
    if (USE_CLA) begin : g_cla
      cla_adder u_add (.a(a), .b(b_in), .cin(is_sub), .sum(sum), .cout(cout));
    end else begin : g_plus
      assign {cout, sum} = {1'b0, a} + {1'b0, b_in} + {32'b0, is_sub};
    end
  endgenerate

  // Signed overflow: operands (as seen by the adder) have the same sign
  // but the sum has a different sign.
  assign overflow = (a[31] == b_in[31]) && (sum[31] != a[31]);

  logic lt_signed, lt_unsigned;
  assign lt_signed   = sum[31] ^ overflow;
  assign lt_unsigned = ~cout;

  // ---- result multiplexer ---------------------------------------------------
  always_comb begin
    case (op)
      ALU_ADD, ALU_SUB: y = sum;
      ALU_SLT:          y = {31'b0, lt_signed};
      ALU_SLTU:         y = {31'b0, lt_unsigned};
      ALU_XOR:          y = a ^ b;
      ALU_OR:           y = a | b;
      ALU_AND:          y = a & b;
      ALU_SLL:          y = a << b[4:0];                    // only 5 bits used
      ALU_SRL:          y = a >> b[4:0];
      ALU_SRA:          y = $unsigned($signed(a) >>> b[4:0]);
      default:          y = sum;
    endcase
  end

  assign zero     = (y == 32'b0);
  assign negative = y[31];

endmodule


// =============================================================================
// regfile  -  32 x 32-bit register file, 2 read ports, 1 write port  (s2, s3)
// -----------------------------------------------------------------------------
// * x0 always reads as zero; writes to x0 are ignored.
// * Reads are combinational (level), the write happens on the rising clock
//   edge (edge triggered) - the same timing convention as s3 slide 32.
// * BYPASS=1 makes a read return the value being written in the same cycle.
//   The pipeline needs this: WB writes in the same cycle ID reads (in the
//   textbook this is "write in the first half, read in the second half").
// =============================================================================
module regfile #(
  parameter bit BYPASS = 1'b0
)(
  input  logic        clk,
  input  logic [4:0]  ra1, ra2,       // read addresses (rs1, rs2)
  output logic [31:0] rd1, rd2,       // read data
  input  logic        we,             // write enable
  input  logic [4:0]  wa,             // write address (rd)
  input  logic [31:0] wd              // write data
);
  logic [31:0] regs [1:31];           // x1..x31; x0 is not stored

  always_ff @(posedge clk)
    if (we && wa != 5'd0) regs[wa] <= wd;

  always_comb begin
    rd1 = (ra1 == 5'd0) ? 32'b0 : regs[ra1];
    rd2 = (ra2 == 5'd0) ? 32'b0 : regs[ra2];
    if (BYPASS) begin
      if (we && wa != 5'd0 && wa == ra1) rd1 = wd;
      if (we && wa != 5'd0 && wa == ra2) rd2 = wd;
    end
  end
endmodule


// =============================================================================
// imm_gen  -  immediate generator                             (s2 slide 53)
// -----------------------------------------------------------------------------
// The immediate bits are scattered in the instruction so that the sign bit is
// ALWAYS instr[31] and most bits stay in the same place across formats.
// Hardware then only "re-routes wires" (s3 slide 62); instr[31] is replicated
// for sign extension.
// =============================================================================
module imm_gen
  import rv_pkg::*;
(
  input  logic [31:0] instr,
  input  imm_e        sel,
  output logic [31:0] imm
);
  always_comb begin
    case (sel)
      IMM_I: imm = {{21{instr[31]}}, instr[30:20]};
      IMM_S: imm = {{21{instr[31]}}, instr[30:25], instr[11:7]};
      IMM_B: imm = {{20{instr[31]}}, instr[7], instr[30:25], instr[11:8], 1'b0};
      IMM_U: imm = {instr[31:12], 12'b0};
      IMM_J: imm = {{12{instr[31]}}, instr[19:12], instr[20], instr[30:21], 1'b0};
      default: imm = 32'b0;
    endcase
  end
endmodule


// =============================================================================
// branch_unit  -  evaluates the branch condition from funct3       (s2, s3)
// =============================================================================
module branch_unit (
  input  logic [2:0]  funct3,
  input  logic [31:0] a,              // rs1
  input  logic [31:0] b,              // rs2
  output logic        taken
);
  always_comb begin
    case (funct3)
      3'b000:  taken = (a == b);                       // BEQ
      3'b001:  taken = (a != b);                       // BNE
      3'b100:  taken = ($signed(a) <  $signed(b));     // BLT
      3'b101:  taken = ($signed(a) >= $signed(b));     // BGE
      3'b110:  taken = (a <  b);                       // BLTU
      3'b111:  taken = (a >= b);                       // BGEU
      default: taken = 1'b0;
    endcase
  end
endmodule
