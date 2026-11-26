// =============================================================================
// cla_adder.sv  -  32-bit two-level Carry Look-Ahead adder     (lecture s4)
// -----------------------------------------------------------------------------
// Ripple adder: carry c[i+1] = g[i] | p[i]&c[i] must pass through all 32
// bit positions, so the delay grows linearly with the width.
//
// CLA idea (s4 "Carry Look Ahead Adder", "CLA logic"):
//   generate   g[i] = a[i] & b[i]     (this bit creates a carry by itself)
//   propagate  p[i] = a[i] ^ b[i]     (this bit passes an incoming carry on)
//   c[i+1] = g[i] | p[i]g[i-1] | p[i]p[i-1]g[i-2] | ... | p[i]..p[0]c[0]
// Every carry is then a two-level AND-OR expression of the inputs.
//
// Doing that for all 32 bits needs very wide gates, so a two-level scheme
// is used:
//   Level 1: eight 4-bit groups.  Each group computes its carries internally
//            and a group generate G and group propagate P:
//              G = g3 | p3g2 | p3p2g1 | p3p2p1g0
//              P = p3p2p1p0
//   Level 2: the carry INTO each group is computed with the same look-ahead
//            formula, but using the group G/P signals instead of bit g/p.
//
// FPGA note: Cyclone V ALMs contain a dedicated hard carry chain.  Quartus
// maps a plain "a + b" onto that chain, which is usually FASTER than a CLA
// built from LUTs.  This module exists to show the s4 circuit; the ALU has a
// parameter to choose between it and the "+" operator, so you can compare
// both in the Timing Analyzer.
// =============================================================================
module cla_adder (
  input  logic [31:0] a,
  input  logic [31:0] b,
  input  logic        cin,     // carry in (1 for subtraction: a + ~b + 1)
  output logic [31:0] sum,
  output logic        cout     // carry out of bit 31
);

  logic [31:0] g, p;           // bit generate / propagate
  logic [7:0]  gg, gp;         // group generate / propagate (level 1 -> 2)
  logic [8:0]  gc;             // carry into each group (gc[8] = cout)
  logic [31:0] c;              // carry into each bit

  assign g = a & b;
  assign p = a ^ b;

  // ---------------- Level 1: group G and P for each 4-bit group -------------
  always_comb begin
    for (int k = 0; k < 8; k++) begin
      gg[k] = g[4*k+3]
            | (p[4*k+3] & g[4*k+2])
            | (p[4*k+3] & p[4*k+2] & g[4*k+1])
            | (p[4*k+3] & p[4*k+2] & p[4*k+1] & g[4*k]);
      gp[k] = p[4*k+3] & p[4*k+2] & p[4*k+1] & p[4*k];
    end
  end

  // ---------------- Level 2: look-ahead across the eight groups --------------
  // gc[j] = gg[j-1] | gp[j-1]gg[j-2] | ... | gp[j-1]..gp[0]cin
  // Written as nested loops; each gc[j] is still a flat sum of products.
  logic term, acc;             // scratch variables of the loop below
  always_comb begin
    gc[0] = cin;
    for (int j = 1; j <= 8; j++) begin
      acc = 1'b0;
      // terms that start with a group generate: gg[k] & gp[k+1] & .. & gp[j-1]
      for (int k = 0; k < 8; k++) begin
        if (k < j) begin
          term = gg[k];
          for (int m = 0; m < 8; m++)
            if (m > k && m < j) term = term & gp[m];
          acc = acc | term;
        end
      end
      // term that starts with the input carry: cin & gp[0] & .. & gp[j-1]
      term = cin;
      for (int m = 0; m < 8; m++)
        if (m < j) term = term & gp[m];
      gc[j] = acc | term;
    end
  end

  // ---------------- Carries inside each group (4-bit look-ahead) -------------
  always_comb begin
    for (int k = 0; k < 8; k++) begin
      c[4*k]   = gc[k];
      c[4*k+1] = g[4*k]   | (p[4*k] & gc[k]);
      c[4*k+2] = g[4*k+1] | (p[4*k+1] & g[4*k])
                          | (p[4*k+1] & p[4*k] & gc[k]);
      c[4*k+3] = g[4*k+2] | (p[4*k+2] & g[4*k+1])
                          | (p[4*k+2] & p[4*k+1] & g[4*k])
                          | (p[4*k+2] & p[4*k+1] & p[4*k] & gc[k]);
    end
  end

  assign sum  = p ^ c;         // s[i] = a[i] ^ b[i] ^ c[i]
  assign cout = gc[8];

endmodule
