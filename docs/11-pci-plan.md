# 11 — PCI plan: Vortex → Boomerang → Cyclone (readiness, decisions, phase gates)

Phase-0a deliverable set for the PCI EtherLink III integration. Verdict: **conditional GO** —
the architecture was designed for this (reserved enums/caps, W1 Vortex delta, Window-7 list
pointers, a Boomerang-identical descriptor layout, docs/07's lift plan), but integration is
gated on the decisions and specs below. Phases: 0a (this doc, zero code) → 0b (QEMU test
loop) → 1 (Vortex beachhead) → 2 (Boomerang SG rings) → 3 (Cyclone HW checksum — the north
star: it removes the per-byte TCP-checksum CPU cost that bounds NVMe/TCP goodput on 486/
Pentium). Each phase ends in its own go/no-go.

## D1 — Architecture decision: extend the NASM driver; do NOT build the C HAL

docs/07 Tier C plans a C vtable HAL (`src/core/hal.c`, `src/hw/bus_pci.c`, lifting cache-kit
C verbatim). That predates the NASM-only reality: the shipping driver is pure NASM (docs/01,
CLAUDE.md — "no C runtime, no C code in the main driver"), `hardware.h` is a reference
mirror (never compiled), and real dispatch is `g_nic_gen` + `build_plan`. **Decision: PCI
extends the NASM flag-dispatch driver.**

- `g_nic_gen` {0,1} widens to the full `nic_type_t` ladder (mirror `hardware.h:15-23`:
  0=3C509B, 1=3C515, 2=VORTEX, 3=BOOMERANG, 4=CYCLONE, 5=TORNADO). Existing `0/1` semantics
  unchanged — all current comparisons still hold.
- `build_plan` (start.asm) remains the single choke point where NIC-gen × CPU-tier × DMA
  resolve; PCI generations are new cases there, not a parallel mechanism.
- cache-kit `CK_IO.C` / `enum_pci_devices()` are **reference specs re-expressed in NASM**,
  never linked C. The old repo's 47-model PCI ID table is lifted as *data*.
- If the C-HAL rewrite is ever wanted, that is a different (much larger) plan — re-decide
  at a phase gate, don't drift into it.

## D2 — Driver PCI foundation spec (Phase 1 implementation contract)

**New files** (all cold-phase, freed at copy-down; all gated `%ifdef CFG_PCI`):

| File | Contents |
|------|----------|
| `src/asm/pci_io.asm` | Mechanism-#1 config access: `pci_cfg_read8/16/32`, `pci_cfg_write16/32`. CF8h address = `0x80000000 \| bus<<16 \| dev<<11 \| func<<8 \| (reg & 0xFC)`; data at CFCh (+reg&3 for sub-dword). Uses the 32-bit-port-I/O-in-16-bit-real-mode idiom (`cpu 386` section, `in eax,dx`/`out dx,eax`) — precedent: `frag/tx_pio_386.asm`. Includes `pci_present` sanity (write CF8, read back). Spec source: cache-kit `CK_IO.C`. |
| `src/asm/pcibus.asm` | `detect_nic_pci`: scan bus/dev/func (bus 0–7 suffices for period machines; multi-function honored via header-type bit 7), match vendor `0x10B7`, look up device ID in `pci_el3_ids` table → `g_nic_gen`; read BAR0 (`reg 0x10`, mask low 2 type bits → `& 0xFFFC`) → `g_nic_io`; read IRQ line (`reg 0x3C`) → `g_nic_irq`; **set command-reg (0x04) bit 0 (I/O enable) and bit 2 (bus master)**. Fills the exact same globals the ISA probes fill — everything downstream is unchanged. |
| `include/el3_vortex.inc`, `include/el3_boomerang.inc` | Per-family deltas over `el3_core.inc`, mirroring `el3_tomahawk.inc`/`el3_corkscrew.inc`. Slots already anticipated by the core comment block. |

**Initial device-ID table** (verify against the old repo's 47-model table at implementation):
`0x5900` 3C590 10M, `0x5950` 3C595-TX, `0x9000/0x9001` 3C900, `0x9050/0x9051` 3C905,
`0x9055` 3C905B-TX (Cyclone), `0x9200` 3C905C-TX (Tornado).

**Probe order** (in the start.asm detect block, extending the existing CFG_PNP pattern):
≥386 && CFG_PCI → `detect_nic_pci`; else/miss → existing `detect_nic_pnp` (CFG_PNP, ≥286)
→ `detect_nic` (ID-port floor). A force flag (analogous to `/5`) selects PCI explicitly;
exact letter chosen at implementation (command-tail scanner).

**Build gate:** `wmake pci` target = `DEFS=-dCFG_PCI` (+`-dCFG_PNP`), mirroring the existing
`pnp:` target. **Floor safety (R6):** all PCI code is ≥386-checked at runtime, profile-gated
at build, cold-only — the 8088 resident floor and ≤~2 KB resident budget are untouched.
While here: fix `hardware.h:45`'s "HWCSUM usually unused by DOS" comment — for our CPU-bound
NVMe/TCP workload it is precisely the payoff.

**Register access stays port I/O.** Vortex/Boomerang/Cyclone all decode the windowed
register file through the I/O BAR; `EL3_W1_DELTA_VORTEX` (0x10) applies to all PCI parts.
No MMIO primitive until a measured need (`FRAG_IO_MMIO` stays doc-only). PCI BIOS INT 1Ah
shim stays out of scope (mechanism #1 only), per docs/07.

**IRQ model note:** PCI interrupts are level-triggered. The ISR's edge-oriented
ack-then-EOI discipline must be re-verified for level semantics (ack at the NIC *before*
PIC EOI, or the IRQ re-fires forever). Single-NIC, no-sharing is an acceptable initial
assumption on period DOS; document it. Phase-1 work item.

## D3 — Datapath extension spec: software ring → hardware-walked chain

**Today (515):** both `dma_tx_enqueue` (486+ 4-slot ring) and `dma_tx_caller`
(TX_SUBMIT path) issue **standalone single transfers** — every descriptor has `NEXT=0`;
each StartDmaDown moves one descriptor; the "ring" is software bookkeeping. The ISR drains
every descriptor whose completion bit is set (coalescing-safe) and re-kicks.

**Boomerang target:** the NIC hardware-walks a `NEXT`-chained download list from
`DnListPtr` (`EL3_W7_DOWN_LIST_PTR` — the offsets already in `el3_regs.h:113-120`), with
`DnStall`/`DnUnStall` discipline for appending to a live list; RX mirrors via `UpListPtr`.
The driver's 16-byte NEXT/STATUS/ADDR/LEN descriptor (`el3_corkscrew.inc:49-58`) is already
byte-identical to the Boomerang DPD/UPD shape, so the extension is behavioral, not
structural: chain instead of re-kick.

### ⚠ D3.1 — Completion-bit convention conflict (found during this readiness pass)

Three conventions are in play for "descriptor complete", and they cannot all be right:

| Party | DN complete | Source |
|-------|-------------|--------|
| Our driver + our QEMU 515 model | `0x4000` (bit 14, low word) | `el3_corkscrew.inc`, `el3_core.c` live path — **mutually consistent, works in emulation** |
| Becker ref header | `0x00010000` DN / `0x00020000` UP (high word) | `elink-qemu/refs/3c515.h:197-202` — hardware-true lineage |
| QEMU `3c59x.c` chain walker | bit 31 ownership + `0x4000` complete | in-tree prototype |

If Becker is right, **today's 515 DMA driver would fail on real Corkscrew silicon** — the
emulator and driver simply share the same wrong bit. **0b work item (blocking):** resolve
the hardware-true convention from Becker's actual `3c515.c`/`3c59x.c` sources (not just the
header) + the 3Com refs, then align *all four*: the driver (`el3_corkscrew.inc` +
`resident.asm`/`isr.asm` polling), the ISA 515 model, the PCI model, and the new
`el3_boomerang.inc`. This is a fidelity fix with real-hardware consequences, independent of
PCI.

### D3.2 — Addressing: 24-bit ISA → 32-bit PCI

- The `<16 MB` guards (`DMA_ISA_16M_LIMIT`; checks in `f_xms_tx_configure`/`f_xms_tx_submit`)
  become **policy-dependent**: ISA bus-master keeps 16 MB; PCI allows full 32-bit.
- `seg*16+off` phys math is valid (<1 MB conventional) for both buses; the change is
  *accepting* caller-phys/XMS/VDS-locked buffers above 16 MB on PCI. VDS lock primitives
  already exist on the stack side (Phase 8a.1 `xms.c`); test-before-trust applies (docs/04).

### D3.3 — RX: `RX_CONFIGURE2` → upload list

The stubbed v2 ABI (`XMS_DMA_RX_CONFIGURE2` 0x03, `xms_slot_desc_t`/`xms_ring_hdr_t`
completion/free rings in `xms_dma.inc:90-124`) is structurally the Boomerang upload list:
slots ↔ UPDs, slot `status/flags` ↔ UpPktStatus. Implementing it *is* the PCI RX datapath.

### D3.4 — Backlog sequencing (hard prerequisites)

- **#25 (Phase 8b descriptor-ownership/copybreak)** exercises the same machinery — do it on
  the 515 first (fast loop, known model) or explicitly fold it into the Phase-1→2 gate.
  Not both independently.
- **#6 (RX-DMA single-shot frame loss)** must be fixed before Phase-2 RX rings inherit it.

## D4 — Offload readiness spec (Cyclone, Phase 3)

**Stack TX gates** (`dos-nvmeotcp`): IP header checksum at `ip_send` (`ip.c:43`); TCP
checksum at `tcp_xmit` (`tcp.c:275`) and the hot path `tcp_xmit_data` (the `cksum_copy`
copy+sum fuse, which degenerates to a plain copy when offloading). Gate all three on a
capability learned **once** at init via the INT 60h AH=0xF0 QUERY (new `XMS_CAP_HWCSUM`
bit), leaving the checksum fields zero when set.

**Per-frame signaling is required, not per-config:** the Cyclone requests checksum insertion
via per-descriptor FSH bits (add-IP/add-TCP), and blanket-adding them would corrupt non-IP
frames (ARP). So TX needs a per-frame flags channel → a **`TX_SUBMIT2` subfunction**
(register `SI`=flags: bit0 add-IP-csum, bit1 add-TCP-csum), cap-gated, with the existing
`TX_SUBMIT` unchanged for backward compatibility. Cross-repo ABI change — single-source +
pinned byte tables + drift check per the established ABI-rigor practice.

**RX:** the stack performs **no** checksum verification today (`ip_input`/`tcp_input` never
check) — nothing to disable; optionally later *trust* the Cyclone's UpPktStatus csum-checked
bits if RX verify is ever added.

**QEMU Cyclone model:** new badge (`MODEL_3C905B`, device 0x9055) over the shared core;
honor the DPD csum-request bits by computing (via `net/checksum.h`, per the `e1000.c`/
`rtl8139.c` pattern) and set UPD csum-ok status on RX. The checksum descriptor-bit
vocabulary is already sketched in `el3_core.h:112,140`. **Measurability:** icount captures
the win directly — an offloading guest executes fewer instructions → faster virtual time —
so the Phase-3 claim is provable in the emulator before real hardware.

## D5 — Go/no-go (fill at end of Phase 0b)

**GO to Phase 1 iff** all of:
- [ ] D1 fork confirmed (NASM path; no C-HAL revival)
- [ ] QEMU PCI model re-badged/split (3C590 PIO-only; 3C905 chain-DMA) and validated by a
      known-good initiator (vendor DOS packet driver / iPXE 3c90x / Linux 3c59x) — probes,
      links, moves frames on both badges
- [ ] D3.1 completion-bit convention resolved against the refs; driver + models aligned
- [ ] No spec-identified blocker requiring re-architecture; R6 floor safety confirmed

**NO-GO / defer if:** the model can't reach a probeable state in ~a week of effort
(fallback would be real-hardware-only development — reconsider scope), or the C-HAL rewrite
is chosen instead.

## Phase gates & verification (summary)

| Phase | Gate |
|-------|------|
| 0b | known-good initiator moves frames on both QEMU badges; D3.1 resolved |
| 1 (Vortex) | our driver PCI-probes 3C590, link up, echo test, PIO NVMe smoke |
| 2 (Boomerang) | SG correctness; `run_nvme_matrix.sh` + real-SPDK smoke; sequential beats the 515's ISA-capped numbers |
| 3 (Cyclone) | pcap-verified wire checksums; icount slow-CPU lift; tier-matrix no-regress on 509/515/590/905 |

Non-goals: PCI BIOS shim, EISA/MCA/PCMCIA probers, Tornado beyond enum reservation,
real-hardware validation (emulator-first; real HW later confirms the Cyclone claim — and,
per D3.1, the 515 DMA convention).
