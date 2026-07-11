;==============================================================================
; pci_io.asm -- PCI configuration mechanism #1 (ports 0xCF8/0xCFC).
;
; COLD-phase only, reclaimed after install. Compiled only under CFG_PCI (full
; profile); callers gate on g_cpu_class >= CPU_80386 (32-bit port I/O in
; 16-bit real mode: `in eax, dx` -- the idiom proven in frag/tx_pio_386.asm).
; Spec source: cache-kit CK_IO.C re-expressed in NASM (docs/11-pci-plan.md D2);
; no PCI BIOS INT 1Ah -- mechanism #1 only.
;
; Common register convention (all routines):
;   BX = (bus << 8) | (dev << 3) | fn      ("bus:devfn")
;   CL = configuration register offset (0..255)
; Clobbers EAX/EDX high halves freely -- cold code, no resident caller.
;==============================================================================
cpu 386

PCI_ADDR_PORT   equ 0xCF8
PCI_DATA_PORT   equ 0xCFC

;------------------------------------------------------------------------------
; pci_present -- mechanism-#1 sanity check: the address register latches and
; reads back with the enable bit. CF=0 PCI config space usable, CF=1 absent.
;------------------------------------------------------------------------------
pci_present:
        mov     dx, PCI_ADDR_PORT
        mov     eax, 0x80000000
        out     dx, eax
        in      eax, dx
        cmp     eax, 0x80000000
        je      .ok
        stc
        ret
.ok:
        clc
        ret

;------------------------------------------------------------------------------
; pci_cfg_addr -- latch the config-space address for BX/CL.
;   dword = 0x80000000 | bus<<16 | devfn<<8 | (reg & 0xFC)
; in: BX, CL. clobbers EAX, DX.
;------------------------------------------------------------------------------
pci_cfg_addr:
        movzx   eax, bh             ; bus -> bits 16..23 (after shift)
        shl     eax, 16
        mov     ah, bl              ; devfn -> bits 8..15
        mov     al, cl
        and     al, 0xFC            ; dword-aligned register select
        or      eax, 0x80000000     ; enable
        mov     dx, PCI_ADDR_PORT
        out     dx, eax
        ret

;------------------------------------------------------------------------------
; pci_cfg_read32 -- in: BX, CL (dword-aligned). out: DX:AX = value.
;------------------------------------------------------------------------------
pci_cfg_read32:
        call    pci_cfg_addr
        mov     dx, PCI_DATA_PORT
        in      eax, dx
        mov     edx, eax
        shr     edx, 16             ; DX:AX
        ret

;------------------------------------------------------------------------------
; pci_cfg_read16 -- in: BX, CL (word-aligned). out: AX = value.
;------------------------------------------------------------------------------
pci_cfg_read16:
        call    pci_cfg_addr
        mov     dx, PCI_DATA_PORT
        mov     al, cl
        and     al, 2               ; word lane within the dword
        add     dl, al
        in      ax, dx
        ret

;------------------------------------------------------------------------------
; pci_cfg_read8 -- in: BX, CL. out: AL = value.
;------------------------------------------------------------------------------
pci_cfg_read8:
        call    pci_cfg_addr
        mov     dx, PCI_DATA_PORT
        mov     al, cl
        and     al, 3               ; byte lane within the dword
        add     dl, al
        in      al, dx
        ret

;------------------------------------------------------------------------------
; pci_cfg_write16 -- in: BX, CL (word-aligned), AX = value.
;------------------------------------------------------------------------------
pci_cfg_write16:
        push    ax
        call    pci_cfg_addr        ; clobbers EAX
        mov     dx, PCI_DATA_PORT
        mov     al, cl
        and     al, 2
        add     dl, al
        pop     ax
        out     dx, ax
        ret

cpu 8086
