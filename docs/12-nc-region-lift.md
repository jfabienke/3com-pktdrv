# 12 — Lifting NC-region capability from cache-kit

This is the detailed plan behind `07-porting-plan.md`'s Tier A′ line *"`chipset_ops_t` registry
pattern + `nc_region_t` → NC-region model."* The payoff is specific: it **dissolves the worst-case
overhead cell** identified in `11`/`10` — a non-snooping 486 driving a 3C515 at 100 Mbit, where a
per-transfer `WBINVD` (~250 µs) can exceed the inter-frame budget. A non-cacheable (NC) DMA pool
removes that flush entirely.

## What we lift — and the part that matters, what we *don't*

From `~/Development/cache-kit` (CACHEKIT, same Open Watcom v2 cross-toolchain — `07` Tier A′):

| Lift | To | Notes |
|------|----|-------|
| `nc_region_t` model + `nc_read`/`nc_write`/`nc_clear` primitives | `src/dma/cache.c` (pattern) | the abstraction the composer calls; never touches register encoding |
| `chipset_ops_t` registry pattern | mirrors `nic_ops_t` | per-chipset `{nc_*, nc_count, granularity, max, tier/score}` |
| the 3 real encoding families | folded into the per-chipset ops | OPTi (base + 4-bit size nibble, 8 KB), SiS (16-bit packed), VIA/ALi (64 KB units + size code) |
| `generic_wbinvd_flush()` / `generic_invd_flush()` | `src/dma/cache.c` | raw `0F 09` / `0F 08`; the **fallback** when no NC region (`07` line 38) |
| **cache write-mode** detect (write-through vs write-back) | `src/dma/cache.c` | picks cheap `INVD` vs expensive `WBINVD`; the worst case is write-*back* only (`docs/13`) |
| **timing-based cache** presence/size detector | `src/dma/cache.c` | the *only* way to size an un-probeable 386 + 82385 cache → bounds the eviction sweep (`docs/13`) |
| per-chipset **flush op** (controller register / 82385 FLUSH) | per-chipset ops | flushes caches `WBINVD` can't reach (386, stubborn L2); the chipset-recognized path before the sweep (`docs/13`) |

**Do NOT lift:** the 62-vendor desktop-chipset table (`07` skip list), and — the key scoping
decision — **only the 486-era ISA NC chipset ops**, not all 16 NC-capable parts. NC region only
matters for **non-snooping bus-master DMA**, which is a pre-PCI 486 ISA/VLB problem; PCI/CardBus
parts snoop, so their NC support is moot for us.

## The chipset subset worth carrying (the worst-case rescuers)

| Chipset | `ops` | NC granularity | Fit for the small DMA ring |
|---------|-------|:--------------:|----------------------------|
| OPTi 82C391 / Viper | `ops_opti_391` / `ops_opti_viper` | **8 KB** | tightest — wraps an Ethernet ring exactly |
| UMC UM82C491 | `ops_umc_491` | **8 KB**, 1 region | fine; 1 region is all we need |
| Eteq 82C495WB Bengal | `ops_eteq_bengal` | **8 KB** (OPTi-compat) | same as OPTi |
| SiS 85C460 / Rabbit | `ops_sis_460` / `ops_sis_rabbit` | 64 KB | coarse, but one window holds all DMA |
| ALi M1489 Aladdin IV | `ops_ali_aladdin4` | 64 KB | same |
| OPTi 82C381 Symphony | `ops_opti_381` | 512 KB | very coarse; still 1-region workable |

We need **exactly one** NC region (the conventional ring is one contiguous block — `10`), so even
the single-region UMC 491 suffices; the constraint is *granularity*, not count. The Pentium/PCI NC
parts (SiS 5598/530/5591, VIA VP1/VP3/MVP3, ALi Aladdin V) are **out of scope** — they snoop.

## The gate: real ops, never `nc_count` (the landmine)

Several stubbed chipsets advertise `nc_count > 0` while their ops still point at `hal_stub_*`
(C&T PEAK/SCAT, ALi Finis, VLSI VL82C311, Faraday, VIA VT82C310 — declared-but-not-implemented).
The composer must gate on **`ops.nc_write != hal_stub_*`**, not on `nc_count`. Marking a region NC
through a stub marks *nothing* → the DMA buffer stays cacheable → **silent stale-read corruption**,
worse than the flush it was avoiding.

## Test-before-trust: the NC DMA self-test

Even with real ops, confirm the *effect* (consistent with `04`'s busmaster test-before-trust):

```
   mark ring NC  →  DMA a known pattern into it  →  read it back WITHOUT a flush
        read == pattern   → NC is real     → emit DMA path with NO cache-flush fragment
        read == stale     → NC ineffective → fall back to batched WBINVD
```

Testing the *effect* (not the register encoding) covers the three encoding families for free, and
catches a wrong size-code or a half-working chipset. Re-run **every load** — never cache the
environment (`04`).

## Composer integration — what NC presence changes

The cold probe already runs for bus-master trust (`04`); NC detection rides the same pass:

```
   detect chipset → chipset_ops_t {real NC?  +  tier/score}
        snooping bus (PCI/CardBus)      → no flush fragment at all; NC irrelevant
        non-snoop + NC verified         → mark pool NC once at init (align/size to granularity,
                                          1 region); emit DMA path WITHOUT FRAG_CACHE_FLUSH
        non-snoop + no/failed NC        → emit FRAG_CACHE_FLUSH (batched WBINVD, once per batch — 05)
```

The chipset `tier/score` also seeds the busmaster-test confidence (`04`), so NC-region detection and
bus-master trust share one cold pass and one chipset lookup.

## Scope & order

- Lands in `07`'s order step 5 (*"386+ cache tiers"*) — NC is part of the cache-tier work, all
  `full`-profile (≥386); the 8088/286 floor never touches it.
- Carry the model + the ~8 ISA chipset ops above; skip the 62-table, the Pentium/PCI NC parts, and
  cache-kit's TUI (`07` skip list).

## Status & relationship

- Detailed plan for `07` Tier A′ (NC-region model). Escapes the worst cell in `11`/`10`; the
  fallback (batched WBINVD) and the cache tiers live in `04`; the NC-vs-flush choice is sketched in
  `05`.
- After NC detection, the irreducible worst case narrows to **486 + 3C515 + a stubbed legacy
  chipset** (C&T / Headland / VLSI / Faraday …) with no NC and no ISA-master snoop — batched WBINVD
  only, and only latency-bound single-frame I/O can't hide it.
- Not yet implemented; part of the 386+ cache-tier milestone.

---

_Last updated: 2026-06-15 09:32 CEST._
