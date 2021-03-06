/*
 * xen/arch/arm/head.S
 *
 * Start-of-day code for an ARMv7-A with virt extensions.
 *
 * Tim Deegan <tim@xen.org>
 * Copyright (c) 2011 Citrix Systems.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 */

#include <asm/config.h>
#include <asm/page.h>
#include <asm/processor-ca15.h>
#include <asm/processor-ca7.h>
#include <asm/asm_defns.h>
#include <asm/early_printk.h>

#define ZIMAGE_MAGIC_NUMBER 0x016f2818

#define PT_PT     0xe7f /* nG=1 AF=1 SH=10 AP=01 NS=1 ATTR=111 T=1 P=1 */
#define PT_MEM    0xe7d /* nG=1 AF=1 SH=10 AP=01 NS=1 ATTR=111 T=0 P=1 */
#define PT_DEV    0xe71 /* nG=1 AF=1 SH=10 AP=01 NS=1 ATTR=100 T=0 P=1 */
#define PT_DEV_L3 0xe73 /* nG=1 AF=1 SH=10 AP=01 NS=1 ATTR=100 T=1 P=1 */

#define PT_UPPER(x) (PT_##x & 0xf00)
#define PT_LOWER(x) (PT_##x & 0x0ff)

#if (defined (EARLY_PRINTK)) && (defined (EARLY_PRINTK_INC))
#include EARLY_PRINTK_INC
#endif

/*
 * Common register usage in this file:
 *   r0  -
 *   r1  -
 *   r2  -
 *   r3  -
 *   r4  -
 *   r5  -
 *   r6  -
 *   r7  - CPUID
 *   r8  - DTB address (boot CPU only)
 *   r9  - paddr(start)
 *   r10 - phys offset
 *   r11 - UART address
 *   r12 - is_secondary_cpu
 *   r13 - SP
 *   r14 - LR
 *   r15 - PC
 */
/* Macro to print a string to the UART, if there is one.
 * Clobbers r0-r3. */
#ifdef EARLY_PRINTK
#define PRINT(_s)       \
        adr   r0, 98f ; \
        bl    puts    ; \
        b     99f     ; \
98:     .asciz _s     ; \
        .align 2      ; \
99:
#else /* EARLY_PRINTK */
#define PRINT(s)
#endif /* !EARLY_PRINTK */

        .arm

        /* This must be the very first address in the loaded image.
         * It should be linked at XEN_VIRT_START, and loaded at any
         * 2MB-aligned address.  All of text+data+bss must fit in 2MB,
         * or the initial pagetable code below will need adjustment. */
        .global start
start:
        /* zImage magic header, see:
         * http://www.simtec.co.uk/products/SWLINUX/files/booting_article.html#d0e309
         */
        .rept 8
        mov   r0, r0
        .endr
        b     past_zImage

        .word ZIMAGE_MAGIC_NUMBER    /* Magic numbers to help the loader */
        .word 0x00000000             /* absolute load/run zImage address or
                                      * 0 for PiC */
        .word (_end - start)         /* zImage end address */

past_zImage:
        cpsid aif                    /* Disable all interrupts */

        /* Save the bootloader arguments in less-clobberable registers */
        mov   r8, r2                 /* r8 := DTB base address */

        /* Find out where we are */
        ldr   r0, =start
        adr   r9, start              /* r9  := paddr (start) */
        sub   r10, r9, r0            /* r10 := phys-offset */

        /* Using the DTB in the .dtb section? */
#ifdef CONFIG_DTB_FILE
        ldr   r8, =_sdtb
        add   r8, r10                /* r8 := paddr(DTB) */
#endif

        mov   r12, #0                /* r12 := is_secondary_cpu */

        b     common_start

GLOBAL(init_secondary)
        cpsid aif                    /* Disable all interrupts */

        /* Find out where we are */
        ldr   r0, =start
        adr   r9, start              /* r9  := paddr (start) */
        sub   r10, r9, r0            /* r10 := phys-offset */

        mov   r12, #1                /* r12 := is_secondary_cpu */

