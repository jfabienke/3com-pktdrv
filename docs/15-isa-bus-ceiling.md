# 15 — The ISA bus ceiling (3C515 @ 100 Mbit)

The 3C515 "Corkscrew" is a **100 Mbit Fast Ethernet card on a 16-bit ISA bus**. The bus, not the wire,
is the throughput ceiling at 100 Mbit on any CPU fast enough to reach it — and the realtiming emulator
model now reflects that for **both** the bus-master DMA path and the PIO path. This note records the
fidelity fix, the measured ceilings, an ISA-frequency sweep, and the datapath-faithfulness flags that
matter when measuring slow CPUs on a fast emulator core.

> Measured under QEMU's el3 realtiming model (`elink-qemu`), `-icount shift=N,sleep=off`. CPU speed is
> modeled by the shift (8088≈11, 286=10, 386=7, 486=5, Pentium=3); the NIC's TX rate is modeled by
> `linkspeed` (wire) and `dma_rate` (ISA bus). These are *modeled* numbers, but they track real-3C515
> behavior and Brutman's mTCP measurements to within the right order of magnitude.

## The fidelity gap: PIO wasn't bus-capped

The realtiming model already capped **bus-master DMA** at `dma_rate_bps` (default 6 MiB/s ≈ 48–50 Mbit,
the 0-wait-state 16-bit ISA rate): `el3_core_dma_tx_single` paces each frame's TxComplete at
`max(bus_ns, wire_ns)` per byte. But **PIO TX was only wire-paced**: `el3_tx_drain_advance` drained the
TX FIFO at `tx_ns_per_byte` (the link rate) and was otherwise gated only by `-icount`. Since icount
counts each `out` as one instruction (`2^shift` ns), at a low shift (fast CPU) a port write costs ~8 ns
instead of a realistic ~500 ns ISA I/O cycle — roughly **60× too fast**. So 486/Pentium PIO @100M ran
all the way to the 100 Mbit wire, which a 16-bit ISA card physically cannot do. This is a known limit
of the model (see `include/hw/net/el3_core.h`: *"QEMU has no per-access bus-latency API"*; shift=10 ≈
286 happens to make ISA I/O realistic, which is why it was the documented "sweet spot").

### The fix

`el3_tx_drain_advance` (in `el3_core.c`) now paces the PIO FIFO drain at the **slower** of the wire and
the ISA I/O rate:

```c
per_byte = c->tx_ns_per_byte;                       /* wire */
if (c->dma_rate_bps) {
    int64_t isa_pio_ns = 1000000000LL / c->dma_rate_bps;   /* ISA I/O */
    if (isa_pio_ns > per_byte) per_byte = isa_pio_ns;       /* min(wire, ISA) rate */
}
```

So PIO is capped at `min(wire, ISA-bus)`:

- **@10 Mbit**: `max(800 ns, ~167 ns)` = 800 ns → wire-paced (unchanged; the 10 Mbit wire is slower
  than the ISA bus, so it dominates).
- **@100 Mbit**: `max(80 ns, ~167 ns)` = 167 ns → **ISA-paced ≈ 48 Mbit**.

DMA TX is untouched — it uses its own `tx_drain_deadline` (`dma_rate`) pacing, not this FIFO path.

## Measured ceilings (with the cap)

### L4 raw-TCP TX (payload Mbit/s)

| CPU @100M | PIO before fix | PIO after fix | async DMA |
|---|---|---|---|
| 486     | 90.9 | **48.65** | 48.41 |
| Pentium | 96.1 | **48.65** | 48.73 |

10 Mbit cells (9.62, wire-capped) and the CPU-bound 386 (22.8) are unchanged — they sit below the ISA
ceiling, so the cap doesn't bind.

### L2 raw-driver TX (`blast.com`, kbit/s)

| CPU | pio-10 | dma-10 | **pio-100** | dma-100 |
|---|---|---|---|---|
| 486     | 9899 | 9932 | **50,093** | 49,860 |
| Pentium | 9895 | 9940 | **50,069** | 50,187 |

`pio-100` was inflated toward 100,000 before the fix; now PIO and DMA both land on the ISA ceiling.

A useful cross-check: the cap reads **~50 Mbit in L2 vs ~48.5 in L4** — exactly right, because L2 counts
*frame* throughput (`dma_rate` = 6 MiB/s = 50.3 Mbit) while L4 counts *TCP payload*
(50.3 × 1460/1514 = 48.5 Mbit). Same ceiling, frame-vs-payload.

## ISA frequency sweep

If the bus is the ceiling, throughput should scale with the ISA clock. We sweep `dma_rate` =
`MHz × 786432` B/s (0.75 MiB/s per MHz, anchored to the 6 MiB/s @ 8 MHz default), L4 async @100 Mbit:

| CPU \ ISA | 6 MHz | 8 MHz | 10 MHz | 12 MHz | 16 MHz | 20 MHz | bottleneck |
|---|---|---|---|---|---|---|---|
| **286**     | 3.14  | 3.14  | 3.14  | 3.14  | 3.14  | 3.14  | CPU (checksum) — flat |
| **386**     | 32.59 | 32.59 | 32.59 | 32.59 | 32.59 | 32.59 | CPU (checksum) — flat |
| **486**     | 36.33 | 48.41 | 60.09 | 72.51 | 94.78 | 94.79 | ISA bus → CPU ~95 |
| **Pentium** | 36.51 | 48.73 | 60.59 | 73.24 | 96.02 | 96.02 | ISA bus → wire ~96 |
| *(bus B/W)* | *36*  | *48*  | *60*  | *72*  | *96*  | *120* | |

