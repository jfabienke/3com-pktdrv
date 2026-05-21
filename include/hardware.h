/*
 * hardware.h — canonical NIC model (vtable HAL).
 *
 * THE single runtime NIC type is nic_info_t. Families keep private state behind priv.
 * There are deliberately NO competing per-family context structs visible to the core
 * (the old codebase's defining mistake).  See docs/03-hal-vtable.md.
 */
#ifndef PKTDRV_HARDWARE_H
#define PKTDRV_HARDWARE_H

#include <stdint.h>
#include <stdbool.h>

/* NIC family (the EtherLink III lineage). */
typedef enum {
    NIC_NONE = 0,
    NIC_3C509B,        /* EtherLink III, ISA, PIO            (the floor)        */
    NIC_3C515,         /* Corkscrew, ISA, +bus-master ring                       */
    NIC_VORTEX,        /* 3C59x PCI, PIO                                         */
    NIC_BOOMERANG,     /* 3C90x PCI, +ring DMA                                   */
    NIC_CYCLONE,       /* 3C905B PCI, +HW csum, NWAY                             */
    NIC_TORNADO        /* 3C905C PCI, +scatter-gather, WoL                       */
} nic_type_t;

typedef enum {
    BUS_ISA8 = 0,      /* 8-bit ISA (5150 floor)            */
    BUS_ISA16,
    BUS_EISA,
    BUS_PCI,
    BUS_CARDBUS
} bus_type_t;

/* Capability flags — discovered at detect, drive runtime behavior AND which fragments
 * the composer emits (docs/02, docs/03). */
#define HW_CAP_PIO         0x0001u   /* always set — the universal floor          */
#define HW_CAP_BUSMASTER   0x0002u   /* NIC can master the bus (only if TESTED ok) */
#define HW_CAP_RING_DMA    0x0004u   /* linked descriptor-ring DMA (DOWN/UP_LIST)  */
#define HW_CAP_MII         0x0008u   /* MII PHY present                            */
#define HW_CAP_FULLDUPLEX  0x0010u
#define HW_CAP_HWCSUM      0x0020u   /* Cyclone+ (detected, usually unused by DOS) */
#define HW_CAP_PERMWIN1    0x0040u   /* Vortex+ keep window 1 mapped (elide switch) */

struct nic_info;
struct emit_plan;                    /* see codegen.h */

/* Vtable. Operates at two times:
 *  - cold: emit_plan() names the hot fragments to compose for this NIC.
 *  - run/cold control: init/reset/control-plane calls. The per-packet hot path is the
 *    EMITTED code, not these pointers. */
typedef struct nic_ops {
    int  (*init)(struct nic_info *nic);
    int  (*reset)(struct nic_info *nic);
    int  (*send)(struct nic_info *nic, const uint8_t *pkt, uint16_t len);
    int  (*recv)(struct nic_info *nic, uint8_t *buf, uint16_t *len);
    void (*isr)(struct nic_info *nic);
    int  (*set_rx_mode)(struct nic_info *nic, uint8_t mode);
    int  (*get_mac)(struct nic_info *nic, uint8_t mac[6]);
    void (*emit_plan)(struct nic_info *nic, struct emit_plan *plan);
} nic_ops_t;

typedef struct nic_info {
    nic_type_t       type;
    bus_type_t       bus;
    uint16_t         io_base;
    uint8_t          irq;
    uint8_t          mac[6];
    uint32_t         caps;           /* HW_CAP_* */
    const nic_ops_t *ops;
    void            *priv;           /* family-private context (opaque to core) */
} nic_info_t;

#endif /* PKTDRV_HARDWARE_H */
