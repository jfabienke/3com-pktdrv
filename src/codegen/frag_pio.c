/* frag_pio.c -- fragment library + frag_lookup (COLD).
 *
 * The fragment byte arrays + patch tables in g_frags[] are AUTO-GENERATED from the NASM
 * sources in src/asm/frag/ by tools/mkfrag.py (-> build/frags.inc). Each fragment is
 * position-independent 8086 machine code with io_base baked in at compose time via the
 * patch table. See docs/02-resident-construction.md. */
#include "codegen.h"
#include "frags.inc"   /* generated: f_*[] byte arrays, *_patches[], g_frags[] */

const fragment_t *frag_lookup(frag_id_t id, cpu_class_t cls)
{
    unsigned i;
    const fragment_t *best = 0;
    for (i = 0; i < sizeof(g_frags) / sizeof(g_frags[0]); ++i) {
        const fragment_t *f = &g_frags[i];
        if (f->id == id && f->cpu_min <= cls)
            if (!best || f->cpu_min > best->cpu_min) best = f;
    }
    return best;
}
