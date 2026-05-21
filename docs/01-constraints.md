# 01 — Constraints (the IBM 5150 floor)

The driver is bounded at the bottom by the original IBM PC and at the top by Pentium/PCI.
The floor is the hard one: if it doesn't fit and run on a 5150, the design has failed.

## The hard floor: IBM PC 5150

| Aspect | 5150 reality | Consequence for the driver |
|--------|--------------|----------------------------|
| CPU | Intel **8088 @ 4.77 MHz** | 8088 instruction subset only (see below) |
| Bus | **8-bit ISA** (XT bus) | No 16-bit cards bus-mastering; 3C509B in 8-bit slot, PIO |
| Memory | **Conventional only**, ~256 KB typical (640 KB max) | No XMS; conventional-only path must fully work |
| DMA | No viable NIC bus-mastering | DMA capability axis collapses to PIO |
| Buses absent | No PCI, no PCMCIA, no EISA | ISA-only detection on this class |

### 8088 instruction subset (mandatory for ALL code)

Composer, init, and every emitted fragment must execute on an 8088. **Forbidden** below
the 286/386 fragments (which are *additive*, emitted only when the CPU supports them):

- No `PUSHA`/`POPA`, no `PUSH imm`, no `ENTER`/`LEAVE`
- No `INS`/`OUTS` string I/O (186+)
- No `IMUL r, imm`, no shift/rotate by immediate > 1 (use `CL`)
- No 32-bit registers, no `0x66`/`0x67` prefixes
- `MUL`/`DIV` are slow — avoid in hot paths

### Memory reality on a 5150

- **Conventional only.** XMS implies ≥286 and >1 MB addressing — absent. EMS via a
  hardware board is the *only* possible "extra" memory and is optional.
- The entire `.EXE` loads into conventional RAM at init. On a 256 KB box minus DOS
  (~30–60 KB) you have ~180 KB to load **and** run the composer. The image must be small.

## The capability ladder (everything above the floor is additive)

```
8088/5150  : 3C509B PIO, conventional mem, tiny resident         <-- FLOOR (always works)
80286      : + ISA bus-master DMA (tested), + XMS buffers
80386+     : + 32-bit datapath fragments, + cache-coherency tiers, + SMC-class emits
80486/Pent : + WBINVD/CLFLUSH cache mgmt, deeper batches
PCI present: + Vortex/Boomerang/Cyclone/Tornado generations
```

The JIT composer emits only the rungs the detected machine actually has. On a 5150 it
emits the floor and nothing else.

## TSR / Crynwr / real-mode rules

- **Crynwr semantics:** INT 60h, `AH`=function, `BX`=handle, `DS:SI`/`ES:DI`=params,
  `AX`=result, **CF set on error / clear on success**; `"PKT DRVR"` signature at vector+3.
- **Vector hygiene:** install/uninstall via INT 21h AH=35h/25h, interrupts masked around
  get/set, restore `ES:BX` exactly.
- **PIC/EOI:** save and restore both PIC masks (0x21, 0xA1); correct EOI ordering for
  master/slave; honor IRQ2↔9 aliasing. **No DOS/BIOS calls from the ISR.**
- **ELCR:** do not touch by default; never reprogram system IRQs (0,1,2,8).
- **Bounded ISR:** fixed work per interrupt; defer the rest to a bottom half.

## Size & residency budgets (design targets)

| Budget | Target | Rationale |
|--------|--------|-----------|
| Resident (emitted hot image) | **single-digit KB** | leave RAM for the app on a 5150 |
| Minimal-profile load footprint | **≤ ~64 KB** | must load on a modest 5150 + DOS |
| Full-profile load footprint | **≤ ~128 KB** | comfortable on a 256 KB+ machine |
| Instruction floor | **8088** for all non-additive code | runs on 5150 |
| Memory floor | **conventional-only path complete** | no XMS dependency |

Budgets are enforced by parsing the linker map for the resident classes and by the
build profile that excludes higher-tier cold code.

## Build profiles (one source, two images)

- **`minimal`** — `-DCFG_FLOOR`: 3C509B PIO, conventional memory, 8088 baseline only.
  PCI/DMA/XMS/cache cold code compiled out. Smallest possible image for bare 5150s.
- **`full`** — all generations, buses, and memory tiers. Targets 256 KB+ machines.

Both build from identical source; the difference is conditional compilation of cold
support, never of the floor datapath.
