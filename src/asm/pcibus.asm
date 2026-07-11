;==============================================================================
; pcibus.asm -- PCI bus prober: find the first 3Com EtherLink III PCI NIC.
;
; COLD-phase, CFG_PCI only, >=386 (caller gates -- mechanism #1 needs 32-bit
; port I/O). Fills the exact same globals the ISA probes fill, so everything
; downstream (el3_init, build_plan, compose, install) is unchanged:
;   g_nic_io   <- BAR0 & ~3      (I/O-space BAR; Vortex/Boomerang are port-mapped)
;   g_nic_irq  <- config 0x3C    (BIOS-routed interrupt line)
;   g_nic_gen  <- device-id map  (NIC_GEN_VORTEX / _BOOMERANG / _CYCLONE)
;   g_mac      <- Window-0 EEPROM (Vortex+ keeps the 3C509 W0 EEPROM registers)
; and enables I/O decode + bus mastering in the PCI command register.
;
; Scan: buses 0..7, function 0 only (EtherLink III PCI parts are single-
; function). Design contract: docs/11-pci-plan.md D2.
;==============================================================================
cpu 386

PCI_VENDOR_3COM equ 0x10B7

; device-id -> generation map. Tornado (3C905C) runs the Cyclone datapath.
pci_el3_ids:
        dw      0x5900
        db      NIC_GEN_VORTEX          ; 3C590 (10 Mbit Vortex)
        dw      0x5950
        db      NIC_GEN_VORTEX          ; 3C595-TX (100 Mbit Vortex)
        dw      0x9000
        db      NIC_GEN_BOOMERANG       ; 3C900-TPO
        dw      0x9001
        db      NIC_GEN_BOOMERANG       ; 3C900-Combo
        dw      0x9050
        db      NIC_GEN_BOOMERANG       ; 3C905-TX
        dw      0x9051
        db      NIC_GEN_BOOMERANG       ; 3C905-T4
        dw      0x9055
        db      NIC_GEN_CYCLONE         ; 3C905B-TX
        dw      0x9200
        db      NIC_GEN_CYCLONE         ; 3C905C-TX (Tornado)
PCI_EL3_IDS_N   equ 8

;------------------------------------------------------------------------------
; detect_nic_pci -- CF=0 found (globals filled, card enabled), CF=1 none.
; Clobbers everything cold-legal (AX/BX/CX/DX/SI + EAX/EDX high halves; the
; el3_load_mac_io tail clobbers BP/DI too).
;------------------------------------------------------------------------------
detect_nic_pci:
        call    pci_present
        jc      .fail
        xor     bx, bx              ; BH = bus 0, BL = devfn 0
.scan:
        xor     cl, cl              ; register 0: device:vendor dword
        call    pci_cfg_read32      ; DX:AX = device:vendor
        cmp     ax, PCI_VENDOR_3COM
        jne     .next
        ; 3Com part -- match the device id against the EL3 table.
        mov     si, pci_el3_ids
        mov     cx, PCI_EL3_IDS_N
.match:
        cmp     dx, [si]
        je      .found
        add     si, 3
        loop    .match
        ; a 3Com device we don't drive (e.g. 3C985 gigabit) -- keep scanning
.next:
        add     bl, 8               ; next device slot (function 0 only)
        jnz     .scan
        inc     bh
        cmp     bh, 8               ; buses 0..7 cover period machines
        jb      .scan
.fail:
        stc
        ret

.found:
        mov     al, [si + 2]
        mov     [g_nic_gen], al

        ; BAR0 must be an I/O BAR (bit 0); mask the low type bits for the base.
        mov     cl, 0x10
        call    pci_cfg_read32      ; DX:AX = BAR0
        test    al, 1
        jz      .fail               ; memory BAR here would be a config we don't drive
        and     ax, 0xFFFC
        mov     [g_nic_io], ax

        ; Interrupt line as routed by the BIOS (must be a usable master/slave IRQ).
        mov     cl, 0x3C
        call    pci_cfg_read8
        cmp     al, 1
        jb      .fail
        cmp     al, 15
        ja      .fail
        xor     ah, ah
        mov     [g_nic_irq], ax

        ; Enable I/O decode (bit 0) + bus mastering (bit 2). Mastering is set now
        ; even for the PIO-only Vortex path -- harmless, and the Boomerang DMA
        ; datapath (Phase 2) depends on it.
        mov     cl, 0x04
        call    pci_cfg_read16
        or      ax, 0x0005
        call    pci_cfg_write16     ; BX/CL still hold busdevfn/0x04

        ; MAC via Window-0 EEPROM at the plain 3C509 offsets (gen != 1 path --
        ; only the ISA 3C515 uses the +0x2000 alias).
        call    el3_load_mac_io
        clc
        ret

cpu 8086
