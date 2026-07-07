# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## Project Overview

A clean-room DOS packet driver (Crynwr Packet Driver API v1.11, INT 60h) for the 3Com
EtherLink III family (3C509B ISA, 3C515 ISA PnP/PCI). Written entirely in NASM assembly.
Targets every generation from the IBM PC 5150 (8088) through Pentium/PCI — from one binary
via JIT fragment composition at load time.

**Hard floor: IBM 5150 — 8088 only, 8-bit ISA, conventional memory, 3C509B PIO.**
All improvements (286 bus-master, 386+ 32-bit, XMS, PCI) are strictly additive.

## Build System

Requires: **NASM** (assembler), **Open Watcom** `wmake` + `wlink` (make/linker), **Python 3**.

```bash
wmake              # default build → build/3cpd.exe (8088/5150 floor)
wmake fakenic      # test build for DOSBox-X (skips NIC probe, uses fake NIC)
wmake debug        # instrumented build for hardware testing
wmake debugfake    # debug + fake NIC (DOSBox-X)
wmake pnp          # full profile with ISA PnP probe (3C515 Corkscrew)
wmake debugpnp     # pnp + debug instrumentation
wmake clean
```

The hot-path fragment palette (`src/asm/frag/*.asm`) is assembled to raw position-independent
bins by `tools/mkfrag.py` and embedded as data (`build/frags_asm.inc`) — **not linked**.

## Source Layout

```
src/asm/
  start.asm          Entry point; top-level cold init + install flow
  el3_probe.asm      NIC detection (ID-port, PnP, EISA)
  el3_init.asm       Hardware init sequence, window setup
  resident.asm       TSR resident data segment template
  isr.asm            Interrupt service scaffolding
  install.asm        TSR install: JIT compose, copy-down, hook INT
  isapnp.asm         ISA Plug and Play enumeration (3C515 / PnP 3C509B)

src/asm/frag/        Hot-path fragments (assembled to raw bins, embedded as data)
  api.asm            Packet Driver API dispatcher
  isr_entry.asm      ISR entry stub
  isr_eoi.asm        EOI + chain
  rx_pio.asm         8088 PIO receive
  rx_pio_286.asm     286 16-bit PIO receive
  rx_pio_386.asm     386+ 32-bit rep-insd PIO receive
  tx_pio.asm         8088 PIO transmit
  tx_pio_286.asm     286 PIO transmit
  tx_pio_386.asm     386+ PIO transmit

include/
  codegen.inc        NASM codegen constants (fragment offsets, vtable layout)
  el3_core.inc       EL3 register window constants (shared across NIC generations)
  el3_tomahawk.inc   3C509B-specific registers/constants
  el3_corkscrew.inc  3C515-specific registers/constants
  codegen.h / cpu.h / dma.h / hardware.h / etc.   C-header mirrors (reference only)

tools/
  mkfrag.py          Assembles frag/*.asm → raw bins → builds/frags_asm.inc
  blast.asm          Raw TX throughput probe (.COM, assembled with -f bin)

docs/
  00-overview.md     Scope, EtherLink III lineage
  01-constraints.md  IBM 5150 floor, TSR/Crynwr/8088 rules, size budgets
  02-resident-construction.md  JIT fragment composition + copy-down
  03-hal-vtable.md   nic_info_t / nic_ops_t, shared EL3 core + generational deltas
  04-dma-model.md    DMA two-axis model, test-before-trust, VDS/bounce/cache tiers
  05-memory-buffering.md  Three-tier memory, adaptive buffering
  06-boot-sequence.md     Phased boot + unwind + config cache
  07-porting-plan.md      What to lift from the old repo, in tiers
```

## Architecture

The driver has two phases:

**Cold phase (non-resident):** CPU detect → NIC probe → hardware init → DMA/bus-master
test-before-trust → JIT-compose the minimal hot-path from the fragment palette → copy-down
the resident image → hook INT 60h → free cold code.

**Hot phase (resident TSR):** The copied-down fragment sequence handles INT 60h (Packet
Driver API) and the NIC IRQ. No cold code remains in memory.

### Key design constraints
- `cpu 8086` everywhere in assembled sources; no 286+ instructions in the floor path
- No C runtime, no C code in the main driver (NASM + wlink only)
- All fragment bins are position-independent (no fixups)
- DMA is always tested, never assumed; falls back to PIO if DMA setup fails
- Size budget: resident image ≤ ~2 KB on the 5150 floor path

## Testing

No automated test suite. Test approaches:
- `wmake fakenic` → load in **DOSBox-X** (exercises install/resident without real hardware)
- `wmake debug` / `wmake debugfake` → instrumented build with event log + video heartbeat
- Hardware testing on period machines with real 3C509B/3C515 NICs
- `tools/blast.com` for TX throughput profiling

DOSBox-X is the primary emulator for development testing.
