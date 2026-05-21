# 00 — Overview

## What this is

A DOS TSR packet driver for the **3Com EtherLink III family**, exposing the Crynwr
Packet Driver Specification v1.11 over a software interrupt (default INT 60h) so DOS
network stacks (mTCP, NCSA Telnet, etc.) can use the NIC.

One binary supports the whole family, from the original IBM PC to Pentium/PCI machines,
by *specializing itself to the host at load time* rather than shipping fat runtime
branches.

## Why the design looks the way it does

The driver is modeled on the structure of Donald Becker's Linux `3c59x`/`3c515` drivers,
because 3Com's hardware is a **lineage**, not a set of unrelated cards. Each generation
inherits the previous one's traits and adds new bus support and features:

```
3C509B   EtherLink III   ISA 8/16-bit   PIO, register windows           (the base)
3C515-TX Corkscrew        ISA 16-bit     + bus-master DMA, MII PHY
3C59x    Vortex           PCI            (Vortex core on PCI), bigger FIFO
3C90x    Boomerang        PCI            + descriptor-ring DMA
3C905B   Cyclone          PCI            + HW checksum, NWAY
3C905C   Tornado          PCI            + scatter-gather, WoL, power mgmt
         + CardBus/Mini-PCI variants
```

This shapes the code: a **shared EtherLink III core** (windowing, EEPROM, MAC, PIO
datapath) plus **per-generation capability deltas**, dispatched through one vtable
(`nic_ops`) and gated by capability flags (`HW_CAP_*`). PIO is the universal fallback
every card shares; DMA, bus-mastering, checksum, etc. are capabilities layered on top.

## The four design pillars

1. **Generational HAL** — `nic_info_t` + `nic_ops_t` vtable; common core + deltas.
   (`03-hal-vtable.md`)
2. **DMA is a two-axis problem** — the NIC's DMA capability gradient (PIO → single →
   ring → bus-master) intersected with the runtime environment (V86/VMM, ISA 16 MB/64 KB,
   cache coherency), and **never trusted until tested**. (`04-dma-model.md`)
3. **Adaptive performance** — buffer geometry tuned at init to CPU × bus × memory; a
   per-packet size threshold routes small packets through PIO and large through DMA;
   XMS used only for large/staging. (`05-memory-buffering.md`)
4. **Self-specializing resident** — the cold phase JIT-composes the minimal hot path for
   this machine and copies it down; the composer and all init are then discarded.
   (`02-resident-construction.md`)

## The defining constraint

Everything must fit and run on an **IBM 5150 (8088)** at the floor, and scale up to
Pentium/PCI at the ceiling. The 5150 is not an afterthought — it is the baseline the
whole design is measured against. (`01-constraints.md`)

## Non-goals

- Not a protocol stack — it is the link-layer packet driver only.
- No 8237 third-party DMA for the NIC datapath (NIC bus-mastering only, where present).
- Hardware checksum/VLAN offload is detected but not consumed by DOS stacks; exposed only
  if a future consumer needs it.