- **486/Pentium track the ISA bandwidth almost 1:1** (36/48/60/72) — the bus is the bottleneck — then
  cross over to their own CPU ceiling (486 ≈ 95 Mbit, ~13 MHz crossover) or the 100 Mbit wire
  (Pentium ≈ 96 Mbit, ~16 MHz crossover; at 20 MHz the 120 Mbit bus exceeds the wire, so the wire caps).
- **286/386 are flat** — their CPUs cannot saturate even a 6 MHz bus, so ISA speed is irrelevant to them.

**Takeaway:** at the standard 8 MHz ISA, the 3C515's 100 Mbit ceiling is **~48 Mbit (payload) for any
CPU fast enough to reach it**. Approaching the 100 Mbit wire needs a ~14+ MHz (overclocked) ISA bus
*and* a Pentium. The "Corkscrew" really was a Fast Ethernet card shackled to a slow bus.

## PIO vs DMA, and the async ring

With PIO now correctly ISA-capped, **PIO no longer "beats" DMA on fast CPUs** — both top out at the
ISA bus. The zero-copy **async TX ring** (the `AH=0xF1` ABI, doc `09`-adjacent / `include/async_tx.inc`)
is therefore the universal best TX path:

- **286 / 386** (CPU-bound, below the bus): async pipelines the next frame's checksum with the current
  frame's DMA → **+43% (386: 22.7→32.6)** and **+43% (286: 2.19→3.14)** over PIO.
- **486 / Pentium** (bus-bound): async *ties* PIO at the ~48 Mbit ceiling while freeing the CPU from the
  per-byte PIO grind for the rest of the stack.

## Datapath faithfulness on a fast emulator core (`/2`, `/8`)

The emulator always presents a 486+ core (only `-icount shift` models the slower CPU's *speed*), so the
driver's CPU auto-detect picks the **386+ datapaths** even for a "286" or "8088" cell. Force the right
generation with the driver flags:

- **`/2`** — force the 286-class datapath: 16-bit `rep outsw` PIO + single-transfer (blocking, zero-copy)
  bus-master DMA (`g_cpu_class = CPU_80286`, so `g_tx_ring = 0`). Reports `CPU class=1`.
- **`/8`** — force the 8088-class datapath: 8-bit byte-loop PIO. Reports `CPU class=0`.

This matters most where the **datapath is the whole cost** (L2, no checksum):

| 286 L2 @100M | 486-core (no `/2`) | faithful (`/2`) |
|---|---|---|
| pio-100 | 24,314 (386 `rep outsd`) | **13,365** (16-bit `rep outsw`) |
| dma-100 | 19,354 (copy-ring) | **27,931** (single-transfer) |
| verdict | PIO > DMA ✗ | **DMA ≫ PIO (+109%)** ✓ |

Without `/2` the 486 core ran a *faster-than-286* PIO path **and** a copy-ring DMA the 286 never uses —
wrong in both directions, making PIO look like the winner. Forced faithful, single-transfer DMA wins by
2× (and matches the driver's own cited 28,668), because on a 286 PIO makes the slow CPU issue 757
`outsw` per 1514 B frame while DMA hands the NIC a descriptor. (At 10 Mbit it reverses — PIO keeps up
with the slow wire while blocking single-transfer DMA can't overlap.)

L4 is **checksum-dominated**, so `/2` barely moves it (286 L4 PIO 2.35→2.19 with `CKSUM=16` already
forcing the faithful 16-bit checksum); async is unchanged at 3.14 because `dma_tx_async` is 8086-clean.

> Harnesses (`elink-qemu/tests`): `l4-tx-test.sh` and `l2-baseline.sh` take a `MANUAL` env — pass
> `"/b=300 /q=10 /2"` for a faithful 286. `l4-tx-test.sh` takes a `DMARATE` env (→ the `dma_rate` prop);
> `l4-isa-sweep.sh` drives the frequency sweep above.

## Implications for the capability matrix (doc `11`)

The "% of wire" gate is only meaningful where the wire is the actual limit:

- **10 Mbit**: the wire (1.25 MB/s) is below the ISA bus, so the wire is the real ceiling — the gate
  applies. Fast CPUs hit ~96%.
- **100 Mbit**: the **ISA bus (~48 Mbit payload) is the ceiling**, not the wire. "70% of 100 Mbit" is
  physically unreachable on this card at the standard ISA clock, regardless of CPU or PIO/DMA. The
  honest 100 Mbit gate is `min(ISA-bus, CPU, wire)` ≈ **48 Mbit** at 8 MHz ISA.
- Slow CPUs (8088/286/386) are **CPU-bound** below the bus on both rungs — their ceiling is the CPU
  (checksum at L4, per-byte PIO/DMA setup at L2), and the biggest lever there is the asm checksum
  (doc-adjacent `dos-nvmeotcp/src/cksum.asm`) plus the zero-copy async ring.

---

_Last updated: 2026-06-17 11:27 CEST._
