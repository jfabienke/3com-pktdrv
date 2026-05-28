/*
 * xms_dma.h — Proprietary INT 60h extension: DMA receive ring configuration.
 *
 * Allows nvmetsr.exe to hand 3cpd.exe the physical/linear addresses of
 * receive buffers so the 3C515 bus-master can DMA directly into them.
 *
 * Three buffer classes are supported (two DMA modes each):
 *   CONV_SINGLE  conventional memory, 1 slot, single-transfer       (286+  / 10  Mbps)
 *   CONV_RING    conventional memory, 2 slots, ring mode            (386+ / 100  Mbps)
 *   XMS_COPY     XMS extended memory, 1 slot, single + INT 15h copy (286   / 10  Mbps)
 *   XMS_RING     XMS extended memory, 2 slots, ring  + INT 15h copy (386+ / 100  Mbps)
 *
 * Caps are determined at install time by CPU-generation JIT selection.
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

/* ---- capability flags (BX on successful QUERY) ------------------------- */
/*
 * Caps are set in stone at install time by JIT fragment selection.
 * 286-assembled binary: XMS_COPY + SINGLE + CONV_SINGLE
 * 386+-assembled binary: XMS_RING + RING  + CONV_SINGLE + CONV_RING
 */
#define XMS_CAP_CONV_SINGLE 0x0001u /* conventional mem, 1 slot, single-xfer (286+)  */
#define XMS_CAP_CONV_RING   0x0002u /* conventional mem, 2 slots, ring mode  (386+)  */
#define XMS_CAP_XMS_COPY    0x0004u /* XMS + INT 15h single-xfer             (286)   */
#define XMS_CAP_RING        0x0008u /* ring descriptor mode (386+)                   */
#define XMS_CAP_SINGLE      0x0010u /* single-transfer descriptor mode (286+)        */
#define XMS_CAP_XMS_RING    0x0020u /* XMS + INT 15h ring mode               (386+)  */

/* ---- memory policy ----------------------------------------------------- */
/*
 * Policy values are paired by bit 0: 0=single, 1=ring.
 * This lets the CONFIGURE NEXT-field setup use a single TEST instruction.
 *   bit0=0: CONV_SINGLE(0), XMS_COPY(2)  → NEXT=0, ISR re-arms or pre-arms
 *   bit0=1: CONV_RING(1),   XMS_RING(3)  → NEXT chained, NIC auto-advances
 * Policies ≥ XMS_COPY(2) require GDT setup for INT 15h AH=87h.
 */
typedef enum {
    XMS_POLICY_CONV_SINGLE = 0, /* conventional memory, single-transfer; zero CPU copies  */
    XMS_POLICY_CONV_RING   = 1, /* conventional memory, ring mode;        zero CPU copies  */
    XMS_POLICY_XMS_COPY    = 2, /* XMS + INT 15h single-xfer (286);        one CPU copy   */
    XMS_POLICY_XMS_RING    = 3, /* XMS + INT 15h ring mode   (386+);       one CPU copy   */
} xms_mem_policy_t;
/* No policy value = no extension call; standard Crynwr PIO path */

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

#endif /* PKTDRV_XMS_DMA_H */
