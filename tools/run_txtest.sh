#!/bin/bash
# run_txtest.sh -- raw-frame harness for Phase 8b.2a (TX_CONFIGURE / TX_SUBMIT).
#
# Boots FreeDOS under QEMU with a 3C515 (el3), loads the floor driver with /5 /d (so g_use_dma=1),
# and runs txtest.com. Verifies from the serial log that QUERY advertises XMS_TX, TX_CONFIGURE is
# accepted, a valid TX_SUBMIT completes, and the range/size rejects return the right DH; and from a
# packet capture that the magic payload actually egressed -- i.e. the card DMA'd from the submitted
# caller phys (not the resident tx_slots). Needs the same QEMU+builder image as tools/run_matrix.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
QEMU="${QEMU:-$HOME/Development/qemu/build/qemu-system-i386-unsigned}"
BUILDER_IMG="${BUILDER_IMG:-$HOME/Development/pnpmgr/qemu/builder.img}"
DEV515="-device 3c515,netdev=n1,iobase=0x300,irq=10,linkspeed=100,realtiming=on"
TIMEOUT="${QEMU_TIMEOUT:-120}"

[ -x "$QEMU" ]        || { echo "qemu not found: $QEMU"; exit 1; }
[ -f "$BUILDER_IMG" ] || { echo "builder image not found: $BUILDER_IMG"; exit 1; }

# Build the floor driver (real el3 probe -- NOT fakenic) + the harness.
wmake >/dev/null 2>&1 || { echo "wmake failed"; exit 1; }
nasm -f bin tools/txtest.asm -o build/txtest.com

W="${TMPDIR:-/tmp}/3cpd-txtest"; rm -rf "$W"; mkdir -p "$W/mnt"
RAW="$W/builder.raw"; SER="$W/serial.txt"; PCAP="$W/tx.pcap"
qemu-img convert -O raw "$BUILDER_IMG" "$RAW" 2>/dev/null

MT="$W/mtoolsrc"; printf 'drive z: file="%s" partition=1\n' "$RAW" > "$MT"; export MTOOLSRC="$MT"
mtype z:/fdconfig.sys | sed 's/MENUDEFAULT=[0-9],[0-9]*/MENUDEFAULT=2,2/' > "$W/FDCONFIG.SYS"
mcopy -o "$W/FDCONFIG.SYS" z:/FDCONFIG.SYS 2>/dev/null
printf '@ECHO OFF\r\nSET PATH=C:\\FreeDOS\\BIN\r\nCTTY COM1\r\nECHO TXTEST-START\r\nCALL D:\\GO.BAT\r\nECHO TXTEST-END\r\nFDAPM POWEROFF\r\n' > "$W/FDAUTO.BAT"
mcopy -o "$W/FDAUTO.BAT" z:/FDAUTO.BAT 2>/dev/null

{ printf '@ECHO OFF\r\n'
  printf 'D:\\3cpd.exe /b=300 /q=10 /5 /d\r\n'
  printf 'D:\\txtest.com\r\n'
  printf 'ECHO ===TXTEST-GO-DONE===\r\n'
} > "$W/mnt/GO.BAT"
cp build/3cpd.exe build/txtest.com "$W/mnt/"

"$QEMU" -cpu pentium -m 64M \
    -hda "$RAW" \
    -drive file=fat:rw:"$W/mnt",format=raw,index=1,media=disk \
    $DEV515 \
    -netdev user,id=n1 \
    -object filter-dump,id=fd,netdev=n1,file="$PCAP" \
    -serial file:"$SER" \
    -display none -no-reboot -boot c >/dev/null 2>/dev/null &
QPID=$!
( sleep "$TIMEOUT" && kill -9 "$QPID" 2>/dev/null ) & KPID=$!
wait "$QPID" 2>/dev/null || true
kill "$KPID" 2>/dev/null || true

S=$(tr -d '\r' < "$SER" 2>/dev/null || true)
echo "── txtest serial ──"
echo "$S" | grep -E '^CAPS=|^CFG |^SUB|^OOR|^BIG|^TXTEST-DONE|No packet driver' || echo "(no txtest output -- see $SER)"

echo "── checks ──"
fail=0
chk() { if echo "$S" | grep -qE "$2"; then echo "  PASS  $1"; else echo "  FAIL  $1"; fail=1; fi; }
chk "QUERY advertises XMS_TX"        'XMSTX=1'
chk "TX_CONFIGURE accepted"          'CFG CF=0'
chk "valid TX_SUBMIT completes"      'SUB\(valid\) CF=0'
chk "out-of-pool rejected DH=09"     'OOR.* DH=09'
chk "oversized rejected DH=04"       'BIG.* DH=04'
# Wire proof: the magic payload egressed -> the card DMA'd from the submitted caller phys.
if [ -f "$PCAP" ] && grep -aq 'TXOKtxtest-8b2a-magic' "$PCAP"; then
    echo "  PASS  magic payload egressed (DMA read from submitted phys)"
else
    echo "  FAIL  magic payload NOT found in capture ($PCAP)"; fail=1
fi

[ "$fail" = 0 ] && echo "run_txtest: ALL PASS" || { echo "run_txtest: FAIL"; exit 1; }
