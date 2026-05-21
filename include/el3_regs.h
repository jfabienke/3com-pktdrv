/*
 * el3_regs.h — EtherLink III register / window / EEPROM definitions.
 *
 * TIER-A LIFT TARGET (docs/07-porting-plan.md): port the factual #define blocks from the
 * old repo's include/3c509b.h and include/3c515.h here — register offsets, the 8 register
 * windows, command/status bits, RX-filter bits, EEPROM offsets/commands, MII registers.
 * Bring ONLY the constants; leave the old structs behind (the canonical runtime type is
 * nic_info_t in hardware.h).
 *
 * Organize by window, since that is how the hardware is addressed:
 *   Window 0  EEPROM / config
 *   Window 1  operating set (TX/RX FIFO, status)
 *   Window 2  station address
 *   Window 3  config (internal config, MAC control)
 *   Window 4  media / diagnostics / MII
 *   Window 6  statistics
 *   Window 7  bus-master (DOWN_LIST_PTR / UP_LIST_PTR)
 */
#ifndef PKTDRV_EL3_REGS_H
#define PKTDRV_EL3_REGS_H

/* TODO(lift): port register/window/EEPROM constants from old 3c509b.h / 3c515.h */

#endif /* PKTDRV_EL3_REGS_H */
