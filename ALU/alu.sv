module alu #(
  parameter W = 8
)(
  input  logic [W-1:0] a, b,
  input  logic [2:0]   opcode,
  output logic [W-1:0] result,
  output logic         zero,
  output logic         carry_out
);

  // W+1 bit internal bus to physically capture the overflow bit during arithmetic
  logic [W:0] math_temp; 

  always_comb begin //combinational logic
    // Default initializations to strictly prevent asynchronous latch inference
    math_temp = '0;
    result    = '0;
    carry_out = 1'b0;

    unique case (opcode) //similar to switch case
      3'd0: begin // ADD
        math_temp = {1'b0, a} + {1'b0, b}; 
        result    = math_temp[W-1:0];
        carry_out = math_temp[W];
      end
      3'd1: begin // SUBTRACT
        math_temp = {1'b0, a} - {1'b0, b};
        result    = math_temp[W-1:0];
        carry_out = math_temp[W]; // Acts as a borrow-out flag
      end
      3'd2: result = a & b;                 // BITWISE AND
      3'd3: result = a | b;                 // BITWISE OR
      3'd4: result = a ^ b;                 // BITWISE XOR
      3'd5: result = a << b[$clog2(W)-1:0]; // LOGICAL SHIFT LEFT
      3'd6: result = a >> b[$clog2(W)-1:0]; // LOGICAL SHIFT RIGHT
      3'd7: result = a;                     // PASS A
      default: result = '0;
    endcase

    // Generate the zero flag dynamically based on the final multiplexed result
    zero = (result == '0) ? 1'b1 : 1'b0;
  end

endmodule