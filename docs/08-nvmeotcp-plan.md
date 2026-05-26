# 08 — RetroSAN: DOS NVMe/TCP initiator roadmap & status

The north star: a native MS-DOS **NVMe-over-TCP initiator** that presents remote NVMe
storage as a DOS drive, over a 3Com NIC, using FDDI-sized (~4.5 KB) frames so that one
4 KB NVMe page + headers = one PDU = one TCP segment = one Ethernet frame.

This is a multi-repo initiative; this driver repo (`3com-pktdrv`) is the packet-driver
half. The plan below is the umbrella roadmap so any repo can see where the whole thing is.

## Repos

| Repo | Role |
|------|------|
| `~/Development/3com-pktdrv` | The 3Com packet driver (`3cpd.exe`) — the NIC half. Driver docs: `docs/00`–`07`. |
| `~/Development/dos-nvmeotcp` | The DOS NVMe/TCP **initiator**: TCP/IP stack (`tcpip.lib`) + NVMe codec/session + harness binaries. |
| `~/Development/elink-qemu` | QEMU fork with the el3 NIC device + test harnesses + the NVMe/TCP target stub. |
| `~/Development/nvmeof-macos` | macOS NVMe-oF TCP initiator — the spec-faithful reference the DOS codec is lifted from. |

Design docs: `dos-nvmeotcp/docs/nvmetcp-design.md` (the lift plan), and Claude memory
`project_dos_nvmetcp_design.md` / `project_nvmeotcp_goal.md`.

## Phase roadmap & status (2026-05-26)

| Phase | What | Status | Commit (dos-nvmeotcp) |
|-------|------|--------|------------------------|
| 1 | PDU codec (`nvmetcp.c/.h`): common header, ICReq/Resp, CapsuleCmd/Resp, C2H/H2C/R2T | **DONE** | `300406a` |
| 2.1 | Fabrics + admin command builders (Connect, Property Get/Set, Identify) | **DONE** | `6ff12a6` |
| 2.2 | Session layer + connect-to-ready (`nvmesess.c/.h`): framing, ICReq→Connect→CC enable→CSTS.RDY | **DONE** | `67527ba` |
| 2.3 | Identify Controller + Namespace; parse MDTS / NSZE / block size (via C2HData) | **DONE** | `f9fb852` |
| 3a | Multi-connection TCP (`TCP_NCONN=2`, `tcp_use`); open I/O queue (qid 1) as a 2nd TCP connection | **DONE** | `fa05bbb` |
| 3b | NVM Read on the I/O queue (opcode 0x02, SLBA/NLB in CDW10-12, transport SGL → C2HData) | **DONE** | `cf6b07f` |
| 3c | NVM Write (CapsuleCmd → R2T → H2CData → CapsuleResp) | **DONE** | `8a7e0cd` |
| 4 | Read-only block-device personality: `nvmecache` (4-slot direct-mapped 512 B↔4 KB cache, `__far` data) + `nvmedisk.exe` (interactive sector browser: `r <lba>`) | **DONE** | `fd80eb1` |
| 5 | Write-back cache (`nvmc_write_sector`, `nvmc_flush`, dirty eviction) + keep-alive (`nvt_keepalive` via `kbhit` loop) + `nvmedisk` write/flush commands | **DONE** | `8597b2b` |
| 6 | FDDI-sized MSS end-to-end: `TCP_MSS` 4096→4446, `memcpy`/`memmove` RX path, `io_maxh2cdata` stored + H2CData chunking | **DONE** | `77f66b0` |
| 7 | INT 13h TSR (`nvmetsr.exe`): hooks INT 13h + INT 2Fh (mux 0xE5), registers BIOS hard disk, `/u` unload | **DONE** | `f31cadf` |
| 8 | XMS buffer migration + memory-policy JIT fragments: move TCP/cache buffers out of load image → `LOADHIGH`-capable TSR | **PLANNED** | — |

Harness/emulator side (`elink-qemu`): connect harness `tests/nvme-connect.sh` + threaded
spec-faithful target stub `tests/nvmetgt.py` (latest `d67c91e`, includes NVM Read/Write
with in-memory backing store).

## How it's validated

- **Stub (default, NAS-independent):** `tests/nvmetgt.py` runs on the Mac; the QEMU guest reaches
  it at `10.0.2.2:4420` over slirp NAT. Drives the full bootstrap; serves one TCP connection per
  NVMe queue. Run: `python3 -u tests/nvmetgt.py & TARGET_IP=10.0.2.2 ./tests/nvme-connect.sh`.
