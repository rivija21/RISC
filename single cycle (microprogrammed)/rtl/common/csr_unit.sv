// =============================================================================
// csr_unit.sv  -  Control & Status Registers, traps, interrupts
//                 (s2 slide 52 "System instructions and CSR", s6 OS, s1 metrics)
// -----------------------------------------------------------------------------
// This is the hardware an operating system relies on (s6):
//   * a TRAP mechanism: on an exception or interrupt the CPU saves the PC of
//     the interrupted instruction (mepc), records why (mcause, mtval),
//     disables interrupts and jumps to the handler address (mtvec).
//     MRET returns: PC = mepc and interrupts are re-enabled.
//     s6: "it is possible to interrupt a running process and later resume
//     execution as if the interruption had not occurred" - this is how.
//   * a TIMER INTERRUPT (mip.MTIP from the timer in mmio.sv).  An OS
//     scheduler uses it to take the CPU back from a running process.
//   * performance counters mcycle / minstret (s1: CPI = cycles / instructions).
//
// Only Machine mode (M-mode) is implemented; there is no user mode.
//
// Interface timing (same for all three cores):
//   * csr_rdata / csr_illegal are combinational from csr_addr.
//   * a CSR write, a trap entry and an MRET take effect at the rising clock
//     edge in the cycle where csr_commit / trap_take / mret_take is 1.
// =============================================================================
module csr_unit
  import rv_pkg::*;
