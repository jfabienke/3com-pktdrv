# 02 — Resident Construction: JIT Composition + Copy-Down

This is the heart of the design. The resident driver is not statically linked code that
runs as-is; it is **composed at load time** for the specific machine, then **copied down**
into a compact resident image while everything else is reclaimed.

## Why compose instead of branch

The driver must span 8088→Pentium and PIO→bus-master DMA. The two conventional options
both fail our budgets:

- **Ship every variant + branch at runtime** → fat resident, runtime CPU/cap tests in the
  hot path, won't fit a 5150.
- **Patch a fixed image (classic SMC)** → better, but still ships a worst-case image and
  only tweaks bytes.

So we go one step further than SMC: the cold phase **composes** the hot path from
fragments, emitting *only* what this machine needs, with decisions baked in as immediates.
No CPU/capability branches survive in the resident — they were resolved at emit time.

> SMC patches a fixed image; the composer *builds* the image. The prior codebase's
> `*_smc.asm` patch points (e.g. `mov cx, imm16 ; nop ; nop` sleds, CPU-scaled batch
> limits) are exactly the fragment palette this model draws from.

## The pipeline (all of this is COLD and discarded afterward)

```
  detect            test              compose            relocate          install
 ┌────────┐      ┌─────────┐       ┌──────────┐       ┌──────────┐      ┌─────────┐
 │ CPU /  │      │ DMA /   │       │ select + │       │ copy-down│      │ hook    │
 │ NIC /  │ ───▶ │ busmast │ ────▶ │ stitch + │ ────▶ │ + fixups │ ───▶ │ INT 60h │
 │ env    │      │ + cache │       │ patch    │       │          │      │ + IRQ   │
 └────────┘      └─────────┘       └──────────┘       └──────────┘      └─────────┘
                                        │                   │                │
                                    fragment            packed           TSR-keep
                                    library            resident          minimal
                                    (cold)              image            paragraphs
```

1. **Detect** — CPU class (8088→Pentium), NIC type/generation, environment (V86/VMM,
   VDS, memory tiers). See `04-dma-model.md`, `06-boot-sequence.md`.
2. **Test** — validate bus-mastering by actually exercising it (confidence score) and
   select a cache-coherency tier. On a 5150 this is skipped (PIO floor).
3. **Compose** — pick the fragment set for {CPU class × datapath × NIC × environment},
   concatenate into a work buffer, and patch immediates (I/O base, copybreak threshold,
   batch limits, ring addresses, window-switch presence/absence).
4. **Copy-down** — relocate the composed image to its compact resident home (low, packed),
   apply relocation fixups, then DOS-keep only those paragraphs.
5. **Install** — point INT 60h and the NIC IRQ vector at the emitted entry points.

## Fragments

A fragment is a small, **position-independent** hot-path building block, hand-written and
hand-verified, with declared inputs/outputs and patch slots.

```
fragment record (cold, in the library):
  id            which logical step (e.g. FRAG_RX_PIO_COPY)
  cpu_min       minimum CPU class this fragment targets (8088, 286, 386, ...)
  bytes[]       the position-independent machine code
  len
  patch[]       list of { offset, kind } immediate slots to fill at compose time
  reloc[]       list of intra-image references needing fixup after copy-down
```

Rules:
- Every logical hot-path step has an **8088 baseline fragment** (the floor). Higher-CPU
  fragments for the same step are *additive* and chosen only when `cpu_min` is satisfied.
- Fragments are PIC: no absolute self-references except via the `reloc[]` table.
- Patch kinds are immediates only (imm8/imm16, seg, offset) — no structural rewriting.

The composer is the only thing that understands fragment *selection*; the fragments
themselves are dumb byte blocks. Selection logic lives in the HAL (`03-hal-vtable.md`) —
the vtable's job at cold time is "given my capabilities, name the fragments to emit."

## Copy-down (residency)

The `.EXE` loads wherever DOS puts it; the composer builds the hot image in a work buffer.
Copy-down then **packs** that image to the front of the kept region (right after the
resident data) and TSRs with the minimal paragraph count, so the composer, fragment
library, detection, and test code are all reclaimed.

- Chosen over shrink-in-place because packing to the front yields the tightest resident
  (no holes left by interspersed cold code).
- The relocator walks each fragment's `reloc[]` to fix intra-image references to the final
  load address.
- Resident data (counters, NIC state, ring descriptors, buffers) is laid out first; the
  emitted code follows; the keep boundary is the end of the emitted code.

## Resident memory map (after copy-down)

```
PSP
├── resident data        (NIC state, handle table, ring descriptors, small buffers)
├── emitted hot code      (ISR, datapath, INT 60h dispatch — JIT-composed)
└── [keep boundary]  ◄──── DOS reclaims everything above here
    (composer, fragments, detection, test, init — gone)
```

## The composer must itself run on a 5150

Composition is `mov` / `movsb` / immediate-store in loops — trivially 8088-clean and
compact. The composer carries no 186+ conveniences. This keeps the *whole* executable,
not just the resident, within the 5150 floor.

## Debuggability (designed in, not bolted on)

You cannot single-step source for code that didn't exist at build time, so:

- **Fragment unit tests** — each fragment is testable in isolation against a known
  input/output contract on its target CPU class.
- **Emit dump** — a build/debug switch dumps the composed image (hex + length + chosen
  fragment ids + applied patches) before copy-down, so the emitted hot path can be
  disassembled and diffed.
- **Deterministic selection** — given the same detected capabilities, composition is
  reproducible; capability inputs are logged in debug builds.

## Caching (optional, additive)

Detection/test *results* (CPU, chipset, busmaster confidence, cache tier) may be cached to
a per-machine file to skip re-probing on later loads — but the **environment is always
re-detected** (V86/VDS/memory managers can change between boots on the same hardware) and
the policy recomputed. Emission itself is cheap, so the image is re-composed every load.
See `04-dma-model.md` for the cache-safety rule.
