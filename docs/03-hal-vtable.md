# 03 — Hardware Abstraction: vtable + generational core

## The model

`nic_info_t` is the one canonical runtime NIC object. It carries a capability bitmask and
a pointer to a `nic_ops_t` **vtable**. Generic code (API dispatch, packet ops, IRQ) never
type-checks the NIC — it calls through the vtable. Each NIC family populates its own vtable
at detection time.

```c
typedef struct nic_info {
    nic_type_t   type;          /* 3C509B, 3C515, VORTEX, BOOMERANG, ... */
    bus_type_t   bus;           /* ISA8, ISA16, EISA, PCI, CARDBUS       */
    uint16_t     io_base;
    uint8_t      irq;
    uint8_t      mac[6];
    uint32_t     caps;          /* HW_CAP_* — see below                  */
    const nic_ops_t *ops;       /* vtable                                */
    void        *priv;          /* family-private context (opaque)       */
} nic_info_t;

typedef struct nic_ops {
    int  (*init)(nic_info_t*);
    int  (*reset)(nic_info_t*);
    int  (*send)(nic_info_t*, const uint8_t *pkt, uint16_t len);
    int  (*recv)(nic_info_t*, uint8_t *buf, uint16_t *len);
    void (*isr)(nic_info_t*);
    int  (*set_rx_mode)(nic_info_t*, uint8_t mode);   /* promisc/multicast */
    int  (*get_mac)(nic_info_t*, uint8_t mac[6]);
    /* cold-time only: name the hot fragments to emit for this NIC */
    void (*emit_plan)(nic_info_t*, struct emit_plan*);
} nic_ops_t;
```

Note `priv` is **opaque** — the family's private hardware context (rings, EEPROM image,
window state) hangs off here. There is exactly one runtime context type (`nic_info_t`);
families do **not** define competing `*_context_t` structs visible to the core. (This is
the single biggest sin of the old codebase — four parallel `nic_context_t` definitions.)

## Shared EtherLink III core + generational deltas

The lineage means most behavior is shared. Structure it as a base the families extend:

```
el3_core   : register windowing, EEPROM read, MAC fetch, PIO send/recv,
             RX filter, basic reset      (every EtherLink III card)
   ▲
   ├── el3_isa   : 3C509B (PIO),  3C515-TX (+ ISA bus-master ring)
   ├── el3_pci   : Vortex (PIO, permanent window 1, big FIFO)
   │              Boomerang (+ descriptor-ring DMA)
   │              Cyclone  (+ HW checksum, NWAY)
   │              Tornado  (+ scatter-gather, WoL)
   └── el3_cardbus / mini-pci variants
```

A family's vtable reuses core functions for shared behavior and overrides only its delta.
The 3C509B vtable is almost entirely core (PIO); the 3C515 adds the ISA ring send/recv;
Boomerang+ replace send/recv with the PCI descriptor-ring path.

## Capability flags (`HW_CAP_*`)

Capabilities are discovered at detection and drive both runtime behavior and **which
fragments get emitted**:

```
HW_CAP_PIO            always (the floor)
HW_CAP_BUSMASTER      NIC can master the bus (subject to test — see 04)
HW_CAP_RING_DMA       linked descriptor-ring DMA (DOWN/UP_LIST_PTR)
HW_CAP_MII            MII PHY present
HW_CAP_FULLDUPLEX
HW_CAP_HWCSUM         Cyclone+ (detected, generally unused by DOS)
HW_CAP_PERMWIN1       Vortex+ keep window 1 mapped (elide window switches)
```

`HW_CAP_PERMWIN1` is a good example of capability→emit: if set, the composer omits the
window-switch fragments entirely from the hot path.

## Bus is an orthogonal axis (bus probers)

The bus is not a NIC generation — the EtherLink III core and the emitted datapath are
**bus-agnostic**. The bus differs only in *cold-time* concerns, handled by a small
per-bus **prober** that finds the card and fills `nic_info_t` (io_base, irq, caps):

| Bus | EL3 NIC(s) | Enumeration / config | DMA constraint |
|-----|-----------|----------------------|----------------|
| ISA8/16 | 3C509B, 3C515 | PnP isolation / ID port / manual | ISA 24-bit/16 MB/64 KB |
| EISA | 3C579, 3C597-TX | slot scan, EISA ID `0xzC80`, config regs | 32-bit bus-master |
| MCA | 3C529 | POS registers, adapter-ID slot scan | 32-bit bus-master, level IRQ |
| PCMCIA-16 | 3C589, 3C562 | CIS tuples via Socket Services / PCIC | PIO (no bus-master) |
| PCI / CardBus | Vortex…Tornado, 3C575 | PCI config space | PCI-class (no 16 MB limit) |

```c
typedef struct bus_prober {
    bus_type_t bus;
    int (*probe)(nic_info_t *out, int max);   /* enumerate EL3 cards on this bus */
} bus_prober_t;
```

Probers run in boot phase 4 (cold) and are reclaimed after install. The only thing the
bus contributes to the *hot* path is the I/O access primitive — port `in`/`out` for
ISA/EISA/MCA/PCMCIA-16, optional MMIO for PCI/CardBus — selected as one fragment
(`FRAG_IO_PORT` vs `FRAG_IO_MMIO`). Everything else downstream is identical.

Floor note: only ISA8 is in the 5150 `minimal` profile. EISA/MCA/PCMCIA/PCI probers are
additive (`full` profile), compiled out of the floor build.

## How the vtable relates to the JIT

The vtable operates at **two times**:

- **Cold time:** `emit_plan()` translates the NIC's capabilities into a list of fragment
  ids for the composer (`02-resident-construction.md`). This is where polymorphism lives.
- **Run time (fallback / cold paths):** the function pointers (`init`, `reset`,
  `set_rx_mode`, …) are ordinary calls used during init and for infrequent control ops.

The **per-packet hot path** is the *emitted* code, not a vtable indirection — so the hot
datapath has zero dispatch overhead. The vtable decided *what* to emit; the emitted code
*is* the datapath.
