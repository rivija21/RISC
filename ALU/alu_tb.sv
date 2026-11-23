`timescale 1ns / 1ps

module alu_tb;
  parameter W = 8;
  
  // Testbench internal signals
  logic [W-1:0] tb_a, tb_b;
  logic [2:0]   tb_opcode;
  logic [W-1:0] tb_result;
  logic         tb_zero;
  logic         tb_carry_out;

  // Instantiate the Device Under Test (DUT)
  alu #(.W(W)) dut (
    .a(tb_a),
    .b(tb_b),
    .opcode(tb_opcode),
    .result(tb_result),
    .zero(tb_zero),
    .carry_out(tb_carry_out)
  );

  initial begin
    $display("Initializing ALU Simulation...");
    
    // Test Case 1: Addition causing a Carry-Out
    tb_a = 8'd250; tb_b = 8'd10; tb_opcode = 3'd0;
    #10;
    
    // Test Case 2: Subtraction resulting in Zero
    tb_a = 8'd150; tb_b = 8'd150; tb_opcode = 3'd1;
    #10;
    
    // Test Case 3: Bitwise XOR
    tb_a = 8'b1010_1010; tb_b = 8'b1100_1100; tb_opcode = 3'd4;
    #10;
    
    // Test Case 4: Logical Shift Left (shift tb_a by the lower 3 bits of tb_b)
    tb_a = 8'b0000_1111; tb_b = 8'd4; tb_opcode = 3'd5;
    #10;

    $stop; // Suspend simulation
  end
endmodule