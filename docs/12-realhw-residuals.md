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

**R1.a Claim-before-deliver (ISR discipline; small, driver-only).**  *(IMPLEMENTED)*
Reorder `xms_rx_deliver`: after step 3 (length captured from STATUS into `rx_len`),
**immediately clear the descriptor STATUS** ("claimed by driver"), THEN pre-arm/upcall.
A re-entered ISR finds STATUS=0 at step 2 and exits — dup-delivery becomes structurally
impossible. Safety argument: clearing STATUS is a *claim*, not a re-arm — the up engine
is stalled (end-of-list) and no UpListPtr write happens until step 12, so the slot data
stays stable through the upcall copy. Steps become: 1 select → 2 verify → 3a claim
(STATUS lo+hi = 0; AX still holds the pre-claim status) → 3b len → 4 pre-arm-other →
5..10 deliver → 12 re-arm. Old step 11's post-upcall clear is subsumed by 3a.
**Activation caveat:** the fix is in the shared `xms_rx_deliver`, but RX-DMA on PCI stays
withheld (QUERY cap) until R1.c, so the triplicate-delivery *oracle* (which needs RX-DMA
live on the level-INTx 905) is validated with R1.c — not by a standalone R1.a run. On the
paths that use RX-DMA today (ISA 515, edge-triggered) the reorder is a correctness-neutral
no-regress.

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

### Design — retire on EITHER evidence  *(IMPLEMENTED)*
In the ISR drain loop (`isr.asm` ~119), the ack-race recheck (`isr.asm` ~350), and the
foreground self-heal (`resident.asm` ~468): when the DN-bit test fails, call the shared
helper **`dn_ptr_is_zero`** — reads DownListPtr (32-bit via two word INs at
`[g_nic_io]+[g_dnlist_off]`, clobbers only AX, preserves the sites' `BX=&desc[tail]`) and
sets ZF=1 when it reads **0** (engine consumed the single-descriptor list; unambiguous
because our kicks are always NEXT=0). Cost: two INs on the *miss* path only — the hot path
(write-back present) is unchanged. Safety: DownListPtr=0 on real silicon means the
descriptor AND its buffer have been fetched (Linux ships on exactly this), so slot reuse is
safe.

Model counterpart: an EL3Core `dn_writeback` flag (default **true**, a qdev property on all
four badges) gates the FSH DN-complete write-back — off suppresses it so the driver's
fallback is CI-testable. The ISA single-transfer path (`el3_core_dma_tx_single` +
`el3_tx_drain_timer_cb`) now zeroes `down_list_ptr` when the descriptor is consumed —
**deferred to the paced completion deadline, not fetch**: keyed to a `down_list_ptr ==
dn_pend[i].addr` match in the drain cb so a foreground poll can't retire+refill the slot
*before* the paced write-back has landed (that ordering is the whole point — early zeroing
would let the fallback clobber a refilled descriptor). The PCI walker already zeroes at its
natural chain end, so the drain-cb match is a no-op there; its write-back is hardware-proven
(iPXE polls it) and stays on in practice.

**Scope note:** the meaningful `dn_writeback=off` gate is the **515dma100** cell — that is
where the residual lives (Becker's Corkscrew driver retires by comparison, never reads the
bit). The property exists on the 90x badges for symmetry, but 90x silicon writes the bit,
so its fallback is not the operative real-HW path.

### Verification  *(RAN — Pentium 515dma100 CONV_RING, timed icount)*
(1) `dn_writeback=on` (default): no behavior change — VERIFY OK, 32Kw **1133 KB/s** (matches
the pre-R2 baseline exactly; drain-cb `down_list_ptr` zeroing is paced-deadline-gated, so
IRQ-driven retirement timing is unchanged). (2) `dn_writeback=off` (write-back fully
suppressed → fallback is the *only* retirement evidence): **VERIFY OK** (the >64 KB
write+readback matched byte-for-byte, proving the fallback retires only after the engine
consumed descriptor **and** buffer — no early-reuse corruption), NVME/IOQ READY, all benches
complete, drive self-healed (`recover=1`). Throughput drops under this fault-injection mode
(per-retire port INs + the icount hlt-warp interaction), which is expected and harmless: real
Corkscrew silicon either writes the bit (hot path, full speed) or doesn't (fallback carries
it) — either way the driver works. (3) Real-HW checklist entry: run txdiag on a real
Corkscrew; if 'n' bail counts dominate with zero 'T' retires from the bit, the silicon answer
is "no write-back" and the fallback carries it.

