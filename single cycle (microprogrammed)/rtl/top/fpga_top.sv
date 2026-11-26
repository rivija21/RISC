// =============================================================================
// fpga_top.sv  -  top level for Quartus (Cyclone V, e.g. 5CSEMA5F31C6)
// -----------------------------------------------------------------------------
// Selects one of the three SoCs with the CORE parameter:
//   CORE = 0 : multi-cycle microprogrammed RV32IM   (soc_mc)
//   CORE = 1 : single-cycle RV32I                   (soc_sc; CTRL_ROM selects
//              1 = ROM / microprogrammed control, 0 = hardwired control)
//   CORE = 2 : 5-stage pipeline RV32IM + caches     (soc_pipe)
// Change it in Quartus under Assignments > Settings > Compiler Settings >
// Default Parameters, or with "set_parameter -name CORE 2" in the .qsf.
//
// Pins: clock, active-low reset button, and the 32-bit GPIO output.
// Without a board the GPIO pins matter anyway: Quartus removes every piece of
// logic that cannot influence an output pin.  The program writes GPIO, so the
// whole CPU stays in the netlist and the resource/timing reports are real.
//
// INIT_FILE is the program loaded into RAM at configuration time
// ($readmemh).  The path is relative to the Quartus project directory.
// =============================================================================
module fpga_top #(
  parameter int CORE        = 2,
  parameter int CTRL_ROM    = 1,
  parameter int RAM_BYTES   = 4096,
  parameter int MEM_LATENCY = 4,
  parameter     INIT_FILE   = "../sw/build/fpga_demo.hex",
  parameter int TIMER_DIV   = 50        // 50 MHz / 50 = 1 MHz mtime tick
)(
  input  logic        clk,              // 50 MHz board clock
  input  logic        rst_n,            // push button, active low
  output logic [31:0] gpio_out
);

  // ---------------- reset synchronizer ------------------------------------
  // The button is asynchronous to clk.  Two flip-flops remove metastability;
  // reset is asserted immediately and released synchronously.
  logic [1:0] rst_sync;
  logic       rst;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) rst_sync <= 2'b11;
    else        rst_sync <= {rst_sync[0], 1'b0};
  assign rst = rst_sync[1];

  // simulation-only outputs, unused on hardware
  logic        sim_putc, sim_exit, retire;
  logic [7:0]  sim_char;
  logic [31:0] sim_exit_code;

  generate
    if (CORE == 0) begin : g_mc
      soc_mc #(.RAM_BYTES(RAM_BYTES), .MEM_LATENCY(MEM_LATENCY),
               .INIT_FILE(INIT_FILE), .TIMER_DIV(TIMER_DIV)) u_soc (
        .clk, .rst, .meip(1'b0), .gpio_out,
        .sim_putc, .sim_char, .sim_exit, .sim_exit_code, .retire);
    end else if (CORE == 1) begin : g_sc
      soc_sc #(.CTRL_ROM(CTRL_ROM != 0), .RAM_BYTES(RAM_BYTES),
               .INIT_FILE(INIT_FILE), .TIMER_DIV(TIMER_DIV)) u_soc (
        .clk, .rst, .meip(1'b0), .gpio_out,
        .sim_putc, .sim_char, .sim_exit, .sim_exit_code, .retire);
    end else begin : g_pipe
      logic [31:0] ic_hit, ic_miss, dc_hit, dc_miss, dc_wb;
      soc_pipe #(.RAM_BYTES(RAM_BYTES), .MEM_LATENCY(MEM_LATENCY),
                 .INIT_FILE(INIT_FILE), .TIMER_DIV(TIMER_DIV)) u_soc (
        .clk, .rst, .meip(1'b0), .gpio_out,
        .sim_putc, .sim_char, .sim_exit, .sim_exit_code, .retire,
        .ic_hit, .ic_miss, .dc_hit, .dc_miss, .dc_wb);
    end
  endgenerate

endmodule
