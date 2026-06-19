# 13 — Cache coherency: measure, don't assume

Cache coherency with bus-master DMA is a property of the **chipset / cache controller**, not the
bus. So the driver **measures** it at cold init rather than inferring it from ISA/EISA/MCA/PCI. This
corrects the bus-determined framing in earlier docs (`11` §2) and narrows the worst case in `10`/`11`.

## Why the bus doesn't tell you

Snooping (the cache controller invalidating on a DMA write) is orthogonal to the bus the master sits
on — a write-back cache may or may not snoop. The honest priors:

- **PCI / CardBus** — coherent by spec (the host bridge snoops). Safe to trust.
- **ISA** — commodity 486 boards are *commonly* non-coherent (the worst case is real), but some
  chipsets snoop. Not guaranteed.
- **EISA / MCA** — designed for bus-mastering on professional systems, so **often coherent in
  hardware**, but system-specific. **Never safe to assume non-coherent.**
- **386 + external controller (82385 etc.)** — *transparent*, no software-visible registers, and the
  386 predates `CPUID`, so coherency (and even cache presence) **cannot be probed programmatically**.
  This case forces the test-first approach: you must *measure*.

## The cold probe ladder (self-verifying at each rung)

```
   1. TRUST PCI/CardBus            → coherent (spec); skip to "done"
   2. COHERENCY SELF-TEST          warm small buf=A (cache it) → loopback-DMA buf=B → read, NO flush
        == B → snoops → COHERENT   → cacheable pool, no flush, no NC               [best]
        == A → non-coherent → ↓
   3. NC ATTEMPT + RE-TEST         mark a VIRGIN region NC → DMA B → read, NO flush
        (real nc_write op only —12)   == B → NC works → NC pool, no flush          [good]
                                       == A → NC ineffective → ↓
   4. FLUSH FLOOR                  cacheable pool + per-transfer flush (see flush ladder below)
```

The self-test measures the *symptom*, so it handles the invisible cache by construction: **no cache**
and **snooping cache** both read fresh → "coherent"; only a **non-snooping** cache reads stale. You
never have to detect "is there a cache" to make the flush decision.

**Probe hygiene** (or you false-positive "coherent"):
- keep the test buffer **small** (fits any cache) and **warm it in the instruction just before** the
  DMA — cold init is single-threaded, so it won't evict in the µs gap. An evicted line reads fresh
  and lies "coherent."
- the loopback is TX→RX through the **MAC's internal loopback** (the only way to make the NIC *write*
  host memory for an RX-coherency check).
- rung 3 uses a **virgin** (never-read) region so no full-cache flush is needed to clear stale lines.

## What cache detection adds — and what it can't

Detecting the cache (cache-kit, `12`) refines the verdict; it does **not** replace the self-test.

- **Pre-filter:** no cache / cache disabled → coherent by definition → skip the probe and the flush.
  Catches the "386/486 with cache off or no external cache" case that CPU class can't see.
- **Write mode — the high-value one.** The ~250 µs/frame worst case is a **write-back** phenomenon
  (`WBINVD` is expensive because it *writes dirty lines back*). The common **486DX/SX L1 is
  write-through** → coherency needs only an **invalidate**, ~µs, *if* the whole hierarchy is
  write-through (nothing dirty to lose). Detecting write mode is what lets you safely pick the cheap
  invalidate over the conservative `WBINVD`. So the real worst case is **non-coherent + write-back**,
  not "non-coherent."
- **Sizing:** cache size → size the probe buffer to actually cache, and bound the 386 software sweep;
  line size → align/pad the ring precisely (vs the conservative 32 B).
- **Cannot do:** tell you whether the chipset *snoops* (orthogonal to mode/size). The self-test stays
  the ground truth.
- **386/82385:** un-probeable → **timing-based** detection (loop-read a small region vs a large one;
  the size where latency jumps is the cache size) is the *only* way to get presence/size — and it's
  what bounds the software sweep below. cache-kit, being a cache tool, already has it (`12`).

## The flush ladder (when non-coherent)

```
   1. NC region        chipset op, ONE-TIME at init → no per-transfer cost           [best]
   2. WBINVD / INVD     CPU instruction (486+); INVD if write-through-safe, else WBINVD
   3. chipset flush op  for caches WBINVD can't reach: 386 (no WBINVD) or a stubborn external L2
   4. software eviction read a cache-sized region to evict — universal fallback       [floor]
```

**The chipset flush op** is the cache *controller's* own flush — a write to its config registers
(the index/data ports `CK_IO` abstracts: 0x22/0x23, OPTi 0x22/0x24, VIA 0xA8/0xA9) or a pulse of the
82385 FLUSH pin. It exists because (a) the 386 has no `WBINVD`, and (b) some 486/Pentium external L2
controllers ignore the `WBINVD` flush cycle. Its cost follows the write policy: **write-through →
cheap invalidate; write-back → expensive drain.** The trigger is board-specific (the 82385
standardizes the pin, not how the board pulses it), so it comes from a **per-chipset table**
(`chipset_ops_t`, `12`) — and when the chipset is *unrecognized*, you fall to rung 4 (the
timing-sized software sweep).

The 386 + 82385 is doubly forgiving: the 82385 **snoops** (usually tests coherent → no flush) and is
**write-through** (cheap invalidate if not). This is `04`'s "386 software-barrier" tier made concrete:
no `WBINVD`, so the flush is a chipset op (recognized) or a timing-sized sweep (unrecognized).

## Combined verdict — one cold pass

