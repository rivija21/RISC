// =============================================================================
// rv_pkg.sv  -  Shared definitions for every core in this project
// -----------------------------------------------------------------------------
// Lecture links
//   s2 ISA ............ opcode map, instruction formats, CSR addresses
//   s3 Microarch ...... the "control word" (ctrl_t) that drives the datapath
//   s5 Memory ......... byte addressing, alignment, little-endian byte lanes
//
// Everything here is either a constant, a type, or a pure function
// (combinational logic).  No registers live in a package.
// =============================================================================
package rv_pkg;

  // ---------------------------------------------------------------------------
  // 1. Major opcodes (instr[6:0]).  RV32I base: instr[1:0] is always 2'b11.
  // ---------------------------------------------------------------------------
  localparam logic [6:0] OPC_LOAD     = 7'b0000011;
  localparam logic [6:0] OPC_MISC_MEM = 7'b0001111;  // FENCE, FENCE.I
  localparam logic [6:0] OPC_OP_IMM   = 7'b0010011;  // ADDI, SLTI, ...
  localparam logic [6:0] OPC_AUIPC    = 7'b0010111;
  localparam logic [6:0] OPC_STORE    = 7'b0100011;
  localparam logic [6:0] OPC_OP       = 7'b0110011;  // ADD, SUB, ... and RV32M
  localparam logic [6:0] OPC_LUI      = 7'b0110111;
  localparam logic [6:0] OPC_BRANCH   = 7'b1100011;
  localparam logic [6:0] OPC_JALR     = 7'b1100111;
  localparam logic [6:0] OPC_JAL      = 7'b1101111;
  localparam logic [6:0] OPC_SYSTEM   = 7'b1110011;  // ECALL, EBREAK, CSR*, MRET

  // ---------------------------------------------------------------------------
  // 2. ALU operations.  4 bits are enough for the 10 RV32I operations.
  // ---------------------------------------------------------------------------
  typedef enum logic [3:0] {
    ALU_ADD  = 4'd0,
    ALU_SUB  = 4'd1,
    ALU_SLL  = 4'd2,   // shift left logical
    ALU_SLT  = 4'd3,   // set if less than (signed)
    ALU_SLTU = 4'd4,   // set if less than (unsigned)
    ALU_XOR  = 4'd5,
    ALU_SRL  = 4'd6,   // shift right logical   (fills with 0)
    ALU_SRA  = 4'd7,   // shift right arithmetic (fills with sign bit)
    ALU_OR   = 4'd8,
    ALU_AND  = 4'd9
  } alu_op_e;

  // Which immediate format to build (see imm_gen.sv and s2 "Immediate encoding")
  typedef enum logic [2:0] {
    IMM_I = 3'd0,      // 12-bit signed      : loads, OP-IMM, JALR
    IMM_S = 3'd1,      // 12-bit signed      : stores
    IMM_B = 3'd2,      // 13-bit signed, even: branches
    IMM_U = 3'd3,      // upper 20 bits      : LUI, AUIPC
    IMM_J = 3'd4       // 21-bit signed, even: JAL
  } imm_e;

  // ALU operand A source
  typedef enum logic [1:0] {
    A_RS1  = 2'd0,
    A_PC   = 2'd1,
    A_ZERO = 2'd2
  } asel_e;

  // ALU operand B source
  typedef enum logic [0:0] {
    B_RS2 = 1'b0,
    B_IMM = 1'b1
  } bsel_e;

  // Register-file write-back source
  typedef enum logic [2:0] {
    WB_ALU = 3'd0,     // ALU result
    WB_MEM = 3'd1,     // load data (after sign/zero extension)
    WB_PC4 = 3'd2,     // return address for JAL/JALR
    WB_CSR = 3'd3,     // old value of a CSR (CSRRW/S/C)
    WB_MD  = 3'd4      // multiplier / divider result (RV32M)
  } wb_e;

  // ---------------------------------------------------------------------------
  // 3. The CONTROL WORD.
  //    One control word = the set of control signals needed to execute one
  //    instruction in the single-cycle and pipelined datapaths (s3, slide 66).
  //    The hardwired unit computes it with logic; the ROM unit looks it up.
  //    Field order below is the bit order of the word (MSB first).
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic    illegal;    // instruction is not a legal RV32I(M) encoding
    logic    reg_write;  // write rd at the end of the instruction
    asel_e   a_sel;      // ALU input A mux
    bsel_e   b_sel;      // ALU input B mux
    alu_op_e alu_op;     // ALU function
    imm_e    imm_type;   // immediate format
    logic    mem_read;   // load
    logic    mem_write;  // store
    wb_e     wb_sel;     // write-back mux
    logic    branch;     // conditional branch (BEQ..BGEU)
    logic    jal;        // JAL
    logic    jalr;       // JALR
    logic    csr;        // CSRRW/S/C(I)
    logic    ecall;
    logic    ebreak;
    logic    mret;
    logic    muldiv;     // RV32M instruction
  } ctrl_t;

  localparam int CTRL_W = $bits(ctrl_t);

  // ---------------------------------------------------------------------------
  // 4. Instruction identifiers.  Used by the ROM (microprogrammed) control
  //    unit as the "address" of the control store row, and by the multi-cycle
  //    core's dispatch table.  6 bits -> up to 64 instructions.
  // ---------------------------------------------------------------------------
  typedef enum logic [5:0] {
    I_ILLEGAL = 6'd0,
    I_LUI, I_AUIPC, I_JAL, I_JALR,
    I_BEQ, I_BNE, I_BLT, I_BGE, I_BLTU, I_BGEU,
    I_LB, I_LH, I_LW, I_LBU, I_LHU,
    I_SB, I_SH, I_SW,
    I_ADDI, I_SLTI, I_SLTIU, I_XORI, I_ORI, I_ANDI, I_SLLI, I_SRLI, I_SRAI,
    I_ADD, I_SUB, I_SLL, I_SLT, I_SLTU, I_XOR, I_SRL, I_SRA, I_OR, I_AND,
    I_FENCE, I_FENCE_I, I_ECALL, I_EBREAK, I_MRET, I_WFI,
    I_CSRRW, I_CSRRS, I_CSRRC, I_CSRRWI, I_CSRRSI, I_CSRRCI,
    I_MUL, I_MULH, I_MULHSU, I_MULHU, I_DIV, I_DIVU, I_REM, I_REMU
  } instr_id_e;

  // ---------------------------------------------------------------------------
  // 5. CSR addresses (s2 slide 52: "System instructions and CSR")
  // ---------------------------------------------------------------------------
  localparam logic [11:0] CSR_MSTATUS   = 12'h300;
  localparam logic [11:0] CSR_MISA      = 12'h301;
  localparam logic [11:0] CSR_MIE       = 12'h304;
  localparam logic [11:0] CSR_MTVEC     = 12'h305;
  localparam logic [11:0] CSR_MSTATUSH  = 12'h310;
  localparam logic [11:0] CSR_MSCRATCH  = 12'h340;
  localparam logic [11:0] CSR_MEPC      = 12'h341;
  localparam logic [11:0] CSR_MCAUSE    = 12'h342;
  localparam logic [11:0] CSR_MTVAL     = 12'h343;
  localparam logic [11:0] CSR_MIP       = 12'h344;
  localparam logic [11:0] CSR_MCYCLE    = 12'hB00;
  localparam logic [11:0] CSR_MINSTRET  = 12'hB02;
  localparam logic [11:0] CSR_MCYCLEH   = 12'hB80;
  localparam logic [11:0] CSR_MINSTRETH = 12'hB82;
  localparam logic [11:0] CSR_CYCLE     = 12'hC00;   // read-only user copies
  localparam logic [11:0] CSR_TIME      = 12'hC01;
  localparam logic [11:0] CSR_INSTRET   = 12'hC02;
  localparam logic [11:0] CSR_CYCLEH    = 12'hC80;
  localparam logic [11:0] CSR_TIMEH     = 12'hC81;
  localparam logic [11:0] CSR_INSTRETH  = 12'hC82;
  localparam logic [11:0] CSR_MVENDORID = 12'hF11;
  localparam logic [11:0] CSR_MARCHID   = 12'hF12;
  localparam logic [11:0] CSR_MIMPID    = 12'hF13;
  localparam logic [11:0] CSR_MHARTID   = 12'hF14;

  // Exception cause codes written to mcause (interrupts also set bit 31)
  localparam logic [31:0] CAUSE_INSTR_MISALIGNED = 32'd0;
  localparam logic [31:0] CAUSE_ILLEGAL_INSTR    = 32'd2;
  localparam logic [31:0] CAUSE_BREAKPOINT       = 32'd3;
  localparam logic [31:0] CAUSE_LOAD_MISALIGNED  = 32'd4;
  localparam logic [31:0] CAUSE_STORE_MISALIGNED = 32'd6;
  localparam logic [31:0] CAUSE_ECALL_M          = 32'd11;
  localparam logic [31:0] CAUSE_IRQ_M_TIMER      = 32'h8000_0007;
  localparam logic [31:0] CAUSE_IRQ_M_EXT        = 32'h8000_000B;

  // ---------------------------------------------------------------------------
  // 6. Memory map (identical for all three SoCs)
  // ---------------------------------------------------------------------------
  //   0x0000_0000 .. RAM_BYTES-1  : RAM (code + data + stack)
  //   0x0200_4000                 : mtimecmp (lo), +4 hi      \  "CLINT" timer,
  //   0x0200_BFF8                 : mtime    (lo), +4 hi      /  standard addrs
  //   0x1000_0000                 : CONSOLE  (write a char; simulation only)
  //   0x1000_0004                 : EXIT     (write code; simulation stops)
  //   0x1000_0008                 : GPIO     (32-bit output port, e.g. LEDs)
  //   0x1000_0010 .. 0x1000_0020  : cache statistics (read only, s5)
  localparam logic [31:0] MMIO_MTIMECMP = 32'h0200_4000;
  localparam logic [31:0] MMIO_MTIME    = 32'h0200_BFF8;
  localparam logic [31:0] MMIO_CONSOLE  = 32'h1000_0000;
  localparam logic [31:0] MMIO_EXIT     = 32'h1000_0004;
  localparam logic [31:0] MMIO_GPIO     = 32'h1000_0008;
  localparam logic [31:0] MMIO_IC_HIT   = 32'h1000_0010;
  localparam logic [31:0] MMIO_IC_MISS  = 32'h1000_0014;
  localparam logic [31:0] MMIO_DC_HIT   = 32'h1000_0018;
  localparam logic [31:0] MMIO_DC_MISS  = 32'h1000_001C;
  localparam logic [31:0] MMIO_DC_WB    = 32'h1000_0020;

  // An address is memory-mapped I/O (never cached) if any of bits 31:28 or
  // 27:24 are set.  RAM lives in the lowest 16 MiB.
  function automatic logic is_mmio(input logic [31:0] addr);
    return (addr[31:24] != 8'h00);
  endfunction

  // ---------------------------------------------------------------------------
  // 7. ALU operation from funct3/funct7 for OP and OP-IMM instructions.
  //    Used by the hardwired decoder and by the multi-cycle core's microcode
  //    field "ALU function = from IR".
  // ---------------------------------------------------------------------------
  function automatic alu_op_e alu_op_from_ir(input logic [31:0] ir);
    logic [2:0] f3;
    logic       is_op, b30;
    f3    = ir[14:12];
    is_op = (ir[6:0] == OPC_OP);        // register-register (SUB exists)
    b30   = ir[30];                     // funct7 bit 5: SUB / SRA selector
    case (f3)
      3'b000:  if (is_op && b30) return ALU_SUB; else return ALU_ADD;
      3'b001:  return ALU_SLL;
      3'b010:  return ALU_SLT;
      3'b011:  return ALU_SLTU;
      3'b100:  return ALU_XOR;
      3'b101:  if (b30) return ALU_SRA; else return ALU_SRL;
      3'b110:  return ALU_OR;
      default: return ALU_AND;
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // 8. Load/store unit helpers (s2 "Endianness", s5 byte addressing).
  //    Memory is 32 bits wide and little endian: byte k of a word is at
  //    address word_address + k and sits in bits [8k+7 : 8k].
  // ---------------------------------------------------------------------------

  // Is the access misaligned?  funct3[1:0]: 00 byte, 01 half, 10 word.
  function automatic logic lsu_misaligned(input logic [1:0] off,
                                          input logic [2:0] f3);
    case (f3[1:0])
      2'b00:   return 1'b0;           // bytes are always aligned
      2'b01:   return off[0];         // halfword needs an even address
      default: return (off != 2'b00); // word needs a multiple of 4
    endcase
  endfunction

  // Store: move the data into the right byte lane and build the byte enables.
  function automatic logic [35:0] lsu_store(input logic [31:0] data,
                                            input logic [1:0]  off,
                                            input logic [2:0]  f3);
    logic [31:0] wdata;
    logic [3:0]  be;
    case (f3[1:0])
      2'b00: begin wdata = {4{data[7:0]}};  be = 4'b0001 << off;          end
      2'b01: begin wdata = {2{data[15:0]}}; be = off[1] ? 4'b1100 : 4'b0011; end
      default: begin wdata = data;          be = 4'b1111;                  end
    endcase
    return {be, wdata};               // {byte enables, write data}
  endfunction

  // Load: pick the addressed byte/halfword out of the word and extend it.
  // funct3[2] = 1 means unsigned (LBU, LHU): zero extension.
  function automatic logic [31:0] lsu_load(input logic [31:0] word,
                                           input logic [1:0]  off,
                                           input logic [2:0]  f3);
    logic [7:0]  b;
    logic [15:0] h;
    b = word[8*off +: 8];
    h = off[1] ? word[31:16] : word[15:0];
    case (f3)
      3'b000:  return {{24{b[7]}},  b};   // LB  (sign extend)
      3'b001:  return {{16{h[15]}}, h};   // LH
      3'b100:  return {24'b0, b};         // LBU (zero extend)
      3'b101:  return {16'b0, h};         // LHU
      default: return word;               // LW
    endcase
  endfunction

endpackage
