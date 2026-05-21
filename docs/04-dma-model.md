# 04 — DMA Model: two axes, tested before trusted

DMA is the hardest part because the *right* strategy is the intersection of what the NIC
can do, what the environment safely allows, and what actually works on this chipset — and
getting it wrong corrupts memory silently. DOS gives us none of this; we build it at init.

## Axis 1 — NIC DMA capability (a gradient, inherited up the lineage)

```
PIO only          3C509B                 the universal floor; every card has it
single / one-shot                        program one transfer, kick, wait, repeat
linked ring DMA   3C515, Boomerang+      NIC walks a descriptor chain (DOWN/UP_LIST_PTR)
bus mastering     3C515 (ISA), all PCI   NIC is first-party bus master (not the 8237)
```

Capability is "what kind of DMA, and how many in flight" — not one bit. Single-shot and
ring-walking are *different emitted datapaths*.

## Axis 2 — the environment that gates Axis 1

| Constraint | Cause | Mitigation |
|------------|-------|------------|
| linear ≠ physical | V86/VMM (EMM386, QEMM, Windows DOS box) | **VDS** (INT 4Bh): translate, lock pages, check contiguity |
| 24-bit / 16 MB limit | ISA bus mastering | bounce buffer for memory above 16 MB |
| no 64 KB crossing | ISA DMA | split the transfer or bounce |
| cache vs DMA | non-snooping 386/486 | cache-coherency tier (flush) |

The environment can change between boots **without any hardware change** (user loads
EMM386 today, not yesterday), so it is **always detected fresh** and never trusted from a
cache. (See cache-safety rule below.)

## The decision: capability ∩ environment ∩ tested-working

```
            NIC capability        environment safety        proven by test
            (axis 1)              (axis 2)                  (busmaster + cache)
                │                      │                          │
                └──────────┬──────────┴────────────┬─────────────┘
                           ▼                        ▼
                  chosen datapath           wrappers required
              PIO / single / ring        VDS lock | bounce | cache flush
```

Resolved into a policy:

```
dma_policy = DIRECT     real mode, physical == linear      → DMA addresses used directly
           | COMMONBUF  V86 + VDS present                  → VDS-locked / common buffers
           | FORBID     V86, no VDS                        → fall back to PIO
```

On a **5150 the whole thing collapses to PIO**: no bus-mastering possible, so axis 1 is
PIO, the busmaster test and cache tiering are skipped, and `dma_policy` is moot.

## Test before trust

Bus-mastering on older ISA/EISA chipsets is unreliable, so the driver **proves it** before
enabling it:

1. Run a bounded DMA exercise (pattern transfers, boundary cases, timing).
2. Score confidence; require a threshold (higher on 286 where chipsets vary most).
3. Only then set `HW_CAP_BUSMASTER` "trusted" and let the composer emit the DMA path.
4. On any doubt, emit PIO. PIO is always correct; DMA is an optimization.

Cache-coherency tier is selected per CPU/chipset:

```
tier 1  CLFLUSH         Pentium 4+      surgical line flush
tier 2  WBINVD          486/Pentium     full flush (batched to amortize)
tier 3  software barrier 386            manual ordering
tier 4  none            286 / no cache  nothing to do
disable bus master      coherency unproven → PIO
```

## Cache-safety rule (load-time)

If detection/test results are cached to skip re-probing:

- **Cache only hardware-stable facts** — busmaster confidence, cache tier, chipset, CPU,
  EEPROM — validated by a hardware signature; invalidate on mismatch.
- **Never cache the environment** — re-detect V86/VDS/memory managers every load and
  recompute `dma_policy` from cached-capability ∩ fresh-environment.
- A stale cache can therefore never silently enable DMA into an unsafe environment.
- Even on the cached path, a sub-second sanity DMA check gates first trust.

## What gets emitted

- 5150/floor: PIO fragments only.
- 286 + tested ISA bus-master + (XMS/bounce as needed): ring-DMA fragments + bounce/VDS
  wrappers selected by `dma_policy`.
- 386+/486: same, plus the matching cache-flush fragment for the chosen tier.
- PCI Boomerang+: PCI ring-DMA fragments (32-bit addressing, no 16 MB limit).
