# 13 — R1.c: multi-UPD RX ring (RX-DMA on PCI; merges #6 / #25 / #26)

The keystone residual from docs/12. Closes the RX-DMA-on-PCI deferral by giving the up
engine a ring it can never starve, retiring four backlog items at once:
- **#6** RX-DMA single-shot frame loss (the re-arm gap between consume and re-arm).
- **R1.a oracle** — needs RX-DMA live on the level-INTx 905 to prove no triplicate delivery.
- **#25 / #26** Phase 8b copybreak — the completion/free-ring descriptor-ownership machinery
  is *the same* machinery; build once, not twice.

Evidence base: the existing fixed-2-descriptor RX path (`resident.asm` f_xms_configure +
`isr.asm` xms_rx_deliver), the v2 ABI already pinned in `xms_dma.inc` (`XMS_CFG2_*`,
`XMS_SLOT_*`, `XMS_RING_*`, `XMS_COMPL_*`, `XMS_FREE_*`), and the QEMU RX placer
(`3c59x.c` el3_pci_rx_place_frame) which **already walks circular NEXT-chained rings** and
stalls on a still-complete head — so the model is largely ready.

---

## Current state (what exists)

- **Driver RX-DMA** is a fixed **two-descriptor** arrangement: `xms_rx_desc0`/`xms_rx_desc1`
  (resident), armed by `f_xms_configure` (subfn 0x01). Policies: `CONV_SINGLE` (1 slot,
  NEXT=0) and `XMS_RING` / `CONV_RING` (2 slots, NEXT-chained circular desc0↔desc1).
  Delivery is the **classic Crynwr receiver upcall** — `xms_rx_deliver` copies the frame
  into the app's receiver buffer (`call far [cs:bx]`), then re-arms.
- **R1.a (docs/12)** already makes per-slot claim-before-deliver dup-safe: STATUS is cleared
  at step 3a before any upcall. The 2-slot ring inherits this per slot.
- **RX_CONFIGURE2 (0x03)** and **RX_REFILL (0x06)** are ABI-defined but **stubbed**
  (`resident.asm:129`).
- **PCI withholds all RX-DMA caps** (`resident.asm` ~898: `g_uplist_off==EL3_UP_LIST_PCI`
  → clears CONV_SINGLE/CONV_RING/XMS_RING/RING) → RX stays PIO on 90x.
- **QEMU placer** (`el3_pci_rx_place_frame`): one packet per UPD, `UP_COMPLETE` write-back,
  advance `up_list_ptr = next` on a circular walk, **stall** (not pointer-zero) at end of
  list or on a still-complete head. The ISA 515 core RX dispatch gates on
  `bus_master_enabled && rx_place_frame && up_list_ptr`.

