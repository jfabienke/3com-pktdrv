# 3com-pktdrv — 3Com EtherLink III DOS Packet Driver (clean-room rebuild)

A single, self-specializing DOS packet driver (Crynwr Packet Driver API v1.11, INT 60h)
for the 3Com EtherLink III family — from the original **IBM PC 5150 (8088)** up to
Pentium/PCI machines — built from one source.

This is a clean-room rebuild. The design is documented first (`docs/`), then implemented.
It deliberately carries over only hardware-true facts and proven datapath logic from the
prior codebase; see `docs/07-porting-plan.md`.

## The one-paragraph design

The driver adapts to the machine at load time. A **cold init/composer phase** detects the
CPU, NIC, and environment; validates DMA/bus-mastering by *testing* it (never assuming);
then **JIT-composes** the minimal hot path this machine needs from a library of
position-independent fragments, **copies it down** to a compact resident image, and frees
everything else. The result is small and optimal on every machine — a tiny 8088 PIO path
on a 5150, a 32-bit DMA path on a Pentium — from the same binary.

## Hard floor: it must run on an IBM 5150

8088 instructions only, 8-bit ISA, conventional memory only, 3C509B PIO, tiny resident.
Everything above the 5150 (286 bus-master/XMS, 386+ 32-bit/cache, PCI) is **additive**.
See `docs/01-constraints.md`.

## Build

All-assembly: NASM + Open Watcom `wlink` (no C, no C runtime), driven by `wmake` (`Makefile`).
One binary covers every CPU/NIC tier; the tier is chosen at load time, not build time.

| Target | Builds |
|--------|--------|
| `wmake` / `wmake all` | `build/3cpd.exe` (the driver) + `build/blast.com` (raw-frame TX throughput probe) |
| `wmake fakenic` | test build that skips the NIC probe (`-dCFG_FAKENIC`), for dosbox-x |
| `wmake debug` | instrumented build for hardware testing (`-dCFG_DEBUG`: cold trace, event log, heartbeat, 0x7F debug block) |
| `wmake debugfake` | `debug` + `fakenic` |
| `wmake pnp` | adds the direct ISA PnP probe (3C515 / PnP-mode 3C509B), tried before the ID port on ≥286 (`-dCFG_PNP`) |
| `wmake debugpnp` | `debug` + `pnp` |
| `wmake clean` | remove objects, fragment bins, `frags_asm.inc`, the `.exe`/`.com`/`.map` |

Other variant builds pass NASM defines through `DEFS`, after forcing `start.obj` to rebuild:

```sh
rm build/start.obj && wmake DEFS=-dCFG_FORCE_NC      # force the NC re-test path (structural test; use with /n=254)
rm build/start.obj && wmake DEFS=-dCFG_FORCE_FLUSH   # force the WBINVD flush tier on the DMA paths
```

## Command-line switches

| Switch | Effect |
|--------|--------|
| `/u` | uninstall the resident driver and exit |
| `/b=NNN` | manual I/O base (hex); skips the ID-port probe |
| `/q=NN` | manual IRQ (decimal); use with `/b=`. On an AT, 2 is taken as 9 (the cascade line); on a PC/XT-class board (one 8259) 9 is taken as 2 and 10–15 are refused. Default without `/q=`: 10 |
| `/5` | the card is a 3C515 Corkscrew (EEPROM at +0x2000, Window-1 base +0x10) |
| `/d` | request bus-master DMA (3C515 + ≥286 only; still test-before-trust — falls back to PIO) |
| `/j` | request FDDI-sized large frames (3C515 only) |
| `/8` | force the 8088-class datapath (8-bit PIO), for testing on a faster CPU |
| `/2` | force the 286-class datapath (16-bit PIO + single-transfer DMA); ignored on an 8088/8086-class CPU |
| `/n=<id>` | opt in to a chipset non-cacheable DMA region: 1=OPTi 2=Eteq 3=UMC 4=SiS 254=synthetic test; re-test-gated (`docs/12`, `docs/17`) |
| `/v` | trust the V86 host (EMM386/JEMM386) to emulate `WBINVD`; without it a non-coherent cache under V86 falls back to PIO (`docs/17`) |

## Docs

| Doc | Topic |
|-----|-------|
| `docs/00-overview.md` | Scope, the EtherLink III lineage, what this is |
| `docs/01-constraints.md` | IBM 5150 floor, TSR/Crynwr/8088 rules, size budgets |
| `docs/02-resident-construction.md` | **JIT fragment composition + copy-down** (centerpiece) |
| `docs/03-hal-vtable.md` | `nic_info_t`/`nic_ops_t`, shared EL3 core + generational deltas |
| `docs/04-dma-model.md` | DMA two-axis model, test-before-trust, VDS/bounce/cache tiers |
| `docs/05-memory-buffering.md` | Three-tier memory, adaptive buffering, size-tiered datapath |
| `docs/06-boot-sequence.md` | Phased boot + unwind + config cache |
| `docs/07-porting-plan.md` | What to lift from the old repo, in tiers |
| `docs/08-nvmeotcp-plan.md` | RetroSAN: DOS NVMe/TCP initiator roadmap & status |
| `docs/09-xms-dma-ext.md` | Proprietary INT 60h AH=F0 XMS/conv DMA RX-ring extension (cfg ABI v2) |
| `docs/10-copybreak-pipelines.md` | Copybreak pipelines & the conventional zero-copy DMA ring |
| `docs/11-capability-matrix.md` | NIC generation × capability matrix |
| `docs/12-nc-region-lift.md` | Non-cacheable DMA region (chipset NC) lift + region policy |
| `docs/13-cache-coherency-probe.md` | Cache coherency: measure, don't assume (probe recipe) |
| `docs/14-bus-detection-lift.md` | Bus detection & enumeration |
| `docs/15-isa-bus-ceiling.md` | The ISA bus ceiling (3C515 @ 100 Mbit) |
| `docs/16-l4-rxtx-optimization.md` | L4 raw-TCP RX/TX optimization |
| `docs/17-cache-coherency-impl.md` | Cache coherency implementation (Phase 2) + 2026-09 review fixes |

---

_Last updated: 2026-09-25 09:53 CEST (`/q=` IRQ 2/9 mapping and the PC/XT IRQ 0-7 limit; `/2` ignored below a 286). Prior: 2026-09-22 21:23 CEST (Build section now lists the real `Makefile` targets and `DEFS` variant builds; added the command-line switch list incl. `/v`; docs table extended to 08–17)._