- **Real SPDK (interop):** the QNAP NAS target — `192.168.25.100:4420`, NQN
  `nqn.2026-04.com.arqitekta.nas:spdk-e2e` (memory `nas-nvmetcp-target`). Usually down; bring up with
  `NAS_MGMT_HOST=192.168.25.100 nvmeof-macos/scripts/spdk-up.sh` (mgmt `.50.100` is unreachable; the
  data-fabric SSH `.25.100` works). Then `TARGET_IP=192.168.25.100 ./tests/nvme-connect.sh`. The full
  DOS→slirp→NAS TCP path is already proven (handshake reaches the real NAS).

Current green output (`nvmecon.exe`): `NVME=READY` + `IDENT mdts=5 nsze=16384 blocksize=4096 capacity=64MB` + `IOQ=READY qid=1` + `WRITE lba=0 OK` + `READ lba=0 got=4096: A0 A1 A2 ...`

`nvmedisk.exe` commands: `r <lba>` (hex+ASCII dump), `w <lba> <fill_hex>` (fill sector, cache dirty), `f` (flush all dirty), `q` (flush + disconnect).

`nvmetsr.exe` install output: `NVME=READY` + `IOQ=READY` + `GEOM: C=N H=255 S=63 total=N sectors` + `DRIVE: 0x81 (~D:)` + `TSR: resident (N paragraphs)`. Then `nvmetsr /u` to unload.

## Phase 8 — XMS buffer migration + memory-policy JIT (PLANNED)

### Problem

`nvmetsr.exe` TSR resident footprint is ~110 KB:

| Region | Size |
|--------|------|
| TCP RX buffers × 2 (`__far`, 16 KB each) | 32 KB |
| TCP TX rings × 2 (`__far`, 16 KB each) | 32 KB |
| NVMe page cache × 4 (`__far`, 4 KB each) | 16 KB |
| Code + DGROUP | ~30 KB |

Too large for `LOADHIGH` into a UMB (typical contiguous UMB ≤ 64 KB under EMM386).

### Architecture

The driver assumes V86 mode within a VMM implementing VDS (INT 4Bh). The cold-phase init
detects the memory environment and selects a policy; that policy drives JIT fragment
composition — no runtime branching in the resident hotpath.

**Memory policy hierarchy (detected once at install, baked into resident image):**

| Policy | Mechanism | RX copies | TX copies | TSR size |
|--------|-----------|-----------|-----------|----------|
| `MEM_VCPI` | XMS EMB + VCPI DE05h page mapping into V86 space | 0 | 0 | ~30 KB |
| `MEM_DPMI` | XMS EMB + DPMI 1.0 INT 31h AX=0508h page mapping | 0 | 0 | ~30 KB |
| `MEM_XMS_COPY` | XMS EMB + INT 15h AH=87h staging copy | 1 | 1 | ~30 KB |
| `MEM_CONVENTIONAL` | `__far` buffers in load image (current) | 2 | 2 | ~110 KB |

**Detection sequence (cold phase, in order):**

1. VCPI present? `INT 67h AX=DE00h` → `AL=0` → try `DE05h` page mapping
2. DPMI 1.0? `INT 2Fh AX=1687h` → `AX=0`, version ≥ 1.0 → try `INT 31h AX=0508h`
3. XMS present? `INT 2Fh AX=4300h` → `AL=80h` (HIMEM.SYS) → allocate EMB, VDS lock,
   verify physical < 16 MB (ISA DMA 24-bit limit), verify contiguous
4. Fallback → `MEM_CONVENTIONAL` (no XMS, or VDS lock failed)

**ISA DMA addressing note:** AT-class ISA DMA uses 24-bit physical addresses (8237A 16-bit
counter + 8-bit page register) — full 16 MB range. All realistic XMS on DOS machines is
below 16 MB, so 3C515 bus-master DMA can target XMS directly. VDS (INT 4Bh AX=8103h)
provides the locked physical address; write it into `UP_LIST_PTR` / `DOWN_LIST_PTR`.

**XMS shared between 3cpd.exe and nvmetsr.exe:**
`nvmetsr.exe` allocates and locks the XMS EMB, obtains the physical address via VDS, and
passes it to `3cpd.exe` via a custom INT 60h extension. `3cpd.exe` programs the 3C515 DMA
ring with that physical address. At unload: stop DMA → VDS unlock → VCPI/DPMI unmap →
XMS unlock → XMS free → restore vectors → freemem.

