/*
 * codegen.h — JIT fragment composition + copy-down (the resident-construction core).
 * See docs/02-resident-construction.md.  All of this runs COLD and is reclaimed.
 */
#ifndef PKTDRV_CODEGEN_H
#define PKTDRV_CODEGEN_H

#include <stdint.h>
#include "cpu.h"

/* Logical hot-path steps. Each has an 8088 baseline fragment (the floor); higher-CPU
 * and DMA variants are additive, selected by capability. */
typedef enum {
    FRAG_ISR_ENTRY = 0,
    FRAG_ISR_EOI,
    FRAG_RX_PIO,           /* PIO receive (floor)               */
    FRAG_TX_PIO,           /* PIO transmit (floor)              */
    FRAG_RX_RING,          /* descriptor-ring receive (DMA)     */
    FRAG_TX_RING,          /* descriptor-ring transmit (DMA)    */
    FRAG_RX_COPYBREAK,     /* small-RX copy + recycle           */
    FRAG_WIN_SELECT,       /* register window switch (omitted if HW_CAP_PERMWIN1) */
    FRAG_CACHE_FLUSH,      /* WBINVD/CLFLUSH/sw-barrier per tier */
    FRAG_API_DISPATCH,     /* INT 60h entry/dispatch            */
    FRAG__COUNT
} frag_id_t;

/* Immediate patch kinds filled in at compose time. */
typedef enum {
    PATCH_IMM8 = 0,
    PATCH_IMM16,
    PATCH_SEG,
    PATCH_OFF
} patch_kind_t;

typedef struct { uint16_t offset; patch_kind_t kind; uint16_t value; } frag_patch_t;
typedef struct { uint16_t offset; } frag_reloc_t;   /* intra-image ref to fix post-copy-down */

/* A fragment in the (cold) library: position-independent code + slot tables. */
typedef struct {
    frag_id_t       id;
    cpu_class_t     cpu_min;        /* minimum CPU class this fragment targets */
    const uint8_t  *bytes;
    uint16_t        len;
    const frag_patch_t *patches;    /* immediate slots (values filled per-machine) */
    uint8_t         n_patches;
    const frag_reloc_t *relocs;     /* fixups applied after copy-down */
    uint8_t         n_relocs;
} fragment_t;

/* The plan the HAL hands the composer: which fragments, in order, with their immediates. */
#define EMIT_MAX_STEPS 16
typedef struct emit_plan {
    frag_id_t  steps[EMIT_MAX_STEPS];
    uint16_t   imm[EMIT_MAX_STEPS][4];   /* per-step immediate values to patch */
    uint8_t    n_steps;
} emit_plan_t;

/* Result of composition: total emitted length + where each fragment id landed in the
 * arena (0xFFFF if not emitted). The installer uses off[FRAG_API_DISPATCH] /
 * off[FRAG_ISR_ENTRY] to point INT 60h and the NIC IRQ vector at the right entry. */
typedef struct compose_result {
    uint16_t len;
    uint16_t off[FRAG__COUNT];
} compose_result_t;

#define FRAG_OFF_NONE 0xFFFFu

/* Composer: select+stitch+patch into the emit arena; fills res; returns emitted length
 * (0 on over-budget or missing fragment). */
uint16_t compose_resident(const emit_plan_t *plan, uint8_t *arena, uint16_t arena_len,
                          compose_result_t *res);

/* Copy-down: pack the emitted image to its compact resident home, apply relocs.
 * Returns the resident size in paragraphs to TSR-keep. */
uint16_t copy_down(const uint8_t *emitted, uint16_t emitted_len);

#endif /* PKTDRV_CODEGEN_H */
