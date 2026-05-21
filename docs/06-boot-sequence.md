# 06 — Boot Sequence

The boot is a strict, phased sequence with reverse-order unwind on any failure. It ends by
composing and copying down the resident, then installing vectors. Everything here is cold.

## Phases

| # | Phase | Does | Unwind |
|---|-------|------|--------|
| 0 | Entry / args | parse CONFIG.SYS args, validate environment | — |
| 1 | CPU detect | 8088→Pentium class + features | — |
| 2 | Platform probe | V86/VMM, VDS present?, memory tiers | — |
| 3 | Config | merge args + (optional) cached results | CFG |
| 4 | NIC detect | ISA (3C509B/3C515) + PCI (if bus present); EEPROM/MAC | NIC |
| 5 | DMA validate | busmaster test + cache tier (skipped on floor) | — |
| 6 | Memory | tiers + buffer geometry (per CPU×bus×mem) | MEM |
| 7 | **Compose** | JIT-emit the hot path for this machine | — |
| 8 | **Copy-down** | pack resident, relocation fixups | RESIDENT |
| 9 | Install | hook INT 60h + NIC IRQ; PIC unmask | VECTORS |
| 10 | Activate / TSR-keep | go live, keep minimal paragraphs | — |

Phase ordering matters: capabilities (1–5) must be known before geometry (6), which must
be known before composition (7), which must complete before copy-down (8). Vectors are
installed only after the resident image is final (9), never before.

## Unwind

Each phase that acquires a resource marks itself complete. On any error, `unwind` releases
completed phases in reverse order: restore vectors, re-mask PIC, free memory, undo NIC
init, restore config. Guarantees no leaked vectors/memory/PnP state regardless of where it
fails. This is the same discipline as the old repo's 15-phase unwind, trimmed to what we
need.

## Config cache (optional, additive)

At phase 3, if a per-machine cache exists and its hardware signature matches, load the
**hardware-stable** results (CPU, chipset, busmaster confidence, cache tier, EEPROM) to
skip the slow phase-5 tests. The **environment (phase 2) is always re-run** and the DMA
policy recomputed (`04-dma-model.md`). Composition (phase 7) always runs — it is cheap.

## Floor path (5150)

On an 8088: phase 5 is skipped entirely (PIO only), phase 6 uses the conventional-only
minimal geometry, phase 7 emits the 8088 PIO fragments and nothing else. The composer and
all of phases 0–8 are 8088 code and fit within the floor load budget.
