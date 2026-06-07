/*
 * xms_dma.h — Proprietary INT 60h extension: DMA receive ring configuration.
 *
 * Allows nvmetsr.exe to hand 3cpd.exe the physical/linear addresses of
 * receive buffers so the 3C515 bus-master can DMA directly into them.
 *
 * Three buffer classes are supported:
 *   CONV_SINGLE  conventional memory, 1 slot, single-transfer       (286+  / 10  Mbps)
 *   CONV_RING    conventional memory, 2 slots, ring mode            (486+ / 100  Mbps)
 *   XMS_RING     XMS extended memory, 2 slots, ring + INT 15h copy  (486+ / 100  Mbps)
 *
 * XMS single-transfer (286 + HIMEM) is not supported: INT 15h AH=87h on a
 * 286SX/16 costs ~1200-1800 us, consuming the entire 10 Mbps inter-frame gap.
 * CONV_SINGLE is always available on 286+ at zero copy cost.
 *
 * Caps are fixed at install time by CPU-generation JIT fragment selection.
 * On sub-286 or when QUERY returns CF=1, caller falls back to PIO.
 *
 * See docs/09-xms-dma-ext.md for the full design.
 */
#ifndef PKTDRV_XMS_DMA_H
#define PKTDRV_XMS_DMA_H

#include <stdint.h>

/* ---- function and sub-function codes ----------------------------------- */

#define XMS_DMA_FUNC        0xF0u   /* INT 60h AH value; above standard Crynwr range (1-28) */

#define XMS_DMA_QUERY       0x00u   /* AL: query driver capabilities                        */
#define XMS_DMA_CONFIGURE   0x01u   /* AL: configure XMS DMA receive ring (ES:DI → cfg)     */
#define XMS_DMA_RELEASE     0x02u   /* AL: release ring, stop DMA, restore conventional path */

/* v2 sub-functions (Phase 8b copybreak; see docs/10-copybreak-ext.md). Defined but
 * currently stubbed (CF=1, DH=XMS_ERR_NOT_V2) until the implementing increment lands.
 * Single source of truth: this file + xms_dma.inc + dos-nvmeotcp/src/xms.h,
 * cross-checked by tools/abi_check.sh. */
#define XMS_DMA_RX_CONFIGURE2 0x03u /* AL: N-slot RX ring + completion/free rings (ES:DI → xms_rx_cfg2_t) */
#define XMS_DMA_TX_CONFIGURE  0x04u /* AL: register caller TX slot pool, once (ES:DI → xms_tx_cfg_t)      */
#define XMS_DMA_TX_SUBMIT     0x05u /* AL: submit one TX frame from caller phys (DX:CX=phys, BX=len)       */
#define XMS_DMA_RX_REFILL     0x06u /* AL: reserved RX free-ring doorbell                                  */

/* ---- capability flags (BX on successful QUERY) ------------------------- */
/*
 * Caps are fixed at install time by JIT fragment selection (the ring tier is gated on
 * g_tx_ring, which is 486+ since Phase 8b.1 -- 286/386 use single-transfer):
 *   286/386: CONV_SINGLE
 *   486+   : XMS_RING | RING | CONV_SINGLE | CONV_RING
 */
#define XMS_CAP_CONV_SINGLE 0x0001u /* conventional mem, 1 slot, single-xfer (286+)  */
#define XMS_CAP_CONV_RING   0x0002u /* conventional mem, 2 slots, ring mode  (486+)  */
/* 0x0004 = RESERVED/DEPRECATED (was XMS_CAP_XMS_COPY; XMS_COPY policy dropped) -- never reuse */
#define XMS_CAP_RING        0x0008u /* ring descriptor mode (486+)                   */
/* 0x0010 = RESERVED (was a stack-only XMS_CAP_SINGLE; unused by the driver) -- never reuse */
#define XMS_CAP_XMS_RING    0x0020u /* XMS + INT 15h ring mode               (486+)  */
#define XMS_CAP_RX_DESC_V2  0x0040u /* N-slot RX ring + completion/free rings (RX vertical) */
#define XMS_CAP_XMS_TX      0x0080u /* caller-phys TX submit path             (TX vertical) */

/* ---- memory policy ----------------------------------------------------- */
/*
 * CONV_SINGLE is the only single-transfer policy; CONFIGURE NEXT setup uses a
 * single compare. Policies ≥ XMS_RING(2) require GDT setup for INT 15h AH=87h.
 */
typedef enum {
    XMS_POLICY_CONV_SINGLE = 0, /* conventional memory, single-transfer; zero CPU copies  */
    XMS_POLICY_CONV_RING   = 1, /* conventional memory, ring mode;        zero CPU copies  */
    XMS_POLICY_XMS_RING    = 2, /* XMS + INT 15h ring mode   (486+);       one CPU copy   */
} xms_mem_policy_t;
/* No policy value = no extension call; standard Crynwr PIO path */

/* ---- error codes (DH on CF=1) ------------------------------------------ */

#define XMS_ERR_BAD_VERSION 0x01u   /* cfg.version != XMS_CFG_VERSION             */
#define XMS_ERR_BAD_POLICY  0x02u   /* cfg.policy not in xms_mem_policy_t range   */
#define XMS_ERR_PHYS_RANGE  0x03u   /* physical address >= DMA_ISA_16M_LIMIT      */
#define XMS_ERR_SLOT_SIZE   0x04u   /* cfg.slot_size > DX returned by QUERY       */
#define XMS_ERR_ALREADY_CFG 0x05u   /* ring already configured; call RELEASE first */
#define XMS_ERR_NOT_CFG     0x06u   /* RELEASE called but ring not configured      */
#define XMS_ERR_BAD_NSLOTS  0x07u   /* cfg2.n_slots out of range [2, RX_DMA_SLOTS] */
#define XMS_ERR_TX_NOT_CFG  0x08u   /* TX_SUBMIT before TX_CONFIGURE               */
#define XMS_ERR_TX_RANGE    0x09u   /* TX_SUBMIT phys/len outside the pool         */
#define XMS_ERR_NOT_V2      0x0Au   /* v2 sub-function recognized but not implemented in this build */
/* 0x0B is PD_ERR_BADCMD (genuinely-unknown AL) -- do not reuse for an XMS error */
#define XMS_ERR_TX_BUSY     0x0Cu   /* a TX_SUBMIT single-transfer is already in flight (transient) */
#define XMS_ERR_TX_TIMEOUT  0x0Du   /* no TxComplete within the bound -- card wedged */

