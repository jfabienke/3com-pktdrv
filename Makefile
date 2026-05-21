# 3com-pktdrv — Open Watcom build (wmake)
#
# Profiles:
#   wmake minimal   8088/5150 floor: 3C509B PIO, conventional memory (smallest image)
#   wmake full      everything: ISA+PCI, PIO+DMA, XMS, all generations
#   wmake clean
#
# Small memory model (-ms): one 64KB code + one 64KB data segment. Resident is the
# JIT-emitted hot image (copied down); cold init/composer is reclaimed after install.

CC      = wcc
ASM     = wasm
LINK    = wlink
BUILD   = build
TARGET  = $(BUILD)/3cpd.exe

# 8088-safe, small model. -0 = 8088 codegen (mandatory floor for all compiled code).
#   -ms small model  -0 8088  -os size-opt  -zq quiet  -zp1 pack  -zu SS!=DS for TSR
CFLAGS_BASE = -ms -0 -os -zq -zp1 -zu -wcd=201 -Iinclude -fr=$(BUILD)/
AFLAGS_BASE = -0 -mt -zq

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
# but emits the resident hot image.
CG_OBJS = &
    $(BUILD)/compose.obj &
    $(BUILD)/relocate.obj &
    $(BUILD)/frag_pio.obj

# COLD: detection, test, memory, boot. Reclaimed after copy-down.
COLD_OBJS = &
    $(BUILD)/main.obj &
    $(BUILD)/boot.obj &
    $(BUILD)/config.obj &
    $(BUILD)/platform.obj &
    $(BUILD)/unwind.obj &
    $(BUILD)/el3_core.obj &
    $(BUILD)/el3_isa.obj &
    $(BUILD)/el3_eeprom.obj &
    $(BUILD)/memory.obj &
    $(BUILD)/buffers.obj

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
    $(ASM) $(AFLAGS) -fo=$@ $<

clean: .SYMBOLIC
    @if exist $(BUILD)\*.obj del $(BUILD)\*.obj
    @if exist $(TARGET) del $(TARGET)
    @if exist $(BUILD)\3cpd.map del $(BUILD)\3cpd.map

# wmake source search paths
.c:   src/core;src/hw;src/dma;src/mem;src/init;src/codegen;src/loader
.asm: src/asm