#(
  parameter bit HAS_M = 1'b1          // reported in misa
)(
  input  logic        clk,
  input  logic        rst,

  // ---------------- CSR instruction port ------------------------------------
  input  logic [11:0] csr_addr,       // instr[31:20]
  input  logic [1:0]  csr_cmd,        // funct3[1:0]: 01 RW, 10 RS (set), 11 RC (clear)
  input  logic [31:0] csr_src,        // rs1 value, or zero-extended uimm (CSR*I)
  input  logic        csr_wr_intent,  // instruction wants to write (see note)
  input  logic        csr_commit,     // perform the write now
  output logic [31:0] csr_rdata,      // old value (goes to rd)
  output logic        csr_illegal,    // unknown CSR, or write to a read-only CSR

  // ---------------- traps -----------------------------------------------------
  input  logic        trap_take,
  input  logic [31:0] trap_cause,
  input  logic [31:0] trap_epc,       // PC of the instruction to resume at
  input  logic [31:0] trap_tval,      // extra info (bad address / instruction)
  input  logic        mret_take,
  output logic [31:0] mtvec_o,        // handler address
  output logic [31:0] mepc_o,         // return address for MRET

  // ---------------- counters / interrupts -------------------------------------
  input  logic        retire,         // one instruction completed this cycle
  input  logic [63:0] mtime,          // from the memory-mapped timer
  input  logic        mtip,           // timer interrupt pending (mtime >= mtimecmp)
  input  logic        meip,           // external interrupt pending (input pin)
  output logic        irq_pending,    // an enabled interrupt is waiting
  output logic [31:0] irq_cause
);
  // Note on csr_wr_intent: CSRRS/CSRRC with rs1 = x0 (or uimm = 0) must NOT
  // write, so they can read read-only CSRs such as "cycle" without being
  // illegal.  CSRRW always writes.  The cores compute this from the
  // instruction fields.

  // ---------------- state -----------------------------------------------------
  logic        mstatus_mie, mstatus_mpie;  // global interrupt enable and its copy
  logic        mie_msie, mie_mtie, mie_meie;
  logic [31:0] mtvec, mscratch, mepc, mcause, mtval;
  logic [63:0] mcycle, minstret;

  // misa: bits 31:30 = 01 (32-bit), bit 8 = 'I' base ISA, bit 12 = 'M' extension
  localparam logic [31:0] MISA = 32'h4000_0100 | (HAS_M ? 32'h0000_1000 : 32'h0);

  // mstatus as seen by software: MPP (bits 12:11) is fixed at 11 = M-mode
  logic [31:0] mstatus_val, mie_val, mip_val;
  assign mstatus_val = {19'b0, 2'b11, 3'b0, mstatus_mpie, 3'b0, mstatus_mie, 3'b0};
  assign mie_val     = {20'b0, mie_meie, 3'b0, mie_mtie, 3'b0, mie_msie, 3'b0};
  assign mip_val     = {20'b0, meip, 3'b0, mtip, 7'b0};

  // ---------------- read mux + legality ----------------------------------------
  logic known;
  always_comb begin
    known     = 1'b1;
    csr_rdata = 32'b0;
    case (csr_addr)
      CSR_MSTATUS:   csr_rdata = mstatus_val;
      CSR_MSTATUSH:  csr_rdata = 32'b0;
      CSR_MISA:      csr_rdata = MISA;
      CSR_MIE:       csr_rdata = mie_val;
      CSR_MTVEC:     csr_rdata = mtvec;
      CSR_MSCRATCH:  csr_rdata = mscratch;
      CSR_MEPC:      csr_rdata = mepc;
      CSR_MCAUSE:    csr_rdata = mcause;
      CSR_MTVAL:     csr_rdata = mtval;
      CSR_MIP:       csr_rdata = mip_val;
      CSR_MCYCLE,   CSR_CYCLE:    csr_rdata = mcycle[31:0];
      CSR_MCYCLEH,  CSR_CYCLEH:   csr_rdata = mcycle[63:32];
      CSR_MINSTRET, CSR_INSTRET:  csr_rdata = minstret[31:0];
      CSR_MINSTRETH,CSR_INSTRETH: csr_rdata = minstret[63:32];
      CSR_TIME:      csr_rdata = mtime[31:0];
      CSR_TIMEH:     csr_rdata = mtime[63:32];
      CSR_MVENDORID, CSR_MARCHID, CSR_MIMPID, CSR_MHARTID: csr_rdata = 32'b0;
      default:       known = 1'b0;
    endcase
  end
  // CSR address bits [11:10] = 11 mark read-only CSRs (RISC-V convention)
  assign csr_illegal = !known || (csr_wr_intent && csr_addr[11:10] == 2'b11);

  // new value for CSRRW / CSRRS / CSRRC
  logic [31:0] wval;
  always_comb begin
    case (csr_cmd)
      2'b01:   wval = csr_src;                 // write
      2'b10:   wval = csr_rdata |  csr_src;    // set bits
      2'b11:   wval = csr_rdata & ~csr_src;    // clear bits
      default: wval = csr_rdata;
    endcase
  end

  logic do_write;
  assign do_write = csr_commit && csr_wr_intent && !csr_illegal;

  // ---------------- sequential update -----------------------------------------
  always_ff @(posedge clk) begin
    if (rst) begin
      mstatus_mie  <= 1'b0;
      mstatus_mpie <= 1'b0;
      {mie_msie, mie_mtie, mie_meie} <= 3'b0;
      mtvec    <= 32'b0;
      mscratch <= 32'b0;
      mepc     <= 32'b0;
      mcause   <= 32'b0;
      mtval    <= 32'b0;
      mcycle   <= 64'b0;
      minstret <= 64'b0;
    end else begin
      // counters run by default; a CSR write in the same cycle wins
      mcycle   <= mcycle + 64'd1;
      if (retire) minstret <= minstret + 64'd1;

      if (trap_take) begin
        // ------- trap entry: save state, disable interrupts -------
        mepc         <= {trap_epc[31:2], 2'b00};
        mcause       <= trap_cause;
        mtval        <= trap_tval;
        mstatus_mpie <= mstatus_mie;
        mstatus_mie  <= 1'b0;
      end else if (mret_take) begin
        // ------- return from trap: restore interrupt enable -------
        mstatus_mie  <= mstatus_mpie;
        mstatus_mpie <= 1'b1;
      end else if (do_write) begin
        case (csr_addr)
          CSR_MSTATUS: begin
            mstatus_mie  <= wval[3];
            mstatus_mpie <= wval[7];
          end
          CSR_MIE: begin
            mie_msie <= wval[3];
            mie_mtie <= wval[7];
            mie_meie <= wval[11];
          end
          CSR_MTVEC:     mtvec    <= {wval[31:2], 2'b00};   // direct mode only
          CSR_MSCRATCH:  mscratch <= wval;
          CSR_MEPC:      mepc     <= {wval[31:2], 2'b00};
          CSR_MCAUSE:    mcause   <= wval;
          CSR_MTVAL:     mtval    <= wval;
          CSR_MCYCLE:    mcycle[31:0]    <= wval;
          CSR_MCYCLEH:   mcycle[63:32]   <= wval;
          CSR_MINSTRET:  minstret[31:0]  <= wval;
          CSR_MINSTRETH: minstret[63:32] <= wval;
          default: ;                  // misa, mip, mstatush: writes ignored
        endcase
      end
    end
  end

  assign mtvec_o = mtvec;
  assign mepc_o  = mepc;

  // ---------------- interrupt request -------------------------------------------
  // Taken only if globally enabled (mstatus.MIE) AND individually enabled (mie)
  // AND pending (mip).  External has priority over timer (RISC-V ordering).
  logic ext_irq, tmr_irq;
  assign ext_irq     = mstatus_mie && mie_meie && meip;
  assign tmr_irq     = mstatus_mie && mie_mtie && mtip;
  assign irq_pending = ext_irq || tmr_irq;
  assign irq_cause   = ext_irq ? CAUSE_IRQ_M_EXT : CAUSE_IRQ_M_TIMER;

endmodule
