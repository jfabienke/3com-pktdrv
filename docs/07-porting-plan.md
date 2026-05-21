# 07 — Porting Plan (what to lift from the old repo)

Source repo: `~/Development/3com-packet-driver`. We carry over **hardware-true facts** and
**proven datapath logic**, and leave the accreted abstractions behind. Four tiers.

## Tier A — Lift clean (hardware-true; port near-verbatim)

These are facts about the silicon and the platform; they don't carry the old code's
structural sins.

| From (old) | To (new) | Notes |
|------------|----------|-------|
| `include/3c509b.h`, `3c515.h` (the `#define` blocks) | `include/el3_regs.h` | register/window/EEPROM constants only; drop the structs |
| `src/c/3com_pci_detect.c` (device table) | `src/hw/pci_ids.c` | 47-model PCI database (factual) |
| `src/asm/cpu_detect.asm` + `cpu_detect.h` + `loader/cpu_detect.c` | `src/asm/cpu_detect.asm`, `include/cpu.h` | CPU class/feature detection |
| `src/c/vds.c` + `vds.h` | `src/dma/vds.c`, `include/vds.h` | VDS INT 4Bh primitives (already clean, ~193 lines) |
| `include/dma_boundary.h` (constants/inline checks) | `include/dma.h` | 64 KB / 16 MB / 24-bit checks |
| `include/api.h` (function numbers) | `include/pktdrv.h` | Crynwr API constants |
| `include/media_types.h` | `include/media.h` | media-type enums |
| `src/c/pci_bios.c` + `src/asm/pci_io.asm` | `src/hw/pci_bios.c`, `src/asm/pci_io.asm` | PCI BIOS INT 1Ah |
| ISR/PIC/EOI mechanism from `nic_irq_smc.asm`, `tsr_common.asm`, `quiesce.asm` | `src/asm/`, `src/codegen/` | the IRQ entry/EOI discipline; becomes fragment material |

## Tier B — Lift with cleanup (load-bearing; reconcile to canonical types)

Good logic, tangled types/contexts. Port the algorithm; bind to `nic_info_t`/`HW_CAP_*`
and the single `dma_policy`/`cache_tier`.

| From (old) | To (new) | Notes |
|------------|----------|-------|
| `direct_pio.asm` + 3C509B PIO send/recv | `src/codegen/frag_pio_*`, `src/hw/el3_core.c` | the PIO datapath → floor fragments |
| descriptor-ring code (DOWN/UP_LIST_PTR) extracted from `3c515.c` | `src/codegen/frag_ring_*`, `src/hw/el3_isa.c` | the *genuine* ring path — NOT the "enhanced ring manager" |
| `busmaster_test.c` + `dma_capability_test.c` | `src/dma/busmaster_test.c` | test-before-trust core |
| `cache_coherency.c` (tier system) + `cache_management.c` | `src/dma/cache.c` | ONE cache model |
| `dma_policy.c` | `src/dma/dma_policy.c` | DIRECT/COMMONBUF/FORBID |
| `eeprom.c` | `src/hw/el3_eeprom.c` | EEPROM word layout/read |
| `xms_detect.c` | `src/mem/xms.c` | XMS tier |
| platform/V86/VDS env detection | `src/init/platform.c` | environment (axis 2) |
| `buffer_autoconfig.c` + copybreak (`rx_batch_refill`, `copy_break.h`) | `src/mem/buffers.c` | adaptive geometry + copybreak |
| `smc_patches.c` + `patch_apply.c` + `*_smc.asm` patch points | `src/codegen/` | becomes the emitter + fragment palette |

## Tier C — Rewrite around the canonical model (concept core, code tangled)

Don't port; re-implement against the docs. The concepts are right; the old
implementations carry the duplicate-type and dead-code disease.

| Concept | New home |
|---------|----------|
| vtable HAL (`nic_info_t`/`nic_ops_t`/`HW_CAP_*`) | `include/hardware.h`, `src/core/hal.c` |
| shared EL3 core + family deltas | `src/hw/el3_core.c`, `el3_isa.c`, `el3_pci.c` |
| unified packet ops (TX/RX dispatch) | `src/core/packet.c` (+ emitted hot path) |
| Crynwr API dispatch | `src/core/api.c` |
| phased boot + unwind + config cache | `src/init/boot.c`, `unwind.c`, `config.c`, `main.c` |
| three-tier memory | `src/mem/memory.c` |
| the JIT composer + copy-down | `src/codegen/compose.c`, `relocate.c` |

## Tier D — Drop

Orphaned, aspirational, or duplicate. Do not carry forward.

- "enhanced ring manager" (`enhanced_ring_context.h`) — collapse into the real ring path
- `chipset_database.h` (community CSV/JSON export), `smc_safety_patches.h` (missing),
  `dma_operation_t` (undefined)
- the duplicate `cache_coherency_enhanced.h`; the 4× `nic_context_t`; `nic_capabilities.h`
  parallel context; `hardware_stubs.c` (fold in)
- all `*.bak`, `docs/archive/orphaned-src`, dead/duplicate function bodies

### Assess (decide per feature, not auto-drop)

- `pci_shim` / `pci_multiplex` / `pci_shim_enhanced` — INT 1Ah BIOS shim/multiplex.
  **Default: out of scope** for the initial skeleton; stub the INT 1Ah path and lift
  later only if PCI BIOS shimming is wanted.

## Bus probers (all buses fully supported — scope decision)

Each bus gets a cold prober that enumerates EL3 cards and fills `nic_info_t`/caps, then
hands off to the shared HAL + emitted datapath (docs/03). All are `full`-profile (above
the 5150 floor).

| Bus | New home | Lift source / effort |
|-----|----------|----------------------|
| ISA8/16 | `src/hw/bus_isa.c` | old 3c509b/3c515 detect + PnP isolation (Tier B) |
| EISA (3C597-TX) | `src/hw/bus_eisa.c` | old `3com_eisa.c` + `nic_irq_eisa.asm` (Tier B) — slot scan, EISA ID `0xzC80` |
| MCA (3C529) | `src/hw/bus_mca.c` | **near clean-room** (old repo only stubbed it) — POS registers, adapter-ID scan |
| PCMCIA-16 (3C589) | `src/hw/bus_pcmcia.c` | old `pcmcia_manager/cis/ss_backend/pe_backend` + `pcmcia_isr.asm` (Tier B, large) |
| PCI / CardBus | `src/hw/bus_pci.c` | old `pci_bios.c` + `pci_integration.c` + `3com_pci_detect.c` (Tier A/B); CardBus = PCI class scan |

## Order of work

1. Tier A facts + canonical headers (`include/`) — gives the vocabulary.  ✅ (registers, cpu)
2. Tier C skeleton: HAL, boot phases, composer/copy-down stubs.  ✅ (links to .EXE)
3. Tier B PIO floor: 8088 PIO fragments → a 5150 build that links, installs, and echoes.
4. copy-down + TSR install (runnable under an emulator).
5. Climb the ladder: 286 ISA ring DMA + busmaster test, 386+ cache tiers.
6. Bus probers (full profile): PCI/CardBus core, then EISA, PCMCIA-16, MCA.
