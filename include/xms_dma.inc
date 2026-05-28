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

; ---- capability flags (BX on successful QUERY) --------------------------
; Caps are fixed at install time by JIT fragment selection:
;   286 binary:  XMS_COPY | SINGLE | CONV_SINGLE
;   386+ binary: XMS_RING | RING   | CONV_SINGLE | CONV_RING

XMS_CAP_CONV_SINGLE equ 0x0001  ; conventional mem, 1 slot, single-xfer (286+)
XMS_CAP_CONV_RING   equ 0x0002  ; conventional mem, 2 slots, ring mode  (386+)
XMS_CAP_XMS_COPY    equ 0x0004  ; XMS + INT 15h single-xfer             (286)
XMS_CAP_RING        equ 0x0008  ; ring descriptor mode (386+)
XMS_CAP_SINGLE      equ 0x0010  ; single-transfer descriptor mode (286+)
XMS_CAP_XMS_RING    equ 0x0020  ; XMS + INT 15h ring mode               (386+)

; ---- memory policy (xms_rx_cfg_t.policy field) --------------------------
; Bit 0 encodes ring/single: 0=single (policies 0,2), 1=ring (policies 1,3).
; Policies >= XMS_POLICY_XMS_COPY require GDT setup (INT 15h AH=87h).

XMS_POLICY_CONV_SINGLE equ 0    ; conventional memory, single-transfer; zero CPU copies
XMS_POLICY_CONV_RING   equ 1    ; conventional memory, ring mode;        zero CPU copies
XMS_POLICY_XMS_COPY    equ 2    ; XMS + INT 15h single-xfer (286);       one CPU copy
XMS_POLICY_XMS_RING    equ 3    ; XMS + INT 15h ring mode   (386+);      one CPU copy

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

; ---- ISA 24-bit DMA physical address limit ------------------------------

DMA_ISA_16M_LIMIT   equ 0x0100  ; physical high byte must be < this (16 MB)

%endif ; XMS_DMA_INC
