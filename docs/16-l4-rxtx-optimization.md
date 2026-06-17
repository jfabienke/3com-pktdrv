# 16 — L4 raw-TCP RX/TX optimization (the final matrix)

_Last updated: 2026-06-17 17:34 CEST_

This note records the end state of the L4 raw-TCP throughput work: the per-CPU RX/TX matrix with every
optimization enabled, the levers that produced it, and — crucially — **which levers the `-icount` model
can measure and which are real-hardware-only**. It is the performance companion to
[`15-isa-bus-ceiling.md`](15-isa-bus-ceiling.md) (the bus ceiling) and [`10-copybreak-pipelines.md`](10-copybreak-pipelines.md).

> Measured under the `elink-qemu` el3 realtiming model, `-icount shift=N,sleep=off`. CPU speed is the
> shift (286=10, 386=7, 486=5, Pentium=3); NIC rate is `linkspeed` (wire) + `dma_rate` (ISA bus ≈ 48
> Mbit payload). Modeled numbers, but they track real-3C515 / mTCP behavior to the right order. The 286
> is forced to its faithful datapath with the driver's `/2` flag (16-bit `insw`/`outsw` + single-transfer
> DMA + `cksum16`), since the emulator core is a 486.

## Final matrix @100 Mbit (Mbit/s, all optimizations on)

| CPU | RX no-verify | RX verify | TX sync (PIO) | TX async (DMA) | bound by |
|-----|-------------:|----------:|--------------:|---------------:|----------|
| 286     |  2.69 |  1.87 |  2.17 |  3.12 | CPU (~1 MIPS) |
| 386     | 23.73 | 20.20 | 24.80 | **37.04** | CPU (below the ISA cap) |
| 486     | 48.81 | 48.81 | 48.65 | 48.41 | **ISA bus ~48 (flat)** |
| Pentium | 48.81 | 48.81 | 48.65 | 48.73 | **ISA bus ~48 (flat)** |

RX uses the zero-copy receiver ring + delayed-ACK + a window of 4; **RX verify** folds the checksum into
the delivery copy; **TX async** uses the AH=0xF1 zero-copy DMA ring + the mem→mem template fold.

Two regimes, cleanly separated:

- **486 / Pentium are flat at ~48 in every cell** — RX/TX, verify/no-verify, sync/async all pin to the
  16-bit ISA bus. The bus was already the wall, so the CPU-side optimizations are invisible there;
  `verify == no-verify` because the checksum hides under the bus. (See `15-isa-bus-ceiling.md`.)
- **386 is CPU-bound**, every cell under 48 — this is where the optimizations show. The **async TX 37.04**
  is the standout: zero-copy DMA pipeline + the template fold, sitting just under the ISA cap.