common_start:
        mov   r7, #0                 /* r7 := CPU ID. Initialy zero until we
                                      * find that multiprocessor extensions are
                                      * present and the system is SMP */
        mrc   CP32(r1, MPIDR)
        tst   r1, #MPIDR_SMP         /* Multiprocessor extension supported? */
        beq   1f
        tst   r1, #MPIDR_UP          /* Uniprocessor system? */
        bne   1f
        bic   r7, r1, #(~MPIDR_HWID_MASK) /* Mask out flags to get CPU ID */
1:

        /* Non-boot CPUs wait here until __cpu_up is ready for them */
        teq   r12, #0
        beq   1f

        ldr   r0, =smp_up_cpu
        add   r0, r0, r10            /* Apply physical offset */
        dsb
2:      ldr   r1, [r0]
        cmp   r1, r7
        beq   1f
        wfe
        b     2b
1:

#ifdef EARLY_PRINTK
        ldr   r11, =EARLY_UART_BASE_ADDRESS  /* r11 := UART base address */
        teq   r12, #0                /* Boot CPU sets up the UART too */
        bleq  init_uart
        PRINT("- CPU ")
        mov   r0, r7
        bl    putn
        PRINT(" booting -\r\n")
#endif

        /* Check that this CPU has Hyp mode */
        mrc   CP32(r0, ID_PFR1)
        and   r0, r0, #0xf000        /* Bits 12-15 define virt extensions */
        teq   r0, #0x1000            /* Must == 0x1 or may be incompatible */
        beq   1f
        PRINT("- CPU doesn't support the virtualization extensions -\r\n")
        b     fail
1:

        /* Check that we're already in Hyp mode */
        mrs   r0, cpsr
        and   r0, r0, #0x1f          /* Mode is in the low 5 bits of CPSR */
        teq   r0, #0x1a              /* Hyp Mode? */
        beq   hyp

        /* OK, we're boned. */
        PRINT("- Xen must be entered in NS Hyp mode -\r\n" \
              "- Please update the bootloader -\r\n")
        b     fail

hyp:    PRINT("- Xen starting in Hyp mode -\r\n")

        /* Zero BSS On the boot CPU to avoid nasty surprises */
        teq   r12, #0
        bne   skip_bss

        PRINT("- Zero BSS -\r\n")
        ldr   r0, =__bss_start       /* Load start & end of bss */
        ldr   r1, =__bss_end
        add   r0, r0, r10            /* Apply physical offset */
        add   r1, r1, r10

        mov   r2, #0
1:      str   r2, [r0], #4
        cmp   r0, r1
        blo   1b

skip_bss:
        PRINT("- Setting up control registers -\r\n")

        /* Get processor specific proc info into r1 */
        mrc   CP32(r0, MIDR)                /* r0 := our cpu id */
        ldr   r1, = __proc_info_start
        add   r1, r1, r10                   /* r1 := paddr of table (start) */
        ldr   r2, = __proc_info_end
        add   r2, r2, r10                   /* r2 := paddr of table (end) */
