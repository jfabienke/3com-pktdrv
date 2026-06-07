# 10 — INT 60h AH=0xF0 v2 extension (copybreak ABI)

This is the **single authoritative source** for the Phase 8b copybreak extension to the
proprietary `INT 60h AH=0xF0` XMS-DMA interface. Three mirrors must match it exactly:

- `include/xms_dma.inc` — NASM constants + struct offset/SIZE consts (the driver assembles against these)
- `include/xms_dma.h` — C reference mirror (same constants + packed structs)
- `../dos-nvmeotcp/src/xms.h` — the stack's C mirror (packed structs + build-breaking layout asserts)

`../dos-nvmeotcp/tools/abi_check.sh` compiles a dumper against both C headers, diffs them, and
cross-checks the NASM consts — run from the stack's `build.sh`, so any drift breaks the build.
The broader datapath design is `../dos-nvmeotcp/docs/copybreak-memory-design.md`.

**8b.0 status:** the ABI below is *defined*; sub-functions `0x03`–`0x06` are **stubbed** (the
driver returns `CF=1, DH=XMS_ERR_NOT_V2`) and the new caps are **not advertised** until the
implementing increment lands. v1 (`0x00`–`0x02`) behavior is unchanged.

## Sub-functions (AL)
| AL | Name | Args | Status |
|----|------|------|--------|
| 0x00 | QUERY | — → BX=caps, DX=max_slot | live (v1) |
| 0x01 | CONFIGURE | ES:DI → `xms_rx_cfg_t` (20 B, 2-slot) | live (v1) |
| 0x02 | RELEASE | — | live (v1) |
| 0x03 | RX_CONFIGURE2 | ES:DI → `xms_rx_cfg2_t` | stubbed (RX vertical) |
| 0x04 | TX_CONFIGURE | ES:DI → `xms_tx_cfg_t` | stubbed (TX vertical) |
| 0x05 | TX_SUBMIT | DX:CX=phys (hi:lo), BX=len | stubbed (TX vertical) |
| 0x06 | RX_REFILL | reserved free-ring doorbell | stubbed |

## Capability bits (BX from QUERY)
| Bit | Name | Status |
|-----|------|--------|
| 0x0001 | CONV_SINGLE | live |
| 0x0002 | CONV_RING | live |
| 0x0004 | — | **RESERVED/DEPRECATED** (was XMS_CAP_XMS_COPY) — never reuse |
| 0x0008 | RING | live |
| 0x0010 | — | **RESERVED** (was a stack-only XMS_CAP_SINGLE) — never reuse |
| 0x0020 | XMS_RING | live |
| 0x0040 | RX_DESC_V2 | new — advertised by the RX vertical only |
| 0x0080 | XMS_TX | new — advertised by the TX vertical only |

## Error codes (DH on CF=1)
`0x01` BAD_VERSION · `0x02` BAD_POLICY · `0x03` PHYS_RANGE · `0x04` SLOT_SIZE ·
`0x05` ALREADY_CFG · `0x06` NOT_CFG · `0x07` BAD_NSLOTS · `0x08` TX_NOT_CFG ·
`0x09` TX_RANGE · `0x0A` **NOT_V2** (v2 sub-function recognized but unimplemented in this build).
A genuinely-unknown AL returns the packet-driver `PD_ERR_BADCMD` (0x0B), distinct from NOT_V2.

## Wire structs (PINNED — little-endian; addresses are real-mode seg:off where the driver CPU-touches them)
The contract is the build-breaking compile-time asserts in `xms.h` + `abi_check.sh`, not implicit
packing; the C mirrors wrap these in `#pragma pack(1)`.

`xms_rx_cfg2_t` (ES:DI → RX_CONFIGURE2), **24 bytes**:
```
off w  field            notes
 0  1  version          = 2
 1  1  policy           CONV_RING(1) | XMS_RING(2)
 2  2  n_slots          2..RX_DMA_SLOTS (8)
 4  2  slot_size        <= QUERY DX
 6  2  compl_ring_n     completion ring entries (power of two)
 8  2  free_ring_n      free ring entries (power of two)
10  2  reserved         0
12  4  slots_lin        seg:off (hi16=seg, lo16=off) of xms_slot_desc_t[n_slots]
16  4  compl_ring_lin   seg:off of completion ring (xms_ring_hdr_t + xms_rx_compl_t[compl_ring_n])
20  4  free_ring_lin    seg:off of free ring       (xms_ring_hdr_t + xms_rx_free_t[free_ring_n])
```
```
xms_slot_desc_t: 0 u32 phys (<16MB, NIC-visible) ; 4 u32 lin (seg:off CPU alias, 0 if XMS-only) ; SIZE 8
xms_ring_hdr_t : 0 u16 head ; 2 u16 tail ; 4 u16 mask (n-1, pow2) ; 6 u16 rsv ; SIZE 8
xms_rx_compl_t : 0 u16 slot_id ; 2 u16 len ; 4 u16 status ; 6 u16 seq ; SIZE 8   (driver→stack)
xms_rx_free_t  : 0 u16 slot_id ; SIZE 2                                          (stack→driver)
xms_tx_cfg_t   : 0 u8 version(=1) ; 1 u8 flags(bit0=XMS) ; 2 u16 rsv ; 4 u32 pool_phys(<16MB) ; 8 u32 pool_len ; SIZE 12
```
TX_SUBMIT (0x05) is **register-only** (no wire struct): `DX:CX` = caller phys (hi:lo), `BX` = len.

Constants: `XMS_CFG2_VERSION=2`, `XMS_TX_CFG_VERSION=1`, `RX_DMA_SLOTS=8`, `TXSLOT_HEADROOM=128`.
