# 17 — Cache coherency: the implementation plan (Phase 2)

The concrete build plan for the cache-coherency milestone. The *what/why* is in
[`13-cache-coherency-probe.md`](13-cache-coherency-probe.md) (measure-don't-assume) and
[`12-nc-region-lift.md`](12-nc-region-lift.md) (NC regions); both got a 2026-06-19 research-validation update.
This note is the *how*, in the order it lands, with the hardware reality stated up front.

## Governing principles (from the research + the emulator reality)

1. **Safe core first.** The always-correct path — coherency self-test → `WBINVD`/software-eviction flush —
   leads. The NC-region lift (`12`) is an optional optimization added *after*, gated on a real chipset op + a
   re-test. Rationale: `WBINVD` is universally safe; cache-kit's NC encodings are unverified on real hardware.
2. **`WBINVD`, never `INVD`** (unless write-through is positively proven). `INVD` drops dirty lines → data loss.
3. **Batched flush.** One flush per NAPI drain (the ISR already loops all ready slots), never per frame — a
   per-frame `WBINVD` (~250 µs) exceeds the 100-Mbit inter-frame budget (~121 µs).
4. **Descriptors are coherency-critical**, not just payload — the card writes `UP_COMPLETE` the CPU polls.
5. **Test-before-trust, every load.** Never cache the verdict across loads (mirrors `04`'s bus-master test).
6. **Emulator can only structurally verify.** QEMU/TCG has no cache model → the self-test reads "coherent" →
   the no-flush path. So on QEMU we verify: the probe *runs*, concludes coherent, the driver still works, and
   (force-flag) `WBINVD`/evict execute harmlessly. The *effect* (stale-read prevention, throughput) needs real
   386/486 hardware. No matrix number changes from this work on the emulator.

## The verdict (one tuple, produced by the cold pass)

Extend the existing `dma_decision_t` (`include/dma.h`) / resident state. Fields the cold pass resolves:

```
coherent?      : self-test read fresh with no flush        (snoop / no-cache / emulator → true)
flush_tier     : NONE | WBINVD | SOFTWARE_EVICT | CHIPSET   (NONE when coherent)
nc_effective?  : NC marked AND re-test confirmed it works   (false unless a real chipset op + re-test pass)
evict_span     : bytes to read for the 386 software sweep   (timing-sized; bounded)
```

`flush_tier` selects which body the resident `cache_flush` helper carries (below).

## Piece 1 — the resident `cache_flush` helper (patched, batched)

The DMA datapath is hand-written resident code (`resident.asm` / `isr.asm`), **not** fragment-composed (the
JIT `g_plan` is PIO-only). So the flush is a **resident helper the DMA paths `call`**, whose body is selected
at cold init by `flush_tier`:

| tier | body | when |
|------|------|------|
| `NONE` | bare `ret` | coherent (snoop / no cache / NC effective / emulator) |
| `WBINVD` | `0F 09` `ret` | non-coherent, 486+ |
| `SOFTWARE_EVICT` | read `evict_span` bytes (16-byte stride) `ret` | 386 (no `WBINVD`) |
| `CHIPSET` | per-chipset register write `ret` | recognized 386/L2 controller |

Selected by **patching the first bytes** of one resident routine (or an indirect `call [g_cache_flush]` through
a resident pointer — simpler, one extra indirection; chosen at impl time). `FRAG_CACHE_FLUSH equ 8` already
exists as an id but the fragment model doesn't fit the hand-written DMA path; the helper supersedes it.

**Batching:** the helper is called **once per drain**, not per frame:
- RX: in the NAPI poll/ISR drain (`f_xms_poll` / `xms_rx_deliver`), invalidate **once** after the loop has
  determined how many slots completed, **before** reading any slot payload or the descriptors. (On a coherent
  system this is the `ret`; cost nil.)
- TX: `WBINVD` **before** `tx_kick` so the card reads fresh frame bytes (write-back caches only; harmless on WT).

## Piece 2 — the coherency self-test (rides `phase_validate_dma`)

Add after the existing bus-master "can it DMA?" test passes (`start.asm` `phase_validate_dma`, `.pv_pass`),
sharing its probe buffer/descriptor machinery. **RX-direction** (the failure mode that matters):

```
  1. (pre-filter) PCI/CardBus bus → trust coherent, skip          [not reachable on the 3C515 ISA target]
  2. warm a small buf with pattern A   (mov a tag in, the instruction before the DMA — no eviction gap)
  3. MAC internal loopback ON; TX a frame carrying pattern B (B != A) so the card RX-DMAs B into buf
  4. poll the RX descriptor UP_COMPLETE (bounded, like the TX probe)
  5. read buf with NO cache flush:
        == B → fresh → COHERENT  → flush_tier = NONE                         [emulator lands here]
        == A → stale → NON-COHERENT → flush_tier = WBINVD (486+) / SOFTWARE_EVICT (386)
  6. repeat ~3x for confidence; any stale → non-coherent (conservative)
```

Probe hygiene (or it false-positives "coherent"): buf **small** (fits any cache), warmed in the instruction
just before the DMA (cold init is single-threaded — no eviction in the µs gap), **virgin** region for the NC
re-test (no full-cache flush needed to clear it), loopback at the modeled 100 Mbit. Cost ~1–5 ms cold,
sub-ms over the bus-master test already run; **never full-cache-flush inside the probe**.

## Piece 3 — descriptor coherency

The RX descriptors (`xms_rx_descs`) and TX descriptors (`tx_descs`) are DMA-touched (card reads TX desc; card
writes RX `UP_COMPLETE`). On a non-coherent cache the CPU's descriptor poll spins on stale data. Options, in
preference order: (a) if NC is effective, place the descriptors **inside** the NC region (they're tiny —
`RX_RING_N*16` + `TX_RING_N*16`); (b) else, the batched RX invalidate (Piece 1) runs **before** the descriptor
status read in the drain, so each drain re-reads fresh descriptors. Align the descriptor block to the cache
line (already `alignb 16`; bump to 32) so an invalidate can't disturb a neighbour.

## Piece 4 — buffer alignment (cheap, do alongside)

- `tx_slots` currently has **no alignment** → add `alignb 32` (cache line; `docs/10`).
- `xms_rx_descs` `alignb 16` → bump to `alignb 32`.
- The conv ring (conventional pool) is already 32-aligned by the stack (`docs/10`); for NC it must additionally
  be aligned/sized to the chipset granularity (8 KB–64 KB) and not share a granule with cached data (`12`).

## Piece 5 — NC-region lift (DEFERRED, optional, gated)

After the safe core: lift the ~8 real ISA chipset `nc_write` ops from cache-kit (OPTi 391/Viper/381, SiS
460/Rabbit, UMC 491, Eteq Bengal, ALi Aladdin-IV). Gate: recognized chipset **and** `ops.nc_write != stub`
**and** a post-marking re-test of Piece 2 flips to fresh. Encodings are unverified on real HW (`12`) → the
re-test is the only thing that makes this safe. Skip the 62-vendor table, the PCI/snooping parts, cache-kit's
TUI/board-config. This is its own milestone; do not block the safe core on it.

## Build order

1. **DONE** (3cpd `ae7326f`). `cache.asm` helper scaffold (`cache_flush_none` = bare `ret`,
   `cache_flush_wbinvd` = `0F 09`) + `g_cache_flush_fn` resident pointer + batched `call` sites in the TX/RX
   DMA paths (`tx_kick`, `dma_tx_single`, `f_xms_poll` drain top). **Verified on QEMU:** 386@sh7 conv ring
   unchanged at 15.12 dropped=0 (helper is `ret`); a `CFG_FORCE_FLUSH` build (WBINVD every TX kick + RX drain)
   stays 15.11 dropped=0 — WBINVD harmless under TCG, the reg/flag-preserving contract holds.
2. **DONE** (3cpd `30331b9` + elink-qemu `054c3a3`). `phase_validate_coherency` (its own cold phase after the
   bus-master TX test, not folded into `phase_validate_dma`) runs the RX-direction loopback self-test → records
   `g_flush_tier` (FLUSH_TIER_NONE/WBINVD/EVICT); `install` maps it to the helper. **The emulator's internal
   loopback was a stub** (nothing set `c->internal_loopback`; even when set, no TX→RX feedback), so the faithful
   path was implemented in `el3_core.c`: a Window-4 NET_DIAG bit-5 write arms `internal_loopback`, and a
   bus-master TX in that mode is fed into `el3_core_dma_rx_single` (armed up-descriptor) instead of the wire —
   matching real 3c515 silicon. **Verified on QEMU:** the cold banner reads `CACHE FLUSH=NONE (coherent)` — the
   probe runs end-to-end, the loopback delivers pattern B, all 3 trials read fresh → tier NONE → no flush;
   conv ring unchanged at 15.12 dropped=0 (486@sh7) / Pentium@sh3. `CFG_FORCE_FLUSH` still overrides to WBINVD.
   (Chose faithful emulator loopback over a driver-only timeout fallback so the probe's readback-compare path
   actually executes on the emulator, not just on real HW.)
3. **DONE** (3cpd `ea57980`). Alignment (Piece 4): `tx_descs` `alignb 4→32`, `xms_rx_descs` `16→32`,
   `tx_slots` (was unaligned) `→32` — descriptor blocks end on a cache line so they never false-share with
   the CPU-hot ring counters (+48 resident bytes, DMA paths only). Descriptor coherency (Piece 3): the READ
   side is already covered by step 1 + NAPI (the ISR only masks UP_COMPLETE and defers the armed conv ring to
   `f_xms_poll`, whose batched invalidate precedes every descriptor STATUS read + the sole `xms_rx_deliver`;
   PIO RX is uncacheable port I/O). Added the WRITE side: `f_xms_configure` writes back the just-built
   descriptors before `StartDmaUp` (else a write-back cache could hand the bus master a STALE buffer ADDR →
   DMA into the wrong memory = corruption). The hot per-slot RECYCLE-write race is the remaining non-coherent
   gap NC closes (step 4). **Verified on QEMU:** 486@sh7 conv ring default NONE 15.12 dropped=0, FORCE_FLUSH
   (WBINVD now also at the arm) 15.11 dropped=0 — no regression. (286 single-transfer keep boundary is
   structural-only: QEMU i386 has no 286/386 CPU model, lower gens are a 486 model scaled by icount.)
4. **NC-region lift (Piece 5), opt-in + re-test-gated. Split during implementation into 4a (done) + 4b (next):**
   - **4a — DONE** (3cpd `5e5dece`). The framework: `/n=<id>` opt-in (1=OPTi 2=Eteq 3=UMC 4=SiS 254=synth;
     explicit chipset, *not* a probe, so an unrecognized board never gets a speculative `0x22` write); `nc.asm`
     resident per-chipset NC encode/write lifted from cache-kit (in-scope ISA ops flagged UNVERIFIED — the 4x
     base-unit landmine — real-HW only); and the **re-test gate** — when the cold self-test finds the cache
     non-coherent *and* `/n` is set, `phase_validate_coherency` marks a VIRGIN probe region NC (covering the
     probe **descriptor + payload**, so it validates the card-write coherency the conv ring needs) and re-runs
     the loopback trial. Fresh → `g_nc_effective`; stale → keep the flush. A wrong encoding can only KEEP the
     flush (costs the optimization, never correctness). `f_xms_configure` marks the live conv pool NC when
     validated. **Verified on QEMU:** `/n` absent → NONE 15.12 dropped=0; `/n=4` on the coherent emulator →
     "NC=requested, not effective", 15.12 dropped=0; `CFG_FORCE_NC` + `/n=254` (synth, no port writes) drives
     the whole flow → "NC=validated", WBINVD kept, 15.11 dropped=0. Inert by default (coherent verdict → NC
     skipped); the effect needs real non-coherent 386/486 HW.
   - **4b — IN PROGRESS. Split into the WB gate (done) + the descriptor relocation / flush-drop (next).**
     - **WB discriminator — DONE.** Chipset NC fences only help **386+ write-BACK** caches. They make no sense
       on a 286 (no on-chip cache; its DMA path is the single-transfer 2-slot, not the deep CONV ring), on a
       386+ with no cache (already coherent → tier NONE, NC never armed), or on a 386+ **write-through** cache
       (CPU writes reach memory immediately → the card reads them fresh → invalidation, not chipset NC, is the
       right tool). But the base self-test only probes the card-WRITE→CPU-READ direction, which reads stale on
       **both** WT and WB — so a WT board would look NC-eligible. Added `coh_is_writeback` (`start.asm`): on a
       486+ it builds the loopback descriptors, writes `OLD` to a cached src + `WBINVD` (lands descriptors AND
       `src=OLD` in memory so the card reads them coherently on the very WB cache being probed), writes `NEW`
       with **no** flush, then loopback-reads src into a **virgin** dest — `dest==OLD` ⇒ the card saw stale
       memory ⇒ write-back (NC-eligible); `dest==NEW` ⇒ write-through/no-cache ⇒ keep the flush. The `.pvc_nc`
       gate now requires 486+ **and** a WB verdict before marking NC (`<486` skips — the 386 evict tier is
       deferred). `CFG_FORCE_NC` runs the probe then forces the WB verdict so the synth NC re-test stays
       exercised. Factored the loopback into `coh_build_descs` + `coh_start_dma` (shared with `coh_one_trial`).
       **Verified on QEMU:** default 3c515 `/5 /d` → `CACHE FLUSH=NONE (coherent)`, full conv-ring + NVMe
       round-trip PASS; `CFG_FORCE_NC` `/n=254` → the discriminator runs end-to-end (no hang), `CACHE
       FLUSH=WBINVD`, `NC=validated`, PASS. The WB/WT *logic* is real-HW-only (TCG models no cache).
     - **Descriptor relocation / flush-drop — NEXT.** 4a marks the pool NC but **keeps the per-drain flush**,
       because the RX descriptors live in the cached driver region (`xms_rx_descs`, ~33 near access sites) —
       the card writes `UP_COMPLETE` there for the CPU to poll, and an NC region over the *pool* doesn't cover
       them. So NC saves nothing yet (the WBINVD that covers the descriptors is the cost). Closing it needs the
       descriptors in NC too: **(a) relocate** them into the NC pool (one region covers descriptors + payload;
       the 33 near sites become far) is preferred over **(b)** a dedicated granule-isolated block (needs a
       scarce 2nd chipset region). Gated so the proven path (286/no-cache/WT/coherent) is untouched and only
       the 386+ WB CONV ring relocates + drops the flush.

## What this does and doesn't prove

- **Proven on QEMU:** the cold pass runs, the verdict resolves, the DMA paths still deliver, the flush helper
  is selectable and harmless. Structural correctness + no regression to the existing matrix.
- **Not provable on QEMU (needs real HW):** that the flush/NC actually prevents stale reads, the per-tier
  flush cost, the NC encodings. These are research-validated and runtime test-before-trust, per `13`/`12`.

---

_Last updated: 2026-06-21 10:42 CEST (4b WB discriminator landed: `coh_is_writeback` gates NC to 386+ write-back caches — 286 / no-cache / write-through never arm it. Descriptor relocation (the flush-drop) is the remaining 4b piece. Steps 1–3 + 4a + the 4b WB gate are in; 4a refactored coh_one_trial into coh_build_descs/coh_start_dma)._
