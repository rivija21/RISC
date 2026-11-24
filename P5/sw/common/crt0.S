# crt0.S - C runtime start-up for the rv32_edu SoCs
#
#   _start       : reset entry (address 0)
#     1. stack pointer = top of RAM
#     2. mtvec = trap_entry          (all traps and interrupts go there)
#     3. clear .bss                  (C requires zero-initialised globals)
#     4. call main(); exit(main's return value)
#
#   trap_entry   : saves the registers a C function may clobber, calls
#                  uint32_t trap_handler(mcause, mepc, mtval)
#                  and returns with MRET to the address trap_handler returns.
#                  This is the hardware/software interface of s6: the CPU
#                  saves only the PC (mepc); software saves the registers.

        .section .text.init
        .globl _start
_start:
        la      sp, __stack_top
        la      t0, trap_entry
        csrw    mtvec, t0

        la      t0, __bss_start
        la      t1, __bss_end
1:      bgeu    t0, t1, 2f
        sw      zero, 0(t0)
        addi    t0, t0, 4
        j       1b
2:
        call    main
        call    exit                    # exit(a0) never returns
3:      j       3b

        .text
        .align  2
        .globl  trap_entry
trap_entry:
        addi    sp, sp, -64             # save the 16 caller-saved registers
        sw      ra,  0(sp)
        sw      t0,  4(sp)
        sw      t1,  8(sp)
        sw      t2, 12(sp)
        sw      a0, 16(sp)
        sw      a1, 20(sp)
        sw      a2, 24(sp)
        sw      a3, 28(sp)
        sw      a4, 32(sp)
        sw      a5, 36(sp)
        sw      a6, 40(sp)
        sw      a7, 44(sp)
        sw      t3, 48(sp)
        sw      t4, 52(sp)
        sw      t5, 56(sp)
        sw      t6, 60(sp)

        csrr    a0, mcause
        csrr    a1, mepc
        csrr    a2, mtval
        call    trap_handler            # returns the resume address
        csrw    mepc, a0

        lw      ra,  0(sp)
        lw      t0,  4(sp)
        lw      t1,  8(sp)
        lw      t2, 12(sp)
        lw      a0, 16(sp)
        lw      a1, 20(sp)
        lw      a2, 24(sp)
        lw      a3, 28(sp)
        lw      a4, 32(sp)
        lw      a5, 36(sp)
        lw      a6, 40(sp)
        lw      a7, 44(sp)
        lw      t3, 48(sp)
        lw      t4, 52(sp)
        lw      t5, 56(sp)
        lw      t6, 60(sp)
        addi    sp, sp, 64
        mret
