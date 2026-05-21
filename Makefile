# 3com-pktdrv -- fully-assembly build (NASM + wlink, no C, no C runtime).
#
#   wmake            build build/3cpd.exe (8088/5150 floor)
#   wmake clean
#
# The driver is one NASM object (src/asm/start.asm) linked to a DOS MZ .EXE. The hot-path
# fragment palette (src/asm/frag/*.asm) is assembled to raw bins by tools/mkfrag.py and
# embedded as data (build/frags_asm.inc) -- it is not linked directly. Profiles (minimal vs
# full) return once the >=286 cold phases + their fragments land; the floor is the default.

ASM    = nasm        # Netwide Assembler
LINK   = wlink       # Open Watcom linker
BUILD  = build
TARGET = $(BUILD)/3cpd.exe

# -f obj: 16-bit OMF for wlink. Includes resolve codegen.inc (include/) and the generated
# frags_asm.inc (build/). All sources declare `cpu 8086` -- the 5150 floor.
# DEFS: extra NASM -d defines (e.g. the `fakenic` target sets -dCFG_FAKENIC).
DEFS   =
AFLAGS = -f obj -iinclude/ -i$(BUILD)/ -isrc/asm/ $(DEFS)

# Hot-path fragment palette (assembled to bins + embedded by mkfrag.py, not linked).
FRAG_SRC = &
    src/asm/frag/api.asm &
    src/asm/frag/isr_entry.asm &
    src/asm/frag/isr_eoi.asm &
    src/asm/frag/rx_pio.asm &
    src/asm/frag/tx_pio.asm

# ---- targets ----

all: .SYMBOLIC $(TARGET)

$(BUILD)/frags_asm.inc : tools/mkfrag.py $(FRAG_SRC)
    python3 tools/mkfrag.py

$(BUILD)/start.obj : src/asm/start.asm src/asm/el3_probe.asm src/asm/el3_init.asm &
                     src/asm/resident.asm src/asm/isr.asm src/asm/install.asm &
                     include/codegen.inc include/el3_tomahawk.inc include/el3_core.inc &
                     $(BUILD)/frags_asm.inc
    $(ASM) $(AFLAGS) src/asm/start.asm -o $@

$(TARGET) : $(BUILD)/start.obj 3cpd.lnk
    $(LINK) @3cpd.lnk

# fakenic: test build that skips the probe (no emulator has a 3C509) so the install +
# resident handler are exercisable in dosbox-x. Forces a recompile with -dCFG_FAKENIC.
fakenic: .SYMBOLIC
    @if exist $(BUILD)\start.obj del $(BUILD)\start.obj
    $(MAKE) DEFS=-dCFG_FAKENIC all

# debug: instrumented build for out-of-house HARDWARE testing -- verbose cold trace, the
# resident event log, the video heartbeat, get_statistics, and the 0x7F debug block.
debug: .SYMBOLIC
    @if exist $(BUILD)\start.obj del $(BUILD)\start.obj
    $(MAKE) DEFS=-dCFG_DEBUG all

# debugfake: debug instrumentation + fake NIC, so the whole thing is exercisable in dosbox-x.
debugfake: .SYMBOLIC
    @if exist $(BUILD)\start.obj del $(BUILD)\start.obj
    $(MAKE) DEFS="-dCFG_DEBUG -dCFG_FAKENIC" all

clean: .SYMBOLIC
    @if exist $(BUILD)\*.obj del $(BUILD)\*.obj
    @if exist $(BUILD)\*.bin del $(BUILD)\*.bin
    @if exist $(BUILD)\frags_asm.inc del $(BUILD)\frags_asm.inc
    @if exist $(TARGET) del $(TARGET)
    @if exist $(BUILD)\3cpd.map del $(BUILD)\3cpd.map
