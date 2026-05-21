#!/bin/bash
# run_pkttest.sh -- build the fake-NIC TSR + the pkttest probe, then install and query the
# resident driver in headless dosbox-x. Validates the INT 60h handler / signature / dispatch
# / install / TSR-keep without needing a real 3C509 (no emulator has one). For real RX/TX,
# use hardware.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOSBOX="$(command -v dosbox-x)"
cd "$ROOT"

wmake fakenic >/dev/null 2>&1 || { echo "wmake fakenic failed"; exit 1; }
nasm -f bin tools/pkttest.asm -o build/pkttest.com

T="${TMPDIR:-/tmp}/3cpd-pkttest"
rm -rf "$T" && mkdir -p "$T"
cp build/3cpd.exe build/pkttest.com "$T/"

cat > "$T/dbx.conf" <<EOF
[sdl]
output=surface
[cpu]
cputype=386
[autoexec]
mount c $T
c:
echo --- install --- > OUT.TXT
3cpd.exe >> OUT.TXT
echo --- query --- >> OUT.TXT
pkttest.com >> OUT.TXT
exit
EOF

SDL_VIDEODRIVER=dummy perl -e 'alarm 60; exec @ARGV' \
    "$DOSBOX" -conf "$T/dbx.conf" -nogui >"$T/dbx.log" 2>&1 || true

echo "--- 3cpd install + pkttest query (dosbox-x, fake NIC) ---"
tr -d '\r' < "$T/OUT.TXT" 2>/dev/null || echo "(no output -- see $T/dbx.log)"
