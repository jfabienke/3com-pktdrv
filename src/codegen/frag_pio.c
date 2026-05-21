/* frag_pio.c — fragment library + frag_lookup (COLD). Placeholder 8088 fragments so the
 * composer emits a (no-op) resident image end-to-end; real PIC hot-path fragments will be
 * built with `nasm -f bin` and embedded here (docs/02-resident-construction.md). */
#include "codegen.h"

static const unsigned char f_ret[]  = { 0xC3 };          /* near ret  */
static const unsigned char f_iret[] = { 0xCF };          /* iret      */
static const unsigned char f_nop[]  = { 0x90 };          /* nop       */

static const fragment_t g_frags[] = {
    { FRAG_API_DISPATCH, CPU_8088, f_ret,  1, 0, 0, 0, 0 },
    { FRAG_ISR_ENTRY,    CPU_8088, f_nop,  1, 0, 0, 0, 0 },
    { FRAG_ISR_EOI,      CPU_8088, f_iret, 1, 0, 0, 0, 0 },
    { FRAG_RX_PIO,       CPU_8088, f_ret,  1, 0, 0, 0, 0 },
    { FRAG_TX_PIO,       CPU_8088, f_ret,  1, 0, 0, 0, 0 }
};

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
