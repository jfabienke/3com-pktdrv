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

; ---- bus-master list-pointer registers. HARDWARE-TRUE offsets differ by bus (docs/11 D3.1,
; from Becker 3c515.c `MasterCtrl` + iPXE 3c90x.h): the ISA 3C515 aliases the master block at
; base+0x400 (its windowed ISA extent stops at 0x1F -- base+0x20 is NOT decoded); the PCI 90x
; parts put it at BAR0+0x20. build_plan resolves the pair into the resident words
; g_dnlist_off/g_uplist_off; all datapath code uses those. Writing a non-zero list pointer
; STARTS the engine (the old StartDma command is the Vortex/515 Wn7 single-shot interface --
; never issued on the list-DMA path). A 16-bit driver writes low half then high half; the
; engine starts on the high-half write.
EL3_DN_LIST_ISA         equ 0x404    ; 3C515: DownListPtr (base+0x404/0x406)
EL3_UP_LIST_ISA         equ 0x418    ; 3C515: UpListPtr   (base+0x418/0x41A)
EL3_DN_LIST_PCI         equ 0x24     ; 3C90x: DnListPtr   (BAR0+0x24/0x26)
EL3_UP_LIST_PCI         equ 0x38    ; 3C90x: UpListPtr   (BAR0+0x38/0x3A)

; ---- down/up descriptor (16 bytes, little-endian; the Boomerang DPD/UPD shape):
;   +0 next_desc (0 = end of list)  +4 status/FSH  +8 buffer phys  +12 length
; Completion write-backs are HARDWARE-TRUE (Becker/iPXE, unanimous): the down engine sets
; FSH bit 16 (fshDnComplete -> bit 0 of the word at +6); the up engine writes UpPktStatus =
; upComplete (bit 15) | packet length into the dword at +4. There is NO ownership bit.
EL3_DESC_NEXT           equ 0
EL3_DESC_STATUS         equ 4        ; low word of the status/FSH dword
EL3_DESC_STATUS_HI      equ 6        ; high word of the status/FSH dword
EL3_DESC_ADDR           equ 8
EL3_DESC_LEN            equ 12       ; low word of the length dword
EL3_DESC_LEN_HI         equ 14       ; high word of the length dword
EL3_DESC_SIZE           equ 16
EL3_DESC_DN_COMPLETE_HI equ 0x0001   ; FSH bit16 (in the word at +6): download complete
EL3_DESC_UP_COMPLETE    equ 0x8000   ; UpPktStatus bit15 (in the word at +4): upload complete
EL3_FSH_TX_INDICATE     equ 0x8000   ; FSH bit15 (word at +4): request TxComplete + TxStatus
; Cyclone (3C905B+) checksum-insertion requests: FSH bits 25/26/27 (Linux AddIP/TCP/UDPChksum)
; -- expressed as the word at +6 (EL3_DESC_STATUS_HI).
EL3_FSH_ADD_IP_HI       equ 0x0200   ; insert IP header checksum
EL3_FSH_ADD_TCP_HI      equ 0x0400   ; insert TCP checksum
EL3_FSH_ADD_UDP_HI      equ 0x0800   ; insert UDP checksum
EL3_DESC_LAST_FRAG_HI   equ 0x8000   ; length-dword bit31 (word at +14): last fragment
EL3_DESC_LEN_MASK       equ 0x1FFF   ; 13-bit length field

; ---- non-blocking TX descriptor ring (software ring driven by single-transfer DMA + the
; TxComplete ISR). send_pkt copies the frame into a free slot and returns; the ISR frees the
; finished slot and kicks the next, overlapping CPU frame-prep with the card's DMA.
TX_RING_N               equ 4        ; ring slots (frames in flight). Back to the baseline now that the
                                     ; root fix (ring-full -> wait-for-drain, never PIO into an active ring
                                     ; stream -- see dma_tx_enqueue / EL3_DMA_TX_WEDGE_TICKS) makes FIFO
                                     ; order independent of depth. A deeper ring (8, conventional max under
                                     ; FDDI slots; >8 needs an XMS-backed ring) is now only a throughput
                                     ; layer -- it reduces how often the foreground must wait -- not a
                                     ; correctness lever. Re-evaluate after measuring the root fix clean.
TX_SLOT_SZ              equ 4608     ; per-slot buffer -- FDDI-sized so the ring can DMA large frames
                                     ; (matches the stack's txbuf[4608] and the emulator's
                                     ; EL3_LARGE_FRAME_MAX). 4*4608 = 18 KB, kept only on the 386+
                                     ; ring DMA path (resident_end); the PIO floor drops it.
EL3_MAX_FRAME_LARGE     equ 4490     ; max interoperable large (FDDI) TX frame, excl FCS. Equals the
                                     ; card's allowLargePackets oversize threshold - 1 (and the
                                     ; emulator's EL3_LARGE_RX_MAX): a bigger frame is RX-dropped as
                                     ; oversize by a peer, so the TX path must not exceed it.

; R1.c Stage 1 (docs/13): driver-resident N-slot RX-DMA ring. Circular NEXT-chained UPDs over a
; conventional-memory buffer pool (phys < 1 MB -> ISA-DMA-safe by construction). Depth 4 gives the
; up engine enough slack that it never starves in the driver's re-arm gap (#6). Std-MTU only; the
; per-slot stride pads EL3_MAX_FRAME (1514) up to a paragraph so each slot begins seg:0.
EL3_RX_RING_N           equ 4        ; N-slot ring depth (<= RX_DMA_SLOTS ABI max of 8)
EL3_RX_SLOT_STRIDE      equ 1520     ; EL3_MAX_FRAME rounded up to 16 (paragraph-aligned slots)

; TX-DMA completion wait: dma_tx_single sti/hlt's until the TxComplete ISR flags g_tx_done,
; bounded by ELAPSED time via the BIOS 18.2 Hz tick (0040:006C) -- NOT by a wakeup count, since
; RX (TCP-ACK) interrupts during a TX flood would otherwise drain a small spin budget and bail
; before TxComplete. A healthy transfer's drain IRQ fires in well under one tick; this many
; ticks is just the wedged-card escape (~9 * 55 ms) so the caller can't hang forever.
EL3_DMA_TX_TICKS        equ 9
; Ring-full wait (foreground, 486+ ring). The foreground MUST wait for the TxComplete ISR to free
; a slot -- it must NOT fall back to PIO, because a PIO burst jumps the TX FIFO ahead of the frames
; still queued in the DMA ring -> out-of-order TX -> TCP dupack/retransmit storm (the 515dma100
; write collapse). So this bound is a genuine-WEDGE escape ONLY (dead card): generous enough that a
; normal deferred-completion stall never reaches it; on expiry the frame is rejected CANT_SEND (the
; stack retransmits in order), never PIO'd. ~5 s.
EL3_DMA_TX_WEDGE_TICKS  equ 91
BIOS_TICK_COUNT         equ 0x046C   ; 0040:006C -- low word of the BIOS timer-tick counter

; ---- Window 3 MAC control (Corkscrew has it; PIO floor leaves duplex at default) ----
EL3_CS_W3_MAC_CTRL      equ 0x06     ; Window 3 MAC control register
EL3_CS_FULL_DUPLEX      equ 0x20     ; set = full duplex (optional; not set by the PIO floor)
EL3_MAC_CTRL_ALLOW_LARGE equ 0x40    ; bit 6 = allowLargePackets: oversize at >=4491 B not 1515 (FDDI)

%endif ; EL3_CORKSCREW_INC
