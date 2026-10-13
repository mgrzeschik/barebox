#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# flash-barebox-from-linux.sh [-n] IMAGE
#
# Run this ON THE DOCKSTAR / ICONNECT under Linux to replace the
# bootloader in NAND with barebox. Needs mtd-utils (flash_erase,
# nandwrite, nanddump).
#
#   -n   dry run: do all checks, write nothing
#
# The script refuses to write unless:
#   * IMAGE is a Kirkwood kwbimage v0 for NAND boot
#   * /dev/mtd0 starts at NAND offset 0, is writable and large enough
# After writing, the data is read back and compared.

set -e

dry=0
if [ "$1" = "-n" ]; then
	dry=1
	shift
fi

img="$1"
mtd=mtd0
dev=/dev/$mtd

die() {
	echo "ERROR: $*" >&2
	exit 1
}

[ -n "$img" ] || die "usage: $0 [-n] barebox-<board>.img"
[ -f "$img" ] || die "$img not found"

for tool in flash_erase nandwrite nanddump od cmp; do
	command -v $tool >/dev/null 2>&1 || die "$tool missing (install mtd-utils)"
done

byte() {
	od -An -tx1 -j "$2" -N1 "$1" | tr -d ' \n'
}

# --- image checks -----------------------------------------------------------
src=$(byte "$img" 0)
[ "$src" = "8b" ] || die "$img is not a NAND kwbimage (boot source $src, want 8b)"
[ "$(byte "$img" 8)" = "00" ] || die "$img has header version $(byte "$img" 8), Kirkwood needs 0"
magic=$(dd if="$img" bs=1 skip=$((0x220)) count=7 2>/dev/null)
[ "$magic" = "barebox" ] || die "$img does not contain barebox"
size=$(wc -c < "$img")
echo "image: $img, $size bytes, kwbimage v0 for NAND"

# --- mtd checks -------------------------------------------------------------
[ -c "$dev" ] || die "$dev does not exist"
sys=/sys/class/mtd/$mtd

if [ -r $sys/offset ]; then
	[ "$(cat $sys/offset)" = "0" ] || die "$mtd does not start at NAND offset 0"
fi

mtdsize=$(cat $sys/size)
[ "$size" -le "$mtdsize" ] || die "image ($size) larger than $mtd ($mtdsize)"

# MTD_WRITEABLE = 0x400
flags=$(cat $sys/flags)
if [ $((flags & 0x400)) -eq 0 ]; then
	die "$mtd is read-only. The upstream DockStar device tree marks the
       bootloader partition read-only; use kwboot or U-Boot instead, or
       boot a kernel whose partition table makes it writable."
fi

echo "target: $dev \"$(cat $sys/name)\", $mtdsize bytes, writable"

if [ $dry -eq 1 ]; then
	echo "dry run: all checks passed, nothing written"
	exit 0
fi

echo "erasing $dev ..."
flash_erase "$dev" 0 0
echo "writing $img ..."
nandwrite -p "$dev" "$img"

echo "verifying ..."
tmp=$(mktemp)
nanddump -q -l "$size" -f "$tmp" "$dev"
if cmp -n "$size" "$img" "$tmp"; then
	rm -f "$tmp"
	echo "OK: barebox written and verified. Reboot to start it."
else
	rm -f "$tmp"
	die "read back differs from image. DO NOT REBOOT, write again."
fi
