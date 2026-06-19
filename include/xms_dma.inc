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

XMS_DMA_FUNC        equ 0xF0    ; INT 60h AH value
XMS_DMA_QUERY       equ 0x00    ; AL: query driver capabilities
XMS_DMA_CONFIGURE   equ 0x01    ; AL: configure XMS DMA receive ring (ES:DI -> cfg)
XMS_DMA_RELEASE     equ 0x02    ; AL: release ring, stop DMA
XMS_DMA_POLL        equ 0x03    ; AL: NAPI poll -- drain the conv ring from task context + re-arm the
                                ; UP_COMPLETE IRQ (the ISR masks it under load to avoid receive livelock)

; ---- capability flags (BX on successful QUERY) --------------------------

XMS_CAP_VCPI        equ 0x0001  ; VCPI DE05h page mapping (386+)
XMS_CAP_DPMI        equ 0x0002  ; DPMI 1.0 AX=0508h mapping (386+)
XMS_CAP_XMS_COPY    equ 0x0004  ; INT 15h AH=87h copy path (286+)
XMS_CAP_RING        equ 0x0008  ; ring descriptor mode (386+)
XMS_CAP_SINGLE      equ 0x0010  ; single-transfer descriptor mode (286)
XMS_CAP_CONV        equ 0x0020  ; conventional-memory zero-copy ring (deliver slot in place; Phase 3)

; ---- memory policy (xms_rx_cfg_t.policy field) --------------------------

XMS_POLICY_VCPI     equ 0       ; XMS + VCPI DE05h -> zero CPU copies
XMS_POLICY_DPMI     equ 1       ; XMS + DPMI 1.0 AX=0508h -> zero CPU copies
XMS_POLICY_XMS_COPY equ 2       ; XMS + INT 15h AH=87h staging -> one CPU copy
XMS_POLICY_CONV     equ 3       ; ring slots in CONVENTIONAL memory (phys = seg*16) -> deliver in place,
                                ; NO copy. The doc-10 zero-copy landing ring (mandatory on 286/386).
XMS_POLICY_MAX      equ 3       ; CONFIGURE validation bound (cfg.policy must be <= this)

; ---- RX ring depth -----------------------------------------------------
; CONV (conventional, contiguous) uses an N-slot ring so a windowed RX flood doesn't overrun the
; 2-slot ping-pong (Phase-3a depth limit). cfg.phys0 = the base of N contiguous slot_size-byte slots;
; slot i is at phys0 + i*slot_size. XMS_COPY stays 2 explicit slots (phys0/phys1, non-contiguous EMBs).
RX_RING_N           equ 8       ; CONV ring depth (slots); must match dos-nvmeotcp xms.h XMS_RX_RING_N

; ---- error codes (DH on CF=1) -------------------------------------------

XMS_ERR_BAD_VERSION equ 0x01   ; cfg.version != XMS_CFG_VERSION
XMS_ERR_BAD_POLICY  equ 0x02   ; cfg.policy not in xms_mem_policy_t range
XMS_ERR_PHYS_RANGE  equ 0x03   ; physical address >= DMA_ISA_16M_LIMIT
XMS_ERR_SLOT_SIZE   equ 0x04   ; cfg.slot_size > DX returned by QUERY
XMS_ERR_ALREADY_CFG equ 0x05   ; ring already configured; call RELEASE first
XMS_ERR_NOT_CFG     equ 0x06   ; RELEASE called but ring not configured

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

; Compile-time self-consistency: the ISR reads cfg via these offsets, and the producer
; (dos-nvmeotcp xms.h) lays out the matching 20-byte C struct. Catch any drift on this side.
%if XMS_CFG_lin1 + 4 != XMS_CFG_SIZE
  %error "xms_rx_cfg_t offsets inconsistent: lin1 (last field) does not end at XMS_CFG_SIZE"
%endif
%if XMS_CFG_SIZE != 20
  %error "xms_rx_cfg_t must be 20 bytes to match dos-nvmeotcp xms.h"
%endif

; ---- ISA 24-bit DMA physical address limit ------------------------------

DMA_ISA_16M_LIMIT   equ 0x0100  ; physical high byte must be < this (16 MB)

%endif ; XMS_DMA_INC
