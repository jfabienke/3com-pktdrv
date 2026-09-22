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

> **Superseded in part (review, 2026-09 — see [Review fixes](#review-fixes-2026-09)).** The as-built trial
> differs from the sketch above: step 2's "warm" is a *seed* + `WBINVD` (where safe) + a **read** of the dest
> (a store alone doesn't allocate on no-write-allocate caches); step 4 polls **IntStatus `UpComplete`** (I/O,
> never cached), not the in-memory descriptor; the frame is a well-formed **broadcast** with the patterns at
> byte 16; and the NC re-test no longer uses a virgin buffer but a probe area at the top of a whole 64 KB block
> (`13`).

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
  *(As built, 2026-09: the NC fence is always exactly one naturally aligned 64 KB block; the whole pool —
  slots + descriptor block — must fall inside it, else no NC and the flush is kept. See `12`.)*

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
     the loopback trial (*as built since 2026-09: a 512 B probe area at the top of the first whole 64 KB block
     above the image, same (base, code) shape as the live marking, both directions — `13`*). Fresh →
     `g_nc_effective`; stale → keep the flush. A wrong encoding can only KEEP the
     flush (costs the optimization, never correctness). `f_xms_configure` marks the live conv pool NC when
     validated. **Verified on QEMU:** `/n` absent → NONE 15.12 dropped=0; `/n=4` on the coherent emulator →
     "NC=requested, not effective", 15.12 dropped=0; `CFG_FORCE_NC` + `/n=254` (synth, no port writes) drives
     the whole flow → "NC=validated", WBINVD kept, 15.11 dropped=0. Inert by default (coherent verdict → NC
     skipped); the effect needs real non-coherent 386/486 HW.
   - **4b — DONE. WB gate + VDS/COMMONBUF NC reachability + DMA fallback ladder + descriptor relocation.**
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
     - **VDS / COMMONBUF — NC reachable on real write-back machines — DONE.** A WB cache ⇒ 386+/486 ⇒ a paging
       memory manager (EMM386/QEMM) is almost always loaded ⇒ **VDS** ⇒ the DMA ring lives in VDS-managed
       memory, *not* the conventional `CONV` pool (the no-manager path). 4a fenced NC only under `CONV`, so on
       the very WB machines NC exists for, it never fired. Closed that gap end to end:
       - **Stack** (`dos-nvmeotcp` `vds.c`/`vds.h`, lifted from the old repo): VDS presence (BIOS 40:7Bh bit 5 +
         Get Version), V86 detection (`SMSW` CR0.PE), and `vds_lock_region` — lock the conv ring **in place**
         and take `DDS.physical` as the **true bus address** (`seg<<4` is a lie under a paging VMM). Contiguity
         test = `buffer_id == 0` (VDS didn't need a bounce buffer) + a `< 16 MB` ISA range check. (Trust **CF**
         for success, *not* AL — JEMM386 leaves AL≠0 on a successful lock.) `conv_ring_init` now returns the new
         `COMMONBUF` policy under V86+VDS (`phys0` = bus address, `lin0` = the ring's V86 **real-mode linear**
         `seg<<4` — a 32-bit linear < 1 MB the CPU reads in place, *not* a segment value; the ISR turns
         `lin >> 4` back into a segment), or `CONV` in real mode, or PIO if V86 without usable VDS. Lock held
         until `xms_release`.
       - **Driver** (`XMS_POLICY_COMMONBUF`): routes through the same contiguous CONV descriptor builder, but
         delivers in place via `lin0` — a resident `g_lin_delta = lin0 - phys0` (0 for CONV) added to each
         descriptor phys in the ISR. The NC-marking gate now covers `CONV` **and** `COMMONBUF`, fencing the
         **true VDS physical** (`phys0`) — as one aligned 64 KB block that must hold the whole pool (2026-09).
       - **Verified on QEMU under JEMM386 (V86 + VDS):** `VDS avail=1 v86=1`, lock `rc=0 bid=0 isa=1`,
         `CONVRING=on pol=4` (COMMONBUF), conv RX-DMA `[L4RX] delivered=6104260 dropped=0` (= the CONV path, no
         regression); with `CFG_FORCE_NC /n=254` → `NC=validated` marking the VDS physical, still `dropped=0`.
         Real-mode (HIMEMX only) stays `CONV pol=3`, unchanged. Harness: `JEMM386=1` env on `l4-tx-test.sh`.
     - **DMA fallback ladder + V86 safety — DONE.** What happens when the zero-copy ring can't be set up safely:
       - **WB w/o VDS (V86, no VDS host).** The driver now makes the documented `DMA_POLICY_FORBID` explicit:
         `dma_v86_forbid_check` (`build_plan`) does `SMSW` (CR0.PE) + the BIOS-data VDS flag (40:7Bh bit 5);
         **V86 && no VDS → force PIO** (`g_use_dma`/`g_async`/`g_tx_ring` = 0). Real mode keeps DMA; V86 *with*
         VDS keeps DMA **only once proven** (2026-09 review): the 386+ ring is required, and the driver
         VDS-locks its own DMA span `[tx_descs, resident_end)` and requires `phys == seg<<4` (identity), holding
         that lock for its lifetime (plus the cold probe span, released after the probes); any failure → PIO.
         ~~Even without this, TX DMA was already safe~~ — **that earlier claim was wrong**: `phase_validate_dma`
         only proved the page holding `tx_descs`. The TX slots, the RX descriptors and AH=F1 stack buffers
         (`seg<<4` from the caller) were never proven, so a remapping VMM could have sent the card to the wrong
         physical memory after a passing probe. Hence the span proof above plus a per-send VDS lock for AH=F1
         (see [Review fixes](#review-fixes-2026-09)). Verified on QEMU: real mode `DMA=ON` CONV pol=3; JEMM386
         (V86+VDS) `DMA=ON` COMMONBUF pol=4; forced no-VDS `DMA=PIO` (RX falls to PIO, dropped=0).
       - **>16 MB / non-contiguous → PIO** (for the *zero-copy* ring). A conventional buffer is always <1 MB so
         `>16 MB` can't actually arise here; non-contiguous can only happen on a remapping VMM that fragments
         the conv block's physical pages — there `vds_lock_region` reports a bounce (`buffer_id != 0`) /
         `vds_phys_isa_ok` fails → `conv_ring_init` returns NONE → the caller uses **PIO**. A VDS *common
         buffer* (`request_buffer`) would keep DMA alive but only via Copy-In/Out per frame — i.e. a copy
         model, which is exactly the **existing `XMS_COPY` policy** (extended EMBs are contiguous by XMS
         construction and their XMS-lock physical is correct under V86, since EMM386 doesn't page extended
         memory). So the layered fallback is: **COMMONBUF/CONV** (zero-copy) → **XMS_COPY** (copy-DMA, the path
         the TSR already uses) → **PIO** (floor). Reimplementing `request_buffer` for the conv ring would just
         duplicate `XMS_COPY`, so it's deliberately not added; scatter-gather (a descriptor per fragment) is the
         only zero-copy-preserving option for the fragmented case and isn't worth its complexity for that rare
         combo (remapping VMM + slow CPU).
     - **Descriptor relocation / flush-drop — DONE.** 4a marked the pool NC but *kept* the per-drain flush,
       because the RX descriptors lived in the cached driver region (`xms_rx_descs`) — the card writes
       `UP_COMPLETE` there for the CPU to poll, and an NC region over the *pool* didn't cover them. So NC saved
       nothing (the WBINVD covering the descriptors was still the cost). Closed it by relocating the descriptors
       **into the NC pool** (chosen over a dedicated granule-isolated block, which needs a scarce 2nd chipset
       region): one region now covers descriptors + payload, so the per-drain flush drops.
       - **One parameterised path, not dual.** Three resident vars locate the descriptor block: `g_desc_far`
         (CPU far ptr), `g_desc_phys` (card-facing physical), `g_rx_flush_fn` (the *per-drain* RX helper,
         separate from the TX `g_cache_flush_fn`). Every descriptor access (the `.build_conv` loop, the
         `UP_LIST`/`NEXT` arm, the ISR `xms_rx_deliver` STATUS/ADDR/recycle, the `f_xms_poll` drain) goes
         through them. Defaults (`CS:xms_rx_descs`, `phys(CS:xms_rx_descs)`, the flush tier) reproduce the
         cached path byte-for-byte — verified by no-regression. The 286 2-slot path never relocates
         (`g_nc_effective` ⇒ 486+ ⇒ deep ring), but since the 2026-09 review its `NEXT` links and the ISR
         pre-arm also derive from `g_desc_phys` (no second `CS<<4` computation to drift).
       - **Layout.** The stack reserves a `DESC_BLOCK` (`RX_RING_N * 16 B`) at the **pool END** (past the
         slots) — since 2026-09 this is the **cfg v2** contract (`XMS_RX_DESC_BLOCK`; a v1 pool never
         relocates). When `g_nc_effective` + CONV/COMMONBUF + 386+ ring + v2, `f_xms_configure` first fences
         the pool NC and **only if that succeeds** points `g_desc_far`/`g_desc_phys` at `lin0`/`phys0 +
         ring_bytes` and sets `g_rx_flush_fn = cache_flush_none`. The one-time configure writeback
         (`g_cache_flush_fn`) runs **after** the marking and the descriptor build, before `UP_LIST_PTR`
         (marking evicts nothing, so lines written cached before it are still dirty). ~~The 64 KB NC granule
         already covers the +128 B block~~ — **wrong as written**: nothing guaranteed the slots + block sat in
         one fenced granule (the old code sized the region from the slots only and rounded per chipset). Now
         the fence is exactly one aligned 64 KB block computed over the **whole** span (slots + descriptor
         block, `nc_span64`); a span crossing a 64 KB boundary gets no NC and keeps the flush.
       - **Verified on QEMU.** Real-mode CONV `pol=3` and JEMM386 COMMONBUF `pol=4` both `[L4RX]
         delivered=6104260 dropped=0` (no regression from the far-pointer refactor). `CFG_FORCE_NC` `/n=254`
         → `NC=validated (pool+desc NC; RX flush dropped)`, descriptors relocated to the pool end, per-drain
         flush dropped, still `dropped=0`. The flush-drop *effect* is real-HW-only (TCG models no cache); the
         relocated datapath itself is fully exercised.
       This completes Phase 2 step 4 (the whole NC track: safe core → WB gate → VDS/COMMONBUF → fallback ladder
       → descriptor relocation).

## Review fixes (2026-09)

A code review of the step-4b state found defects in the DMA gating, the XMS ABI, V86 addressing, the
coherency probe and the NC region handling. All are fixed; this is the as-built design. (Commits `62beb3c`
.. `235d4bb`: `60da35b` `8af42a3` `5f08ff7` `26a1bb7` `18454af` `8b4a940` `ad81cae` `b1f8ede` `235d4bb`, and
`4a62c5c` (`rx_drain_cksum`'s CPU gate moved to a resident byte); dos-nvmeotcp `0ee2cb9` sends cfg v2.)
The emulator still verifies structure + no regression only.

1. **AH=F0 gated on `g_use_dma`.** On the PIO floor install frees everything past `resident_end_pio`, so the
   whole extension (QUERY/CONFIGURE/RELEASE/POLL) returns bad-command there — `xms_*` state is freed memory.
   VCPI/DPMI configure additionally requires the 386+ ring (QUERY only advertises them with it).
2. **Slot size / 32-byte stride.** QUERY now always reports `DX = 1536` (`TX_SLOT_SZ`, a 32-byte multiple);
   CONFIGURE accepts 1..1536 and requires a 32-byte multiple for CONV/COMMONBUF. Root cause: `xms_rx_deliver`
   finds a CONV slot's CPU segment as `lin >> 4` and reads at offset 0, so every slot must be paragraph-aligned.
   QUERY used to return 1514 unless `/j`; the cold-flag clear missed `g_want_large`, so stale memory usually
   turned `/j` on and QUERY returned 1536 *by accident*. Once that clear was fixed, the 1514 stride put slots
   1..7 mid-paragraph and the conv ring collapsed (~0.01 Mbit).
3. **V86 + WBINVD.** `g_v86` is recorded (SMSW PE) and a new **`/v`** switch trusts the V86 host (EMM386 /
   JEMM386) to emulate `WBINVD` (a privileged `#GP` under V86). `g_wbinvd_ok = 486+ && (real mode || /v)`,
   decided before any probe so no cold phase issues `WBINVD` unguarded. Non-coherent with **no safe flush**
   (V86 without `/v`, or `<486` since the 386 software-evict tier is still deferred) → PIO, banner
   `DMA=PIO (non-coherent, no safe flush)`. Every PIO fallback (`dma_force_pio`) and the probe cleanup call
   `dma_quiesce`: stall both DMA engines, zero both list pointers, unstall, ack — so a timed-out probe
   descriptor can never land later in reclaimed cold memory or the freed DMA region.
4. **V86 + VDS addressing.** Requires the 386+ ring. The driver VDS-locks its own DMA span
   `[tx_descs, resident_end)` and requires `phys == seg<<4` (identity), holding the lock for the driver's
   lifetime; the cold probe span `[bm_test_buf, coh_probe_end)` is proven likewise and released after the
   probes. Any failure → PIO (e.g. `LH` into a remapped UMB). AH=F1 async sends under V86 VDS-lock each frame
   (`DX=0` — JEMM386 rejects the no-alloc flag; `buffer_id` must be 0; end < 16 MB); the lock is released when
   the ring slot is reused, or at `/u`. If a lock fails the frame is copied into that slot's own `tx_slots`
   buffer (proven identity) and still succeeds with CF=0. (Corrects the "TX DMA was already safe" claim in the
   fallback-ladder bullet above.)
5. **Real-HW status/flush in DMA mode.** `SetStatusEnb` includes Up/DnComplete (`0x07FF`) in DMA mode — a real
   3C515 neither shows nor interrupts on a source missing from that mask (PIO keeps `0x00FF`).
   `phase_validate_dma` `WBINVD`-brackets its descriptor (before the kick, and once per BIOS tick while
   polling) when `g_wbinvd_ok`, so a stale cached descriptor line can't cause a false PIO verdict.
6. **Coherency probe** (details in `13`). Completion is polled in **IntStatus `UpComplete`** (I/O, uncached),
   not the in-memory descriptor. Probe frames are **broadcast** with the patterns at byte 16
   (`COH_PAT_OFF`) so a real MAC's RX filter passes them in loopback. `coh_one_trial` does `WBINVD` (if
   safe) then a **read-allocate** of the dest before the DMA. `coh_is_writeback` reads src after the
   `WBINVD` before writing `NEW`, making it a write **hit** — no-write-allocate WB caches (P5 L1, Intel 486
   WB L1, most 486 L2s) were previously misread as write-through.
7. **NC region policy** (details in `12`). Exactly **one naturally aligned 64 KB block** (`nc_span64`); a
   span crossing a 64 KB boundary gets no NC (flush kept). Fixed size codes per chipset (OPTi/Eteq 4, UMC 3,
   SiS 1) from a table — removing a UMC/SiS bug where the size code was recomputed after `CX` had been
   overwritten. `nc_mark_region` saves the chipset's region-0 registers; `nc_clear_region` restores them.
8. **NC re-test.** A 512 B probe area at the **top** of the first whole 64 KB block above the image (a
   non-zero block, probe at its end, so a wrong base unit or size code misses it), marked with the same
   (base, code) shape as the live marking; 3 trials, each testing **both** directions (recipe in `13`).
9. **XMS cfg ABI v2.** `XMS_CFG_VERSION 2` (min 1). v2 = the producer reserves `XMS_RX_DESC_BLOCK`
   (`RX_RING_N*16`) past a CONV/COMMONBUF ring; v1 is still accepted but never relocates / marks NC. New
   error `XMS_ERR_BAD_LIN` (0x07). CONFIGURE validates CONV/COMMONBUF `lin0` (non-zero, 16-aligned, span
   < 1 MB) and the `phys0` span (< 16 MB); CONV additionally requires `lin0 == phys0` and no V86 host. `lin0`
   is a 32-bit real-mode **linear** (`seg<<4`), not "the V86 segment". The stack (`dos-nvmeotcp`) sends v2
   and retries once as v1 on `XMS_ERR_BAD_VERSION`. (See `09`.)
10. **Configure order.** validate → if NC-eligible (`g_nc_effective` && 386+ ring && v2 && CONV/COMMONBUF):
    `nc_span64` + `nc_mark_region`, and **only on success** relocate the descriptors to the pool end + drop
    the per-drain RX flush (`g_nc_marked = 1`) → build descriptors → one-time `g_cache_flush_fn` (`WBINVD`)
    → `UP_LIST_PTR` → `StartDmaUp`. The 2-slot `NEXT` links and the 286 ISR pre-arm derive from `g_desc_phys`.
11. **Release / uninstall.** `xms_release_core` (shared by RELEASE and `/u`) stops up-DMA, disarms, and
    restores the NC region if `g_nc_marked` — else the block stays uncached after the stack frees the pool.
    `/u` calls `dma_teardown` (stop an armed ring + release all VDS locks) before idling the card.
12. **Where NC actually takes effect.** The install banner still prints `NC=validated (pool+desc NC; RX flush
    dropped)`, but that line only reports the **cold re-test** verdict (`g_nc_effective`). The marking,
    descriptor relocation and flush drop happen later, at **CONFIGURE**, and only for a CONV/COMMONBUF v2
    ring on the 386+ ring whose pool fits one 64 KB block; otherwise the flush stays.
13. **TX slot ADDR re-stamp.** `send_pkt` re-stamps the ring slot's buffer `ADDR` on every send: an AH=F1
    async post shares the descriptors and had left the caller's buffer address there, so a later `send_pkt`
    through that slot transmitted the stale buffer (seen as `CLOSE=FAIL` after async blasts). New file
    `src/asm/resident_dma.asm` holds DMA-only resident code past `resident_end_pio` (VDS locks, AH=F1 V86
    lock, `xms_release_core`, `dma_teardown`); `nc.asm` and `cache.asm` moved into the DMA region too, so the
    PIO floor shrank.

## What this does and doesn't prove

- **Proven on QEMU:** the cold pass runs, the verdict resolves, the DMA paths still deliver, the flush helper
  is selectable and harmless. Structural correctness + no regression to the existing matrix.
- **Not provable on QEMU (needs real HW):** that the flush/NC actually prevents stale reads, the per-tier
  flush cost, the NC encodings. These are research-validated and runtime test-before-trust, per `13`/`12`.

---

_Last updated: 2026-09-22 21:37 CEST (added "Review fixes (2026-09)"; corrected in place the wrong "TX DMA was already safe" and "64 KB NC granule already covers the +128 B block" claims, the `lin0` = "V86 segment" wording, the configure order, and the 286 pre-arm note)._

_Prior: 2026-06-22 06:00 CEST (4b descriptor relocation landed — Phase 2 step 4 COMPLETE: the conv RX descriptors relocate into the NC pool end when g_nc_effective, parameterised via g_desc_far/g_desc_phys/g_rx_flush_fn (one path; defaults reproduce the cached path), so the per-drain WBINVD drops. Verified: real CONV pol=3 + JEMM386 COMMONBUF pol=4 dropped=0 (no regression); CFG_FORCE_NC → NC=validated, flush dropped, dropped=0. The whole 4 track is in: safe core → WB gate → VDS/COMMONBUF → fallback ladder → relocation)._
