; xms_dma.inc -- NASM constant mirror of include/xms_dma.h.
;
; Proprietary INT 60h AH=0xF0 extension: XMS DMA receive ring.
; Allows nvmetsr.exe to hand 3cpd.exe the physical/linear addresses of
; XMS-resident receive buffers so the 3C515 bus-master can DMA directly
; into extended memory, bypassing conventional memory from the RX hotpath.
;
; See docs/09-xms-dma-ext.md for the full design.

%ifndef XMS_DMA_INC
%define XMS_DMA_INC

; ---- function and sub-function codes ------------------------------------

XMS_DMA_FUNC          equ 0xF0  ; INT 60h AH value
XMS_DMA_QUERY         equ 0x00  ; AL: query driver capabilities
XMS_DMA_CONFIGURE     equ 0x01  ; AL: configure XMS DMA receive ring (ES:DI -> xms_rx_cfg_t)
XMS_DMA_RELEASE       equ 0x02  ; AL: release ring, stop DMA
; ---- v2 sub-functions (Phase 8b copybreak; see docs/10-copybreak-ext.md) ----
; 0x03..0x06 are DEFINED here but currently STUBBED (return CF=1, DH=XMS_ERR_NOT_V2)
; until the implementing increment lands. The single source of truth is this file +
; include/xms_dma.h + dos-nvmeotcp/src/xms.h, cross-checked by tools/abi_check.sh.
XMS_DMA_RX_CONFIGURE2 equ 0x03  ; AL: N-slot RX ring + completion/free rings (ES:DI -> xms_rx_cfg2_t)
XMS_DMA_TX_CONFIGURE  equ 0x04  ; AL: register caller TX slot pool, once (ES:DI -> xms_tx_cfg_t)
XMS_DMA_TX_SUBMIT     equ 0x05  ; AL: submit one TX frame from caller phys (DX:CX=phys, BX=len)
XMS_DMA_RX_REFILL     equ 0x06  ; AL: reserved RX free-ring doorbell
XMS_DMA_CSUM_CTL      equ 0x07  ; AL: BX=1 enable / 0 disable Cyclone HW checksum insertion
                                ;     (driver then requests IP+TCP/UDP checksums per DMA TX frame;
                                ;      the stack must leave the checksum fields zero while enabled)

; ---- capability flags (BX on successful QUERY) --------------------------
; Caps are fixed at install time by JIT fragment selection (the ring tier is gated
; on g_tx_ring, which is 486+ since Phase 8b.1 -- 286/386 use single-transfer):
;   286/386: CONV_SINGLE
;   486+   : XMS_RING | RING | CONV_SINGLE | CONV_RING

XMS_CAP_CONV_SINGLE equ 0x0001  ; conventional mem, 1 slot, single-xfer (286+)
XMS_CAP_CONV_RING   equ 0x0002  ; conventional mem, 2 slots, ring mode  (486+)
; 0x0004 = RESERVED/DEPRECATED (was XMS_CAP_XMS_COPY; XMS_COPY policy dropped) -- never reuse
XMS_CAP_RING        equ 0x0008  ; ring descriptor mode (486+)
; 0x0010 = RESERVED (was a stack-only XMS_CAP_SINGLE; unused by the driver) -- never reuse
XMS_CAP_XMS_RING    equ 0x0020  ; XMS + INT 15h ring mode               (486+)
XMS_CAP_RX_DESC_V2  equ 0x0040  ; N-slot RX ring + completion/free rings (advertised by the RX vertical)
XMS_CAP_XMS_TX      equ 0x0080  ; caller-phys TX submit path             (advertised by the TX vertical)
XMS_CAP_HWCSUM      equ 0x0100  ; Cyclone (3C905B+): HW IP/TCP/UDP checksum insertion on DMA TX

; ---- memory policy (xms_rx_cfg_t.policy field) --------------------------
; CONV_SINGLE(0) is the only single-transfer policy; CONFIGURE uses a single CMP.
; Policies >= XMS_POLICY_XMS_RING(2) require GDT setup (INT 15h AH=87h).

XMS_POLICY_CONV_SINGLE equ 0    ; conventional memory, single-transfer; zero CPU copies
XMS_POLICY_CONV_RING   equ 1    ; conventional memory, ring mode;        zero CPU copies
XMS_POLICY_XMS_RING    equ 2    ; XMS + INT 15h ring mode   (486+);      one CPU copy

; ---- error codes (DH on CF=1) -------------------------------------------

XMS_ERR_BAD_VERSION equ 0x01   ; cfg.version != XMS_CFG_VERSION
XMS_ERR_BAD_POLICY  equ 0x02   ; cfg.policy not in xms_mem_policy_t range
XMS_ERR_PHYS_RANGE  equ 0x03   ; physical address >= DMA_ISA_16M_LIMIT
XMS_ERR_SLOT_SIZE   equ 0x04   ; cfg.slot_size > DX returned by QUERY
XMS_ERR_ALREADY_CFG equ 0x05   ; ring already configured; call RELEASE first
XMS_ERR_NOT_CFG     equ 0x06   ; RELEASE called but ring not configured
XMS_ERR_BAD_NSLOTS  equ 0x07   ; cfg2.n_slots out of range [2, RX_DMA_SLOTS]
XMS_ERR_TX_NOT_CFG  equ 0x08   ; TX_SUBMIT before TX_CONFIGURE
XMS_ERR_TX_RANGE    equ 0x09   ; TX_SUBMIT phys/len outside the registered pool
XMS_ERR_NOT_V2      equ 0x0A   ; v2 sub-function recognized but not implemented in this build
; 0x0B is the packet-driver PD_ERR_BADCMD (genuinely-unknown AL) -- do not reuse for an XMS error
XMS_ERR_TX_BUSY     equ 0x0C   ; a TX_SUBMIT single-transfer is already in flight (transient, retry)
XMS_ERR_TX_TIMEOUT  equ 0x0D   ; no TxComplete within the bound -- card wedged (slot not safely reusable)
XMS_ERR_NO_CSUM     equ 0x0E   ; CSUM_CTL on a NIC without HW checksum (not a Cyclone) or PIO mode

