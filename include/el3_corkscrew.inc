; el3_corkscrew.inc -- 3C515 "Corkscrew" Fast EtherLink ISA delta (3Com codename).
;
; Second generation in the EL3 lineage: 16-bit ISA, 10/100, ISA Plug-and-Play. It keeps the
; shared windowed register core (command/status at 0x0E, the same windows and commands), so
; in PIO mode its operational bring-up is the 3C509's (Window 2 MAC, Window 4 media, Window 1
; FIFO datapath). The deltas are: it is a PnP-era card (no legacy ID-port contention -- found
; via ISA PnP isolation, see isapnp.asm), a 32-byte I/O extent, and a bus-master DMA engine
; at base+0x400 that PIO mode ignores entirely.
;
; PIO mode is a deliberate stepping stone: get the card detected, configured, and moving
; frames over the shared Window-1 FIFO path first; the bus-master ring datapath (and all the
; VDS / cache-coherency / 386+ machinery it needs) is a later milestone.
;
; Identity values from the 3Com driver references (~/Development/3com-packet-driver); the
; bus-master register map is documented for the future DMA milestone, not used here.

%ifndef EL3_CORKSCREW_INC
%define EL3_CORKSCREW_INC

%include "el3_core.inc"

; ---- identity ----
; The 3C515 is detected via ISA PnP, so identity comes from the PnP serial id, not the legacy
; EEPROM product-id path. 3Com's compressed EISA vendor id is 0x6D50 ("TCM") -- the shared
; EL3_MFG_ID, the same field that flags any card in the lineage as ours. The device portion
; selects the variant within the family.
EL3_PNP_VENDOR_3COM     equ EL3_MFG_ID   ; 0x6D50 -- 3Com ("TCM"), shared across the lineage

; Corkscrew PnP device ids (low word of the EISA product id; family TCM50xx):
EL3_PNP_DEV_3C515TX     equ 0x5050   ; TCM5050  3c515-TX
EL3_PNP_DEV_3C515FX     equ 0x5051   ; TCM5051  3c515-FX
EL3_PNP_DEV_3C515TXP    equ 0x5052   ; TCM5052  3c515-TX+
EL3_PNP_DEV_3C515TXEU   equ 0x5053   ; TCM5053  3c515-TX (EU)

EL3_IO_EXTENT_CORKSCREW equ 32       ; I/O port range per NIC (vs 16 on the 3C509)

; ---- bus-master DMA register block. On the Corkscrew (and the whole 3c59x family) the master
; registers sit right after the windowed block at base+0x20..0x3F (so the real I/O extent is
; 0x40, not 0x20). Offsets per the 3Com/Linux 3c515 map. Untouched in PIO mode.
EL3_CS_DMA_BASE         equ 0x20     ; bus-master register block offset from io_base
EL3_CS_DOWN_LIST_PTR    equ 0x24     ; TX descriptor list pointer (32-bit; two 16-bit OUTs at 0x24/0x26)
EL3_CS_UP_LIST_PTR      equ 0x38     ; RX descriptor list pointer

; ---- bus-master commands (high 5 bits select, low 11 = param; see EL3_CMD encoding).
; StartDma is cmd 0x14 (<<11 = 0xA000): param != 0 -> down (TX), param 0 -> up (RX).
EL3_CMD_START_DMA_DOWN  equ 0xA001   ; kick the down (TX) descriptor at DownListPtr
EL3_CMD_START_DMA_UP    equ 0xA000   ; kick the up (RX) descriptor at UpListPtr

; ---- down/up descriptor (16 bytes, little-endian). Matches the emulator EL3DownDesc:
;   +0 next_desc (0 = single transfer)  +4 status  +8 buffer phys  +12 length
EL3_DESC_NEXT           equ 0
EL3_DESC_STATUS         equ 4
EL3_DESC_ADDR           equ 8
EL3_DESC_LEN            equ 12
EL3_DESC_SIZE           equ 16
EL3_DESC_DN_COMPLETE    equ 0x4000   ; card sets this in status when the down transfer is done
EL3_DESC_UP_COMPLETE    equ 0x4000   ; card sets this in status when the up (RX) transfer is done
EL3_DESC_LEN_MASK       equ 0x1FFF   ; 13-bit length field
RXDMA_BUFSZ             equ 4608     ; resident RX-DMA landing buffer (covers FDDI-sized frames)

; ---- non-blocking TX descriptor ring (software ring driven by single-transfer DMA + the
; TxComplete ISR). send_pkt copies the frame into a free slot and returns; the ISR frees the
; finished slot and kicks the next, overlapping CPU frame-prep with the card's DMA.
TX_RING_N               equ 4        ; ring slots (frames that can be queued in flight)
TX_SLOT_SZ              equ 1536     ; per-slot buffer (holds a max standard frame; FDDI later)

; TX-DMA completion wait: dma_tx_single sti/hlt's until the TxComplete ISR flags g_tx_done,
; bounded by ELAPSED time via the BIOS 18.2 Hz tick (0040:006C) -- NOT by a wakeup count, since
; RX (TCP-ACK) interrupts during a TX flood would otherwise drain a small spin budget and bail
; before TxComplete. A healthy transfer's drain IRQ fires in well under one tick; this many
; ticks is just the wedged-card escape (~9 * 55 ms) so the caller can't hang forever.
EL3_DMA_TX_TICKS        equ 9
BIOS_TICK_COUNT         equ 0x046C   ; 0040:006C -- low word of the BIOS timer-tick counter

; ---- Window 3 MAC control (Corkscrew has it; PIO floor leaves duplex at default) ----
EL3_CS_W3_MAC_CTRL      equ 0x06     ; Window 3 MAC control register
EL3_CS_FULL_DUPLEX      equ 0x20     ; set = full duplex (optional; not set by the PIO floor)
EL3_MAC_CTRL_ALLOW_LARGE equ 0x40    ; bit 6 = allowLargePackets: oversize at >=4491 B not 1515 (FDDI)

%endif ; EL3_CORKSCREW_INC
