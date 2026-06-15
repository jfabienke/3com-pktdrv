# 10 — Copybreak pipelines & the conventional zero-copy DMA ring

How a received (or transmitted) frame is sorted into one of **three size classes** across **two
cold-composed drain pipelines**, and why the bus-master landing ring lives in **conventional**
memory so the CPU reads the DMA'd frame in place — no extra copy, no bounce, no VCPI/DPMI.

This refines `05-memory-buffering.md` (the binary size-tiered datapath and buffer geometry) and
`09-xms-dma-ext.md` (which DMAs into XMS and copies down). See *Status & relationship* at the end.

## Three size classes, two pipelines

```
                                THE WIRE
                                   │  frame
                                   ▼
                    ┌────────────────────────────────┐
                    │        3C515   RX FIFO          │
                    └────────────────┬───────────────┘
                                     │ RxComplete IRQ
                                     ▼
                    ┌────────────────────────────────┐
                    │  len = RxStatus & g_rx_len_mask │   length is known
                    │  CMP  len, T   (T = baked imm.) │   BEFORE the drain
                    └────────────────┬───────────────┘
                                     │     ← the ONE hot-path branch
         ┌───────────────────────────┼───────────────────────────┐
      len ≤ T                  T < len ≤ 1514                 len > 1514
   ── SMALL · PIO ──         ── LARGE · DMA ──            ── FDDI · DMA ──
                                                          (cold: /j + 3C515)
   ┌──────────────┐         ┌──────────────┐             ┌──────────────┐
   │  REP INSW    │         │ arm descr +  │             │ arm descr +  │
   │  FIFO→ES:DI  │         │ StartDmaUp   │             │ StartDmaUp   │
   └──────┬───────┘         └──────┬───────┘             └──────┬───────┘
          ▼                        ▼                            ▼
   ┌──────────────┐         ┌──────────────┐             ┌──────────────┐
   │ upcall buf   │         │ conv slot    │             │ conv slot    │
   │ (conv)       │         │ ~1.5 KB      │             │ ~4.5 KB      │
   │              │         │ cache-align  │             │ cache-align  │
   └──────┬───────┘         └──────┬───────┘             └──────┬───────┘
       1 copy                  0 extra                      0 extra
       (small)                 copies                       copies
          └────────────────────────┼────────────────────────────┘
                                    ▼
                    ┌────────────────────────────────┐
                    │  deliver → registered receiver  │   (Crynwr upcall)
                    └────────────────────────────────┘

   Each lane is one cold-composed fragment, chosen per CPU × NIC; the branch picks
   WHICH fragment runs, it never interprets. On the 5150/PIO floor only the SMALL
   lane is emitted and the compare vanishes entirely.
```

The two boundaries are **different kinds of decision**:

| Boundary | Nature | Mechanism |
|----------|--------|-----------|
| **Small ↔ Large** | runtime, **per-packet** | `CMP len, T` against the cold-baked threshold `T` |
| **Large ↔ FDDI**  | cold, **per-install** | `g_use_large` (`/j` + 3C515): `allowLargePackets`, `g_rx_len_mask` 0x07FF→0x1FFF, slot geometry |

`T` is **CPU/bus-tuned and emitted as an immediate** (break-even where `DMA setup + WBINVD` ≈
`REP INSW` of the bytes; 486 WBINVD ~250 µs vs Pentium ~40 µs — see `05`). Nothing about `T` is
computed hot; only the comparison is.

So at the level of **code** there are two transfer pipelines (PIO, DMA); FDDI is a cold-sized
*parameterization* of the DMA pipeline, not a third hot path. The "third pipeline" is real only at
the level of **size class and buffer geometry**.

## Per-packet classification — size is known before the drain

The single hot-path branch sits where the length is already in hand:

- **TX:** `send_pkt` has `CX` (length) before moving a byte → classify → PIO-FIFO send vs DMA
  descriptor path.
- **RX:** after `RxComplete`, read **RxStatus** (carries the frame length) **before** draining the
  FIFO → classify → small drains via `FRAG_RX_PIO` (`REP INSW`) straight into the Crynwr upcall
  buffer; large arms an up-descriptor + `StartDmaUp` to **DMA-drain the FIFO into a conventional
  slot**, delivered in place. The card does not route by size — the driver does, in the window
  between `RxStatus` and the drain.

This is the **one** runtime branch the otherwise-cold-composed hot path tolerates:

```
        in   ax, RxStatus          ; length already required for the drain
        and  ax, [g_rx_len_mask]
        cmp  ax, T                  ; T = baked immediate
        jbe  .small_pio             ; FRAG_RX_PIO  -> upcall buffer
        ; .large_dma               ; arm descriptor + StartDmaUp -> conventional slot
```

Both arms are cold-composed optimal fragments (per CPU × NIC); the branch chooses *which fragment
runs*, never interprets. On the 5150/PIO floor there is no DMA, so only the PIO arm is emitted and
the compare disappears entirely.

## The DMA landing ring lives in conventional memory

The reason is addressability, and it is what makes the path zero-copy:

