# 12 — Real-hardware residuals: design + plan

The PCI phases (docs/11) closed with three items that are **not** emulator artifacts and
stay open until designed away or validated on silicon: (R1) level-INTx RX-DMA re-entry,
(R2) the 515 DN-complete write-back uncertainty, (R3) small-op latency fidelity. This doc
is the detailed design for each plus the execution plan. Evidence base: the Phase-2 pcap
forensics (triplicate delivery), Becker/iPXE semantics (docs/11 D3.1), and the #75
measurement-validity work.

---

## R1 — Level-INTx-safe RX-DMA (unblocks RX-DMA on PCI; fixes #6's dup/loss class)

### Problem
`xms_rx_deliver` (isr.asm) clears the UPD STATUS at step 11 — **after** the receiver
upcalls (steps 8/10). On edge-triggered ISA that was harmless. On level-triggered PCI
INTx, a re-entered ISR (line still asserted at IRET, or nested via an upcall that STIs)
re-runs step 2, finds UP_COMPLETE still set, and **delivers the same frame again** —
observed as every host frame reaching `tcp_input` in triplicate (dup-ACK storms, then
stream desync). Separately, the single-UPD re-arm gap drops frames that arrive between
consume and re-arm (#6's loss mode).

### Design — three stages, independently shippable

**R1.a Claim-before-deliver (ISR discipline; small, driver-only).**
Reorder `xms_rx_deliver`: after step 3 (length captured from STATUS into `rx_len`),
**immediately clear the descriptor STATUS** ("claimed by driver"), THEN pre-arm/upcall.
A re-entered ISR finds STATUS=0 at step 2 and exits — dup-delivery becomes structurally
impossible. Safety argument: clearing STATUS is a *claim*, not a re-arm — the up engine
is stalled (end-of-list) and no UpListPtr write happens until step 12, so the slot data
stays stable through the upcall copy. Steps become: 1 select → 2 verify → 3 len →
**3b claim (STATUS=0)** → 4 pre-arm-other → 5..10 deliver → 12 re-arm. Step 11 is
subsumed by 3b.

**R1.b Level-INTx ack ordering (defense in depth).**
Audit the ISR prologue for PCI: AckIntr(latch+reasons) at the NIC **before** the upcalls
(not only at `.recv_done`), so the INTx line can drop while the upcall runs; the
`.recv_done` re-check loop (the existing ack-race recheck) already catches events that
latch mid-service. Keep the established rule (never AckIntr mid-recv-loop on the
edge-ISA path — [project_3com_isr_edge_irq_ack]); the PCI ordering is gated per-gen
(`g_uplist_off == EL3_UP_LIST_PCI`), leaving the proven ISA sequence untouched.

**R1.c Multi-UPD ring (the real vertical — merges with #25/#26 Phase 8b).**
The `RX_CONFIGURE2` v2 ABI (N-slot ring + completion/free rings, already specced in
`xms_dma.inc:90-124`) becomes the PCI RX datapath: driver owns a ring of UPDs
(NEXT-chained, circular), claims completed heads (R1.a discipline per slot), the up
engine never starves → the re-arm gap (and #6's single-shot loss) disappears. This is
the same descriptor-ownership machinery as Phase 8b copybreak — implement ONCE for both.

### Verification
The 3c905 CONV_SINGLE repro is the oracle (currently: triplicate delivery within
seconds). Gate R1.a: same cell runs with **zero duplicate deliveries** (pcap: no
dup-ACK triples) and completes the smoke; ISA 515 matrix cell no-regress. Gate R1.c:
RX-DMA re-enabled on PCI (drop the QUERY cap withhold), full smoke + timed cells, RX-DMA
throughput ≥ RX-PIO. Real-HW: soak on real 3C905 (INTx sharing off first, then shared).

---

## R2 — 515 DN-complete dual-evidence retirement (write-back uncertainty)

### Problem
The driver retires TX descriptors by polling the fshDnComplete write-back (FSH bit 16).
That write-back is *proven* on 90x silicon (iPXE polls it in the field) but only
*documented* for the Corkscrew — Becker's 3c515.c never reads it (it retires by
**DownListPtr register comparison**). If real 515 silicon doesn't write the bit, our
ring wedges on real hardware and every TX times out.

### Design — retire on EITHER evidence
In the ISR drain loop, the ack-race recheck, and the foreground self-heal: when the
DN-bit test fails, add a **fallback comparison** — read DownListPtr (32-bit via two INs
at `[g_dnlist_off]`) and treat the tail as complete when the register reads **0**
(engine consumed the single-descriptor list; unambiguous because our kicks are always
NEXT=0). Cost: two INs on the *miss* path only — the hot path (write-back present) is
unchanged. Safety: DownListPtr=0 on real silicon means the descriptor AND its buffer
have been fetched (Linux ships on exactly this), so slot reuse is safe.

Model counterpart (hardware-true anyway): the ISA 515 + PCI walkers zero
`down_list_ptr` when the list is consumed — already true for the PCI walker; add to the
ISA single-transfer path (zero at fetch; the paced DN write-back still lands at the
modeled deadline). Add a test property **`dn_writeback=off`** to both models: suppresses
the FSH write-back entirely, so the driver's fallback path is CI-testable — the matrix
cell must still stream via comparison alone.

### Verification
(1) `dn_writeback=on` (default): no behavior change, matrix baselines hold.
(2) `dn_writeback=off`: 515dma100 + 905 cells still pass VERIFY + benches (fallback
proven). (3) Real-HW checklist entry: run txdiag on a real Corkscrew; if 'n' bail
counts dominate with zero 'T' retires from the bit, the silicon answer is "no
write-back" and the fallback carries it — either way the driver works.

---

## R3 — Small-op latency fidelity + real-hardware validation

### Problem
Emulated 4K IOPS is invalid: host-RTT × virtual-clock inflation + the hlt-warp lottery
dominate per-op time (docs/11 measurement notes). Real-HW small-op behavior (IRQ churn,
PIC latency, bus contention) is modeled only coarsely. The design value claim (random
I/O beats period disks) needs a defensible latency number.

### Design — decompose in-rig, measure on silicon

**R3.a bench13h latency decomposition (in-rig, honest about what it can know).**
Wire the existing prof counters (`PROF_SEND/XMIT/COPY/CKSUM/DRV`, src/prof.h) into a
bench13h `p` flag: per-op breakdown line `LAT: cpu=<µs> drv=<µs> wait=<µs>` where
`wait` = elapsed − accounted (the RTT+warp residue). The **cpu/drv components are
virtual-clock-honest** (instruction-counted); only `wait` is rig-polluted — so the rig
yields a valid per-op CPU cost per tier, and 4K IOPS projects as
`1/(cpu + drv + real_RTT)` with real_RTT supplied from wire measurement.

**R3.b IRQ/PIC cost note (explicitly NOT modeled).**
Per-IRQ virtual cost (PIC ack ~60 cycles + vectoring) is < 5% of per-op cost at every
tier — document as out-of-model rather than extend the icount extension. Revisit only
if real-HW numbers disagree with projections by more than the modeling slack.

**R3.c Real-hardware validation ladder (the ground truth).**
Hardware: one PCI-era box (486/Pentium, PCI slots), 3C905 + 3C905B (+ the ISA 3C509B/
3C515 already owned), clean switched LAN to the SPDK target (no NAT — the vmnet lesson).
Media: bootable floppy/CF image = FreeDOS + `3cpd.exe` (pci build) + `nvmetsr` +
`bench13h` (+ debug builds). Ladder, in order, each gating the next:
  1. **Probe**: `3cpd` (no args) prints the PCI-found I/O/IRQ/MAC — matches the card.
  2. **Link + PIO**: 3C905 *without* /d → VERIFY 128KB (PIO datapath, INTx live).
  3. **R2 answer**: 3C515 `/5 /d` + `debugpci` markers → does real Corkscrew write
     fshDnComplete? ('T' with bit vs fallback retires.) Either way VERIFY must pass.
  4. **DMA**: 3C905 `/d` → VERIFY + 4K/32K sweep. Record 4K µs/op — the first honest
     small-op latency number; compare vs `cpu+drv+RTT` projection from R3.a.
  5. **Csum**: 3C905B `/d` → `CSUM:` line + mirror-port pcap → checksums valid on wire.
  6. **Soak**: 1-hour bench loop per NIC; watch `recover`, `stat_rxerr`, wedges.
Diagnostics pre-staged: debug marker decode table, the DownListPtr fallback (R2), the
RX-PIO policy (R1 not required for the ladder — RX-DMA stays off on PCI until R1.c).

---

## Execution plan (ordered; each stage independently valuable)

| # | Work | Size | Depends |
|---|------|------|---------|
| 1 | **R1.a** claim-before-deliver reorder + per-gen ack ordering (R1.b) | S (driver) | — |
| 2 | **R2** dual-evidence retirement + model `dn_writeback` prop + off-mode CI cell | S/M (driver+model) | — |
| 3 | **R3.a** bench13h `p` decomposition mode | S (stack) | — |
| 4 | R1.a gate: 905 CONV_SINGLE repro clean; re-evaluate RX-DMA-on-PCI cap withhold | run | 1 |
| 5 | **R1.c** multi-UPD ring = the merged #25/#26/#6 descriptor-ownership vertical | L | 1, #25 design |
| 6 | **R3.c** real-hardware ladder (needs hardware acquisition) | ext | 1–3 staged first |

Non-goals: PIC-latency modeling (R3.b documented instead); INTx *sharing* support
(single-NIC assumption stands until a real-HW need); RX-DMA-on-PCI before R1.a proves
clean on the triplicate-delivery oracle.
