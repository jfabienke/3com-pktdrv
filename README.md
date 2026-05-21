# 3com-pktdrv — 3Com EtherLink III DOS Packet Driver (clean-room rebuild)

A single, self-specializing DOS packet driver (Crynwr Packet Driver API v1.11, INT 60h)
for the 3Com EtherLink III family — from the original **IBM PC 5150 (8088)** up to
Pentium/PCI machines — built from one source.

This is a clean-room rebuild. The design is documented first (`docs/`), then implemented.
It deliberately carries over only hardware-true facts and proven datapath logic from the
prior codebase; see `docs/07-porting-plan.md`.

## The one-paragraph design

The driver adapts to the machine at load time. A **cold init/composer phase** detects the
CPU, NIC, and environment; validates DMA/bus-mastering by *testing* it (never assuming);
then **JIT-composes** the minimal hot path this machine needs from a library of
position-independent fragments, **copies it down** to a compact resident image, and frees
everything else. The result is small and optimal on every machine — a tiny 8088 PIO path
on a 5150, a 32-bit DMA path on a Pentium — from the same binary.

## Hard floor: it must run on an IBM 5150

8088 instructions only, 8-bit ISA, conventional memory only, 3C509B PIO, tiny resident.
Everything above the 5150 (286 bus-master/XMS, 386+ 32-bit/cache, PCI) is **additive**.
See `docs/01-constraints.md`.

## Build profiles

- `wmake minimal` — 8088/5150 floor: 3C509B PIO, conventional memory. Smallest image.
- `wmake full`    — everything: ISA+PCI, PIO+DMA, XMS, all generations.

## Docs

| Doc | Topic |
|-----|-------|
| `docs/00-overview.md` | Scope, the EtherLink III lineage, what this is |
| `docs/01-constraints.md` | IBM 5150 floor, TSR/Crynwr/8088 rules, size budgets |
| `docs/02-resident-construction.md` | **JIT fragment composition + copy-down** (centerpiece) |
| `docs/03-hal-vtable.md` | `nic_info_t`/`nic_ops_t`, shared EL3 core + generational deltas |
| `docs/04-dma-model.md` | DMA two-axis model, test-before-trust, VDS/bounce/cache tiers |
| `docs/05-memory-buffering.md` | Three-tier memory, adaptive buffering, size-tiered datapath |
| `docs/06-boot-sequence.md` | Phased boot + unwind + config cache |
| `docs/07-porting-plan.md` | What to lift from the old repo, in tiers |
