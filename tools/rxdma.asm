; rxdma.asm -- bus-master RX-DMA throughput probe (DOS .COM, nasm -f bin).
;
; Posts a conventional-memory RX-DMA descriptor RING to the emulated 3c515, issues StartDmaUp, arms
; the emulator's rxgen wire-rate generator, then spins recycling completed descriptors. The emulator
; DMAs each generated frame into a ring buffer paced at dma_rate (the ISA bus-master ceiling), counts
; the deliveries over its virtual window, and prints [RXGEN] ... Mbit/s to stderr -- the bus-master
; RX rate, CPU-free (zero-copy: the probe never touches the payload, only recycles descriptors).
;
; Run AFTER 3cpd (which enables RX). The NIC IRQ is masked so 3cpd's ISR can't interfere -- delivery
; and counting are entirely emulator-side. Hardcodes iobase 0x300 (the harness uses /b=300).
; Build: nasm -f bin tools/rxdma.asm -o build/rxdma.com

        org     0x100
        bits    16

IOBASE      equ 0x300
CMD_REG     equ IOBASE + 0x0E       ; command/status register (window-independent)
W1_TIMER    equ IOBASE + 0x0A       ; rxgen arm trigger (window 1)
UPLIST_LO   equ IOBASE + 0x20 + 0x18  ; UpListPtr low  = 0x338
UPLIST_HI   equ IOBASE + 0x20 + 0x1A  ; UpListPtr high = 0x33A
NDESC       equ 16
BUFSZ       equ 1600
UP_COMPLETE equ 0x4000              ; EL3_DESC_UP_COMPLETE (low word of desc.status)
CMD_STARTUP equ 0xA000             ; StartDmaUp = command 0x14 << 11, param 0
CMD_SELWIN1 equ 0x0801             ; SELECT_WINDOW | 1
RXGEN_ARM   equ 0x5247             ; magic 'RG' to W1_TIMER

start:
        cld
        push    cs
        pop     ds
        push    cs
        pop     es

        ; --- build the ring: desc[i] = { next=phys(desc[(i+1)%N]), status=0, addr=phys(buf[i]), len } ---
        xor     si, si                  ; i
        mov     di, descs               ; -> desc[i]
.init:
        ; next_desc = phys(desc[(i+1) mod N])
        mov     bx, si
        inc     bx
        cmp     bx, NDESC
        jb      .nowrap
        xor     bx, bx
.nowrap:
        shl     bx, 4                   ; *16
        add     bx, descs               ; offset of desc[(i+1)%N]
        call    calc_phys               ; DX:AX = phys
        mov     [di+0], ax
        mov     [di+2], dx
        ; status = 0
        xor     ax, ax
        mov     [di+4], ax
        mov     [di+6], ax
        ; addr = phys(buf[i]) ; buf[i] = bufs + i*BUFSZ
        mov     ax, si
        mov     bx, BUFSZ
        mul     bx                      ; AX = i*BUFSZ (fits 16-bit for i<16, BUFSZ=1600)
        add     ax, bufs
        mov     bx, ax
        call    calc_phys
        mov     [di+8], ax
        mov     [di+10], dx
        ; length = BUFSZ (capacity)
        mov     word [di+12], BUFSZ
        mov     word [di+14], 0
        add     di, 16
        inc     si
        cmp     si, NDESC
        jb      .init

        ; --- UpListPtr = phys(desc[0]) (two 16-bit halves) ---
        mov     bx, descs
        call    calc_phys               ; DX:AX = phys(desc[0])
        push    dx
        mov     dx, UPLIST_LO
        out     dx, ax                  ; low 16
        pop     ax                      ; high 16 (was DX)
        mov     dx, UPLIST_HI
        out     dx, ax

        ; --- StartDmaUp (arm bus-master receive) ---
        mov     dx, CMD_REG
        mov     ax, CMD_STARTUP
        out     dx, ax

        ; --- mask NIC IRQ10 (slave PIC bit 2) so 3cpd's ISR stays out of the way ---
        in      al, 0xA1
        or      al, 0x04
        out     0xA1, al

        ; --- arm the rxgen generator: select window 1, write magic to W1_TIMER ---
        mov     dx, CMD_REG
        mov     ax, CMD_SELWIN1
        out     dx, ax
        mov     dx, W1_TIMER
        mov     ax, RXGEN_ARM
        out     dx, ax

        ; print a marker so the harness knows we armed (serial via DOS, brief)
        mov     dx, msg_armed
        mov     ah, 9
        int     0x21

        ; --- recycle loop: clear any completed descriptor so the ring never stalls. The emulator
        ;     counts deliveries + prints [RXGEN]; the harness kills QEMU once it sees that line. ---
.recycle:
        mov     si, descs
        mov     cx, NDESC
.scan:
        test    word [si+4], UP_COMPLETE
        jz      .next
        mov     word [si+4], 0          ; recycle (clear status low word)
        mov     word [si+6], 0
.next:
        add     si, 16
        loop    .scan
        jmp     .recycle

; calc_phys: BX = offset in our segment -> DX:AX = 20-bit physical address (DS:offset)
calc_phys:
        push    cx
        mov     ax, ds
        mov     dx, ax
        shr     dx, 12                  ; DX = ds >> 12  (high 4 bits of ds<<4)
        mov     cl, 4
        shl     ax, cl                  ; AX = (ds << 4) & 0xFFF0
        add     ax, bx                  ; + offset
        adc     dx, 0                   ; carry into high
        pop     cx
        ret

msg_armed   db 'RXDMA-ARMED', 13, 10, '$'

        align 16
descs:      times NDESC*16 db 0         ; ring of NDESC 16-byte EL3UpDesc
bufs:       times NDESC*BUFSZ db 0      ; one RX buffer per descriptor