---

## R3 — Small-op latency fidelity + real-hardware validation

### Problem
Emulated 4K IOPS is invalid: host-RTT × virtual-clock inflation + the hlt-warp lottery
dominate per-op time (docs/11 measurement notes). Real-HW small-op behavior (IRQ churn,
PIC latency, bus contention) is modeled only coarsely. The design value claim (random
I/O beats period disks) needs a defensible latency number.

### Design — decompose in-rig, measure on silicon

**R3.a bench13h latency decomposition (in-rig, honest about what it can know).**  *(IMPLEMENTED)*
The prof counters (`PROF_SEND/XMIT/COPY/CKSUM/DRV/POLL`, src/prof.h) accumulate inside the
**nvmetsr TSR** (that is where the hot path runs when it services INT 13h); bench13h is a
separate exe. Exposure: a new INT 13h vendor subfunction **AH=0xFE, CX='PR'** (`nvmetsr.c`,
gated `CFG_PROF`) writes a `prof_snap_t` to the caller's ES:BX and resets the accumulators.
bench13h's **`p` flag** resets before the run, then after emits `<tag>-LAT: cpu=<µs>
drv=<µs> wait=<µs> us/op`: `cpu = SEND + (XMIT − DRV) + POLL` (XMIT is the TX superset; its
DRV sub-span is split out, not double-counted), `drv = DRV`, `wait = elapsed_per_op − cpu −
drv`. The **cpu/drv components are virtual-clock-honest** (PIT-tick instruction-counted, same
overhead-subtraction as `prof_report`); only `wait` is rig-polluted — so the rig yields a
valid per-op CPU cost per tier, and 4K IOPS projects as `1/(cpu + drv + real_RTT)` with
real_RTT supplied from wire measurement. Needs nvmetsr built `-dCFG_PROF` (build.sh now
threads `CFLAGS_EXTRA` into the nvmetsr link); a stock TSR makes `p` print "prof unavailable".

*RAN* (Pentium 515dma100, `-dCFG_PROF` nvmetsr): 4K read `cpu=599 drv=643 wait=131125 us/op`
(elapsed 132367) — **99% wait**: the emulated 4K op is host-RTT × icount-inflation bound, not
CPU-bound (~1.2 ms of real work under a 131 ms RTT residue), the hard number behind "4K IOPS
is invalid in-rig". 32K read `cpu=12827 drv=2469 wait=4065` (elapsed 19361) — **CPU-dominated**
(12.8 ms real work), the valid bus-bound regime. So project 4K on silicon as
`1/(599 µs + 643 µs + real_RTT)`, not the rig's 7 IOPS.

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

| # | Work | Size | Depends | Status |
|---|------|------|---------|--------|
| 1 | **R1.a** claim-before-deliver reorder (+ R1.b confirmed no-change: ack already precedes EOI) | S (driver) | — | **DONE** |
| 2 | **R2** dual-evidence retirement + model `dn_writeback` prop + off-mode CI cell | S/M (driver+model) | — | **DONE** |
| 3 | **R3.a** bench13h `p` decomposition mode + AH=0xFE prof-snapshot vendor call | S (stack) | — | **DONE** |
| 4 | R1.a gate: 905 CONV_SINGLE repro clean — folded into R1.c (needs RX-DMA live on PCI) | run | 1, 5 | deferred → 5 |
| 5 | **R1.c** multi-UPD ring = the merged #25/#26/#6 descriptor-ownership vertical | L | 1, #25 design | pending |
| 6 | **R3.c** real-hardware ladder (needs hardware acquisition) | ext | 1–3 staged first | pending (ext) |

Stages 1–3 landed together (this session), each building clean: driver `wmake pci`
(`dn_ptr_is_zero` helper + claim reorder), QEMU fork (`dn_writeback` prop + paced-deadline
`down_list_ptr` zeroing), stack `-dCFG_PROF` (AH=0xFE vendor + bench `p`). R1.a's
triplicate-delivery oracle is deferred to R1.c because it requires RX-DMA live on the
level-INTx 905 (still withheld by the QUERY cap). Validation sweep: 515dma100 `dn_writeback`
on/off no-regress (R2) + bench `p` LAT decomposition (R3.a).

Non-goals: PIC-latency modeling (R3.b documented instead); INTx *sharing* support
(single-NIC assumption stands until a real-HW need); RX-DMA-on-PCI before R1.a proves
clean on the triplicate-delivery oracle.
