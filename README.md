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
| `wmake` / `wmake all` | `build/3cpd.exe` (the driver) + `build/blast.com` (raw-frame TX throughput probe) + `build/sendlen.com` (send-length guard probe) |
| `wmake fakenic` | test build that skips the NIC probe (`-dCFG_FAKENIC`), for dosbox-x |
| `wmake debug` | instrumented build for hardware testing (`-dCFG_DEBUG`: cold trace, event log, heartbeat, 0x7F debug block) |
| `wmake debugfake` | `debug` + `fakenic` |
| `wmake pnp` | adds the direct ISA PnP probe (3C515 / PnP-mode 3C509B), tried before the legacy probes on ≥286 (`-dCFG_PNP`); CI publishes it as `3cpdpnp.exe` |
| `wmake debugpnp` | `debug` + `pnp` |
| `wmake clean` | remove objects, fragment bins, `frags_asm.inc`, the `.exe`/`.com`/`.map` |

Other variant builds pass NASM defines through `DEFS`, after forcing `start.obj` to rebuild:

```sh
rm build/start.obj && wmake DEFS=-dCFG_FORCE_NC      # force the NC re-test path (structural test; use with /n=254)
rm build/start.obj && wmake DEFS=-dCFG_FORCE_FLUSH   # force the WBINVD flush tier on the DMA paths
```

### Prebuilt binaries

GitHub Actions (`.github/workflows/build.yml`) builds `3cpd.exe`, `3cpdpnp.exe` (the `pnp` profile),
`blast.com` and `sendlen.com` with NASM and Open Watcom on every push and pull request; download them from
the run's **3cpd-binaries** artifact. Pushing a `v*` tag also attaches them to that GitHub release.

### Finding the card

- **3C509/3C509B:** found through the 3Com ID port (I/O base and IRQ from its EEPROM).
- **3C515:** it doesn't answer the ID port. Without `/b=` the driver scans I/O bases 0x100-0x3E0 for a
  3C515 at the base its EEPROM configures and takes the IRQ from the card (`/5` alone: scan for a 3C515
  only). This finds a card whose Plug and Play mode is **off**.
- **3C515 in Plug and Play mode** on a machine without a PnP BIOS (e.g. an IBM PC/AT) is inactive until
  isolated: use `3cpdpnp.exe`, which runs ISA PnP isolation first (the Linux/ISA PnP-spec sequence and
  delays, read ports 0x213-0x3FB) and prints each card it isolates (`PnP card TCM5051 CSN=1 read port
  0x....`). It only places the card on a free I/O base, verified with the card's own ISA PnP I/O range
  check (0x2A0, 0x2C0, 0x340, 0x280, 0x380, then 0x300/0x320; busy ones are listed), IRQ 10 and DMA 5 --
  or exactly `/b=` and `/q=` when given (refused if that base is busy). The range check only catches a
  device that out-drives the 3C515 on the bus (on a real AT an XT-IDE at 0x300 passed it), so the usual
  XT-IDE/NE2000/MPU-401 bases come last; give `/b=` when you know a free base.
- **One copy at a time:** the driver refuses to load when a packet driver already answers INT 60h
  (`3cpd /u` first). Or configure it with isapnptools
  (`pnpdump`/`isapnp`, the CI's **isapnptools-dos** artifact, real-mode DOS build in
  `tools/isapnptools-dos`) and load `3cpd /b=300 /q=10 /5`, or disable PnP with 3Com's utility.
- **Bus mastering (`/d`, 3C515):** the card's ISA DMA channel (from the card) is put in cascade mode and
  unmasked before the DMA self-test (`ISA DMA channel (cascade)=N`); a failed self-test falls back to PIO.

## At load time

The driver prints what it chose. Beyond the CPU class, NIC and DMA/coherency lines:

- **Link speed (`LINK=`).** The 3C509 is 10 Mbit only. For a 3C515 the speed comes from the transceiver
  its EEPROM selects (Window 3 InternalConfig `xcvrSelect`): 10BASE-T/AUI/BNC = 10 Mbit, 100BASE-TX/FX
  = 100 Mbit, MII = unknown.
- **TX start threshold** (how much of a frame is queued before the card starts transmitting it):
  0 on a 286+ at 10 Mbit (the frame leaves while it is still being written); store-and-forward at
  100 Mbit (the wire drains faster than any ISA PIO fill) and on the 8088 class (its fill is slower
  than even the 10 Mbit wire); 512 when the speed is unknown. After a TX underrun the threshold rises
  by 256 bytes, up to store-and-forward.
- **Resident size.** The keep boundary depends on the chosen datapath: the PIO floor stays about
  2.3 KB resident (`MEM /C`: 2,336 bytes including the PSP); the DMA paths keep their descriptors,
  rings and code above it.

## Command-line switches

| Switch | Effect |
|--------|--------|
| `/u` | uninstall the resident driver and exit |
| `/b=NNN` | manual I/O base (hex); skips the ID-port probe |
| `/q=NN` | manual IRQ (decimal); use with `/b=`. On an AT, 2 is taken as 9 (the cascade line); on a PC/XT-class board (one 8259) 9 is taken as 2 and 10–15 are refused. Default without `/q=`: 10 |
| `/5` | the card is a 3C515 Corkscrew (EEPROM at +0x2000, Window-1 base +0x10); without `/b=`, scan for it only |
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
| `docs/09-xms-dma-ext.md` | Proprietary INT 60h AH=F0 XMS/conv DMA RX-ring extension (cfg ABI v3; FDDI-sized slots with `/j`) |
| `docs/10-copybreak-pipelines.md` | Copybreak pipelines & the conventional zero-copy DMA ring |
| `docs/11-capability-matrix.md` | NIC generation × capability matrix |
| `docs/12-nc-region-lift.md` | Non-cacheable DMA region (chipset NC) lift + region policy |
| `docs/13-cache-coherency-probe.md` | Cache coherency: measure, don't assume (probe recipe) |
| `docs/14-bus-detection-lift.md` | Bus detection & enumeration |
| `docs/15-isa-bus-ceiling.md` | The ISA bus ceiling (3C515 @ 100 Mbit) |
| `docs/16-l4-rxtx-optimization.md` | L4 raw-TCP RX/TX optimization |
| `docs/17-cache-coherency-impl.md` | Cache coherency implementation (Phase 2) + 2026-09 review fixes |

---

_Last updated: 2026-09-26 17:54 CEST (PnP base order: rarely-used bases first; no second install over a loaded packet driver). Prior: 2026-09-26 17:40 CEST (PnP picks a free I/O base via the I/O range check; honours /b= /q=). Prior: 2026-09-26 17:15 CEST (3C515 PnP: the rewritten isolation in `3cpdpnp.exe`, the isapnptools DOS tools). Prior: 2026-09-26 16:45 CEST ("Finding the card": 3C515 legacy I/O scan, `3cpdpnp.exe` for PnP-mode cards, ISA DMA cascade for `/d`; CI builds `3cpdpnp.exe`). Prior: 2026-09-26 15:25 CEST (prebuilt binaries via GitHub Actions; "At load time": 3C515 link speed from the transceiver, TX start threshold per link, resident size; `sendlen.com` in `wmake all`; docs/09 is cfg ABI v3). Prior: 2026-09-25 09:53 CEST (`/q=` IRQ 2/9 mapping and the PC/XT IRQ 0-7 limit; `/2` ignored below a 286). Prior: 2026-09-22 21:23 CEST (Build section now lists the real `Makefile` targets and `DEFS` variant builds; added the command-line switch list incl. `/v`; docs table extended to 08–17)._
