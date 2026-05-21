#!/bin/bash
# run_dosbox.sh [cputype] -- run build/3cpd.exe in headless dosbox-x and print its output.
#
# dosbox-x emulates an NE2000, not a 3C509, so the ID-port probe correctly reports "no
# card" here -- this harness validates the cold flow (entry, CPU detect, compose) and, once
# they land, the INT 60h handler / signature / install / TSR-keep. Real 3C509 RX/TX needs
# 86Box or hardware. cputype: 8086 (floor), 286, 386 (default), 486, pentium.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CPUTYPE="${1:-386}"
T="${TMPDIR:-/tmp}/3cpd-dosbox"
DOSBOX="$(command -v dosbox-x)"

[ -f "$ROOT/build/3cpd.exe" ] || { echo "build/3cpd.exe missing -- run wmake first"; exit 1; }
rm -rf "$T" && mkdir -p "$T"
cp "$ROOT/build/3cpd.exe" "$T/"

cat > "$T/dbx.conf" <<EOF
[sdl]
output=surface
[cpu]
cputype=$CPUTYPE
[autoexec]
mount c $T
c:
3cpd.exe > OUT.TXT
exit
EOF

SDL_VIDEODRIVER=dummy perl -e 'alarm 60; exec @ARGV' \
    "$DOSBOX" -conf "$T/dbx.conf" -nogui >"$T/dbx.log" 2>&1 || true

echo "--- 3cpd.exe output (cputype=$CPUTYPE) ---"
tr -d '\r' < "$T/OUT.TXT" 2>/dev/null || echo "(no output produced -- see $T/dbx.log)"
