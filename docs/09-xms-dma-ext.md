# 09 — Proprietary INT 60h XMS DMA extension

Allows `nvmetsr.exe` to hand `3cpd.exe` the physical address of XMS-resident
receive buffers, so the 3C515 bus-master can DMA directly into extended memory.
The NIC DMA ring runs in XMS; the ISR copies received frames into conventional
memory via INT 15h AH=87h (one CPU copy per frame).

**Note on linear addresses:** `xms_rx_cfg_t` has `lin0`/`lin1` fields for
zero-copy VCPI/DPMI delivery. These are always 0 in the current implementation.
VCPI page mapping (DE04h/DE05h allocate/free pages; there is no VCPI call to
map an arbitrary physical page to a V86 linear address from real/V86 mode — that
requires the protected-mode VCPI entry point and direct page-table manipulation).
DPMI AX=0800h maps physical→linear but returns a protected-mode linear address
above 1 MB, not a V86-accessible real-mode segment. `XMS_COPY` (lin0=lin1=0)
with INT 15h delivery is the correct implementation for real-mode DOS.

Constants and struct definitions: `include/xms_dma.h`.  
Phase 8 roadmap context: `docs/08-nvmeotcp-plan.md § Phase 8`.

---

## Prerequisites

| Requirement | Applies to |
|-------------|-----------|
| CPU ≥ 286 | `XMS_POLICY_XMS_COPY` — ISA bus-master DMA + INT 15h AH=87h move |
| CPU ≥ 386 | `XMS_POLICY_VCPI` and `XMS_POLICY_DPMI` — require V86 mode paging |
| VMM present (EMM386 / Windows 3.x enhanced) | VDS (INT 4Bh) for physical address translation |
| HIMEM.SYS loaded | XMS EMB allocation (both 286 and 386+) |
| 3C515 Corkscrew NIC | Bus-master DMA; `UP_LIST_PTR` / `EL3_DESC_*` registers |

On 8088/8086 hardware or when the QUERY call returns CF=1 (old driver), the
caller falls back to `MEM_CONVENTIONAL` — standard Crynwr PIO path, no change
from Phase 7 behaviour.

---

## Memory policy hierarchy

Detected once during `nvmetsr.exe` cold-phase install, in this order:

| Policy | Min CPU | Detection | RX copies | TSR size |
|--------|---------|-----------|-----------|----------|
| `XMS_POLICY_XMS_COPY` | 286+ | `INT 2Fh AX=4300h` → AL=80h (HIMEM.SYS present) | 1 | ~110 KB |
| `MEM_CONVENTIONAL` | 8088+ | fallback (no XMS / QUERY CF=1) | 2 | ~110 KB |

`MEM_CONVENTIONAL` never reaches the extension — no INT 60h call is made.

**VCPI/DPMI note:** `XMS_POLICY_VCPI` and `XMS_POLICY_DPMI` are defined in
`xms_dma.h` and reserved for a future zero-copy path. The `lin0`/`lin1` fields
in `xms_rx_cfg_t` are intended for mapped V86 linear addresses (so the ISR can
deliver without a copy), but no mechanism exists to map XMS physical pages into
the V86 real-mode address range from user code. Both policies fall back to
`XMS_POLICY_XMS_COPY` (lin0=lin1=0) in the current implementation.

---

## DMA descriptor mode vs. CPU tier

_Last updated: 2026-06-19 04:47 CEST — CONV ring deepened to `RX_RING_N` (8) slots;
windowed-RX-DMA collapse traced to receive livelock and fixed with NAPI + backpressure._

Ring **depth** and **layout** depend on the memory policy:

- **`XMS_COPY` / VCPI / DPMI** — two explicit slots (`phys0`/`phys1`), each a
  separate XMS EMB. The caller hands both slot addresses; the descriptors are
  not contiguous.
- **`XMS_POLICY_CONV`** — one *contiguous* block of `RX_RING_N` slots. The
  caller passes only `phys0` (the block base); slot _i_ lives at
  `phys0 + i·slot_size`, and `3cpd.exe` builds every descriptor from that base.

**Windowed RX-DMA needs three things working together** (an earlier note here
credited the deep ring alone — that was measured on a misconfigured run that had
silently fallen back to PIO; corrected below):

1. **A deep ring** (`RX_RING_N` slots) to buffer the in-flight window.
2. **Backpressure, not drop** — the el3 returns RETRY (not a phantom "delivered")
   when the bus is busy or the ring is full, so the closed-loop source doesn't
   advance its sequence over a frame the guest never got.
