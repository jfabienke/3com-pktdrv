# 3com-pktdrv — Open Watcom build (wmake)
#
# Profiles:
#   wmake minimal   8088/5150 floor: 3C509B PIO, conventional memory (smallest image)
#   wmake full      everything: ISA+PCI, PIO+DMA, XMS, all generations
#   wmake clean
#
# Small memory model (-ms): one 64KB code + one 64KB data segment. Resident is the
# JIT-emitted hot image (copied down); cold init/composer is reclaimed after install.

CC      = wcc       # Open Watcom C V2
ASM     = nasm      # Netwide Assembler (NASM)
LINK    = wlink     # Open Watcom linker
BUILD   = build
TARGET  = $(BUILD)/3cpd.exe

# 8088-safe, small model. -0 = 8088 codegen (mandatory floor for all compiled code).
#   -ms small model  -0 8088  -os size-opt  -zq quiet  -zp1 pack
# NOTE: cold/init C runs SS==DS (no -zu). The resident hot path is JIT-emitted asm that
# manages its own stack; any future resident C would be compiled separately with -zu.
CFLAGS_BASE = -ms -0 -os -zq -zp1 -wcd=201 -Iinclude -fr=$(BUILD)/
# NASM -> 16-bit OMF for wlink. Per-file `CPU 8086`/`CPU 386` directives gate ISA usage;
# floor/fragment sources MUST declare `CPU 8086`. Fragment palette also builds raw bins
# (-f bin) embedded for the JIT composer (added when the palette lands).
AFLAGS_BASE = -f obj -iinclude/

# Profile selection sets feature macros; cold support for higher tiers is compiled out
# of the minimal image.
!ifdef MINIMAL
CFLAGS = $(CFLAGS_BASE) -DCFG_FLOOR
!else
CFLAGS = $(CFLAGS_BASE) -DCFG_FULL
!endif
AFLAGS = $(AFLAGS_BASE)

# ---- object groups (residency is decided by segment class, see 3cpd.lnk) ----

# HOT: the runtime support that the emitted datapath calls into. Stays resident.
HOT_OBJS = &
    $(BUILD)/api.obj &
    $(BUILD)/packet.obj &
    $(BUILD)/hal.obj

# CODEGEN: the composer + fragment library + copy-down. COLD (runs once, reclaimed),
# but emits the resident hot image.  (copy_down currently lives in compose.c)
CG_OBJS = &
    $(BUILD)/compose.obj &
    $(BUILD)/frag_pio.obj

# COLD: detection, init. Reclaimed after copy-down. (Trimmed to the floor milestone set;
# config/platform/unwind/memory/buffers/eeprom land as the ladder is climbed.)
COLD_OBJS = &
    $(BUILD)/main.obj &
    $(BUILD)/el3_core.obj &
    $(BUILD)/el3_isa.obj

# Full-profile-only cold support (excluded by the minimal profile).
FULL_OBJS = &
    $(BUILD)/el3_pci.obj &
    $(BUILD)/pci_bios.obj &
    $(BUILD)/pci_ids.obj &
    $(BUILD)/xms.obj &
    $(BUILD)/dma_policy.obj &
    $(BUILD)/busmaster_test.obj &
    $(BUILD)/cache.obj &
    $(BUILD)/vds.obj

# ASM (cpu detect, IRQ entry, PIO primitives that feed the fragment palette)
ASM_OBJS = &
    $(BUILD)/cpu_detect.obj &
    $(BUILD)/nic_irq.obj

!ifdef MINIMAL
ALL_OBJS = $(HOT_OBJS) $(CG_OBJS) $(COLD_OBJS) $(ASM_OBJS)
!else
ALL_OBJS = $(HOT_OBJS) $(CG_OBJS) $(COLD_OBJS) $(FULL_OBJS) $(ASM_OBJS)
!endif

# ---- targets ----

minimal: .SYMBOLIC
    @set MINIMAL=1
    $(MAKE) MINIMAL=1 $(TARGET)

full: .SYMBOLIC
    $(MAKE) $(TARGET)

$(TARGET): $(ALL_OBJS) 3cpd.lnk
    $(LINK) @3cpd.lnk

# pattern rules (sources resolved across src/* via wmake search below)
.c.obj:
    $(CC) $(CFLAGS) -fo=$@ $<

.asm.obj:
    $(ASM) $(AFLAGS) $< -o $@

clean: .SYMBOLIC
    @if exist $(BUILD)\*.obj del $(BUILD)\*.obj
    @if exist $(TARGET) del $(TARGET)
    @if exist $(BUILD)\3cpd.map del $(BUILD)\3cpd.map

# wmake source search paths
.c:   src/core;src/hw;src/dma;src/mem;src/init;src/codegen;src/loader
.asm: src/asm
