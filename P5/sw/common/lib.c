// lib.c - minimal runtime: console output, exit, timer, default trap handler.
// Deliberately uses no division in put_dec so it also runs on the RV32I-only
// single-cycle core without calling libgcc.
#include "soc.h"

void putch(char c) { CONSOLE = (uint32_t)c; }

void puts_(const char *s) { while (*s) putch(*s++); }

void put_hex(uint32_t v)
{
    for (int i = 28; i >= 0; i -= 4) {
        uint32_t d = (v >> i) & 0xF;
        putch(d < 10 ? '0' + d : 'a' + d - 10);
    }
}

// decimal by repeated subtraction of powers of ten (no divide instruction)
void put_dec(uint32_t v)
{
    static const uint32_t p10[10] = {1000000000u, 100000000u, 10000000u,
        1000000u, 100000u, 10000u, 1000u, 100u, 10u, 1u};
    int started = 0;
    for (int i = 0; i < 10; i++) {
        char d = '0';
        while (v >= p10[i]) { v -= p10[i]; d++; }
        if (d != '0' || started || i == 9) { putch(d); started = 1; }
    }
}

// print num/den with two decimals, e.g. CPI.  32-bit division only (libgcc
// __udivsi3 on RV32I, the DIVU instruction on RV32IM).
void put_fix2(uint32_t num, uint32_t den)
{
    if (den == 0) { puts_("n/a"); return; }
    while (den > 40000000u) { num >>= 1; den >>= 1; }  // keep r*100 in 32 bits
    uint32_t q = num / den, r = num % den;
    uint32_t f = (r * 100u + den / 2) / den;             // rounded hundredths
    if (f >= 100) { q++; f -= 100; }
    put_dec(q);
    putch('.');
    putch('0' + f / 10);
    putch('0' + f % 10);
}

void exit(int code)
{
    EXIT_REG = ((uint32_t)code << 1) | 1u;   // 1 = pass
    for (;;) ;
}

uint64_t read_mtime(void)
{
    uint32_t hi, lo;
    do {                                       // re-read if the low word wrapped
        hi = MTIME_HI;
        lo = MTIME_LO;
    } while (hi != MTIME_HI);
    return ((uint64_t)hi << 32) | lo;
}

void timer_set(uint64_t t)
{
    MTIMECMP_HI = 0xFFFFFFFFu;                // avoid a spurious interrupt
    MTIMECMP_LO = (uint32_t)t;
    MTIMECMP_HI = (uint32_t)(t >> 32);
}

// Default trap handler: report and stop.  Programs override it.
__attribute__((weak))
uint32_t trap_handler(uint32_t mcause, uint32_t mepc, uint32_t mtval)
{
    puts_("\nunexpected trap: mcause=");  put_hex(mcause);
    puts_(" mepc=");  put_hex(mepc);
    puts_(" mtval="); put_hex(mtval);
    putch('\n');
    exit(100);
}

// The compiler may emit calls to these even in freestanding code.
void *memset(void *d, int c, unsigned long n)
{
    unsigned char *p = d;
    while (n--) *p++ = (unsigned char)c;
    return d;
}

void *memcpy(void *d, const void *s, unsigned long n)
{
    unsigned char *p = d;
    const unsigned char *q = s;
    while (n--) *p++ = *q++;
    return d;
}
