/*
 * xms_dma.h — Proprietary INT 60h extension: XMS DMA receive ring.
 *
 * Allows nvmetsr.exe to hand 3cpd.exe the physical/linear addresses of
 * receive buffers (XMS EMBs, or a conventional-memory ring) so the 3C515
 * bus-master can DMA directly into them.
 *
 * Available only while 3cpd's bus-master DMA path is active (3C515, >= 286):
 * on the PIO floor every AH=0xF0 sub-function returns CF=1 (bad command) and
 * the caller falls back to MEM_CONVENTIONAL. VCPI/DPMI/ring modes need the
 * 386+ ring.
 *
 * NASM mirror: include/xms_dma.inc (keep the two in sync).
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
#define XMS_DMA_POLL        0x03u   /* AL: NAPI poll -- drain the conv ring from task context
                                     *     and re-arm the UP_COMPLETE IRQ                   */

/* ---- capability flags (BX on successful QUERY) ------------------------- */

#define XMS_CAP_VCPI        0x0001u /* VCPI DE05h page mapping (386+)       */
#define XMS_CAP_DPMI        0x0002u /* DPMI 1.0 AX=0508h mapping (386+)     */
#define XMS_CAP_XMS_COPY    0x0004u /* INT 15h AH=87h copy path (286+)      */
#define XMS_CAP_RING        0x0008u /* ring descriptor mode (386+)           */
#define XMS_CAP_SINGLE      0x0010u /* single-transfer descriptor mode (286) */
#define XMS_CAP_CONV        0x0020u /* conventional-memory zero-copy ring (deliver in place; Phase 3) */

/* ---- memory policy ----------------------------------------------------- */

typedef enum {
    XMS_POLICY_VCPI      = 0,  /* XMS + VCPI DE05h → V86 linear mapping; zero CPU copies  */
    XMS_POLICY_DPMI      = 1,  /* XMS + DPMI 1.0 AX=0508h mapping;       zero CPU copies  */
    XMS_POLICY_XMS_COPY  = 2,  /* XMS + INT 15h AH=87h staging copy;      one CPU copy    */
    XMS_POLICY_CONV      = 3,  /* ring in CONVENTIONAL memory (phys=seg*16); deliver in place, NO copy
                                * -- the doc-10 zero-copy landing ring (mandatory on 286/386). */
    XMS_POLICY_COMMONBUF = 4   /* CONV under a paging VMM: the ring is VDS-locked so phys0 is the TRUE
                                * bus address (!= seg<<4) and lin0 is the ring's real-mode LINEAR
                                * (seg<<4, < 1 MB) the CPU reads in place. */
} xms_mem_policy_t;

#define XMS_POLICY_MAX      4u      /* CONFIGURE validation bound (cfg.policy must be <= this) */

/* ---- RX ring depth ----------------------------------------------------- */

/* CONV/COMMONBUF: one contiguous block of RX_RING_N slots (slot i at phys0 + i*slot_size) on the
 * 386+ ring; 2 slots on the 286 single-transfer path. XMS_COPY/VCPI/DPMI: 2 explicit slots
 * (phys0/phys1, separate EMBs). Must match dos-nvmeotcp xms.h XMS_RX_RING_N. */
#define RX_RING_N           8u

/* v2 producers reserve this many bytes directly past a CONV/COMMONBUF ring; 3cpd may relocate its
 * RX descriptors there when a chipset NC fence is effective (docs/17 step 4b). */
#define XMS_RX_DESC_BLOCK   (RX_RING_N * 16u)

/* ---- error codes (DH on CF=1) ------------------------------------------ */

#define XMS_ERR_BAD_VERSION 0x01u   /* cfg.version outside XMS_CFG_VERSION_MIN..XMS_CFG_VERSION */
#define XMS_ERR_BAD_POLICY  0x02u   /* cfg.policy > XMS_POLICY_MAX (or VCPI/DPMI without the 386+ ring) */
#define XMS_ERR_PHYS_RANGE  0x03u   /* physical address / phys0 span >= DMA_ISA_16M_LIMIT */
#define XMS_ERR_SLOT_SIZE   0x04u   /* cfg.slot_size 0 or > DX from QUERY, or (CONV/COMMONBUF)
                                     * not a 32-byte multiple                               */
#define XMS_ERR_ALREADY_CFG 0x05u   /* ring already configured; call RELEASE first */
#define XMS_ERR_NOT_CFG     0x06u   /* RELEASE called but ring not configured      */
#define XMS_ERR_BAD_LIN     0x07u   /* CONV/COMMONBUF lin0 span invalid (0, not 16-aligned, >= 1 MB),
                                     * or CONV with lin0 != phys0 or under a V86 host        */

/* ---- configuration structure (passed via ES:DI to CONFIGURE) ----------- */

#define XMS_CFG_VERSION     2u      /* current: v2 = producer reserves XMS_RX_DESC_BLOCK past a
                                     * CONV/COMMONBUF ring                                   */
#define XMS_CFG_VERSION_MIN 1u      /* v1 still accepted: 3cpd then never relocates its
                                     * descriptors / marks NC (no room for the block)        */

/*
 * xms_rx_cfg_t — caller-allocated, must remain resident for the lifetime of
 * the DMA ring.  3cpd.exe stores ES:DI and reads lin0/lin1 in the ISR hotpath.
 *
 * phys0/phys1: bus physical addresses (< DMA_ISA_16M_LIMIT), written into
 *              EL3_DESC_ADDR. XMS_COPY: the two slot EMBs. CONV/COMMONBUF:
 *              phys0 = base of the contiguous ring (seg<<4 for CONV, the
 *              VDS-reported address for COMMONBUF); phys1 unused.
 * lin0/lin1:   XMS_COPY: 0 (driver uses its own staging copy).
 *              CONV/COMMONBUF: lin0 = the ring base as a 32-bit real-mode
 *              LINEAR address (seg<<4, < 1 MB, 16-byte aligned) -- not a
 *              segment value; the ISR delivers slot i in place at
 *              (lin0 + i*slot_size) >> 4 : 0. CONV requires lin0 == phys0.
 *              lin1 unused (VCPI/DPMI mapping is reserved, see docs/09).
 * slot_size:   <= DX from QUERY (1536); CONV/COMMONBUF: a 32-byte multiple
 *              (it is the ring stride).
 */
typedef struct {
    uint8_t  version;       /* XMS_CFG_VERSION (2); 1 = legacy                */
    uint8_t  policy;        /* xms_mem_policy_t                               */
    uint16_t slot_size;     /* bytes per slot; must be <= DX from QUERY       */
    uint32_t phys0;         /* bus physical address — slot 0 / ring base      */
    uint32_t lin0;          /* real-mode linear (seg<<4) of slot 0 / ring base; 0 = XMS_COPY */
    uint32_t phys1;         /* bus physical address — slot 1 (XMS_COPY)       */
    uint32_t lin1;          /* 0 (reserved for VCPI/DPMI)                     */
} xms_rx_cfg_t;             /* 20 bytes                                       */

/* The resident ISR reads this struct via the fixed offsets in xms_dma.inc, and the producer
 * (dos-nvmeotcp xms.h) builds the matching layout. Fixed-width fields are naturally aligned, so
 * this stays 20 bytes on any conforming compiler; the check trips if a future edit reorders a
 * field and introduces padding. */
typedef char xms_rx_cfg_size_check[sizeof(xms_rx_cfg_t) == 20 ? 1 : -1];

#endif /* PKTDRV_XMS_DMA_H */
