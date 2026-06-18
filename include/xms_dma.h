/*
 * xms_dma.h — Proprietary INT 60h extension: XMS DMA receive ring.
 *
 * Allows nvmetsr.exe to hand 3cpd.exe the physical/linear addresses of
 * XMS-resident receive buffers so the 3C515 bus-master can DMA directly
 * into extended memory, bypassing conventional memory entirely.
 *
 * Requires 386+ (V86 mode under a VMM implementing VDS). On sub-386 or
 * when the query call returns CF=1, caller falls back to MEM_CONVENTIONAL.
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

/* ---- capability flags (BX on successful QUERY) ------------------------- */

#define XMS_CAP_VCPI        0x0001u /* VCPI DE05h page mapping (386+)       */
#define XMS_CAP_DPMI        0x0002u /* DPMI 1.0 AX=0508h mapping (386+)     */
#define XMS_CAP_XMS_COPY    0x0004u /* INT 15h AH=87h copy path (286+)      */
#define XMS_CAP_RING        0x0008u /* ring descriptor mode (386+)           */
#define XMS_CAP_SINGLE      0x0010u /* single-transfer descriptor mode (286) */
#define XMS_CAP_CONV        0x0020u /* conventional-memory zero-copy ring (deliver in place; Phase 3) */

/* ---- memory policy ----------------------------------------------------- */

typedef enum {
    XMS_POLICY_VCPI     = 0,   /* XMS + VCPI DE05h → V86 linear mapping; zero CPU copies  */
    XMS_POLICY_DPMI     = 1,   /* XMS + DPMI 1.0 AX=0508h mapping;       zero CPU copies  */
    XMS_POLICY_XMS_COPY = 2,   /* XMS + INT 15h AH=87h staging copy;      one CPU copy    */
    XMS_POLICY_CONV     = 3,   /* ring in CONVENTIONAL memory (phys=seg*16); deliver in place, NO copy
                                * -- the doc-10 zero-copy landing ring (mandatory on 286/386). */
} xms_mem_policy_t;

/* ---- error codes (DH on CF=1) ------------------------------------------ */

#define XMS_ERR_BAD_VERSION 0x01u   /* cfg.version != XMS_CFG_VERSION             */
#define XMS_ERR_BAD_POLICY  0x02u   /* cfg.policy not in xms_mem_policy_t range   */
#define XMS_ERR_PHYS_RANGE  0x03u   /* physical address >= DMA_ISA_16M_LIMIT      */
#define XMS_ERR_SLOT_SIZE   0x04u   /* cfg.slot_size > DX returned by QUERY       */
#define XMS_ERR_ALREADY_CFG 0x05u   /* ring already configured; call RELEASE first */
#define XMS_ERR_NOT_CFG     0x06u   /* RELEASE called but ring not configured      */

/* ---- configuration structure (passed via ES:DI to CONFIGURE) ----------- */

#define XMS_CFG_VERSION     1u      /* cfg.version must equal this */
#define XMS_CFG_N_SLOTS     2u      /* fixed: 2-slot ping-pong ring (386+ ring mode only) */

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

/* The resident ISR reads this struct via the fixed offsets in xms_dma.inc, and the producer
 * (dos-nvmeotcp xms.h) builds the matching layout. Fixed-width fields are naturally aligned, so
 * this stays 20 bytes on any conforming compiler; the check trips if a future edit reorders a
 * field and introduces padding. */
typedef char xms_rx_cfg_size_check[sizeof(xms_rx_cfg_t) == 20 ? 1 : -1];

#endif /* PKTDRV_XMS_DMA_H */
