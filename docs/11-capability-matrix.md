# 11 — NIC generation × capability matrix (the fragment-palette design tool)

The lineage looks like a combinatorial explosion — **6 generations × 7 buses × ~5 CPU classes**.
It isn't, because the emitted fragments don't fork on generation or bus. They fork on three
things, and generation/bus are just *selectors* over that space:

```
        fragment identity  =  ( capability  ×  CPU class  ×  coherency )

        generation  ─┐
                     ├─► selects a CAPABILITY SET  ─┐
        bus         ─┘                              ├─► composer picks fragments
        CPU/chipset ───► selects CPU + COHERENCY ───┘     from the (cap × cpu × coh) space
```

So you design the **snippet palette against capabilities**, and the matrices below are the
selection tables. See `03-hal-vtable.md` (vtable + bus probers), `04-dma-model.md` (the two-axis
DMA model + test-before-trust), `05-memory-buffering.md` (tiers + geometry), and
`10-copybreak-pipelines.md` (the datapath this composes).

## 1. Generation × capability

`✓` yes · `—` no · `~` partial/variant. Datapath tier is shown separately in §3 because the **bus**
participates in it.

| Generation | Busmaster | Ring DMA | MII | Full-dup | NWAY | 100M | Large/FDDI | HW csum | S/G TX | PermWin1 | WoL |
|---|---|---|---|---|---|---|---|---|---|---|---|
| **3C509B** EtherLink III | —¹ | — | — | ~ | — | — | — | — | — | — | — |
| **3C515** Corkscrew | ✓ | ✓ | ✓ | ✓ | ~ | ✓ | **✓** | — | — | — | — |
| **Vortex** 3C59x | ~² | — | ✓ | ✓ | ~ | ~ | — | — | — | ✓ | — |
| **Boomerang** 3C90x | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — | — | ✓ | — |
| **Cyclone** 3C905B | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | **✓** | — | ✓ | ~ |
| **Tornado** 3C905C | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | **✓** | ✓ | ✓ |

¹ PIO on ISA — **but the EISA/MCA bus adds single-transfer busmaster** (§3).
² Vortex bus-masters in hardware; treated PIO on PCI, but single-transfer on EISA (3C597).

Flag mapping (`hardware.h`): `HW_CAP_BUSMASTER` alone = single-transfer; `+ HW_CAP_RING_DMA` =
ring-capable. `Large/FDDI` is the storage-critical one and the only ISA part with it is the 3C515.

## 2. Bus × environment (coherency, addressing, enumeration)

| Bus | DMA addr | Coherency | Provides | Enumeration | I/O |
|---|---|---|---|---|---|
| **ISA8** | 24-bit | measured¹ | PIO only | ID port | port (8-bit) |
| **ISA16** | 24-bit / **16 MB** | measured¹ | + NIC busmaster | ISA PnP / ID port | port |
| **EISA** | **32-bit** | measured¹ | **bus busmaster** (single-xfer) | slot ID regs | port |
| **MCA** | 24/32-bit | measured¹ | **bus busmaster** | POS regs | port |
| **PCMCIA-16** | — | — | PIO only | CIS / Socket Svcs | port |
| **PCI** | 32-bit | coherent | NIC busmaster ring | PCI config | port/MMIO |
| **CardBus** | 32-bit | coherent | NIC busmaster ring | PCI cfg + CIS | port/MMIO |

¹ **Coherency is measured, not bus-determined** — it's a chipset/cache property, orthogonal to the
bus (`docs/13`). PCI/CardBus are coherent by spec (host bridge snoops); ISA/EISA/MCA must be
*tested* (ISA commodity often non-coherent; EISA/MCA often coherent; a 386 + transparent 82385 is
un-probeable, so it can only be measured). The other bus-owned fact is the **DMA address limit**
(the 16 MB cap is **ISA-only**; EISA/MCA/PCI/CardBus are 32-bit — see §6).

## 3. Datapath tier = f(silicon, bus, CPU)

There are **three** tiers, not two — single-transfer DMA is a real tier between PIO and ring, and
it is reachable *either* by a 286 on a ring part *or* by the **EISA/MCA bus** on a PIO part:

```
   PIO   <   SINGLE-TRANSFER DMA   <   LINKED RING DMA
                (one descriptor,         (NIC walks DOWN/UP_LIST
                 kick, wait, repeat)      autonomously; 386+ only)
```

| Silicon | ISA | EISA / MCA | PCI / CardBus |
|---|---|---|---|
| **EtherLink III** (3C509/3C579/3C529) | PIO | **single-xfer** (bus) | — |
| **3C515** Corkscrew | single (286) / ring (386+) | — | — |
| **Vortex** 3C59x | — | **single-xfer** (3C597) | PIO |
| **Boomerang+** | — | — | single (286) / ring (386+) |