```
   detect cache (cache-kit) → coherency self-test → cache write-mode
        no cache / disabled              → COHERENT (free)
        snooped                          → COHERENT, cacheable, no flush
        non-snoop + write-through        → cacheable + cheap invalidate   (or NC)
        non-snoop + write-back + NC      → NC pool, no flush
        non-snoop + write-back + no NC   → batched WBINVD / chipset flush / timing-sized sweep
```

This shares the cold harness with the bus-master test (`04`) — one DMA-a-pattern primitive producing
one verdict tuple `{ busmaster_trusted?, coherent?, write_mode, nc_effective? }` that picks the
datapath tier and the cache fragment. Reclaimed after install; **re-run every load** (never cache the
environment — `04`).

## Cost

~1–5 ms cold (dominated by a handful of loopback transfers; sub-ms incremental over the bus-master
test you already run). Keep it bounded: **never full-cache-flush in the probe** (virgin regions),
**loop back at 100 Mbit not 10**, **3 confidence repeats is plenty**. Negligible against the EEPROM
bring-up (~2–3 ms) and a multi-second DOS boot.

## Update 2026-06-19 — research validation + two corrections (Phase 2 implementation)

Before implementing, the hardware claims here were validated against Intel SDM / OSDev / vendor docs, and
two holes in the plan above were found. **The mechanism stands; these refine it.**

**Validated hardware facts** (cite-checked):

- **`WBINVD` (0F09) is the safe universal flush; `INVD` (0F08) is not.** `INVD` invalidates *without*
  write-back → dirty lines are **lost**. So the flush ladder's "INVD if write-through-safe" (rung 2) is a
  real but dangerous micro-opt: only safe when the *whole* hierarchy is proven write-through (nothing dirty).
  **Default to `WBINVD`; use `INVD` never, unless write-through is positively proven.** (Intel SDM Vol 3.)
- **No CPU NC mechanism on 486/Pentium.** MTRRs are Pentium-Pro (P6)+ only; the PCD page bit needs paging,
  which real-mode DOS doesn't have. So an NC region in real mode **must** come from the **chipset (KEN#)** —
  i.e. exactly the per-chipset `nc_write` ops of `12`, which are board-specific. There is no portable fallback.
- **Early 486 (DX/SX/DX2) L1 is write-THROUGH;** write-back only on DX4-`&EW` / DX2-P24D / later AMD-Cyrix.
  So the "non-coherent + write-back" worst case is a *minority* of 486 boards; most 486 L1 is WT (cheap
  coherency — an invalidate, if it were reachable). The conservative `WBINVD` covers both.
- **386 has no `WBINVD`** (486+ instr); the external 82385/chipset flushes reactively on HOLD/HLDA, is
  board-specific, and is **not software-probeable** — which is exactly why the self-test (measure the symptom)
  is the ground truth for the 386 tier, and the flush there is a chipset op or the timing-sized sweep.

**Correction 1 — descriptor coherency (the probe ladder above only covered data buffers).** The NIC writes
`UP_COMPLETE` into the RX *descriptor* that the driver **polls**. On a non-coherent cache the poll caches a
stale "not done" and **spins forever / never sees the frame** — a worse failure than a stale data buffer.
The descriptors must be coherent too: keep them inside the NC region (preferred — they're tiny), or
invalidate before each status read. The coherency verdict must gate descriptor access, not just payload.

**Correction 2 — batched flush + RX-direction self-test.** A per-frame `WBINVD` (~250 µs on a 486) **exceeds
the 100-Mbit inter-frame budget (~121 µs/1514 B)** — it would cap throughput below wire. So the flush is
**batched**: one flush per NAPI drain (the ISR already loops over all ready slots — `14`/conv ring), not per
frame. Also: the self-test must exercise the **RX direction** (the NIC *writes* host memory, via the MAC's
**internal loopback**), since RX (card-writes / CPU-reads → needs *invalidate*) is the failure mode the conv
ring hits; the existing `phase_validate_dma` only does a TX/download probe (card *reads* memory).
TX coherency (CPU-writes / card-reads → needs *write-back*) only bites on a write-back cache; `WBINVD` before
the TX kick covers it and is harmless on write-through.

**Emulator caveat (decisive for how this is validated).** QEMU/TCG models **no CPU cache**, so the self-test
always reads "coherent" and the **flush / NC paths are never exercised by behavior** on the emulator. They are
**structurally verifiable only** (the probe runs, concludes coherent, the driver still works; a force-flag can
prove `WBINVD`/evict execute harmlessly). The *effect* requires real 386/486 hardware — the same gap
cache-kit has. Phase 2 therefore ships as **research-validated + runtime test-before-trust** code, not
emulator-proven throughput. This is why the safe core (self-test + `WBINVD`/evict, always correct) leads, and
the NC-region lift (`12`, unverified encodings) is an optional optimization gated behind a re-test.

Implementation plan: [`17-cache-coherency-impl.md`](17-cache-coherency-impl.md).

## Status & relationship

- Corrects `11` §2 (coherency is *measured*, not bus-determined); narrows the `10`/`11` worst case to
  **non-coherent + write-back + no NC region**.
- Cache tiers + flush opcodes live in `04`; NC ops + cache-detection (write-mode, timing-based size)
  are lifted per `12`; the 386 software-barrier tier (`04`) = chipset flush or timing-sized sweep.
- Mechanism validated 2026-06-19 (above); safe core being implemented per `17`. NC-region lift deferred
  behind the test-before-trust gate.

---

_Last updated: 2026-06-19 12:20 CEST._
