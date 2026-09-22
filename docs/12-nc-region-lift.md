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
                                          [as built 2026-09: one aligned 64 KB block, marked at
                                           CONFIGURE — see "Region policy as built" below]
        non-snoop + no/failed NC        → emit FRAG_CACHE_FLUSH (batched WBINVD, once per batch — 05)
```

The chipset `tier/score` also seeds the busmaster-test confidence (`04`), so NC-region detection and
bus-master trust share one cold pass and one chipset lookup.

## Scope & order

- Lands in `07`'s order step 5 (*"386+ cache tiers"*) — NC is part of the cache-tier work, all
  `full`-profile (≥386); the 8088/286 floor never touches it.
- Carry the model + the ~8 ISA chipset ops above; skip the 62-table, the Pentium/PCI NC parts, and
  cache-kit's TUI (`07` skip list).

## Update 2026-06-19 — NC is an OPTIONAL optimization, not the lead (Phase 2)

A pre-implementation audit of cache-kit (the lift source) plus hardware research changed the risk posture.
The NC-region model above is right, but it is **not** the foundation — it rides on top of an always-correct
flush path.

- **cache-kit's NC encodings are emulator-validated only, never run on real hardware.** The base-unit
  encodings for the very chipsets we'd carry are flagged UNVERIFIED in cache-kit itself: OPTi/UMC/Eteq
  "base unit 64 KB vs 16 KB — VERIFY on 86Box vs datasheet" (a 4× error fences the wrong physical addresses,
  silent DMA corruption); SiS 460/Rabbit base-bit ambiguity. A wrong size-code marks the *wrong* region NC →
  the DMA buffer stays cacheable → stale-read corruption, **worse than the flush it replaced**.
- **The stub landmine is real** (confirmed in cache-kit): C&T PEAK/SCAT, ALi Finis, VLSI VL82C311, Faraday
  FE3600 (`nc_count=3` but ops stubbed), VIA VT82C310 all advertise `nc_count>0` with `hal_stub_*` ops.
  Gate on **`ops.nc_write != hal_stub_*`**, never `nc_count` — as `§3` already says, now verified necessary.
- **The emulator cannot test NC at all** — QEMU models no cache *and* none of these chipsets, so the NC
  register writes go to unimplemented I/O and the re-test can never confirm a real effect there (`13` caveat).

**Consequence — reordered.** The driver leads with the safe core (coherency self-test + `WBINVD`/software-
eviction, universally correct — `13`). NC-region marking is attempted **only** when (a) a recognized chipset
exposes a **real** `nc_write` op, **and** (b) a post-marking **re-test** of the self-test flips the result to
fresh. If either fails, fall back to the flush path. So NC can only ever *remove a flush*, never corrupt — the
re-test is the safety net under the unverified encodings. The ~8 ISA chipset ops here are lifted **after** the
safe core lands, behind that gate.

## Status & relationship

- Detailed plan for `07` Tier A′ (NC-region model). Escapes the worst cell in `11`/`10`; the
  fallback (batched WBINVD) and the cache tiers live in `04`; the NC-vs-flush choice is sketched in
  `05`.
- After NC detection, the irreducible worst case narrows to **486 + 3C515 + a stubbed legacy
  chipset** (C&T / Headland / VLSI / Faraday …) with no NC and no ISA-master snoop — batched WBINVD
  only, and only latency-bound single-frame I/O can't hide it.
- Reframed 2026-06-19 as an optional, re-test-gated optimization on top of the safe flush core; lifted
  after the core (`17`).
- **IMPLEMENTED 2026-06-22** as Phase 2 step 4a (NC framework + re-test gate) and 4b (WB discriminator +
  VDS/COMMONBUF + descriptor relocation): opt-in `/n`, re-test-gated, reached only on non-coherent 386+
  write-back machines with a recognized chipset. NC effect is **structurally verified only** (QEMU/TCG
  models no CPU cache — see `13`); the real cache benefit needs real 386/486 hardware. See
  [`17-cache-coherency-impl.md`](17-cache-coherency-impl.md) step 4 for the build order + commits.
- **Region policy revised 2026-09** after a code review (below; `17` "Review fixes (2026-09)").

## Region policy as built (review fix, 2026-09)

The first cut sized the NC region from the ring (slack + ring KB, rounded up per chipset granularity to
8 KB–512 KB) and re-derived the size code per family. A review found that shape fragile and one family
buggy, so `nc.asm` now uses a single fixed shape:

- **Exactly one naturally aligned 64 KB block.** The base registers are in 64 KB units (A23:A16) and many
  decoders mask the base by the size, so a smaller region can only start on a 64 KB boundary and a larger one
  may silently cover a *different*, size-aligned block. One aligned 64 KB block is correct under either decode.
  `nc_span64` takes the physical span (the **whole** pool: slots + the v2 descriptor block) and returns the
  block's `base_kb` only if the span fits inside one block below 16 MB. A span crossing a 64 KB boundary gets
  **no NC** — the flush is kept (correct, just not faster). The stack does not align the pool to 64 KB, so
  whether NC applies depends on where DOS put the pool.
- **Fixed size codes per chipset** (a 5-byte table `nc_tab`: id, base reg, size reg, data port, size value):

  | Chipset | ports | base / size reg | size value for one 64 KB block |
  |---------|-------|-----------------|--------------------------------|
  | OPTi 82C391/Viper/381, Eteq Bengal | 0x22 / 0x24 | 0x52 / 0x53 | `0x40` — code 4 (`8 KB << (code-1)`), A27:A24 nibble 0 |
  | UMC UM82C491 | 0x22 / 0x23 | 0x50 / 0x51 | `0xB0` — enable `0x80` \| code 3 (`8 KB << code`) |
  | SiS 85C460 / Rabbit | 0x22 / 0x23 | 0x14 / 0x15 | `0x10` — code 1 (`64 KB << (code-1)`) |

  This removed a UMC/SiS bug in the old encoder, which recomputed the size code *after* `CX` (the size input)
  had been overwritten by the base register write. The base unit is still **UNVERIFIED on real silicon**
  (cache-kit's 64 KB vs 16 KB question) — the cold re-test is what catches a wrong one.
- **Save / restore.** `nc_mark_region` reads and saves the chipset's current region-0 base + size registers
  before writing (base first, then the size/enable that turns the region on); `nc_clear_region` restores them
  (size first, then base) instead of writing 0, which could clobber other bits in the SiS/UMC control
  registers. Used for the transient cold re-test marking and for the live marking, which RELEASE and `/u`
  undo (`xms_release_core`, when `g_nc_marked`).
- **Same shape proven and used.** The cold re-test (`13`) marks its probe area with exactly this (base, code)
  shape, so the live CONFIGURE marking reuses an encoding the re-test proved. The probe area sits at the
  *top* of a *non-zero* block, so a wrong base unit or a too-small size code misses it and fails the re-test.
- **Marked at CONFIGURE, not install.** Install only records the re-test verdict (`g_nc_effective`; banner
  `NC=validated …`). The live pool is fenced in `f_xms_configure` only for a v2 CONV/COMMONBUF ring on the
  386+ ring; only if that marking succeeds are the RX descriptors relocated and the per-drain flush dropped.
- `nc.asm` now lives in the DMA-only resident region (past `resident_end_pio`), so the PIO floor drops it.

---

_Last updated: 2026-09-22 21:23 CEST (region policy as built: one aligned 64 KB block, fixed per-chipset size codes, register save/restore, marked at CONFIGURE)._