| Region | CPU-addressable? | DMA-safe (identity + contiguous)? | Tenant |
|--------|------------------|-----------------------------------|--------|
| **Conventional** <640 K | yes | **yes** (identity-mapped under V86) | the DMA landing ring — small, hottest |
| **UMB** 640 K–1 M | yes | **no** (mapped from XMS; linear ≠ physical) | resident code / CPU-only data |
| **XMS** >1 M | **no** | n/a (needs copy or page map) | large **staged** stores (e.g. the page cache) |

```
   ┌───────────────── >16 MB ─────────────────┐
   │   XMS  (extended memory)                  │  ✗ not CPU-addressable (real mode)
   │     └─ staged page cache ─────────────────┼─►  reached by ONE copy at the
   │                                           │     cache access boundary
   ├───────────────── 1 MB ────────────────────┤
   │   UMB / HMA                               │  ✓ addressable   ✗ DMA-safe (mapped)
   │     └─ resident code / CPU-only data      │
   ├───────────────── 640 KB ──────────────────┤
   │   CONVENTIONAL                            │  ✓ addressable  ✓ identity-mapped
   │     ├─ DMA ring slots  ◄══ NIC bus-master │     ✓ DMA-safe  ✓ contiguous
   │     └─ PIO upcall buffers                 │
   └───────────────── 0 ───────────────────────┘
                          ▲
       phys for the ring = VDS (INT 4Bh AX=8103h) under a paging VMM,
                           else  seg × 16  in real mode.   no VCPI · no DPMI · no bounce
```

The DMA ring sits in the one region that is simultaneously **CPU-readable** and **DMA-safe** —
which is exactly what makes it zero-copy.

