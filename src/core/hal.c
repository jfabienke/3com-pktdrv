/*
 * hal.c — vtable HAL core (docs/03-hal-vtable.md).
 * Holds the active NIC(s) and the shared EtherLink III behavior that families reuse.
 * Family vtables live in src/hw/el3_isa.c, el3_pci.c; this is the common spine.
 *
 * Control-plane (init/reset/control) is ordinary C and may be cold. The per-packet hot
 * path is the JIT-emitted code, not these pointers — so the datapath has no vtable cost.
 */
#include "hardware.h"

/* Active NICs (practical limit 2-4 by IRQ availability; MAX kept small for the floor). */
#define MAX_NICS 4
nic_info_t g_nics[MAX_NICS];
int        g_nic_count;

nic_info_t *hal_primary_nic(void)
{
    int i;
    for (i = 0; i < g_nic_count; ++i)
        if (g_nics[i].ops) return &g_nics[i];
    return 0;
}

/* Shared EL3 core helpers (window select, EEPROM, PIO) are implemented in src/hw/el3_core.c
 * and referenced by family vtables; declared here for the core's use. */