So the two structural gaps that block RX-DMA on PCI are: (1) only **2** slots → the engine
starves in the re-arm gap under level-INTx bursts (#6); (2) the QUERY cap withhold. R1.c
grows the ring to N and — proven dup-safe by R1.a + starvation-free by depth — drops the
withhold.

---

## Design — two independently shippable stages

### Stage 1 — N-slot UPD ring behind the existing upcall  *(driver-led; ships RX-DMA-on-PCI + #6 + R1.a oracle)*

Replace the fixed desc0/desc1 pair with an **N-slot ring of UPDs** (N ≤ `RX_DMA_SLOTS`=8),
NEXT-chained circular, still delivering via the classic receiver upcall. This is the minimal
change that structurally fixes #6 and unblocks the oracle — no stack RX rewrite yet.

- **RX_CONFIGURE2 (0x03)** becomes real, **driver-resident buffers** (decided): the stack
  passes only `n_slots` (≤ `RX_DMA_SLOTS`=8) and `slot_size`; the driver owns the N landing
  buffers as a resident BSS pool (`xms_rx_slotbuf`, N×slot_size) + N resident UPDs
  (`xms_rx_ring[N]`, 16 B each), NEXT-chained slot[i]→slot[i+1], slot[N-1]→slot[0] (circular),
  arms `UpListPtr`. **Rationale:** conventional-memory buffers are phys < 1 MB → ISA-DMA-safe
  by construction (no bounce/VDS), and Stage 1 stays driver-only (no stack buffer plumbing).
  Cost: N×slot_size resident BSS (std-MTU 1514 × N — e.g. 6 KB at N=4), acceptable on the
  DMA tier (≥286), never on the 8088 floor. Stage 2 re-plumbs to stack-supplied buffers
  (`slots_lin`, the pinned v2 ABI) for zero-copy. (v1 `CONFIGURE` 0x01 stays for the ISA
  2-slot path; the N-slot v2 ring is the PCI/DMA path.) Std-MTU only in Stage 1; /j large-frame
  RX-DMA deferred (slot pool would be N×4608).
- **`xms_rx_deliver`** walks from `xms_ring_tail`: for each UPD with `UP_COMPLETE` set →
  **claim (R1.a: STATUS=0)** → upcall-copy → advance tail. The head the engine is filling is
  always ≥1 slot ahead of tail, so it never hits a still-complete head until the driver is N
  slots behind — the re-arm gap is gone. Re-arm is implicit: a claimed (STATUS=0) slot the
  engine wraps to is ready; no `UpListPtr` rewrite per frame (only an `UpUnstall` if the
  driver ever fully drained — bounded catch-up).
- **Drop the PCI RX-cap withhold** gated on a new `XMS_CAP_RXRING` (v2) so only v2-aware
  callers get RX-DMA on PCI; legacy upcall-only callers still see RX-PIO. Add
  `XMS_ERR_*`/version checks per the ABI-drift rules.
- **Model:** the placer already walks circular rings; verify N-slot wrap + the stall-on-lap
  case. Likely no code change beyond a `qemu_log` sanity line; add a test knob only if a wrap
  bug surfaces.

**Stage-1 gate (the R1.a oracle, finally runnable):** 3c905 with RX-DMA armed (v2), NVMe/TCP
smoke — pcap shows **no dup-ACK triples** (R1.a proven under live level-INTx RX-DMA), zero
`stat_rxerr` from ring lap, RX-DMA throughput ≥ RX-PIO. ISA 515 v2 ring no-regress; #6 loss
gone (a burst that previously dropped frames in the 2-slot gap now completes).

### Stage 2 — completion/free-ring zero-copy handoff  *(the #25/#26 copybreak win)*

Swap the per-frame upcall copy for the polled **completion ring** (driver→stack) + **free
ring** (stack→driver) already specced in `xms_dma.inc`. On completion the driver pushes
`{slot_id,len,status,seq}` to the completion ring instead of copying; the stack processes the
frame **in place** in the slot buffer and returns the slot via the free ring; **RX_REFILL
(0x06)** re-arms freed slots (clears STATUS, bumps `UpListPtr`/`UpUnstall`). This is copybreak
for RX: zero per-frame copy, the descriptor-ownership machinery #25/#26 need. Stack side: the
NVMe/TCP RX poll (`net_poll`/`tcp_input`) drains the completion ring and frees slots — the
larger change, kept separate so Stage 1's residual-closing value ships first.

**Stage-2 gate:** matrix RX-DMA cells with copybreak on; goodput ≥ Stage 1; no per-frame copy
in the prof `POLL`/`COPY` decomposition (R3.a shows the drop); no-regress on 509/515/590/905.

---

## Risks / constraints

- **Floor safety (R6):** all v2 ring code ≥286 (DMA tier) and cold-init only for the wiring;
  the resident UPD ring is N×16 B (≤128 B at N=8) — within the ~2 KB budget. 8088 floor
  untouched (PIO, no RX-DMA).
- **ABI rigor** (cross-repo): `xms_rx_cfg2_t` / ring structs are pinned in three files
  (`xms_dma.inc`/`.h` + stack `xms.h`); extend `abi_check.sh` to cover the v2 offsets;
  version byte + distinguishable `XMS_ERR_*` on mismatch; no implicit packing.
- **Level-INTx discipline:** keep R1.a's per-slot claim; never AckIntr mid-recv-loop
  (`project_3com_isr_edge_irq_ack`); the ring must lap-detect (tail catches head) and
  `UpUnstall` rather than double-deliver.
- **ISA 24-bit DMA:** slot `phys` must be <16 MB (bounce/VDS per the existing DMA tiers);
  the stack supplies NIC-visible phys in `slots_lin`.

## Execution order

1. Stage 1 driver: RX_CONFIGURE2 N-slot ring + xms_rx_deliver walk + cap gate + abi_check.
2. Stage 1 stack: allocate N slots, call RX_CONFIGURE2 (keep upcall delivery for now).
3. Stage 1 gate: 905 RX-DMA oracle (dup-free) + #6 burst + 515 no-regress + drop withhold.
4. Stage 2 driver+stack: completion/free rings + RX_REFILL (the copybreak vertical).
5. Stage 2 gate: matrix goodput + prof copy-drop; fold #25/#26 closed.