3. **NAPI** (the real lever) — at 100 Mbit the RX IRQ rate outruns a CPU-bound
   guest, so a per-IRQ ISR drain starves the stack's `net_poll` (**receive
   livelock**): a window of 4 collapsed to ~0.14 Mbit/s regardless of ring depth.
   The ISR masks `UP_COMPLETE` under load and defers; the stack drains the whole
   ring from task context via `INT 60h AH=0xF0 AL=0x03`, then re-arms.

With all three: window 4 → **15.1 Mbit/s** on a 386-class cell (486@shift7,
`dropped=0`, and win 4/8 > win 1), **48.8 Mbit/s** (ISA ceiling) on a faster 486,
and **9.6 Mbit/s = 96 % of wire** at 10 Mbit. The collapse was livelock, *not*
ring depth — confirmed by 10 Mbit (slow enough that the guest keeps up) sustaining
96 % at window 4 with the old 2-slot behaviour.

| CPU | RX DMA mode | depth | `EL3_DESC_NEXT` |
|-----|-------------|-------|-----------------|
| 286 | Single-transfer | 2 | 0 (no chain) — ISR re-arms immediately after each completion |
| 386+ `XMS_COPY` | Ring | 2 | → descriptor 1 / → descriptor 0 (circular) — NIC auto-advances |
| 386+ `CONV` | Ring | `RX_RING_N` (8) | → next descriptor (circular over all N) — NIC auto-advances |

**Single-transfer ping-pong (286):** on completion the ISR immediately arms
the *other* slot and kicks `START_DMA_UP` before processing the current frame,
minimising the gap during which a new frame could be dropped. (A 286 **can**
run `CONV` — but as a 2-slot single-transfer ring, both slots carved from the
contiguous base. Only the deep `RX_RING_N=8` `NEXT`-chained ring needs the
386+ ring-mode engine; the policy `CONV` is CPU-gated by *ring depth*, not by
availability.)

**Ring mode (386+):** `EL3_DESC_NEXT` chains the descriptors into a circle
(2 for `XMS_COPY`, all `RX_RING_N` for `CONV`). The NIC advances to the next
descriptor the moment the current one completes, with zero inter-frame gap.
The ISR clears the completed descriptor's status and cycles its slot index
`mod nslots`; no explicit re-arm is needed. The NIC overrun-drops only when it
laps the driver — i.e. the next descriptor still carries `UP_COMPLETE` because
the driver has not yet recycled it (a deeper ring raises the lap threshold).

```
TX: CPU frag  ×  DMA tier    (PIO / single-xfer 286 / ring 386+)
RX: CPU frag  ×  mem policy  (CONVENTIONAL-PIO /
                               XMS_COPY-single 286 /
                               XMS_COPY-ring 386+ /
                               VCPI-ring 386+ /
                               DPMI-ring 386+)
```

---

## INT 60h AH=0xF0 — function definitions

All sub-functions (QUERY/CONFIGURE/RELEASE below, plus `AL=0x03`
`XMS_DMA_POLL`, the NAPI drain) follow the Crynwr error convention: CF=0
success, CF=1 error with DH = error code (`XMS_ERR_*` from `xms_dma.h`).

### AL=0x00 — Query XMS DMA capabilities

```
In:   AH = XMS_DMA_FUNC   (0xF0)
      AL = XMS_DMA_QUERY   (0x00)

Out (CF=0):
      BX = capability flags  (XMS_CAP_* bitmask)
      DX = slot_size to use, in bytes  (always TX_SLOT_SZ = 1536; also the CONV ring stride)

Out (CF=1):  extension not supported — fall back to MEM_CONVENTIONAL
```

