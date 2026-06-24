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

The **chipset identity is a confidence input**, not just the live exercise: cache-kit's
`chipset_ops_t` carries a per-chipset `tier`/`score_x10` (its "S-TIER: Driver's Dream"
grading) that encodes known snooping/bus-master behavior. We don't lift its 62-chipset
desktop table, but the *pattern* — chipset detect → known-coherency/known-busmaster
prior → fold into the test threshold — is the right shape for selecting the cache tier and
seeding the busmaster-test confidence.

Coherency is **measured, not assumed from the bus** (`docs/13`): a cold probe decides
*coherent → no flush* / *NC region* / *per-transfer flush*, since snooping is a chipset property
(and a 386's transparent 82385 can't be probed at all). The flush *tier* below is the mechanism used
only **when the probe says a flush is needed**, selected per CPU/chipset:

```
tier 1  CLFLUSH         Pentium 4+      surgical line flush
tier 2  WBINVD          486/Pentium     full flush (batched to amortize)
tier 3  software barrier 386            chipset flush op or timing-sized eviction sweep (docs/13)
tier 4  none            286 / no cache  nothing to do
disable bus master      coherency unproven → PIO
```

**Flush primitives + ordering (lift from cache-kit `CK_HAL.C`).** WBINVD and INVD are
emitted as raw opcodes — `0F 09` (WBINVD, 486+, write-back then invalidate) and `0F 08`
(INVD, 386, invalidate *without* write-back — data-loss hazard, only safe on a clean or
write-through cache). The **ordering rule is load-bearing**: on a write-back cache you must
**flush before disabling** the cache; disabling first strands dirty lines and corrupts DMA
buffers. (Write-through is the reverse — disable then flush.) `src/dma/cache.c` lifts these
primitives near-verbatim; see `docs/07` Tier A′.

**Hardware NC region as an alternative to per-transfer flush.** On chipsets that expose
non-cacheable region registers, the DMA buffer region can be marked non-cacheable *once* at
init instead of flushing on every transfer — cheaper than WBINVD per packet. This is a
config option for the cache tier, detailed in `05-memory-buffering.md`.

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

See also: the concrete RX-DMA ring depths and CPU tiers in [`09-xms-dma-ext.md`](09-xms-dma-ext.md),
the cross-repo emulator-side model in [`elink-qemu/docs/dma-design.md`](../../elink-qemu/docs/dma-design.md),
and the realized DMA storage throughput in [`elink-qemu/docs/el3-nvmet-target.md`](../../elink-qemu/docs/el3-nvmet-target.md).

---

_Last updated: 2026-06-24 19:42 CEST — added cross-links to the implemented ring depths (`09`) and the
emulator-side DMA/storage results; the two-axis model itself is unchanged._
