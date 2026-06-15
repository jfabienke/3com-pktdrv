# 14 — Bus detection & enumeration (lift from cache-kit)

The detailed plan behind `07`'s Tier A′ `CK_IO.C`/`CK_ENUM.C` rows and the "Bus probers" table.
cache-kit already implements — on our exact Open Watcom v2 cross-toolchain — the bus *presence*
probes and per-bus *enumeration* walks we'd otherwise write from scratch. We lift the protocols and
adapt them: cache-kit builds a general device inventory; **we filter for EtherLink III and fill
`nic_info_t`.**

## Two passes, decoupled — and only `CK_IO` is shared

cache-kit separates three concerns; we keep the same separation:

```
   1. bus PRESENCE       cheap one-shot: "is there an MCA / PCI / EISA bus?"     (CK_IO)
   2. per-bus EL3 PROBE  walk the present buses; first EtherLink III → nic_info_t
   3. chipset/cache probe  SEPARATE pass (docs/13) — coherency, NC, write-mode
```

Passes 2 and 3 are independent and share only **`CK_IO`'s low-level primitives** — the
32-bit-port-in-16-bit idiom (`.386; in eax,dx`), the legacy index/data ports (0x22/0x23, OPTi
0x22/0x24, VIA 0xA8/0xA9), and the **floating-bus guards** (`safe_port_probe` reads a port twice and
rejects on disagreement; `legacy_port_valid` rejects all-`0xFF`). Lifting `CK_IO` once serves both
the bus probers here and the chipset detection in `12`/`13`.

## What we lift — and what we drop

| Lift (adapted) | Drop |
|----------------|------|
| `CK_IO` presence probes + floating-bus guards | the `g_devices[64]` inventory + the TUI display |
| `enum_mca_devices()` → `bus_mca.c` | the ~50/150/45-entry vendor ID databases (keep a tiny EL3-only table) |
| `enum_eisa_devices()` + `decode_eisa_vendor()` → `bus_eisa.c` | **PCIe capability scan + ACPI/MCFG walk** (scope call below) |
| `enum_isapnp_devices()` + `isapnp_isolate()` → `bus_isa.c` | |
| `enum_pci_devices()` + `pci_make_address()` → `bus_pci.c` | |

**The filter-for-EL3 adaptation:** each walk short-circuits on a 3Com / EtherLink III match and fills
`nic_info_t { type, bus, io_base, irq, caps }` — no inventory of non-EL3 devices, no resolved-name
strings. The fiddly *enumeration protocol* is the value; the device-table plumbing isn't.

**Bus-constant remap:** cache-kit's `BUS_PCI=1/PCIE=2/MCA=3/EISA=4/ISAPNP=5` map onto our
`bus_type_t` (`hardware.h`: `ISA8/ISA16/EISA/MCA/PCMCIA16/PCI/CardBus`). The lift normalizes to *our*
enum — and CardBus is detected as PCI-class then refined; PCIE is dropped.

## Per-bus protocol notes (carry near-verbatim)

These are the load-bearing, error-prone bits — don't re-derive them.

**MCA** — presence: `INT 15h AH=C0h` → POST config table in ES:BX, test **feature byte 1 (off 0x05)
bit 1**. Enumerate 8 slots: select POS via **port `0x96`** (`MCA_ADAPTER_SETUP`, **bit 3 set**) — *not*
`0x94`, which is the *system-board* setup register — read the 2-byte adapter ID + 8 POS bytes from
`0x100–0x107`, IRQ from **POS[5] bits [3:1]**. The whole select+read runs inside `_disable()/_enable()`
so an interrupt can't strand a foreign slot on the POS bus, then deselect (`outp(0x96, 0)`).