`nvmetsr.exe` calls this before allocating any XMS. An old `3cpd.exe` that
does not implement `0xF0` returns CF=1 from its dispatcher (bad-command), and
the caller silently takes the conventional path. **The same CF=1 comes back
when 3cpd is on the PIO floor** (no bus-master DMA: 3C509, `/d` not given, a
failed DMA probe, V86 without a provable VDS lock, non-coherent without a safe
flush): the whole AH=F0 extension (QUERY/CONFIGURE/RELEASE/POLL) exists only
while DMA is active, because the PIO floor frees the `xms_*` state. See
[v2 ABI and validation](#v2-abi-and-validation-2026-09).

### AL=0x01 — Configure XMS DMA receive ring

```
In:   AH = XMS_DMA_FUNC      (0xF0)
      AL = XMS_DMA_CONFIGURE  (0x01)
      ES:DI → xms_rx_cfg_t   (caller-allocated, must stay resident)

Out (CF=0):  ring programmed, UP_LIST_PTR armed, DMA running
Out (CF=1):  DH = XMS_ERR_*  (ring not started; caller may retry or fall back)
```

`3cpd.exe` validation steps (current; the full rules are in
[v2 ABI and validation](#v2-abi-and-validation-2026-09)):

1. `XMS_CFG_VERSION_MIN (1) ≤ cfg.version ≤ XMS_CFG_VERSION (2)`
2. `cfg.policy ≤ XMS_POLICY_MAX` (4 = `COMMONBUF`); VCPI/DPMI (0/1) only on the 386+ ring
3. `cfg.phys0` and `cfg.phys1` both `< DMA_ISA_16M_LIMIT` (0x1000000) — ISA
   bus-master 24-bit addressing limit
4. `1 ≤ cfg.slot_size ≤ TX_SLOT_SZ` (1536); a 32-byte multiple for CONV/COMMONBUF
5. CONV/COMMONBUF: the `lin0`/`phys0` span checks (`XMS_ERR_BAD_LIN`)

On success, `3cpd.exe` builds two 16-byte descriptors in its resident data
(`ALIGNB 16`). The `EL3_DESC_NEXT` field is set by the JIT based on CPU tier:

```
; descriptor 0
EL3_DESC_NEXT   → desc1_phys  (386+ ring) / 0  (286 single-transfer)
EL3_DESC_STATUS → 0           (NIC sets UP_COMPLETE on completion)
EL3_DESC_ADDR   → cfg.phys0   (XMS slot 0)
EL3_DESC_LEN    → cfg.slot_size

; descriptor 1
EL3_DESC_NEXT   → desc0_phys  (386+ ring) / 0  (286 single-transfer)
EL3_DESC_STATUS → 0
EL3_DESC_ADDR   → cfg.phys1   (XMS slot 1)
EL3_DESC_LEN    → cfg.slot_size
```

Then:

```asm
OUT  io_base + EL3_CS_UP_LIST_PTR,  physical_address_of_desc0
OUT  io_base + EL3_CMD,             EL3_CMD_START_DMA_UP
```

`3cpd.exe` stores `ES:DI` (the config pointer) and the current slot index
(`0`) in its resident state. The ISR reads `lin0`/`lin1` directly from the
struct pointer — no copy of the struct is made.

### AL=0x02 — Release XMS DMA receive ring

```
In:   AH = XMS_DMA_FUNC    (0xF0)
      AL = XMS_DMA_RELEASE  (0x02)

Out (CF=0):  DMA stopped, UP_LIST_PTR zeroed, config pointer cleared
Out (CF=1):  DH = XMS_ERR_NOT_CFG
```

`3cpd.exe` writes zero to `UP_LIST_PTR` and issues `START_DMA_UP` with a null
pointer to halt the RX engine. The resident config pointer is cleared. If
CONFIGURE fenced the pool non-cacheable (Phase 2, `docs/12`), the chipset's
previous NC registers are restored here too. After this call, the ring
descriptors and the caller's `xms_rx_cfg_t` are dead and the XMS buffers may be
freed. `3cpd /u` does the same for a still-armed ring before it unloads.

---

## ISR hotpath — JIT-composed receive fragments

On RX interrupt, after `EL3_DESC_UP_COMPLETE` is set in the current
descriptor's status word:

### `rx_recv_vcpi.asm` / `rx_recv_dpmi.asm`  (zero copies)

```
read lin_N from cfg.lin{slot}           ; mapped linear address — valid far ptr
call Crynwr upcall AX=0, ES:DI=lin_N, CX=frame_len
clear descriptor status
toggle slot index  (0 ↔ 1)
; ring auto-advances; no need to reprogram UP_LIST_PTR
```

### `rx_recv_xms_ring.asm`  (one copy — 386+ ring mode)

```
INT 15h AH=87h: phys_N → resident staging buffer (conventional, one FDDI frame)
call Crynwr upcall AX=0, ES:DI=staging_buf, CX=frame_len
clear descriptor status
toggle slot index  (0 ↔ 1)
; ring auto-advances — no re-arm needed
```

### `rx_recv_xms_single.asm`  (one copy — 286 single-transfer mode)

```
toggle slot index  (0 ↔ 1)               ; select OTHER slot
arm descriptor{new_slot} EL3_DESC_NEXT=0  ; re-arm immediately — minimise gap
OUT UP_LIST_PTR ← desc{new_slot}_phys
OUT CMD ← EL3_CMD_START_DMA_UP            ; kick NIC before processing old frame
INT 15h AH=87h: phys_{old_slot} → resident staging buffer
call Crynwr upcall AX=0, ES:DI=staging_buf, CX=frame_len
clear old descriptor status
```

Re-arming the NIC *before* the INT 15h copy and upcall minimises the window
during which the NIC has no armed descriptor. The staging buffer lives in
`3cpd.exe`'s resident data — sized to one FDDI frame (4500 bytes).

### `rx_recv_conv.asm`  (two copies — current behaviour, unchanged)

Standard Crynwr AX=1 / AX=0 upcall into conventional `__far` rcvbuf.

---

## xms_rx_cfg_t layout  (from `include/xms_dma.h`)

```
offset  size  field
     0     1  version      XMS_CFG_VERSION (2); 1 = legacy, still accepted
     1     1  policy       xms_mem_policy_t
     2     2  slot_size    bytes per slot (CONV/COMMONBUF: the ring stride)
     4     4  phys0        bus physical address, slot 0 (CONV/COMMONBUF: ring base)
     8     4  lin0         XMS_COPY: 0; CONV/COMMONBUF: ring base as a real-mode
                           LINEAR (seg<<4, < 1 MB)
    12     4  phys1        bus physical address, slot 1 (XMS_COPY; unused by CONV)
    16     4  lin1         0 (reserved for VCPI/DPMI)
total  20 bytes
```

Must remain resident (not on the stack) for the lifetime of the DMA ring.
The `3cpd.exe` ISR reads `lin0`/`lin1` on every received frame.

---

## v2 ABI and validation (2026-09)

Changes from the Phase 2 code review (`docs/17` "Review fixes (2026-09)"):

**AH=F0 needs DMA.** The extension answers only while the bus-master path is
live (`g_use_dma`); on the PIO floor every sub-function returns CF=1
bad-command. VCPI/DPMI configure additionally needs the 386+ ring (QUERY only
advertises `XMS_CAP_VCPI`/`DPMI`/`RING` there).

**cfg version 2.** `XMS_CFG_VERSION` = 2, `XMS_CFG_VERSION_MIN` = 1. A v2
producer reserves `XMS_RX_DESC_BLOCK` (`RX_RING_N * 16` = 128 B) directly past
a CONV/COMMONBUF ring (pool = `RX_RING_N * slot_size + XMS_RX_DESC_BLOCK`), so
3cpd may relocate its RX descriptors there when a chipset NC fence is effective
(`docs/17` step 4b). v1 is still accepted but then 3cpd never relocates or
marks NC (a v1 pool has no room for the block). `dos-nvmeotcp` sends v2 and, on
`XMS_ERR_BAD_VERSION`, retries once as v1 (for an older 3cpd).

**Slot size.** QUERY always returns `DX = 1536` (`TX_SLOT_SZ`, a 32-byte
multiple) — the slot size/stride to use, not the max frame. CONFIGURE accepts
`1..1536`, and for CONV/COMMONBUF requires a **32-byte multiple**: the ISR
finds each slot's CPU segment as `lin >> 4` and reads it at offset 0, so every
slot must start on a paragraph (a 1514 stride put slots 1..7 mid-paragraph).

**`lin0` semantics.** For CONV/COMMONBUF, `lin0` is a 32-bit **real-mode
linear** address, `seg<<4` of the ring base (< 1 MB) — not a segment value and
not a protected-mode linear. For CONV (real mode, identity) `lin0 == phys0`;
for COMMONBUF (V86 + VDS lock) `phys0` is the VDS-reported bus address and
`lin0` is where the CPU reads the same bytes.

**Span checks (CONV/COMMONBUF).** With span = ring bytes (+ the descriptor
block for v2) — 2 slots on the 286 single-transfer path, `RX_RING_N` on the
386+ ring:

| Check | Error |
|-------|-------|
| `lin0` non-zero, 16-byte aligned, `lin0 + span − 1 < 1 MB` | `XMS_ERR_BAD_LIN` (0x07) |
| `phys0 + span − 1 < 16 MB` | `XMS_ERR_PHYS_RANGE` (0x03) |
| CONV: `lin0 == phys0` and not running under a V86 host | `XMS_ERR_BAD_LIN` (0x07) |

Error codes: `0x01 BAD_VERSION` (outside 1..2), `0x02 BAD_POLICY`,
`0x03 PHYS_RANGE`, `0x04 SLOT_SIZE`, `0x05 ALREADY_CFG`, `0x06 NOT_CFG`,
`0x07 BAD_LIN`.

---

## Ownership

| Responsibility | Owner |
|----------------|-------|
| Detect memory policy (VCPI/DPMI/XMS/CONV) | `nvmetsr.exe` cold phase |
| Allocate XMS EMBs | `nvmetsr.exe` |
| VDS lock → physical addresses | `nvmetsr.exe` |
| VCPI/DPMI page mapping → linear addresses | `nvmetsr.exe` |
| Allocate + fill `xms_rx_cfg_t` | `nvmetsr.exe` |
| QUERY + CONFIGURE calls | `nvmetsr.exe` install |
| Build ring descriptors + arm UP_LIST_PTR | `3cpd.exe` (on CONFIGURE) |
| Execute JIT receive fragment (ISR) | `3cpd.exe` |
| Cache invalidation after DMA | `3cpd.exe` ISR (per `dma.h` `cache_tier_t`) |
| RELEASE call | `nvmetsr.exe` unload |
| VDS unlock, VCPI/DPMI unmap, XMS free | `nvmetsr.exe` (after RELEASE) |

---

## Install sequence

```
nvmetsr.exe cold phase:
  1. Detect CPU tier (existing cpu_detect)
  2. Detect memory policy:
       If CPU ≥ 386: try VCPI → DPMI → XMS_COPY → CONVENTIONAL
       If CPU = 286: try XMS_COPY → CONVENTIONAL  (skip VCPI/DPMI)
       If CPU < 286: CONVENTIONAL (no XMS, no DMA)
  3. If policy != CONVENTIONAL:
       a. Allocate two XMS EMBs (slot_size each) via HIMEM.SYS XMS API
       b. XMS Lock both EMBs → pin physical positions
       c. VDS Lock both → phys0, phys1  (verify < 16 MB; the 3C515 is a
          first-party PCI-derived bus master with no 8237A 16-bit counter,
          so no 64K-crossing constraint applies — see commit b7ab981)
       d. If VCPI: INT 67h AX=DE05h × 2 → lin0, lin1
          If DPMI: INT 31h AX=0508h × 2 → lin0, lin1
          If XMS_COPY: lin0 = lin1 = 0
       e. Fill xms_rx_cfg_t
       f. INT 60h AH=F0h AL=00h → QUERY  (verify XMS_CAP_XMS_COPY set, slot_size ≤ DX)
       g. INT 60h AH=F0h AL=01h → CONFIGURE
  4. netif_init → nvt_connect → nvt_open_ioqueue → hook INT 13h → _dos_keep
```

## Unload sequence  (`nvmetsr /u`)

```
  1. INT 60h AH=F0h AL=02h → RELEASE  (stops DMA, clears UP_LIST_PTR)
  2. VDS Unlock both EMBs
  3. If VCPI/DPMI: unmap linear pages
  4. XMS Unlock + XMS Free both EMBs
  5. flush cache + close TCP connections
  6. INT 2Fh AX=E501h → restore INT 13h/INT 2Fh vectors
  7. _dos_freemem(psp_seg)
```

---

_Last updated: 2026-09-22 21:23 CEST — v2 cfg ABI (`XMS_RX_DESC_BLOCK`, v1
still accepted), QUERY slot size always 1536 + the 32-byte CONV/COMMONBUF
stride rule, `XMS_ERR_BAD_LIN` + span checks, `lin0` = real-mode linear, AH=F0
only available with DMA active, RELEASE restores the NC region. Prior:
2026-06-24 19:42 CEST — clarified that `CONV` is CPU-gated by ring *depth*, not
availability (a 286 runs `CONV` as a 2-slot single-transfer ring; only the deep `RX_RING_N=8`
`NEXT`-chained ring needs the 386+ ring-mode engine). Prior: 2026-06-13 20:49 CEST — scrubbed stale
"no 64K crossing" note from the cold-phase sequence (the 3C515 first-party bus master has no 8237A
counter wrap; cf. b7ab981)._
