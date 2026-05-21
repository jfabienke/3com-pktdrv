; cpu_detect.asm  -- CPU class detection, 8088 floor up to CPUID parts.
; NASM, 16-bit, Open Watcom register (watcall) convention.
;
;   cpu_class_t cpu_detect(cpu_info_t *out);
;     watcall: first arg (near ptr) in AX, return value in AX.
;     cpu_info_t layout:  +0 cls(word)  +2 features(word)  +4 mhz(word)
;     cls: 0=8088 1=286 2=386 3=486 4=Pentium 5=PentiumPro+
;
; The early path (8086 vs 286) is 8088-safe. 386+ paths (pushfd/cpuid) are only REACHED
; after the CPU is confirmed >=386, so `cpu 386` (assemble-time permission) is safe to run
; on an 8088.  COLD: runs once during init.

[BITS 16]
cpu 586                 ; assemble-time permission for CPUID (runtime-gated to >=486+ID)

CPU_FEAT_CPUID  equ 0x0002
CPU_FEAT_WBINVD equ 0x0008

segment COLD_TEXT public align=2 class=COLD_TEXT use16

global cpu_detect_
cpu_detect_:
        push    bx
        push    cx
        push    si
        mov     si, ax          ; si -> cpu_info_t
        xor     dx, dx          ; dx = features

        ; ---- 8086/8088 vs 286+ : top FLAGS bits stuck high on 8086 ----
        pushf
        pop     ax
        mov     cx, ax          ; save original FLAGS
        and     ax, 0x0FFF
        push    ax
        popf
        pushf
        pop     ax
        and     ax, 0xF000
        cmp     ax, 0xF000
        jne     .try286
        xor     ax, ax          ; CPU_8088
        mov     [si], ax
        jmp     .store

.try286:
        mov     ax, cx
        or      ax, 0xF000      ; try to set top bits
        push    ax
        popf
        pushf
        pop     ax
        and     ax, 0xF000
        jnz     .is386          ; settable -> 386+
        mov     word [si], 1    ; CPU_80286
        jmp     .store

.is386:
        ; AC bit (EFLAGS.18) distinguishes 386 (cannot toggle) from 486+
        pushfd
        pop     eax
        mov     ebx, eax
        xor     eax, 0x00040000
        push    eax
        popfd
        pushfd
        pop     eax
        push    ebx             ; restore original EFLAGS
        popfd
        cmp     eax, ebx
        jne     .has_ac
        mov     word [si], 2    ; CPU_80386
        jmp     .store
.has_ac:
        ; ID bit (EFLAGS.21) -> CPUID present
        pushfd
        pop     eax
        mov     ebx, eax
        xor     eax, 0x00200000
        push    eax
        popfd
        pushfd
        pop     eax
        push    ebx
        popfd
        cmp     eax, ebx
        jne     .has_cpuid
        mov     word [si], 3    ; CPU_80486 (no CPUID)
        or      dx, CPU_FEAT_WBINVD
        jmp     .store
.has_cpuid:
        or      dx, CPU_FEAT_CPUID
        or      dx, CPU_FEAT_WBINVD
        mov     eax, 1
        cpuid
        mov     cx, ax
        shr     ax, 8
        and     ax, 0x0F        ; family
        cmp     ax, 4
        jbe     .fam_486
        cmp     ax, 5
        je      .fam_pent
        mov     word [si], 5    ; PentiumPro+ (family >=6)
        jmp     .store
.fam_486:
        mov     word [si], 3
        jmp     .store
.fam_pent:
        mov     word [si], 4

.store:
        mov     [si+2], dx      ; features
        xor     ax, ax
        mov     [si+4], ax      ; mhz = 0 (TODO: PIT-based estimate)
        mov     ax, [si]        ; return class
        pop     si
        pop     cx
        pop     bx
        ret
