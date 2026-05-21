/*
 * cpu.h — CPU class/feature detection (lift cpu_detect.asm from the old repo).
 * The class gates which JIT fragments may be emitted (8088 baseline is the floor).
 */
#ifndef PKTDRV_CPU_H
#define PKTDRV_CPU_H

#include <stdint.h>
#include <stdbool.h>

/* Ordered: a fragment with cpu_min = X is emittable iff detected class >= X. */
typedef enum {
    CPU_8088 = 0,      /* IBM 5150 floor */
    CPU_80286,
    CPU_80386,
    CPU_80486,
    CPU_PENTIUM,
    CPU_PENTIUM_PRO    /* P6+ / CPUID family>=6 */
} cpu_class_t;

#define CPU_FEAT_FPU      0x0001u
#define CPU_FEAT_CPUID    0x0002u
#define CPU_FEAT_TSC      0x0004u
#define CPU_FEAT_WBINVD   0x0008u   /* 486+ */
#define CPU_FEAT_CLFLUSH  0x0010u   /* P4+  */
#define CPU_FEAT_V86      0x0020u   /* running in virtual-8086 mode */

typedef struct {
    cpu_class_t cls;
    uint16_t    features;   /* CPU_FEAT_* */
    uint16_t    mhz;        /* approximate; for batch/threshold tuning */
} cpu_info_t;

extern cpu_info_t g_cpu;    /* filled in boot phase 1 */

int cpu_detect(cpu_info_t *out);   /* implemented over src/asm/cpu_detect.asm */

#endif /* PKTDRV_CPU_H */