- **286** is deeply CPU-bound at ~1 MIPS (the honest hardware ceiling; matches mTCP's real 286 band).

## Gains vs the original baseline (386, same datapath — apples-to-apples)

| 386 cell | original | final | gain |
|----------|---------:|------:|-----:|
| RX no-verify | 13.93 | 23.73 | **+70%** |
| RX verify    | 12.21 | 20.20 | **+65%** |
| TX sync      | 22.72 | 24.80 | +9% |
| TX async     | 32.59 | 37.04 | +14% |

## The levers — and what the harness can see

The governing fact is the model's documented limit (`include/hw/net/el3_core.h`: *"QEMU has no per-access
bus-latency API"*): under `-icount` every instruction costs `2^shift` ns regardless of type, so a slow
ISA `in`/`out` is priced the same as an `adc`. The **measurable** levers are the ones that cut *instruction
count*; levers whose real-hardware win is *hiding work behind slow bus accesses* cannot be exhibited.

| Lever | Mechanism | Measurable here? | Result (386) |
|-------|-----------|------------------|--------------|
| Windowed RX + ISR coalescing | keep N frames in flight; ISR drains a batch | yes (small) | +4% |
| Delayed-ACK (RFC 1122) | ACK every 2nd in-order segment | yes | +18–19% |
| Word-wide RX copy (`movsb`→`movsw`) | halve the receiver copy-out | yes | +14–16% |
| Zero-copy RX delivery | hand the ring slot by reference (no copy) | yes | +15–20% |
| **Move-and-fold: TX build** | fuse payload copy + TCP checksum (one pass) | yes | sync +9%, async +14% |
| **Move-and-fold: RX delivery fold** | fuse verify into the rcvbuf delivery copy | yes | verify +7% |
| Checksum-offload (driver, `port→mem`) | fold the checksum during the FIFO drain | **no — real-HW only** | correct, regresses under icount |

**Why copy/ACK levers win but the offload doesn't:** delayed-ACK removes whole `tcp_xmit` calls, narrower
copies and zero-copy remove copy instructions, and the `mem→mem` fold collapses *two* genuine passes
(memcpy + a separate checksum traversal) into *one* — all reduce instruction count, which the model prices
correctly. The driver's `port→mem` checksum-offload, by contrast, replaces a cheap `rep insd` FIFO drain
with an explicit summing loop; on real ISA hardware the `adc` hides behind the ~1 µs `in` (so the whole
software checksum pass becomes free), but the icount model charges that `adc` at full CPU rate, so it
*regresses* there by construction. It is built, **validated byte-exact** (`OFFMISMATCH=0` on both the 386
`insd` and 286 `insw` paths), and **off by default** — a real-silicon lever the harness cannot reward.

## The move-and-fold convergence

The RX checksum drain, the TX checksum, and the copy-and-checksum fusions are one primitive: a
continuous-carry ones-complement fold riding on an element move (the `adc` chain survives because
`LODS`/`STOS`/`LOOP` don't touch CF). A single NASM `FOLD` macro `{width, store}` now generates
`cksum16/32` (verify, no-store) and `cksum_copy16/32` (mem→mem, store); `cksum_copy` builds TX segments
(`tcp_xmit_data`, `tcp_rawblast_async`) **and** does the RX delivery fold (`tcp_input`). The driver's
`rx_drain_cksum` is the `port→mem` sibling (it pins `DX` to the FIFO, so it keeps its own register
layout, but the fold body is identical). One caveat from working it through: a `mem→port`
"checksum-while-writing-the-FIFO" is **impossible for TCP** — the checksum field precedes in the byte
stream the payload it covers, so TX must pre-compute. The realizable instances are `port→mem`, `mem→mem`,
and `mem-only`. A boot-time self-test validates every instance byte-exact against a C reference (the guest
prints `CKSUM=16`/`32`; `0` means a mismatch forced the C fallback).

## Validation

- **Checksum correctness:** the boot self-test (`tcp_cksum_init`) checks `cksum16/32` *and* `cksum_copy16/32`
  against the C reference over odd/boundary lengths; the RX offload is cross-checked per-frame
  (`OFFMISMATCH`); the RX delivery fold is proven to **reject** corrupt frames with the emulator's
  `rxgenbad` prop (it flips each TCP checksum → verify-mode `RXBYTES` collapses to 0 while no-verify
  accepts them).
- **Throughput methodology:** an in-emulator wire-rate TCP generator (`rxgen`/`rxgenl4`, sliding window
  `rxgenwin`, closed-loop via the reflector) for RX; deterministic `rawblast` + an `[L4TX]`/`[L4RX]`
  emulator-side payload tally over a fixed virtual-time window for the headline number, independent of
  the guest's PIT tick. Harness: `elink-qemu/tests/l4-tx-test.sh` + the per-cell sweeps.

## Bottom line

The optimizations moved the **CPU-bound** cells substantially (386 +65–70% RX, +14% async TX) while the
**bus-bound** cells stayed pinned at the honest ISA ceiling — exactly the shape predicted once the wall is
understood as `min(CPU-rate, ISA-bus, wire)`. The slow-CPU tiers (8088/286/386) remain below the 70%-of-wire
gate at 100 Mbit; that is the genuine period-hardware ceiling (a ~1-MIPS 286 cannot TCP at 70 Mbit), already
accepted as "optimize, then accept CPU-bound." The instruction-count levers narrowed that gap as far as the
model can measure; the remaining real-hardware lever (checksum-offload) is built and validated but, by the
model's nature, only pays on silicon.