; ---- configuration structure (xms_rx_cfg_t) offsets --------------------
; Matches the C struct in include/xms_dma.h exactly (20 bytes total).

XMS_CFG_VERSION     equ 1       ; cfg.version must equal this

XMS_CFG_version     equ 0       ; uint8_t  version
XMS_CFG_policy      equ 1       ; uint8_t  policy
XMS_CFG_slot_size   equ 2       ; uint16_t slot_size
XMS_CFG_phys0       equ 4       ; uint32_t phys0
XMS_CFG_lin0        equ 8       ; uint32_t lin0
XMS_CFG_phys1       equ 12      ; uint32_t phys1
XMS_CFG_lin1        equ 16      ; uint32_t lin1
XMS_CFG_SIZE        equ 20

; ---- v2 wire structs (Phase 8b) -----------------------------------------
; PINNED layouts; must byte-match include/xms_dma.h and dos-nvmeotcp/src/xms.h.
; tools/abi_check.sh enforces these offsets against the stack C offsetof().

XMS_CFG2_VERSION    equ 2       ; xms_rx_cfg2_t.version must equal this
XMS_TX_CFG_VERSION  equ 1       ; xms_tx_cfg_t.version must equal this
RX_DMA_SLOTS        equ 8       ; max N-slot RX ring depth
TXSLOT_HEADROOM     equ 128     ; reserved header prefix in each TX slot

; xms_rx_cfg2_t (ES:DI -> RX_CONFIGURE2), 24 bytes
XMS_CFG2_version    equ 0       ; uint8_t  version (=2)
XMS_CFG2_policy     equ 1       ; uint8_t  policy
XMS_CFG2_n_slots    equ 2       ; uint16_t n_slots
XMS_CFG2_slot_size  equ 4       ; uint16_t slot_size
XMS_CFG2_compl_n    equ 6       ; uint16_t compl_ring_n
XMS_CFG2_free_n     equ 8       ; uint16_t free_ring_n
XMS_CFG2_reserved   equ 10      ; uint16_t reserved
XMS_CFG2_slots_lin  equ 12      ; uint32_t slots_lin       (seg:off of xms_slot_desc_t[])
XMS_CFG2_compl_lin  equ 16      ; uint32_t compl_ring_lin  (seg:off of completion ring)
XMS_CFG2_free_lin   equ 20      ; uint32_t free_ring_lin   (seg:off of free ring)
XMS_CFG2_SIZE       equ 24

; xms_slot_desc_t (array at slots_lin), 8 bytes
XMS_SLOT_phys       equ 0       ; uint32_t phys (<16MB, NIC-visible)
XMS_SLOT_lin        equ 4       ; uint32_t lin  (seg:off CPU alias, 0 if XMS-only)
XMS_SLOT_SIZE       equ 8

; xms_ring_hdr_t (prefix of each ring), 8 bytes
XMS_RING_head       equ 0       ; uint16_t head
XMS_RING_tail       equ 2       ; uint16_t tail
XMS_RING_mask       equ 4       ; uint16_t mask (n_entries-1, power of two)
XMS_RING_rsv        equ 6       ; uint16_t reserved
XMS_RING_SIZE       equ 8

; xms_rx_compl_t (completion ring entry, driver->stack), 8 bytes
XMS_COMPL_slot_id   equ 0       ; uint16_t slot_id
XMS_COMPL_len       equ 2       ; uint16_t len
XMS_COMPL_status    equ 4       ; uint16_t status
XMS_COMPL_seq       equ 6       ; uint16_t seq
XMS_COMPL_SIZE      equ 8

; xms_rx_free_t (free ring entry, stack->driver), 2 bytes
XMS_FREE_slot_id    equ 0       ; uint16_t slot_id
XMS_FREE_SIZE       equ 2

; xms_tx_cfg_t (ES:DI -> TX_CONFIGURE), 12 bytes
XMS_TXCFG_version   equ 0       ; uint8_t  version (=1)
XMS_TXCFG_flags     equ 1       ; uint8_t  flags (bit0=pool is XMS)
XMS_TXCFG_reserved  equ 2       ; uint16_t reserved
XMS_TXCFG_pool_phys equ 4       ; uint32_t pool_phys (<16MB)
XMS_TXCFG_pool_len  equ 8       ; uint32_t pool_len
XMS_TXCFG_SIZE      equ 12

; ---- ISA 24-bit DMA physical address limit ------------------------------

DMA_ISA_16M_LIMIT   equ 0x0100  ; physical high byte must be < this (16 MB)

%endif ; XMS_DMA_INC