**Fragment palette extension in `3cpd.exe`:**

The memory policy adds a third JIT axis alongside CPU generation and DMA tier:

```
CPU frag  +  DMA/PIO frag  +  mem-policy frag
               └──── JIT compose at install ────┘
```

New receive fragments (`src/asm/frag/`):
- `rx_recv_vcpi.asm` — signal DMA-complete, data at VCPI-mapped linear addr (zero copy)
- `rx_recv_dpmi.asm` — same, via DPMI mapping
- `rx_recv_xms.asm`  — INT 15h AH=87h staging → XMS rcvbuf
- `rx_recv_conv.asm` — Crynwr upcall into conventional `__far` rcvbuf (current behaviour)

`3cpd.exe` owns the receive fragment and the memory-policy detection. `nvmetsr.exe`
consumes from wherever the fragment deposited data — it does not need to know which path
was taken.

**Zero-copy RX path (MEM_VCPI / MEM_DPMI):**

In V86 mode the VMM's page tables are live. VCPI `DE05h` (or DPMI `0508h`) maps the XMS
physical pages into an unused V86 linear address range (UMB holes). The mapped linear
address is stored as a `__far` pointer in resident state. The NIC DMA's into the physical
address; the CPU reads via the `__far` pointer. No INT 15h required — the copy disappears.

**Unload (`nvmetsr /u`) cleanup order:**
```
stop DMA → VDS unlock → VCPI/DPMI unmap → XMS unlock → XMS free
         → restore INT 13h/INT 2Fh vectors → _dos_freemem(psp_seg)
```

## Gotchas banked

- **16-bit large-model stack overflow:** `nvt_connect` crashed because ~2.3 KB of PDU buffers lived
  on the stack and the packet-driver RX callback borrows the same stack. Big PDU/identify buffers must
  be `static`/file-scope.
- **DGROUP 64 KB cap:** per-connection TCP buffers (4 × 16 KB) and cache data (4 × 4 KB) must be
  `__far` or they overflow the near `_DATA` segment. Use separate named `__far` objects + a
  `__far * const` pointer array — Watcom does not compose `__far` with 2D array syntax cleanly.
- **One TCP connection per NVMe queue** (spec): I/O cannot share the admin connection; hence `TCP_NCONN`.
- **`fgets` blocks keep-alive:** the interactive `nvmedisk` loop must use `kbhit()`/`getch()` so
  `tcp_pump()` and `nvt_keepalive()` can fire while waiting for keystrokes; `fgets` holds the CPU.
- **`io_maxh2cdata` per queue:** the I/O queue ICResp `MAXH2CDATA` is independent of the admin
  queue's. Storing only the admin value (and silently sending oversized H2CData on the I/O queue)
  would break targets with a tight per-PDU limit; store both separately in `nvt_conn`.

## Usage — nvmetsr.exe

```
nvmetsr [ip] [port]   install: connect + hook INT 13h + go resident
nvmetsr /u            unload:  flush cache + close TCP + restore vectors + free memory
```

**First-time setup (one-time):**
1. Add `nvmetsr 192.168.25.100 4420` to `AUTOEXEC.BAT` (before any programs that use the drive).
2. Reboot — DOS assigns a drive letter (e.g. `D:`) to the new BIOS hard disk at boot.
3. Run `FDISK` to create a primary partition, then `FORMAT D: /S` to lay down a FAT filesystem.
4. From then on, `DIR D:`, `COPY`, and all standard DOS file I/O work against the NVMe namespace.

**Direct access without a filesystem:** `DEBUG` can call INT 13h AH=02h/03h directly to read/write
raw 512-byte sectors as soon as the TSR is installed, before any partition or format step.

**INT 13h functions handled:**

| AH | Name | Notes |
|----|------|-------|
| 00h | Reset | flushes write-back cache |
| 02h | Read sectors | CHS addressing; loops via `nvmc_read_sector` |
| 03h | Write sectors | CHS addressing; loops via `nvmc_write_sector` (write-back) |
| 08h | Get drive params | reports 255H / 63S / nC geometry |
| 15h | Get disk type | returns 03h (fixed disk) + sector count |
| other | — | returns AH=01h invalid command |

Non-owned drive numbers are forwarded to the previous INT 13h handler unchanged.