**PCI** — presence: config mechanism #1 — write the enable bit to `0xCF8` for 0:0:0, read `0xCFC`;
all-ones/all-zero vendor → no host bridge. Address: `0x80000000 | bus<<16 | dev<<11 | func<<8 |
(reg & 0xFC)`. Walk 256×32×8 with **multifunction pruning**: read header-type (`0x0E`) at function 0;
if bit 7 clear, skip funcs 1–7 (avoids ghost-function aliasing). Vendor/device at `0x00`,
class/subclass at `0x08`, IRQ at `0x3C`. **CardBus = PCI-class config** — same path.

**EISA** — presence: literal `"EISA"` at `F000:FFD9`. Walk slots 1–15; ID space at `0x?C80` =
`EISA_ID_OFFSET + (slot << 12)` (slot 1 = `0x1C80` … slot 15 = `0xFC80`); read the 4-byte compressed
ID under `_disable()/_enable()`. **Compressed-ID decode** (`decode_eisa_vendor`): 3 letters packed
5-bits-each, biased by `'@'` — computed at runtime, not table-matched:

```c
v[0] = ((b0 >> 2) & 0x1F) + '@';
v[1] = (((b0 & 0x03) << 3) | ((b1 >> 5) & 0x07)) + '@';
v[2] = (b1 & 0x1F) + '@';
```

**ISA-PnP** — the most involved path; lift the whole isolation state machine over ports `0x279`
(addr), `0xA79` (write), and a discovered read port (`0x203–0x3F3`):

1. **Initiation key** — send two zeros then the 32-byte LFSR sequence (seed `0x6A`).
2. **Read-port discovery** — probe candidates in steps of `0x10`; require two consecutive status
   reads to agree and not be `0xFF`.
3. **Serial isolation** — the 72-bit bit-banged tournament: per bit, read twice — `0x55/0xAA` = 1,
   `0xFF/0xFF` = no card; maintain the LFSR checksum and **validate against serial byte 8 before
   assigning a CSN** (bad checksum → discard — glitch protection).
4. **Resource parse** — wake each CSN, walk small/large resource tags for the first IRQ + I/O base.
5. **Timing** — `isapnp_delay()` burns the spec's inter-read delay with dummy reads of port `0x80`,
   not the timer (no system-state disturbance).

> The EL3 **legacy ID-port** activation (the LFSR at `0x110`) is EtherLink-III-specific and already
> lives in `isapnp.asm`; cache-kit's isolation covers the *generic ISA-PnP* mode alongside it. So
> `bus_isa.c` carries both: legacy ID-port for non-PnP 3C509, ISA-PnP isolation for PnP-mode cards.

## Probe order

Cheapest/most-specific first, gated on presence (cache-kit front-loads this in its registry array
order; we mirror it as bus gating):

```
   MCA presence (INT 15h)  →  PCI (mechanism-1)  →  EISA (sig)  →  ISA-PnP / legacy ID-port
        walk only the buses that are present; first EtherLink III wins
```

## Scope calls (confirmed)

- **Skip PCIe / MCFG.** The EL3 lineage tops out at **Tornado (PCI/CardBus)** — no EL3 part is
  PCIe, CardBus is PCI-class config, and the real-mode >1 MB ceiling makes MCFG best-effort anyway.
- **Filter for EL3, no inventory.** We carry the walks + protocols, not `g_devices[64]`, the big ID
  tables, or the TUI.

## The gap cache-kit doesn't fill

**PCMCIA-16 (3C589)** has no cache-kit equivalent — it stays on the old repo's Card Services / CIS
path (`07`, Tier B, larger lift). So cache-kit covers **5 of the 6 buses**; PCMCIA is separate.

## Status & relationship

- Detailed plan for `07`'s Tier A′ `CK_IO`/`CK_ENUM` rows + the bus-prober table; feeds `03`
  (HAL + bus probers). Shares `CK_IO` with `12`/`13` (chipset/NC/coherency); PCMCIA-16 is the one
  bus from the old repo.
- All `full`-profile (≥386) except the ISA8 floor's plain 3C509 ID-port path.
- Not yet implemented; lands with the bus-prober milestone (`07` order step 6).

---

_Last updated: 2026-06-15 17:13 CEST._
