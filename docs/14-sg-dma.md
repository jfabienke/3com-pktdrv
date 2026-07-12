# 14 — Scatter/Gather DMA: zero-copy TX gather + RX copybreak

**Status:** Phase A **IMPLEMENTED + validated** (2026-07-12); Phases B/C/D design. **Goal:**
remove the per-byte payload copies from the DMA datapath — gather TX frames from a header
fragment + an in-place payload fragment, and deliver large RX frames in place (copybreak) — so
the CPU stops touching payload bytes on the fast tiers. Builds on the caller-phys TX vertical
(Phase 8b.2a, #30) and the R1.c RX-DMA ring (#80/#81).

> **Phase A status (mechanism, #82).** ABI opcode `TX_SUBMIT_SG=0x08` + cap `XMS_CAP_SG_TX=0x0200`
> + `xms_tx_sg_t` (16 B) locked across all three ABI sources (`abi_check.sh` OK). Driver builds a
> 24-byte 2-fragment DPD (`f_xms_tx_submit_sg`/`dma_tx_caller.desc_go`, `resident.asm`); the cap is
> advertised **PCI-only** (the ISA 515 single-transfer engine can't fragment-walk) and the handler
> rejects off-PCI submits defensively. The QEMU PCI walker (`el3_pci_process_tx_chain`) was already
> fragment-aware (#72), so **no model change** was needed; it applies Cyclone csum post-gather.
> Proven by `src/sgtxtest.c` + `tools/sgtx_verify.py`: on **3c905b** 4/4 frames gather correctly
> (142 B = 42 B header ++ 100 B payload from non-contiguous pool offsets) with valid inserted
> IP+UDP checksums on the csum frames; on **3c905** gather-only, 4/4. NVMe VERIFY 128 KB still OK
> (no datapath regression). **Not yet wired into the stack's TCP xmit hot path** — that (the actual
> throughput win) is the next sub-step (Phase A.2 / folds with #31 H2C).

Companion docs: [11 PCI plan](11-pci-plan.md), [13 R1.c RX ring](13-r1c-rx-ring.md),
[04 DMA model](04-dma-model.md).

---

## 0. What we have vs. what SG adds

Today every DMA descriptor is a **single-fragment** DPD/UPD: `NEXT(4) FSH/STATUS(4) ADDR(4)
LEN(4)`, 16 bytes, `LAST_FRAG` (LEN bit31) set immediately. One descriptor = one contiguous
buffer = one whole frame. The 486+ TX ring even **copies** the caller frame into a fixed
`TX_SLOT_SZ` slot before DMA. RX copies slot → receiver ring → app.

SG makes each frame span **N fragments**:

- **TX gather:** fragment 0 = the L2/L3/L4 header (the stack's existing TX header template,
  `tcp.c:100`), fragment 1 = the payload *where it already lives* (the caller's INT 13h buffer /
  socket data). No header-prepend copy, no ring-slot copy.
- **RX copybreak:** the UPD points at an **app-owned** buffer; large frames are handed up in
  place (zero-copy), small frames are copied into a recycled pool (cheap). This is R1.c Stage 2
  (#81), folded in here.

The full payoff is **SG-TX + Cyclone HW checksum**: the CPU builds a ~40-byte header, hands the
NIC two pointers, and never reads the payload at all. On non-Cyclone NICs SG still removes the
copy but the stack must read the payload once to checksum it (see §5).

### Memory-touch accounting (per payload byte)

| Path | TX | RX (large frame) |
|------|----|------------------|
| Today (fused cksum+copy TX; slot→ring→app RX) | read+write+accum (~2) | read+write (~2) |
| SG, non-Cyclone | read+accum (~1) | read (~1, copybreak in place) |
| SG + Cyclone HWcsum | **0** (NIC gathers + checksums) | **0** (in place) |

Resident-memory win: the SG-TX path needs **no `TX_SLOT_SZ` bounce slots**; `/j` FDDI (4608-byte
slots × ring depth ≈ 72 KB) collapses to two fragment pointers. Small 1-fragment slots stay only
for control frames (ARP, pure ACK) that are already contiguous and tiny.

---

## 1. Hardware ground truth (fragment descriptor format)

Boomerang/Corkscrew/Cyclone DPD, little-endian (Becker `3c59x.c`, iPXE `3c90x`):

```
+0   DnNextPtr    phys of next DPD (0 = end of list)
+4   FrameStartHdr (FSH)   flags: TxIndicate, dnComplete (NIC-set), AddIP/TCP/UDPChecksum (Cyclone)
+8   Frag0Addr    phys of fragment 0
+12  Frag0Len     length; bit31 = LAST_FRAG
+16  Frag1Addr    phys of fragment 1
+20  Frag1Len     length | LAST_FRAG
...  up to the card's fragment limit
```

Our current 16-byte descriptor **is** a 1-fragment DPD (`Frag0Addr@8`, `Frag0Len@12`). SG just
adds more `(addr,len)` pairs after it. The download engine sums fragment lengths until `LAST_FRAG`
— there is no separate total-length field to maintain. UPD (RX) is the same shape with
`UpPktStatus` in place of the FSH.

**Scope decision — fixed 2-fragment TX.** We only ever need header + payload, so we define a
fixed 24-byte 2-fragment DPD rather than a variable-length walker on the driver side. (The model
walks arbitrary N for fidelity.) Header-only control frames use the existing 1-fragment path.

---

## 2. Dependency & sequencing (read first)

- **BLOCKED ON #80.** The RX-DMA read path still has an open residual (128 KB readback corrupts at
  ~62 KB, see [doc 12](12-realhw-residuals.md) R1.c section). SG-RX reuses the exact same
  descriptor-ownership machinery. **Do not layer SG on a broken RX base** — land #80 first.
- **RX portion == #81.** The completion/free-ring copybreak in §6 *is* R1.c Stage 2. This doc is
  its detailed design; it supersedes the stub in doc 13.
- **TX portion is independent of RX** and can proceed in parallel once #80 is closed, because it
  reuses the mature blocking caller-phys path (`dma_tx_caller`), not the RX ring.

---

## 3. ABI (single-sourced, both repos)

Extend `include/xms_dma.inc` + the stack mirror (`src/pktdrv.h`) together, with the byte-table +
build-assert discipline from the cross-repo ABI rule. New opcodes on INT 60h AH=0xF0:

| AL | Name | Args | Meaning |
|----|------|------|---------|
| `0x08` | `XMS_DMA_TX_SUBMIT_SG` | `ES:DI -> xms_tx_sg_t` | submit one 2-fragment frame |
| `0x06` | `XMS_DMA_RX_REFILL` (was stub) | `DX:CX = buf phys, BX = handle` | return a consumed RX buffer to the free ring |

```c
typedef struct {              /* xms_tx_sg_t — caller fills, driver reads once */
    u32 hdr_phys;   u16 hdr_len;      /* fragment 0: header template */
    u32 pay_phys;   u16 pay_len;      /* fragment 1: payload in place */
    u16 flags;                        /* bit0 = request HW checksum (Cyclone) */
} xms_tx_sg_t;                        /* 16 bytes; version-tagged like xms_rx_cfg2_t */
```

New cap bit: `XMS_CAP_SG_TX equ 0x0200` (advertised on every bus-master tier ≥286). Cyclone
additionally advertises `XMS_CAP_HWCSUM` (already exists); the stack sets `flags.bit0` only when
both are present.

---

## 4. TX gather — driver

Reuse `dma_tx_caller` (resident.asm ~1401), which already builds a 1-fragment `xms_tx_desc` and
blocks on `dnComplete`. Add `dma_tx_caller_sg`:

```
; in: xms_tx_sg_t already copied to a resident scratch (read once, before clobber)
; build xms_tx_desc as a 2-fragment DPD:
   NEXT      = 0
   FSH       = EL3_FSH_TX_INDICATE  [| csum bits if flags.bit0 & Cyclone]
   Frag0Addr = hdr_phys,  Frag0Len = hdr_len            ; NO last-frag bit
   Frag1Addr = pay_phys,  Frag1Len = pay_len | LAST_FRAG
; then identical to dma_tx_caller: write DnListPtr, StartDmaDown, wait dnComplete (R2 dual-evidence)
```

- **Descriptor grows to 24 bytes** — bump `xms_tx_desc` reservation; keep `EL3_DESC_SIZE`=16 for
  the RX ring (still 1-fragment per UPD).
- **Blocking lifetime (Stage A).** The INT 13h caller blocks for the whole `TX_SUBMIT_SG` call, so
  both fragments are stable until `dnComplete`. No retain-until-ACK needed. This covers the NVMe
  **write H2C** path (the memory-heaviest TX we have) and pure-header control frames (1-fragment).
- **Cyclone csum:** set `FSH_ADD_IP_CSUM | FSH_ADD_TCP_CSUM` in the FSH; the NIC computes over the
  gathered frame. Gated on `flags.bit0`.
- **Floor safety:** `dma_tx_caller_sg` is bus-master-only (≥286), cold-selected, behind the
  existing DMA gate; the 8088 PIO floor is untouched.

---

## 5. TX gather — stack

The stack already builds a contiguous **TX header template** per connection (`tcp.c:100`, the
slow-CPU lever). SG makes it fragment 0 and points fragment 1 at the payload:

1. Build/refresh the header template (L2+L3+L4) into a small **pinned** header buffer; capture its
   phys once (revalidate on `txb_stamp` bumps — ARP relearn, per `arp.c:28`).
2. **Checksum:**
   - *Cyclone:* leave TCP/IP checksum fields zero, set `flags.bit0`. Done — no payload read.
   - *Non-Cyclone:* run `cksum` over pseudo-header + **payload in place** (read-only, no copy),
     write the result into the header buffer. This replaces today's fused `cksum_copy` — same
     read pass, minus the write pass (the copy). Net: one fewer memory pass over the payload.
3. Call `pkt_xms_tx_submit_sg(hdr_phys, hdr_len, pay_phys, pay_len, flags)`.

The payload phys for NVMe writes is the caller's INT 13h buffer (already resolved to phys for
`TX_SUBMIT`); for TCP it is the socket send buffer. **Retain-until-ACK (pipelined TCP, #31) is
Stage D** — until then, TCP SG-TX stays send-and-block per segment (correct, just not pipelined),
and only the NVMe write path (blocking by construction) gets the full benefit first.

---

## 6. RX zero-copy — completion/free ring + copybreak (== #81)

Replace the Stage-1 "copy slot → receiver ring → app" with app-owned buffers:

- **Free ring** (driver-owned array of UPDs whose `ADDR` = phys of a **stack-supplied** buffer).
  `RX_CONFIGURE2` gains a `slots_lin[]`/`slots_phys[]` vector; the stack posts app buffers.
- **Completion:** when the NIC sets `upComplete`, the driver decides by **copybreak threshold**
  (`RX_COPYBREAK`, default 256 B):
  - *small frame:* copy into a recycled small-buffer pool, **immediately re-arm** the UPD with the
    same app buffer (buffer never leaves; no free-ring traffic).
  - *large frame:* hand the app buffer up **in place** (zero-copy) and re-arm the UPD from the
    free ring; the stack returns the buffer via `RX_REFILL (0x06)` after consuming.
- **Delivery:** zero-copy uses the receiver **hint path** (`ES:DI` = the filled buffer, read in
  place). Today's receiver has a single hint slot (`pktrecv.asm`); extend it to a small
  **ready-queue** of (seg,off,len) so bursts of in-place frames don't overrun (the Stage-1 bug
  that forced the no-hint copy). Small copybreak frames keep using the existing 16-slot copy ring.

This removes the large-frame RX copy and the need for a deep resident receiver ring; small frames
(ACKs, control) stay cheap. It also naturally carries `/j` FDDI RX (#26): a large frame lands in
one app buffer, no oversized resident slot.

---

## 7. QEMU model changes

- **TX fragment walk.** `el3_pci_process_tx_chain` (and the ISA `el3_core_dma_tx_single`)
  currently read one `(ADDR,LEN)`. Loop: read fragment at `desc+8+8*i`, `memcpy` into the frame
  assembly buffer, stop on `LAST_FRAG`. Guard the fragment count (bound to a sane max).
- **Cyclone csum over the gathered frame.** `FSH_ADD_*_CSUM` is already honored; ensure it runs
  **after** gather (checksum the assembled frame, not a fragment). Add a pcap assert.
- **RX.** No model change for copybreak — the model places a whole frame into the UPD's buffer
  regardless of who owns it; copybreak is a driver/stack policy. (True multi-fragment RX scatter is
  *not* in scope; the win is zero-copy delivery, not fragmented receive.)
- **Fidelity note.** Real Corkscrew fragment DMA is documented but unproven on our side; keep the
  `dn_writeback`/dual-evidence hedging (R2) and validate on 515 silicon in the R3.c ladder.

---

## 8. Phased implementation (each gated)

| Phase | Content | Repos | Gate |
|-------|---------|-------|------|
| **Pre** | Land #80 (RX read residual) | driver+qemu | 128 KB VERIFY read passes on 905 |
| **A** | SG-TX 2-fragment DPD + model fragment walk + `TX_SUBMIT_SG` ABI + Cyclone-first csum | all 3 | pcap shows 2-fragment DMA; VERIFY write passes on 905B; icount confirms **zero payload touch** vs. Phase-8b baseline |
| **B** | Non-Cyclone SG-TX (read-only checksum into header frag) | stack | 515 + 905 write no-regress; one fewer payload pass (CFG_PROF) |
| **C** | RX copybreak — free/completion ring + `RX_REFILL` + receiver ready-queue (== #81) | all 3 | large-frame read zero-copy; matrix no-regress; folds #25/#26 |
| **D** | Retain-until-ACK for pipelined TCP SG-TX (== #31) | stack | pipelined TCP write no-regress; **optional/deferred** |

Emulator-first throughout; the real-HW confirmation rides the R3.c ladder (#79).

---

## 9. Risks

- **R1 — ownership/lifetime.** Fragment buffers must stay stable until `dnComplete`/`upComplete`.
  This is the #80 bug class. Stage A sidesteps it (blocking caller); Stage C/D reintroduce it →
  test-before-trust, adversarial ring-full/burst tests.
- **R2 — ABI drift.** Two new opcodes + a struct across two repos. Single-source with pinned byte
  tables + build-breaking asserts (the cross-repo ABI rule), or the driver/stack silently diverge.
- **R3 — Corkscrew fragment fidelity.** Documented, not proven. Hedge as R2 did; gate real-HW.
- **R4 — checksum correctness on gather.** Non-Cyclone must checksum the *logical* frame
  (pseudo-header + payload) not the fragments; Cyclone must checksum post-gather. pcap-verify both.
- **R5 — floor safety.** All SG ≥286, bus-master-only, cold-gated behind `CFG_PCI`/DMA. Resident
  budget on the 8088 path is untouched; SG *reduces* resident use on the DMA tiers.

---

## 10. Verification

- **Correctness:** pcap shows each frame assembled from 2 fragments with valid on-wire checksums
  (Cyclone offload path already has the 13119/13119 pcap proof to extend).
- **Memory win:** CFG_PROF / icount before-after on 486 + Pentium — payload memory passes drop by
  one (non-Cyclone) or to zero (Cyclone); throughput lift on the per-byte-bound tiers.
- **No-regress:** `run_nvme_matrix.sh` across 509/515/590/905/905B; real-SPDK vmnet smoke.
- **Resident budget:** `/j` build no longer allocates 4608-byte TX slots (map check).
