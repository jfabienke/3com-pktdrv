# 05 — Memory & Buffering

Three decisions, all set up cold and executed hot: which memory tiers exist, how big the
buffers are, and which pipe each packet takes.

## Three-tier memory (graceful degradation to the 5150 floor)

```
Priority 1  XMS (>1 MB)        large pools, DMA staging      286+ only — ABSENT on 5150
Priority 2  UMB (640 KB–1 MB)  extra pools                   needs UMB provider — rare on XT
Priority 3  Conventional       always available              the floor; 5150 lives here
```

On a 5150 only conventional memory exists, so the conventional path must be complete and
self-sufficient. XMS/UMB are *additive* tiers that, when present, move bulk buffering out
of precious conventional space.

### Why XMS is for large/staging only, never the small-packet hot path

- XMS is not directly DMA-able — it needs locking/translation (VDS under a VMM) to yield a
  physical address, and copy-through for ISA DMA.
- Touching XMS is slower than conventional memory.

So: **conventional/UMB** backs the latency-sensitive small/PIO buffers and DMA-safe
regions; **XMS** backs the large pools and DMA staging — which is the same machinery as
COMMONBUF/bounce under a VMM or past the ISA 16 MB line (`04-dma-model.md`).

## Adaptive buffer geometry (init-time, per CPU × bus × memory)

Buffer sizes, pool counts, ring depth, and batch limits are chosen at init to match the
machine, then frozen (and baked into the emitted hot path as immediates):

| Machine | Rings / batches | Pools |
|---------|-----------------|-------|
| 8088/5150 | shallow, batch 1–4 | minimal conventional pool |
| 286 | deeper, batch 8 | + XMS large pool if present |
| 386/486 | deeper, batch 16–24 | XMS pools |
| Pentium | max, batch 32 | XMS pools |

Batch limits map directly to the README's CPU-scaled SMC values; here they are *emitted*
immediates rather than patched ones.

## Size-tiered datapath (per-packet, hot)

DMA has a large fixed cost per transfer — descriptor setup plus, on non-snooping 386/486,
a cache flush (WBINVD ~250 µs on a 486). So:

```
            packet size
                 │
        ┌────────┴─────────┐
   small ≤ T              large > T
   PIO FIFO path          bus-master / ring DMA
   (low latency,          (amortizes fixed cost,
    no flush)              offloads CPU)
   ACKs, telnet, games    file transfer, bulk
```

- The threshold **T is itself CPU/bus-tuned** (break-even shifts: 486 WBINVD ~250 µs vs
  Pentium ~40 µs; ISA vs PCI bandwidth) and is an emitted immediate.
- **RX copybreak:** small received packets are copied out of the DMA buffer into a small
  conventional buffer and the DMA buffer is recycled straight back to the ring; large
  packets are handed up and a replacement buffer is allocated. Keeps the ring full and
  spends large buffers only on large packets.
- On a 5150 there is no DMA, so every packet takes the PIO path; copybreak/threshold logic
  is simply not emitted.

## DMA-safe buffers: NC region vs per-transfer flush

On a non-snooping 386/486, a bus-master/ring-DMA buffer in normal cacheable memory needs a
cache flush around every transfer (`04-dma-model.md`, tier 2 WBINVD ~250 µs). Some chipsets
offer a cheaper path: **mark the DMA buffer region non-cacheable (NC) once at init**, and
no per-transfer flush is needed at all.

- The capability and encoding are chipset-specific (cache-kit's `nc_region_t` /
  `nc_read/write/clear`, with per-chipset granularity and max size — OPTi 64 KB-unit base +
  size nibble, SiS 16-bit packed, Intel/VIA PAM registers). We lift the *model and
  primitives* (`docs/07` Tier A′), not cache-kit's 62-chipset table.
- **Decision (cold, per machine):** if the detected chipset exposes an NC region big enough
  for the DMA pool → allocate the pool there, mark it NC, and the composer emits the DMA
  datapath **without** the cache-flush fragment. Otherwise fall back to the per-transfer
  flush tier.
- This only matters in the bus-master/ring-DMA datapath on a non-snooping cache; it is
  irrelevant to the PIO floor (5150) and to snooping CPUs, where no flush is emitted anyway.

## Resident vs reclaimed

- **Resident:** the handle/NIC state, ring descriptors, and the small conventional buffer
  set live below the copy-down keep boundary (`02-resident-construction.md`).
- **Reclaimed:** buffer auto-sizing logic, XMS negotiation, and pool setup are cold — they
  run once and are discarded; only the resulting pools and the emitted accessors remain.
