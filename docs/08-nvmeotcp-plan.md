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

## Phase roadmap & status (2026-05-25)

| Phase | What | Status | Commit (dos-nvmeotcp) |
|-------|------|--------|------------------------|
| 1 | PDU codec (`nvmetcp.c/.h`): common header, ICReq/Resp, CapsuleCmd/Resp, C2H/H2C/R2T | **DONE** | `300406a` |
| 2.1 | Fabrics + admin command builders (Connect, Property Get/Set, Identify) | **DONE** | `6ff12a6` |
| 2.2 | Session layer + connect-to-ready (`nvmesess.c/.h`): framing, ICReq→Connect→CC enable→CSTS.RDY | **DONE** | `67527ba` |
| 2.3 | Identify Controller + Namespace; parse MDTS / NSZE / block size (via C2HData) | **DONE** | `f9fb852` |
| 3a | Multi-connection TCP (`TCP_NCONN=2`, `tcp_use`); open I/O queue (qid 1) as a 2nd TCP connection | **DONE** | `fa05bbb` |
| 3b | **NVM Read** on the I/O queue (opcode 0x02, SLBA/NLB in CDW10-12, transport SGL → C2HData) | **NEXT** | — |
| 3c | NVM Write (CapsuleCmd in-capsule or R2T → H2CData) | planned | — |
| 4 | Read-only block-device personality (INT 13h or similar) — mirrors the macOS Phase 1 | planned | — |
| 5 | Read/write + page cache (512 B DOS ↔ 4 KB NVMe) + keep-alive | planned | — |
| 6 | FDDI-sized MSS end-to-end (el3 large-frame TX + driver `/j` already done) | partial | — |

Harness/emulator side (`elink-qemu`): connect harness `tests/nvme-connect.sh` + threaded
spec-faithful target stub `tests/nvmetgt.py` (latest `b97cd3f`).

## How it's validated

- **Stub (default, NAS-independent):** `tests/nvmetgt.py` runs on the Mac; the QEMU guest reaches
  it at `10.0.2.2:4420` over slirp NAT. Drives the full bootstrap; serves one TCP connection per
  NVMe queue. Run: `python3 -u tests/nvmetgt.py & TARGET_IP=10.0.2.2 ./tests/nvme-connect.sh`.
- **Real SPDK (interop):** the QNAP NAS target — `192.168.25.100:4420`, NQN
  `nqn.2026-04.com.arqitekta.nas:spdk-e2e` (memory `nas-nvmetcp-target`). Usually down; bring up with
  `NAS_MGMT_HOST=192.168.25.100 nvmeof-macos/scripts/spdk-up.sh` (mgmt `.50.100` is unreachable; the
  data-fabric SSH `.25.100` works). Then `TARGET_IP=192.168.25.100 ./tests/nvme-connect.sh`. The full
  DOS→slirp→NAS TCP path is already proven (handshake reaches the real NAS).

Current green output: `NVME=READY` + `IDENT mdts=5 nsze=16384 blocksize=4096 capacity=64MB` + `IOQ=READY qid=1`.

## Gotchas banked

- **16-bit large-model stack overflow:** `nvt_connect` crashed because ~2.3 KB of PDU buffers lived
  on the stack and the packet-driver RX callback borrows the same stack. Big PDU/identify buffers must
  be `static`/file-scope.
- **DGROUP 64 KB cap:** the 4 × 16 KB per-connection TCP buffers must be `__far` or they overflow the
  near `_DATA` segment.
- **One TCP connection per NVMe queue** (spec): I/O cannot share the admin connection; hence `TCP_NCONN`.

## Next concrete step — Phase 3b (NVM Read)

On the I/O queue (`tcp_use(1)`): build an NVM Read SQE (opcode 0x02, NSID=1, SLBA in CDW10/11, NLB
in CDW12 (0-based), transport SGL), wrap in a CapsuleCmd, send; receive the block via C2HData into a
caller buffer; verify byte-for-byte against a known pattern written to the stub's backing store.