A real-mode/V86 CPU cannot read XMS, so DMA-into-XMS forces either an `INT 15h` copy down
(`09`'s XMS_COPY) or a VCPI/DPMI page mapping (deferred — heavy, and DPMI yields a >1 MB
PM-linear that the real-mode delivery path can't use). **Conventional memory is already in the
addressable window and the low 640 KB is identity-mapped**, so the NIC bus-masters the frame
straight into the buffer the stack reads — no extra copy, and nothing to remap.

**Physical addressing (no VCPI, no DPMI, no bounce):**

- **VDS present** (`0040:007Bh` bit 5 — a paging VMM is active): `INT 4Bh AX=8103h` Lock DMA
  Region returns the true physical address and pins it; `8104h` unlocks at teardown.
- **VDS absent** (real mode, no paging): physical = `segment × 16` directly.
- **No bounce, ever:** identity-mapped low memory is *physically* contiguous, so a multi-page
  slot is adjacent physical pages; request VDS no-buffer-allocation and it succeeds. The 3C515 is
  a first-party PCI-derived master, so there is also **no 64 KB-boundary constraint** to dodge
  (`04-dma-model.md`).

**Zero-copy ceiling.** True NIC→application zero-copy is unreachable for a TCP/NVMe stack: the
payload arrives wrapped in Ethernet/IP/TCP/PDU headers and may need reassembly, so it is extracted
from the framed buffer at least once. This design hits that floor — **one** unavoidable
payload-extraction copy — by deleting the *extra* XMS copy that `XMS_COPY` pays per frame.

## Buffer geometry for the conventional ring

- **MTU-sized from QUERY.** The slot size is `max_slot` reported by `INT 60h AH=F0h` QUERY —
  Ethernet-sized in standard mode, FDDI-sized (~4.5 KB) when `g_use_large`. (Today `TX_SLOT_SZ`
  is 1536, "FDDI later"; the ~4.5 KB slot is the target for this design.) Two ping-pong slots
  ≈ 3 KB (Ethernet) or ≈ 9 KB (FDDI). Copybreak keeps small frames *off* the ring, so the ring only ever
  holds large/FDDI frames — which is what keeps the slot count tiny and the conventional spend low.
- **Cache-line aligned + padded.** Align the base and pad each slot up to a cache-line multiple —
  **32 bytes** (covers 486's 16 and Pentium's 32; superset of the 3C515's dword DMA requirement).
  On a non-snooping ISA bus master this is a *correctness* item: it prevents a cache line shared
  between a slot and neighbouring data from clobbering DMA'd bytes on write-back. On snooping PCI
  parts it is performance (no false sharing; aligned `MOVSD` on the extraction copy). On the
  cacheless 8088/286 it is free and harmless.
- **One contiguous block.** `_dos_allocmem` gives only paragraph (16-byte) alignment, so allocate
  the ring as a single block, round the base to 32, and use a line-padded stride:

  ```
  slot_stride = roundup(14 + payload_max, 32)
  ring_bytes  = slot_stride * 2 + 32        ; +32 to align the base
  slot0 = roundup(base, 32) ;  slot1 = slot0 + slot_stride
  ```

  Both slots inherit alignment, each is physically contiguous (identity), and there is no 64 KB
  hazard. See `05`'s NC-region option to drop the per-transfer flush where a chipset allows it.
- **Don't arm a dirty slot.** Don't pre-touch (e.g. zero) a slot just before posting its
  descriptor, or the slot's own dirty lines write back over the DMA'd bytes. `WBINVD` (or simply
  not touching it) before arming, read after `UP_COMPLETE`.

## FDDI mode — storage-only, optional

FDDI-sized frames exist for one purpose: pack a **4 KB I/O block + metadata into a single frame**
(one PDU = one TCP segment = one frame), or 2 × 2 KB — for storage workloads such as NVMe/TCP and
NetBT/SMBv1. It is **off by default** and never engaged by general networking.

- Cold-gated: `/j` **and** a 3C515 → `g_use_large = 1` → `EL3_MAC_CTRL_ALLOW_LARGE`, the 13-bit RX
  length mask (`g_rx_len_mask = 0x1FFF`), and ~4.5 KB ring slots. Without it the driver pays none
  of the 13-bit handling, the larger slots, or the conventional footprint.

## Copy economics by CPU generation

On a 286/386 a per-byte copy is a large slice of the per-frame budget, and a copy *after* a DMA
hands back the offload the DMA was for — so on those parts the rule is: the CPU must touch the
payload **at most once**.

**Principle:** *eliminate every copy except the one you can fuse with the checksum; on
HW-checksum parts, eliminate that one too.*

What that removes, on every CPU:

- the **`XMS_COPY` `INT 15h`** down-copy → gone (conventional zero-copy ring). On 286/386 this is
  **disqualifying**, not merely slower — it is the exact copy the rule forbids, so the conventional
  ring is **mandatory** there and `XMS_COPY` is a faster-part-only fallback.
- **TCP reassembly** copies → gone, because a FDDI-sized PDU is **one frame** (above), so the 4 KB
  payload is contiguous at a fixed offset — no coalescing.

What remains is extracting the payload to its destination (`INT 13h` owns `ES:BX`; RX is
single-buffer with no scatter, so the frame can't be split). It can't be *eliminated* on a
no-offload part, but it collapses to **one pass** by **fusing the (mandatory) software TCP checksum
into the copy** — read each word once, accumulate the sum, store it — instead of a `REP MOVSD`
*plus* a separate checksum read-pass. On a memory-bound 286/386 that halves the per-byte traffic.

### Per-byte passes by generation

| Tier | RX-deliver fragment | Passes over payload |
|------|---------------------|---------------------|
| **286 / 386** (3C515, EISA), no HW csum | fused **copy-and-checksum** (`MOVSW`+16-bit / `MOVSD`+32-bit accumulate) | **1** |
| **486**, no HW csum | same fused fragment; `WBINVD` raises the copybreak threshold | 1 |
| **Pentium+ / Cyclone+**, HW csum | **zero-copy in place** + read csum-status bit | **0** |

So the deliver step is not one snippet but a CPU × offload-tiered pair: the fused copy-checksum
variant for non-offloading parts, the zero-touch variant for HW-csum parts.

### Knock-on tunings

- **Copybreak threshold `T` drops on 286/386.** Per-byte PIO is slow there and there is no
  expensive cache flush to amortise (286 = no cache; 386 = a cheap software barrier, not `WBINVD`),
  so DMA wins sooner — steer more traffic onto the DMA engine and off the slow CPU. 486 raises `T`
  back up (the `WBINVD` ~250 µs fixed cost).
- **Negotiate NVMe/TCP digests off on slow CPUs.** Header/data digests (CRC32C) are a *second*
  per-byte pass with no hardware help on these NICs. On 286/386 the session layer should negotiate
  them off and lean on the fused TCP checksum — one pass, not two. (Consumer-side policy, gated on
  CPU class.)

Net: the slow CPUs hit exactly **one** mandatory pass and nothing more — the best a non-offloading
NIC can physically do — and the HW-checksum parts hit zero.

## Producer-side implications (`dos-nvmeotcp`)

The conventional ring is allocated by the consumer of the link (e.g. `nvmetsr.exe`) and handed to
the driver via the existing `INT 60h AH=F0h` ring extension — but with a **conventional zero-copy
policy** rather than XMS_COPY:

- `cfg.phys0/phys1` point at **VDS-locked, cache-aligned, MTU-sized conventional slots**.
- The driver's large-RX arm delivers the slot **in place** (no `INT 15h`); the upcall hands the
  filled buffer straight to the registered receiver.
- `XMS_COPY` (`09`) remains the **fallback** for the rare case where conventional memory can't be
  spared — it trades the extra copy for footprint.

## Status & relationship

- **Refines `05`:** the size-tiered datapath gains an explicit third class (FDDI) and a sharper RX
  model — small frames never enter a DMA buffer (PIO straight to the upcall buffer); large frames
  DMA into a conventional slot delivered in place. This supersedes the earlier "DMA everything,
  copy small frames out and recycle" framing for the bus-master RX path.
- **Refines `09`:** the conventional zero-copy ring is the **preferred** bus-master RX landing;
  XMS_COPY becomes the fallback. The XMS DMA ring's purpose narrows to footprint relief for staged
  data (the page cache), not the hot RX landing.
- **Not yet implemented** — design of record for the bus-master RX datapath; the resident path
  today is PIO-only with the opt-in XMS ring (`09`).

---

_Last updated: 2026-06-15 09:02 CEST — added "Copy economics by CPU generation"._