1:      ldr   r3, [r1, #PROCINFO_cpu_mask]
        and   r4, r0, r3                    /* r4 := our cpu id with mask */
        ldr   r3, [r1, #PROCINFO_cpu_val]   /* r3 := cpu val in current proc info */
        teq   r4, r3
        beq   2f                            /* Match => exit, or try next proc info */
        add   r1, r1, #PROCINFO_sizeof
        cmp   r1, r2
        blo   1b
        mov   r4, r0
        PRINT("- Missing processor info: ")
        mov   r0, r4
        bl    putn
        PRINT(" -\r\n")
        b     fail
2:

        /* Jump to cpu_init */
        ldr   r1, [r1, #PROCINFO_cpu_init]  /* r1 := vaddr(init func) */
        adr   lr, cpu_init_done             /* Save return address */
        add   pc, r1, r10                   /* Call paddr(init func) */

cpu_init_done:
        /* Set up memory attribute type tables */
        ldr   r0, =MAIR0VAL
        ldr   r1, =MAIR1VAL
        mcr   CP32(r0, MAIR0)
        mcr   CP32(r1, MAIR1)
        mcr   CP32(r0, HMAIR0)
        mcr   CP32(r1, HMAIR1)

        /* Set up the HTCR:
         * PT walks use Outer-Shareable accesses,
         * PT walks are write-back, write-allocate in both cache levels,
         * Full 32-bit address space goes through this table. */
        ldr   r0, =0x80002500
        mcr   CP32(r0, HTCR)

        /* Set up the HSCTLR:
         * Exceptions in LE ARM,
         * Low-latency IRQs disabled,
         * Write-implies-XN disabled (for now),
         * D-cache disabled (for now),
         * I-cache enabled,
         * Alignment checking enabled,
         * MMU translation disabled (for now). */
        ldr   r0, =(HSCTLR_BASE|SCTLR_A)
        mcr   CP32(r0, HSCTLR)

        /* Rebuild the boot pagetable's first-level entries. The structure
         * is described in mm.c.
         *
         * After the CPU enables paging it will add the fixmap mapping
         * to these page tables, however this may clash with the 1:1
         * mapping. So each CPU must rebuild the page tables here with
         * the 1:1 in place. */

        /* Write Xen's PT's paddr into the HTTBR */
        ldr   r4, =boot_pgtable
        add   r4, r4, r10            /* r4 := paddr (boot_pagetable) */
        mov   r5, #0                 /* r4:r5 is paddr (boot_pagetable) */
        mcrr  CP64(r4, r5, HTTBR)

        /* Setup boot_pgtable: */
        ldr   r1, =boot_second
        add   r1, r1, r10            /* r1 := paddr (boot_second) */
        mov   r3, #0x0

        /* ... map boot_second in boot_pgtable[0] */
        orr   r2, r1, #PT_UPPER(PT)  /* r2:r3 := table map of boot_second */
        orr   r2, r2, #PT_LOWER(PT)  /* (+ rights for linear PT) */
        strd  r2, r3, [r4, #0]       /* Map it in slot 0 */

        /* ... map of paddr(start) in boot_pgtable */
        lsrs  r1, r9, #30            /* Offset of base paddr in boot_pgtable */
        beq   1f                     /* If it is in slot 0 then map in boot_second
                                      * later on */
        lsl   r2, r1, #30            /* Base address for 1GB mapping */
        orr   r2, r2, #PT_UPPER(MEM) /* r2:r3 := section map */
        orr   r2, r2, #PT_LOWER(MEM)
        lsl   r1, r1, #3             /* r1 := Slot offset */
        strd  r2, r3, [r4, r1]       /* Mapping of paddr(start) */

1:      /* Setup boot_second: */
        ldr   r4, =boot_second
        add   r4, r4, r10            /* r1 := paddr (boot_second) */

        lsr   r2, r9, #20            /* Base address for 2MB mapping */
        lsl   r2, r2, #20
        orr   r2, r2, #PT_UPPER(MEM) /* r2:r3 := section map */
        orr   r2, r2, #PT_LOWER(MEM)

        /* ... map of vaddr(start) in boot_second */
        ldr   r1, =start
        lsr   r1, #18                /* Slot for vaddr(start) */
        strd  r2, r3, [r4, r1]       /* Map vaddr(start) */

        /* ... map of paddr(start) in boot_second */
        lsrs  r1, r9, #30            /* Base paddr */
        bne   1f                     /* If paddr(start) is not in slot 0
                                      * then the mapping was done in
                                      * boot_pgtable above */

        mov   r1, r9, lsr #18        /* Slot for paddr(start) */
        strd  r2, r3, [r4, r1]       /* Map Xen there */
1:

        /* Defer fixmap and dtb mapping until after paging enabled, to
         * avoid them clashing with the 1:1 mapping. */

        /* boot pagetable setup complete */

        PRINT("- Turning on paging -\r\n")

        ldr   r1, =paging            /* Explicit vaddr, not RIP-relative */
        mrc   CP32(r0, HSCTLR)
        orr   r0, r0, #(SCTLR_M|SCTLR_C) /* Enable MMU and D-cache */
        dsb                          /* Flush PTE writes and finish reads */
        mcr   CP32(r0, HSCTLR)       /* now paging is enabled */
        isb                          /* Now, flush the icache */
        mov   pc, r1                 /* Get a proper vaddr into PC */
paging:

        /* Now we can install the fixmap and dtb mappings, since we
         * don't need the 1:1 map any more */
        dsb
#if defined(EARLY_PRINTK) /* Fixmap is only used by early printk */
        /* Non-boot CPUs don't need to rebuild the fixmap itself, just
	 * the mapping from boot_second to xen_fixmap */
        teq   r12, #0
        bne   1f

        /* Add UART to the fixmap table */
        ldr   r1, =xen_fixmap        /* r1 := vaddr (xen_fixmap) */
        mov   r3, #0
        lsr   r2, r11, #12
        lsl   r2, r2, #12            /* 4K aligned paddr of UART */
        orr   r2, r2, #PT_UPPER(DEV_L3)
        orr   r2, r2, #PT_LOWER(DEV_L3) /* r2:r3 := 4K dev map including UART */
        strd  r2, r3, [r1, #(FIXMAP_CONSOLE*8)] /* Map it in the first fixmap's slot */
1:

        /* Map fixmap into boot_second */
        ldr   r1, =boot_second       /* r1 := vaddr (xen_fixmap) */
        ldr   r2, =xen_fixmap
        add   r2, r2, r10            /* r2 := paddr (xen_fixmap) */
        orr   r2, r2, #PT_UPPER(PT)
        orr   r2, r2, #PT_LOWER(PT)  /* r2:r3 := table map of xen_fixmap */
        ldr   r4, =FIXMAP_ADDR(0)
        mov   r4, r4, lsr #18        /* r4 := Slot for FIXMAP(0) */
        strd  r2, r3, [r1, r4]       /* Map it in the fixmap's slot */

        /* Use a virtual address to access the UART. */
        ldr   r11, =EARLY_UART_VIRTUAL_ADDRESS
#endif
        /* Map the DTB in the boot misc slot */
        teq   r12, #0                /* Only on boot CPU */
        bne   1f

        ldr   r1, =boot_second
        mov   r3, #0x0
        lsr   r2, r8, #21
        lsl   r2, r2, #21            /* r2: 2MB-aligned paddr of DTB */
        orr   r2, r2, #PT_UPPER(MEM)
        orr   r2, r2, #PT_LOWER(MEM) /* r2:r3 := 2MB RAM incl. DTB */
        ldr   r4, =BOOT_FDT_VIRT_START
        mov   r4, r4, lsr #18        /* Slot for BOOT_FDT_VIRT_START */
        strd  r2, r3, [r1, r4]       /* Map it in the early fdt slot */
        dsb
1:

        PRINT("- Ready -\r\n")

        /* The boot CPU should go straight into C now */
        teq   r12, #0
        beq   launch

        /* Non-boot CPUs need to move on to the proper pagetables, which were
         * setup in init_secondary_pagetables. */

        ldr   r4, =init_ttbr         /* VA of HTTBR value stashed by CPU 0 */
        ldrd  r4, r5, [r4]           /* Actual value */
        dsb
        mcrr  CP64(r4, r5, HTTBR)
        dsb
        isb
        mcr   CP32(r0, TLBIALLH)     /* Flush hypervisor TLB */
        mcr   CP32(r0, ICIALLU)      /* Flush I-cache */
        mcr   CP32(r0, BPIALL)       /* Flush branch predictor */
        dsb                          /* Ensure completion of TLB+BP flush */
        isb

launch:
        ldr   r0, =init_data
        add   r0, #INITINFO_stack    /* Find the boot-time stack */
        ldr   sp, [r0]
        add   sp, #STACK_SIZE        /* (which grows down from the top). */
        sub   sp, #CPUINFO_sizeof    /* Make room for CPU save record */
        mov   r0, r10                /* Marshal args: - phys_offset */
        mov   r1, r8                 /*               - DTB address */
        mov   r2, r7                 /*               - CPU ID */
        teq   r12, #0
        beq   start_xen              /* and disappear into the land of C */
        b     start_secondary        /* (to the appropriate entry point) */

/* Fail-stop
 * r0: string explaining why */
fail:   PRINT("- Boot failed -\r\n")
1:      wfe
        b     1b

/* Copy Xen to new location and switch TTBR
 * r1:r0       ttbr
 * r2          source address
 * r3          destination address
 * [sp]=>r4    length
 *
 * Source and destination must be word aligned, length is rounded up
 * to a 16 byte boundary.
 *
 * MUST BE VERY CAREFUL when saving things to RAM over the copy */
ENTRY(relocate_xen)
        push {r4,r5,r6,r7,r8,r9,r10,r11}

        ldr   r4, [sp, #8*4]                /* Get 4th argument from stack */

        /* Copy 16 bytes at a time using:
         * r5:  counter
         * r6:  data
         * r7:  data
         * r8:  data
         * r9:  data
         * r10: source
         * r11: destination
         */
        mov   r5, r4
        mov   r10, r2
        mov   r11, r3
1:      ldmia r10!, {r6, r7, r8, r9}
        stmia r11!, {r6, r7, r8, r9}

        subs  r5, r5, #16
        bgt   1b

        /* Flush destination from dcache using:
         * r5: counter
         * r6: step
         * r7: vaddr
         */
        dsb        /* So the CPU issues all writes to the range */

        mov   r5, r4
        ldr   r6, =cacheline_bytes /* r6 := step */
        ldr   r6, [r6]
        mov   r7, r3

1:      mcr   CP32(r7, DCCMVAC)

        add   r7, r7, r6
        subs  r5, r5, r6
        bgt   1b

        dsb                            /* Ensure the flushes happen before
                                        * continuing */
        isb                            /* Ensure synchronization with previous
                                        * changes to text */
        mcr   CP32(r0, TLBIALLH)       /* Flush hypervisor TLB */
        mcr   CP32(r0, ICIALLU)        /* Flush I-cache */
        mcr   CP32(r0, BPIALL)         /* Flush branch predictor */
        dsb                            /* Ensure completion of TLB+BP flush */
        isb

        mcrr  CP64(r0, r1, HTTBR)

        dsb                            /* ensure memory accesses do not cross
                                        * over the TTBR0 write */
        isb                            /* Ensure synchronization with previous
                                        * changes to text */
        mcr   CP32(r0, TLBIALLH)       /* Flush hypervisor TLB */
        mcr   CP32(r0, ICIALLU)        /* Flush I-cache */
        mcr   CP32(r0, BPIALL)         /* Flush branch predictor */
        dsb                            /* Ensure completion of TLB+BP flush */
        isb

        pop {r4, r5,r6,r7,r8,r9,r10,r11}

        mov pc, lr

#ifdef EARLY_PRINTK
/* Bring up the UART.
 * r11: Early UART base address
 * Clobbers r0-r2 */
init_uart:
#ifdef EARLY_PRINTK_INIT_UART
        early_uart_init r11, r1, r2
#endif
        adr   r0, 1f
        b     puts                  /* Jump to puts */
1:      .asciz "- UART enabled -\r\n"
        .align 4

/* Print early debug messages.
 * r0: Nul-terminated string to print.
 * r11: Early UART base address
 * Clobbers r0-r1 */
puts:
        early_uart_ready r11, r1
        ldrb  r1, [r0], #1           /* Load next char */
        teq   r1, #0                 /* Exit on nul */
        moveq pc, lr
        early_uart_transmit r11, r1
        b puts

/* Print a 32-bit number in hex.  Specific to the PL011 UART.
 * r0: Number to print.
 * r11: Early UART base address
 * Clobbers r0-r3 */
putn:
        adr   r1, hex
        mov   r3, #8
1:
        early_uart_ready r11, r2
        and   r2, r0, #0xf0000000    /* Mask off the top nybble */
        ldrb  r2, [r1, r2, lsr #28]  /* Convert to a char */
        early_uart_transmit r11, r2
        lsl   r0, #4                 /* Roll it through one nybble at a time */
        subs  r3, r3, #1
        bne   1b
        mov   pc, lr

hex:    .ascii "0123456789abcdef"
        .align 2

#else  /* EARLY_PRINTK */

init_uart:
.global early_puts
early_puts:
puts:
putn:   mov   pc, lr

#endif /* !EARLY_PRINTK */

/*
 * Local variables:
 * mode: ASM
 * indent-tabs-mode: nil
 * End:
 */
