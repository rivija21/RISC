// soc.h - hardware definitions and tiny runtime for the rv32_edu SoCs
#ifndef SOC_H
#define SOC_H
#include <stdint.h>

// ---------------- memory map (must match rtl/common/rv_pkg.sv) -------------
#define REG32(a)      (*(volatile uint32_t *)(a))
#define MTIMECMP_LO   REG32(0x02004000)
#define MTIMECMP_HI   REG32(0x02004004)
#define MTIME_LO      REG32(0x0200BFF8)
#define MTIME_HI      REG32(0x0200BFFC)
#define CONSOLE       REG32(0x10000000)
#define EXIT_REG      REG32(0x10000004)
#define GPIO          REG32(0x10000008)
#define IC_HIT        REG32(0x10000010)
#define IC_MISS       REG32(0x10000014)
#define DC_HIT        REG32(0x10000018)
#define DC_MISS       REG32(0x1000001C)
#define DC_WB         REG32(0x10000020)

// ---------------- CSR access -------------------------------------------------
#define csr_read(name)  ({ uint32_t v_; __asm__ volatile ("csrr %0, " #name : "=r"(v_)); v_; })
#define csr_write(name, v) __asm__ volatile ("csrw " #name ", %0" :: "r"(v))
#define csr_set(name, v)   __asm__ volatile ("csrs " #name ", %0" :: "r"(v))
#define csr_clear(name, v) __asm__ volatile ("csrc " #name ", %0" :: "r"(v))

#define MSTATUS_MIE  (1u << 3)
#define MIE_MTIE     (1u << 7)
#define MCAUSE_IRQ   0x80000000u
#define CAUSE_TIMER  (MCAUSE_IRQ | 7u)

// ---------------- runtime (lib.c) --------------------------------------------
void     putch(char c);
void     puts_(const char *s);             // no newline added
void     put_hex(uint32_t v);              // 8 hex digits
void     put_dec(uint32_t v);              // unsigned decimal
void     put_fix2(uint32_t num, uint32_t den); // num/den with 2 decimals
void     exit(int code) __attribute__((noreturn));
uint64_t read_mtime(void);
void     timer_set(uint64_t t);            // mtimecmp = t
uint32_t trap_handler(uint32_t mcause, uint32_t mepc, uint32_t mtval);
#endif
