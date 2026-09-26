#!/bin/bash
# build.sh <isapnptools-checkout> <outdir> -- real-mode DOS pnpdump.exe + isapnp.exe (Open Watcom, large model,
# 8086 code) from upstream isapnptools (GPL-2.0, https://github.com/retroprom/isapnptools), with the shims here:
# config.h (Watcom port I/O + DOS), shim.c (usleep via ~1 us ISA reads of port 0x80, getopt_long), getopt.h.
# ISA PnP diagnostics for a PnP card on a machine with no PnP BIOS (e.g. a 3C515 in an IBM PC/AT): pnpdump
# isolates and lists every card, isapnp configures + activates one from a config file.
set -e
SRC="$(cd "$1" && pwd)"; OUT="$(mkdir -p "$2" && cd "$2" && pwd)"; HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$SRC/ow" && cp "$HERE"/config.h "$HERE"/shim.c "$HERE"/getopt.h "$SRC/ow/"
cd "$SRC/src"
COMMON="callbacks.c cardinfo.c iopl.c mysnprtf.c pnp-access.c pnp-select.c realtime.c release.c res-access.c resource.c ../ow/shim.c"
FLAGS="-bcl=dos -ml -0 -q -zq -DHAVE_CONFIG_H -i=../ow -i=../include"
wcl $FLAGS -fe="$OUT/pnpdump.exe" pnpdump.c pnpdump_main.c $COMMON
wcl $FLAGS -fe="$OUT/isapnp.exe" isapnp.c isapnp_main.c $COMMON
rm -f *.obj
cp "$SRC/COPYING" "$OUT/COPYING.isapnptools"
echo "built $OUT/pnpdump.exe $OUT/isapnp.exe"