The load-bearing row is EtherLink III: **PIO on ISA, single-transfer on EISA/MCA** — same core,
different tier, because the bus contributes the DMA engine. So this refines `hardware.h`'s "datapath
is bus-agnostic": mostly true, except **EISA/MCA busmaster unlocks the single-transfer tier**.

Tier selection rule:

```
   !BUSMASTER  ||  cpu < 286            → PIO
   BUSMASTER && (!RING_DMA || cpu==286) → SINGLE-TRANSFER
   RING_DMA  &&  cpu >= 386             → RING
```

## 4. Capability → fragment(s) — and the variant multiplier

`*` exists · `+` enumerated in `codegen.inc`, unwritten · `NEW` needed for the offload/zero-copy work.

| Capability | Fragment slot(s) | Forks on… | Count |
|---|---|---|---|
| PIO datapath | `FRAG_RX_PIO`*, `FRAG_TX_PIO`* | **CPU** {8086, 286, 386} | 2 × 3 = **6** |
| Window select | `FRAG_WIN_SELECT`+ | — (elided if `PERMWIN1`) | 1 |
| ISR enter / EOI | `FRAG_ISR_ENTRY`*, `FRAG_ISR_EOI`* | IRQ {master, slave} | ~3 |
| API dispatch | `FRAG_API_DISPATCH`* | — | 1 |
| Single-transfer DMA | `FRAG_*_RING`+ (single-xfer mode) | CPU {286} / bus | shared w/ ring |
| Ring DMA | `FRAG_RX_RING`+, `FRAG_TX_RING`+ | **CPU** {286 single, 386 ring} | 2 × 2 = **4** |
| Cache management | `FRAG_CACHE_FLUSH`+ | **coherency/CPU** {386 sw-barrier, 486 WBINVD, P CLFLUSH}; none if snoop | ~3 |
| Copybreak | `FRAG_RX_COPYBREAK`+ | — (threshold = baked immediate, CPU-tuned — `10`) | 1 |
| **RX deliver** | NEW | **CPU × HW-csum** (see below) | 2 |
| HW checksum | NEW (TX set-bits / RX read-status) | TX/RX; **Cyclone+** only | ~2 |
| S/G TX gather | NEW (fragment-list descriptor) | **Tornado** only | 1 |

The **RX deliver** fragment is itself CPU × offload-tiered (`10` — Copy economics): a fused
**copy-and-checksum** variant for no-csum parts (286/386/486 → **one** payload pass) and a
**zero-copy-in-place + read-csum-status** variant for HW-csum parts (Cyclone+ → **zero** passes).

## 5. The combinatorial collapse

The whole lineage is **~24 distinct snippets**, not ~200 configs. A new generation or bus adds a
**row that re-uses existing fragments**; it forces a *new* snippet only when it introduces a new
**capability** (HW csum, S/G) or a new **CPU/coherency tier**. Three buckets of work:

- **Done:** the 6 PIO fragments (`rx_pio`/`tx_pio` × 8086/286/386).
- **Enumerated, unwritten:** single-transfer + ring DMA (×2 CPU modes), cache management (×3 tiers),
  copybreak, window-select — the bus-master path.
- **New for offload/zero-copy:** the conventional zero-copy / fused copy-checksum RX-deliver pair,
  HW-checksum TX/RX, S/G TX.

## 6. Capability negotiation extends QUERY (the AH=F0h handshake)

Two per-bus / per-NIC facts must be **reported by the driver**, not hardcoded by the consumer —
both are one extra field on the `INT 60h AH=F0h` QUERY response (alongside `max_slot`):

- **`dma_addr_limit`** — the producer's `xms.c` currently hardcodes the ISA 16 MB check
  (`phys >> 24`), which **wrongly rejects valid buffers on EISA/PCI/CardBus** (32-bit) with >16 MB
  RAM, silently dropping to PIO. The driver knows the limit from `bus_type_t`; report it.
- **`csum_offload`** — `HW_CAP_HWCSUM` is detected but "unused by DOS"; exposing it lets the stack
  elide its software checksum (and skip the fused-copy variant) on Cyclone+.

Both follow the same `max_slot` pattern already in the handshake: driver reports the capability,
consumer gates its software path on it.

## Status & relationship

- Design-of-record selection tables for the fragment palette. Corrects the earlier framing that
  single-transfer DMA was only a 286 CPU-mode: it is a **tier**, also unlocked by the EISA/MCA bus.
- Feeds `10` (the RX-deliver fragment tiers) and is fed by `03`/`04`/`05`.
- The bus-master fragments (`+`) and the offload fragments (`NEW`) are not yet written; the resident
  path today is PIO-only with the opt-in XMS ring (`09`).

---

_Last updated: 2026-06-15 09:02 CEST._
