// =============================================================================
// soc_sc.sv  -  single-cycle core + dual-port RAM + peripherals
// -----------------------------------------------------------------------------
//                 imem port ─────────────┐
//     sc_core ────                        ├──► mem_dp_async (RAM)
//                 dmem port ──┬───────────┘
//                             └──► mmio (timer, console, GPIO)   addr >= 16 MiB
// =============================================================================
module soc_sc
  import rv_pkg::*;
#(
  parameter bit CTRL_ROM  = 1'b1,
  parameter int RAM_BYTES = 16384,
  parameter     INIT_FILE = "",
  parameter int TIMER_DIV = 1
)(
  input  logic        clk,
  input  logic        rst,
  input  logic        meip,             // external interrupt pin
  output logic [31:0] gpio_out,
  // simulation / debug outputs
  output logic        sim_putc,
  output logic [7:0]  sim_char,
  output logic        sim_exit,
  output logic [31:0] sim_exit_code,
  output logic        retire
);
  logic [31:0] imem_addr, imem_rdata;
  logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
  logic        dmem_we;
  logic [3:0]  dmem_be;
  logic [63:0] mtime;
  logic        mtip;
  logic [31:0] pc_unused;

  sc_core #(.CTRL_ROM(CTRL_ROM)) u_core (
    .clk, .rst,
    .imem_addr, .imem_rdata,
    .dmem_addr, .dmem_we, .dmem_be, .dmem_wdata, .dmem_rdata,
    .mtip, .meip, .mtime,
    .retire_o(retire), .pc_o(pc_unused)
  );

  // ---------------- address decode ---------------------------------------
  logic sel_io;
  assign sel_io = is_mmio(dmem_addr);

  logic [31:0] ram_rdata, io_rdata;

  mem_dp_async #(.RAM_BYTES(RAM_BYTES), .INIT_FILE(INIT_FILE)) u_ram (
    .clk,
    .a_addr(imem_addr), .a_rdata(imem_rdata),
    .b_addr(dmem_addr), .b_we(dmem_we && !sel_io), .b_be(dmem_be),
    .b_wdata(dmem_wdata), .b_rdata(ram_rdata)
  );

  mmio #(.TIMER_DIV(TIMER_DIV)) u_io (
    .clk, .rst,
    .we(dmem_we && sel_io), .addr(dmem_addr), .wdata(dmem_wdata), .rdata(io_rdata),
    .mtime, .mtip, .gpio_out,
    .sim_putc, .sim_char, .sim_exit, .sim_exit_code,
    .ic_hit(32'b0), .ic_miss(32'b0), .dc_hit(32'b0), .dc_miss(32'b0), .dc_wb(32'b0)
  );

  assign dmem_rdata = sel_io ? io_rdata : ram_rdata;

endmodule
