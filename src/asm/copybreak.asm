; copybreak.asm -- autotune the RX copybreak threshold (cold; %included by start.asm).
;
; The break point T is where DMA and PIO cost the same CPU time for a frame of length L:
;   PIO  costs  a * L      (REP INSW: per-byte CPU work, a = ns/byte)
;   DMA  costs  c          (descriptor arm + StartDmaUp + the cache flush; the per-byte transfer is
;                           the bus-master engine -- the CPU is FREE during it)
; so break-even L* = c / a. Route L > T to the conventional DMA ring, L <= T to PIO -- small frames
; never pay the DMA setup, large frames offload the slow CPU and stay off the 2-slot ring.
;
;   a  is MEASURED here by PIT-timing an ISA-I/O loop, so T adapts to the actual bus (8 vs 16 MHz).
;   c  is the per-CPU cache-flush tier (docs/12-13: 286 none, 386 software barrier, 486 WBINVD ~250us,
;      Pentium+ ~40us) plus the fixed descriptor-arm cost. (Until the Phase-2 flush probe lands, c is a
;      per-CPU-class estimate; the probe will refine it.)
; 8088 / no bus-master -> T = CB_T_MAX (all PIO). Result baked into g_copybreak_t (resident).

CB_SAMPLES   equ 2048           ; I/O reads to time (>> PIT resolution + loop overhead, < one PIT wrap)
CB_T_MIN     equ 64             ; clamp floor: below this PIO is always cheaper than the DMA setup
CB_T_MAX     equ 1514           ; clamp ceiling: a standard frame -- T>=this means "never DMA" (all PIO)
PIT_NS_TICK  equ 838            ; ~838 ns per 1.193182 MHz PIT tick

;------------------------------------------------------------------------------
; copybreak_autotune -- compute g_copybreak_t. Cold; clobbers AX BX CX DX. Call after
; phase_validate_dma (needs g_use_dma resolved) and detect_cpu (needs g_cpu_class).
;------------------------------------------------------------------------------
copybreak_autotune:
        cmp     byte [g_cpu_class], CPU_80286
        jb      .all_pio                ; 8088: 8-bit ISA, no bus-master -> always PIO
        cmp     byte [g_use_dma], 0
        je      .all_pio                ; bus-master not engaged this run -> always PIO

        ; --- a = PIO ns/byte: PIT-time CB_SAMPLES single-byte ISA reads (one ISA cycle each, the
        ;     cost a REP INSW pays per word; port 0x80 is a benign motherboard port) ---
        call    cb_pit
        mov     bx, ax                  ; t0 (PIT ch0 is a down-counter)
        mov     cx, CB_SAMPLES
.cbl:   in      al, 0x80
        loop    .cbl
        call    cb_pit                  ; t1
        sub     bx, ax                  ; elapsed ticks = t0 - t1
        jbe     .all_pio                ; wrapped / zero -> safe default
        mov     ax, bx
        mov     dx, PIT_NS_TICK
        mul     dx                      ; DX:AX = elapsed_ticks * 838 (ns for CB_SAMPLES words)
        mov     bx, CB_SAMPLES * 2      ; total bytes (2 per word)
        div     bx                      ; AX = ns/byte (a)
        or      ax, ax
        jnz     .have_a
        inc     ax                      ; a >= 1 (guard the divide below)
.have_a:
        mov     cx, ax                  ; CX = a

        ; --- c = per-CPU setup cost (ns, 32-bit) into DX:AX, then T = c / a ---
        mov     bl, [g_cpu_class]
        xor     bh, bh
        shl     bx, 1
        shl     bx, 1                   ; index * 4 (dd entries)
        mov     ax, [cb_c_table + bx]
        mov     dx, [cb_c_table + bx + 2]
        cmp     dx, cx                  ; would c/a overflow 16 bits? (high word >= divisor)
        jae     .bake_max
        div     cx                      ; AX = c / a = break-even length T
        cmp     ax, CB_T_MAX
        jae     .bake_max
        cmp     ax, CB_T_MIN
        jb      .bake_min
        mov     [g_copybreak_t], ax
        ret
.bake_max:
        mov     word [g_copybreak_t], CB_T_MAX
        ret
.bake_min:
        mov     word [g_copybreak_t], CB_T_MIN
        ret
.all_pio:
        mov     word [g_copybreak_t], CB_T_MAX
        ret

;------------------------------------------------------------------------------
; cb_pit -- latch + read PIT channel 0 counter -> AX. Cold helper.
;------------------------------------------------------------------------------
cb_pit:
        pushf
        cli
        xor     al, al                  ; channel 0, latch-count command
        out     0x43, al
        in      al, 0x40                ; LSB
        mov     ah, al
        in      al, 0x40                ; MSB
        xchg    al, ah                  ; AX = (MSB << 8) | LSB
        popf
        ret

; c (ns) per g_cpu_class = the cache-flush tier (the dominant DMA setup term) + ~descriptor arm.
cb_c_table:
        dd 0                            ; CPU_8088   (unused -- .all_pio)
        dd 3000                         ; CPU_80286  no cache: arm only
        dd 6000                         ; CPU_80386  software write barrier + arm
        dd 252000                       ; CPU_80486  WBINVD ~250 us + arm
        dd 44000                        ; CPU_CPUID  Pentium+ WBINVD ~40 us + arm
