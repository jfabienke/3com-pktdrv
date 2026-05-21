/*
 * compose.c — the JIT composer + copy-down (docs/02-resident-construction.md).
 * COLD: selects fragments, stitches them into the emit arena, patches immediates; then
 * copy-down packs the result into the resident home and reports paragraphs to keep.
 * Must itself be 8088-safe (mov/movsb/store loops only).
 */
#include "codegen.h"
#include "cpu.h"
#include <string.h>

#pragma code_seg("COLD_TEXT", "COLD_TEXT")

/* The fragment library is provided by src/codegen/frag_*.c (per-step, per-CPU variants).
 * frag_lookup() returns the best fragment for (id, detected CPU class). */
extern const fragment_t *frag_lookup(frag_id_t id, cpu_class_t cls);

uint16_t compose_resident(const emit_plan_t *plan, uint8_t *arena, uint16_t arena_len)
{
    uint16_t pos = 0;
    uint8_t  s;

    for (s = 0; s < plan->n_steps; ++s) {
        const fragment_t *f = frag_lookup(plan->steps[s], g_cpu.cls);
        uint8_t i;

        if (f == 0 || pos + f->len > arena_len) return 0;   /* over budget / missing */

        memcpy(arena + pos, f->bytes, f->len);

        /* patch immediates with this step's resolved values */
        for (i = 0; i < f->n_patches; ++i) {
            const frag_patch_t *p = &f->patches[i];
            uint16_t v = plan->imm[s][i];
            if (p->kind == PATCH_IMM8) arena[pos + p->offset] = (uint8_t)v;
            else                       *(uint16_t *)(arena + pos + p->offset) = v;
            /* reloc[] fixups are applied after copy-down, when the final base is known */
        }
        pos += f->len;
    }
    return pos;   /* emitted length */
}

uint16_t copy_down(const uint8_t *emitted, uint16_t emitted_len)
{
    /* TODO: pack `emitted` into the resident home (EMIT_ARENA class, low/packed),
     * walk each fragment's reloc[] to fix intra-image refs to the final base, and
     * return ceil(resident_size / 16) paragraphs to TSR-keep. */
    (void)emitted; (void)emitted_len;
    return 0;
}

#pragma code_seg()
