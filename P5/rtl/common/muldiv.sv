// =============================================================================
// muldiv.sv  -  RV32M multiply / divide unit                      (lecture s4)
// -----------------------------------------------------------------------------
// Contains three modules:
//   booth_mul      : sequential radix-2 Booth multiplier, 1 bit per clock
//   restoring_div  : sequential restoring divider,       1 bit per clock
//   muldiv         : wrapper that decodes funct3 and handles signs
//
// Handshake used by the cores:
//   start (1 cycle)  ->  busy = 1 for ~33 cycles  ->  valid = 1, result held
//   'valid' stays 1 until the next start.  'abort' returns to idle at once
//   (used by the pipeline when the instruction is flushed by a trap).
//
// Why sequential?  s4 "Multiplication hardware": the shift-and-add
// multiplier needs one add per multiplier bit.  Doing all 32 adds in one
// cycle needs 32 adders in series (a huge, slow circuit).  Doing one add per
// clock re-uses a single adder, at the cost of ~33 clocks per operation.
// (Cyclone V also has hard 27x27 DSP multipliers; Quartus would use them for
// a plain "a*b".  Here the algorithm itself is the point.)
// =============================================================================


// -----------------------------------------------------------------------------
// booth_mul  -  Booth's algorithm for two's complement numbers  (s4 "Booth")
// -----------------------------------------------------------------------------
// Registers (names as in Stallings / the lecture notes):
//   M   multiplicand
//   Q   multiplier (shifted right each step)
//   Q_1 the bit shifted out of Q last step  (Q_-1, initially 0)
//   A   accumulator (upper half of the product)
//
// Each step looks at the pair {Q[0], Q_1}:
//   0 0 / 1 1 : inside a run of equal bits  -> no operation
//   1 0       : a run of 1s starts          -> A = A - M
//   0 1       : a run of 1s ends            -> A = A + M
// then shifts {A, Q, Q_1} ARITHMETICALLY right by one.
// After N steps {A, Q} holds the 2N-bit product.
//
// RISC-V needs signed x signed (MULH), signed x unsigned (MULHSU) and
// unsigned x unsigned (MULHU).  Trick: extend both 32-bit operands to 33
// bits (sign extension if signed, zero extension if unsigned).  Every case
// is then a signed 33 x 33 multiplication, which Booth handles directly.
// A gets one extra guard bit (34 bits) so A +/- M never overflows.
// -----------------------------------------------------------------------------
module booth_mul (
  input  logic        clk,
  input  logic        rst,
  input  logic        start,
  input  logic        abort,
  input  logic [31:0] a,            // multiplicand (rs1)
  input  logic [31:0] b,            // multiplier   (rs2)
  input  logic        a_signed,
  input  logic        b_signed,
  output logic        busy,
  output logic        done,         // 1-cycle pulse when the product is ready
  output logic [63:0] product
);
  localparam int N = 33;            // operand width after extension

  logic [N:0]   A;                  // 34 bits: accumulator + guard bit
  logic [N:0]   M;                  // multiplicand, sign-extended to 34 bits
  logic [N-1:0] Q;                  // 33-bit multiplier
  logic         Q_1;
  logic [5:0]   count;              // steps remaining

  logic [N:0] A_next;               // A after the add/subtract of this step
  always_comb begin
    case ({Q[0], Q_1})
      2'b10:   A_next = A - M;      // start of a run of 1s
      2'b01:   A_next = A + M;      // end of a run of 1s
      default: A_next = A;          // 00 or 11: nothing
    endcase
  end

  always_ff @(posedge clk) begin
    done <= 1'b0;
    if (rst || abort) begin
      busy <= 1'b0;
    end else if (start) begin
      // load: A = 0, M = extended a, Q = extended b, Q_1 = 0
      A     <= '0;
      M     <= {{2{a_signed & a[31]}}, a};
      Q     <= {b_signed & b[31], b};
      Q_1   <= 1'b0;
      count <= 6'd33;                 // N = 33 steps
      busy  <= 1'b1;
    end else if (busy) begin
      // arithmetic shift right of the combined register {A_next, Q, Q_1}
      A     <= {A_next[N], A_next[N:1]};
      Q     <= {A_next[0], Q[N-1:1]};
      Q_1   <= Q[0];
      count <= count - 6'd1;
      if (count == 6'd1) begin
        busy <= 1'b0;
        done <= 1'b1;
      end
    end
  end

  // {A,Q} is the 67-bit signed product; the low 64 bits are what RISC-V needs
  assign product = {A[30:0], Q};

endmodule


// -----------------------------------------------------------------------------
// restoring_div  -  unsigned restoring division       (s4 "Division hardware")
// -----------------------------------------------------------------------------
// Pencil-and-paper long division in binary, one quotient bit per clock:
//   R:Q <<= 1           shift the next dividend bit into the remainder
//   T = R - D           trial subtraction
//   if T >= 0 : R = T, quotient bit = 1
//   else      :        quotient bit = 0  ("restore": keep the old R)
// After 32 steps Q = quotient, R = remainder.
// -----------------------------------------------------------------------------
module restoring_div (
  input  logic        clk,
  input  logic        rst,
  input  logic        start,
  input  logic        abort,
  input  logic [31:0] dividend,
  input  logic [31:0] divisor,
  output logic        busy,
  output logic        done,
  output logic [31:0] quotient,
  output logic [31:0] remainder
);
  logic [32:0] R;                   // 33 bits so the trial result has a sign
  logic [31:0] Q, D;
  logic [5:0]  count;

  logic [32:0] R_shift, T;
  assign R_shift = {R[31:0], Q[31]};   // shift left, bring in next dividend bit
  assign T       = R_shift - {1'b0, D};

  always_ff @(posedge clk) begin
    done <= 1'b0;
    if (rst || abort) begin
      busy <= 1'b0;
    end else if (start) begin
      R     <= '0;
      Q     <= dividend;
      D     <= divisor;
      count <= 6'd32;
      busy  <= 1'b1;
    end else if (busy) begin
      if (!T[32]) begin             // T >= 0 : subtraction succeeds
        R <= T;
        Q <= {Q[30:0], 1'b1};
      end else begin                // T < 0  : restore (keep shifted R)
        R <= R_shift;
        Q <= {Q[30:0], 1'b0};
      end
      count <= count - 6'd1;
      if (count == 6'd1) begin
        busy <= 1'b0;
        done <= 1'b1;
      end
    end
  end

  assign quotient  = Q;
  assign remainder = R[31:0];

endmodule


// -----------------------------------------------------------------------------
// muldiv  -  RV32M front end
// -----------------------------------------------------------------------------
// funct3: 000 MUL    001 MULH   010 MULHSU  011 MULHU
//         100 DIV    101 DIVU   110 REM     111 REMU
// Signed division is done on magnitudes, then the signs are fixed:
//   quotient sign  = sign(a) XOR sign(b)
//   remainder sign = sign(a)                 (RISC-V rounds toward zero)
// Special cases required by the RISC-V spec (no exception is raised):
//   x / 0         -> quotient = all ones, remainder = x
//   -2^31 / -1    -> quotient = -2^31,   remainder = 0  (falls out naturally)
// -----------------------------------------------------------------------------
module muldiv (
  input  logic        clk,
  input  logic        rst,
  input  logic        start,
  input  logic        abort,
  input  logic [2:0]  funct3,
  input  logic [31:0] a,            // rs1
  input  logic [31:0] b,            // rs2
  output logic        busy,
  output logic        valid,        // result valid (held until next start)
  output logic [31:0] result
);
  // ---------------- latch the operation at start -----------------------------
  logic [2:0] f3_q;
  logic       neg_q, neg_r, div0;
  logic [31:0] a_q;

  logic is_div, a_sgn, b_sgn;
  assign is_div = funct3[2];
  // which operands are signed?
  assign a_sgn  = (funct3 == 3'b001) || (funct3 == 3'b010) ||   // MULH, MULHSU
                  (funct3 == 3'b100) || (funct3 == 3'b110);     // DIV, REM
  assign b_sgn  = (funct3 == 3'b001) ||                          // MULH
                  (funct3 == 3'b100) || (funct3 == 3'b110);     // DIV, REM

  logic [31:0] a_mag, b_mag;        // magnitudes for signed division
  assign a_mag = (a_sgn && a[31]) ? -a : a;
  assign b_mag = (b_sgn && b[31]) ? -b : b;

  // ---------------- the two sequential units ---------------------------------
  logic        m_busy, m_done, d_busy, d_done;
  logic [63:0] prod;
  logic [31:0] quo, rem;

  booth_mul u_mul (
    .clk, .rst, .abort,
    .start(start && !is_div),
    .a, .b, .a_signed(a_sgn), .b_signed(b_sgn),
    .busy(m_busy), .done(m_done), .product(prod)
  );

  restoring_div u_div (
    .clk, .rst, .abort,
    .start(start && is_div),
    .dividend(a_mag), .divisor(b_mag),
    .busy(d_busy), .done(d_done), .quotient(quo), .remainder(rem)
  );

  always_ff @(posedge clk) begin
    if (rst || abort) begin
      valid <= 1'b0;
    end else if (start) begin
      valid <= 1'b0;
      f3_q  <= funct3;
      a_q   <= a;
      div0  <= (b == 32'b0);
      neg_q <= a_sgn && (a[31] ^ b[31]);
      neg_r <= a_sgn && a[31];
    end else if (m_done || d_done) begin
      valid <= 1'b1;
    end
  end

  assign busy = m_busy || d_busy;

  // ---------------- select / fix up the result -------------------------------
  always_comb begin
    case (f3_q)
      3'b000:  result = prod[31:0];                         // MUL
      3'b001,
      3'b010,
      3'b011:  result = prod[63:32];                        // MULH, MULHSU, MULHU
      3'b100,
      3'b101:  result = div0  ? 32'hFFFF_FFFF              // DIV, DIVU
                       : (neg_q ? -quo : quo);
      default: result = div0  ? a_q                         // REM, REMU
                       : (neg_r ? -rem : rem);
    endcase
  end

endmodule
