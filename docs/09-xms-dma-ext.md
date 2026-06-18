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

_Last updated: 2026-06-18 17:12 CEST — CONV ring deepened 2 → `RX_RING_N` (8) slots._

Ring **depth** and **layout** depend on the memory policy:

- **`XMS_COPY` / VCPI / DPMI** — two explicit slots (`phys0`/`phys1`), each a
  separate XMS EMB. The caller hands both slot addresses; the descriptors are
  not contiguous.
- **`XMS_POLICY_CONV`** — one *contiguous* block of `RX_RING_N` slots. The
  caller passes only `phys0` (the block base); slot _i_ lives at
  `phys0 + i·slot_size`, and `3cpd.exe` builds every descriptor from that base.
  A 2-slot ping-pong overruns under a windowed RX flood (a window of 4 collapsed
  the old 2-slot CONV ring to ~0.14 Mbit/s); the deep ring absorbs the burst
  (window 4 → 16.8 Mbit/s on a 386-class cell, `dropped=0`; the bus ceiling
  ~48 Mbit/s on a Pentium, `dropped=0`).

| CPU | RX DMA mode | depth | `EL3_DESC_NEXT` |
|-----|-------------|-------|-----------------|
| 286 | Single-transfer | 2 | 0 (no chain) — ISR re-arms immediately after each completion |
| 386+ `XMS_COPY` | Ring | 2 | → descriptor 1 / → descriptor 0 (circular) — NIC auto-advances |
| 386+ `CONV` | Ring | `RX_RING_N` (8) | → next descriptor (circular over all N) — NIC auto-advances |

**Single-transfer ping-pong (286):** on completion the ISR immediately arms
the *other* slot and kicks `START_DMA_UP` before processing the current frame,
minimising the gap during which a new frame could be dropped. (A 286 `CONV`
ring also uses 2 single-transfer slots, both carved from the contiguous base —
the deep ring requires the 386+ ring-mode engine.)

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

All three sub-functions follow the Crynwr error convention: CF=0 success,
CF=1 error with DH = error code (`XMS_ERR_*` from `xms_dma.h`).

### AL=0x00 — Query XMS DMA capabilities

```
In:   AH = XMS_DMA_FUNC   (0xF0)
      AL = XMS_DMA_QUERY   (0x00)

Out (CF=0):
      BX = capability flags  (XMS_CAP_* bitmask)
      DX = maximum slot_size in bytes  (TX_SLOT_SZ; 4500 with FDDI)

Out (CF=1):  extension not supported — fall back to MEM_CONVENTIONAL
```

`nvmetsr.exe` calls this before allocating any XMS. An old `3cpd.exe` that
does not implement `0xF0` returns CF=1 from its dispatcher (bad-command), and
the caller silently takes the conventional path.

### AL=0x01 — Configure XMS DMA receive ring

```
In:   AH = XMS_DMA_FUNC      (0xF0)
      AL = XMS_DMA_CONFIGURE  (0x01)
      ES:DI → xms_rx_cfg_t   (caller-allocated, must stay resident)

Out (CF=0):  ring programmed, UP_LIST_PTR armed, DMA running
Out (CF=1):  DH = XMS_ERR_*  (ring not started; caller may retry or fall back)
```

`3cpd.exe` validation steps:

1. `cfg.version == XMS_CFG_VERSION` (1)
2. `cfg.policy` in `[XMS_POLICY_VCPI, XMS_POLICY_XMS_COPY]`
3. `cfg.phys0` and `cfg.phys1` both `< DMA_ISA_16M_LIMIT` (0x1000000) — ISA
   bus-master 24-bit addressing limit
4. `cfg.slot_size ≤ TX_SLOT_SZ`

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
pointer to halt the RX engine. The resident config pointer is cleared. After
this call, the ring descriptors and the caller's `xms_rx_cfg_t` are dead and
the XMS buffers may be freed.

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
     0     1  version      must be XMS_CFG_VERSION (1)
     1     1  policy       xms_mem_policy_t
     2     2  slot_size    bytes per slot
     4     4  phys0        VDS physical address, slot 0
     8     4  lin0         VCPI/DPMI linear address, slot 0  (0 = XMS_COPY)
    12     4  phys1        VDS physical address, slot 1
    16     4  lin1         VCPI/DPMI linear address, slot 1  (0 = XMS_COPY)
total  20 bytes
```

Must remain resident (not on the stack) for the lifetime of the DMA ring.
The `3cpd.exe` ISR reads `lin0`/`lin1` on every received frame.

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

_Last updated: 2026-06-13 20:49 CEST — scrubbed stale "no 64K crossing" note from the
cold-phase sequence (the 3C515 first-party bus master has no 8237A counter wrap; cf. b7ab981)._
