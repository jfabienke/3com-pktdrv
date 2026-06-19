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

1. `dma.h` verdict fields + the resident `cache_flush` helper scaffold (default `NONE`) + `call` sites in the
   TX/RX DMA paths (batched). **Verify on QEMU:** still works, helper is `ret` (coherent), no regression.
2. The RX-direction self-test in `phase_validate_dma`. **Verify on QEMU:** probe runs, concludes coherent
   (no cache modeled), no regression; a `FORCE_FLUSH` build flag makes the helper `WBINVD` and the driver
   still works (proves the flush path is harmless under TCG).
3. Descriptor coherency (Piece 3) + alignment (Piece 4).
4. (separate milestone) NC-region lift (Piece 5), behind the re-test gate.

## What this does and doesn't prove

- **Proven on QEMU:** the cold pass runs, the verdict resolves, the DMA paths still deliver, the flush helper
  is selectable and harmless. Structural correctness + no regression to the existing matrix.
- **Not provable on QEMU (needs real HW):** that the flush/NC actually prevents stale reads, the per-tier
  flush cost, the NC encodings. These are research-validated and runtime test-before-trust, per `13`/`12`.

---

_Last updated: 2026-06-19 12:20 CEST._