/* ---- configuration structure (passed via ES:DI to CONFIGURE) ----------- */

#define XMS_CFG_VERSION     1u      /* cfg.version must equal this */
#define XMS_CFG_N_SLOTS     2u      /* fixed: 2-slot ping-pong ring (486+ ring mode only) */

/*
 * xms_rx_cfg_t — caller-allocated, must remain resident for the lifetime of
 * the DMA ring.  3cpd.exe stores ES:DI and reads lin0/lin1 in the ISR hotpath.
 *
 * phys0/phys1: VDS-locked physical addresses (< DMA_ISA_16M_LIMIT).
 *              Written into EL3_DESC_ADDR of the two ring descriptors.
 * lin0/lin1:   VCPI/DPMI mapped linear addresses, valid as real-mode far pointers.
 *              Used by the ISR to deliver the frame to the Crynwr AX=0 upcall.
 *              Set to 0 for XMS_POLICY_XMS_COPY (driver uses its own staging buf).
 */
typedef struct {
    uint8_t  version;       /* must be XMS_CFG_VERSION (1)                    */
    uint8_t  policy;        /* xms_mem_policy_t                               */
    uint16_t slot_size;     /* bytes per slot; must be <= DX from QUERY       */
    uint32_t phys0;         /* VDS physical address — slot 0 data buffer      */
    uint32_t lin0;          /* VCPI/DPMI linear address — slot 0 (0=XMS_COPY) */
    uint32_t phys1;         /* VDS physical address — slot 1 data buffer      */
    uint32_t lin1;          /* VCPI/DPMI linear address — slot 1 (0=XMS_COPY) */
} xms_rx_cfg_t;             /* 20 bytes                                       */

/* ======================================================================== */
/* v2 wire structs (Phase 8b copybreak; see docs/10-copybreak-ext.md).        */
/* PINNED layouts; must byte-match xms_dma.inc and dos-nvmeotcp/src/xms.h.     */
/* Explicit pack(1): the layout contract is enforced by the compile-time      */
/* asserts in the stack mirror + tools/abi_check.sh, never by implicit packing.*/
/* ======================================================================== */

#define XMS_CFG2_VERSION    2u      /* xms_rx_cfg2_t.version */
#define XMS_TX_CFG_VERSION  1u      /* xms_tx_cfg_t.version  */
#define RX_DMA_SLOTS        8u      /* max N-slot RX ring depth */
#define TXSLOT_HEADROOM     128u    /* reserved header prefix per TX slot */

#pragma pack(push, 1)

typedef struct {                /* ES:DI -> RX_CONFIGURE2; 24 bytes */
    uint8_t  version;           /* = XMS_CFG2_VERSION (2)                       */
    uint8_t  policy;            /* xms_mem_policy_t (CONV_RING | XMS_RING)      */
    uint16_t n_slots;           /* 2..RX_DMA_SLOTS                              */
    uint16_t slot_size;         /* <= DX from QUERY                            */
    uint16_t compl_ring_n;      /* completion ring entries (power of two)       */
    uint16_t free_ring_n;       /* free ring entries (power of two)             */
    uint16_t reserved;          /* 0                                            */
    uint32_t slots_lin;         /* seg:off (hi16=seg, lo16=off) of slots[]      */
    uint32_t compl_ring_lin;    /* seg:off of completion ring (hdr + entries)   */
    uint32_t free_ring_lin;     /* seg:off of free ring (hdr + entries)         */
} xms_rx_cfg2_t;

typedef struct {                /* one per RX slot (array at slots_lin); 8 bytes */
    uint32_t phys;              /* NIC DMA phys (< DMA_ISA_16M_LIMIT)           */
    uint32_t lin;              /* seg:off CPU alias for header peel (0=XMS-only)*/
} xms_slot_desc_t;

typedef struct {                /* prefix of each ring; 8 bytes */
    uint16_t head;              /* producer index                              */
    uint16_t tail;             /* consumer index                              */
    uint16_t mask;             /* n_entries - 1 (power of two)                 */
    uint16_t rsv;
} xms_ring_hdr_t;

typedef struct {                /* completion ring entry (driver->stack); 8 bytes */
    uint16_t slot_id;
    uint16_t len;
    uint16_t status;
    uint16_t seq;
} xms_rx_compl_t;

typedef struct {                /* free ring entry (stack->driver); 2 bytes */
    uint16_t slot_id;
} xms_rx_free_t;

typedef struct {                /* ES:DI -> TX_CONFIGURE; 12 bytes */
    uint8_t  version;          /* = XMS_TX_CFG_VERSION (1)                     */
    uint8_t  flags;            /* bit0 = pool is XMS                           */
    uint16_t reserved;         /* 0                                           */
    uint32_t pool_phys;        /* base phys (< DMA_ISA_16M_LIMIT)             */
    uint32_t pool_len;         /* pool size in bytes                          */
} xms_tx_cfg_t;

#pragma pack(pop)

#endif /* PKTDRV_XMS_DMA_H */
