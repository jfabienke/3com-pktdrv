/*
 * main.c — cold entry point and boot orchestration (docs/06-boot-sequence.md).
 * Everything in this file is COLD: it runs once, composes+copies-down the resident, then
 * its memory is reclaimed. Hence the COLD_TEXT segment class.
 */
#include "hardware.h"
#include "cpu.h"
#include "dma.h"
#include "codegen.h"

#pragma code_seg("COLD_TEXT", "COLD_TEXT")

cpu_info_t      g_cpu;
dma_decision_t  g_dma;

extern const nic_ops_t el3_3c509b_ops;    /* src/hw/el3_isa.c */

/* Boot phases — see docs/06. Stubs for the skeleton. */
static int  phase_detect_cpu(void)        { return (int)cpu_detect(&g_cpu); }
static int  phase_platform_probe(void)    { return 0; /* V86/VDS/mem tiers */ }
static int  phase_detect_nic(nic_info_t *nic)
{
    /* Floor: assume a 3C509B at a default I/O base (real probe comes later). */
    nic->type    = NIC_3C509B;
    nic->bus     = BUS_ISA8;
    nic->io_base = 0x300;
    nic->irq     = 10;
    nic->caps    = HW_CAP_PIO;
    nic->ops     = &el3_3c509b_ops;
    nic->priv    = 0;
    return 0;
}
static int  phase_validate_dma(nic_info_t *nic) { (void)nic; return 0; /* skipped on floor */ }
static int  phase_memory(nic_info_t *nic) { (void)nic; return 0; }

static uint16_t phase_compose_and_copydown(nic_info_t *nic, uint8_t *arena, uint16_t arena_len)
{
    emit_plan_t plan;
    uint16_t emitted_len;

    plan.n_steps = 0;
    nic->ops->emit_plan(nic, &plan);             /* HAL names the fragments */
    emitted_len = compose_resident(&plan, arena, arena_len);
    return copy_down(arena, emitted_len);        /* returns paragraphs to keep */
}

int main(void)
{
    static nic_info_t nic;
    static uint8_t    emit_arena[4096];          /* COLD scratch; reclaimed after keep */
    uint16_t          keep_paragraphs;

    if (phase_detect_cpu() != 0)        return 1;
    if (phase_platform_probe() != 0)    return 1;
    if (phase_detect_nic(&nic) != 0)    return 1;
    (void)phase_validate_dma(&nic);
    if (phase_memory(&nic) != 0)        return 1;

    keep_paragraphs = phase_compose_and_copydown(&nic, emit_arena, sizeof emit_arena);
    if (keep_paragraphs == 0)           return 1;

    /* TODO: install INT 60h + NIC IRQ, then DOS TSR-keep(keep_paragraphs). */
    (void)keep_paragraphs;
    return 0;
}

#pragma code_seg()
