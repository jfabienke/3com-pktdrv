/*
 * dma.h — the SINGLE canonical DMA policy + cache tier + boundary model.
 * (The old repo had dma_policy_t as both a struct and an enum, and cache_tier_t twice.)
 * See docs/04-dma-model.md.
 */
#ifndef PKTDRV_DMA_H
#define PKTDRV_DMA_H

#include <stdint.h>
#include <stdbool.h>

/* ISA constraints (axis 2). */
#define DMA_64K_BOUNDARY   0x10000UL
#define DMA_ISA_16M_LIMIT  0x1000000UL    /* ISA bus-master 24-bit addressing */

static inline bool dma_crosses_64k(uint32_t phys, uint16_t len) {
    return ((phys & 0xFFFFUL) + len) > DMA_64K_BOUNDARY;
}
static inline bool dma_above_16m(uint32_t phys, uint16_t len) {
    return (phys + len) > DMA_ISA_16M_LIMIT;
}

/* Environment-resolved policy (axis 2 ∩ real/V86). */
typedef enum {
    DMA_POLICY_DIRECT = 0,   /* real mode: physical == linear, use addresses directly */
    DMA_POLICY_COMMONBUF,    /* V86 + VDS: VDS-locked / common buffers                */
    DMA_POLICY_FORBID        /* V86, no VDS: fall back to PIO                          */
} dma_policy_t;

/* Cache-coherency tier (per CPU/chipset). Single definition. */
typedef enum {
    CACHE_TIER_NONE = 0,     /* 286 / no cache — nothing to do            */
    CACHE_TIER_SOFTWARE,     /* 386 software barriers                     */
    CACHE_TIER_WBINVD,       /* 486/Pentium full flush (batched)          */
    CACHE_TIER_CLFLUSH,      /* P4+ surgical line flush                   */
    CACHE_TIER_DISABLE_BM    /* coherency unproven -> disable bus master  */
} cache_tier_t;

/* Resolved at boot phases 2/5 from capability ∩ environment ∩ test. */
typedef struct {
    dma_policy_t  policy;
    cache_tier_t  tier;
    bool          busmaster_trusted;   /* set only after busmaster_test passes */
    uint16_t      confidence;          /* 0..N test score */
} dma_decision_t;

extern dma_decision_t g_dma;

#endif /* PKTDRV_DMA_H */
