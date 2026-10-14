#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# kirkwood-nas.sh - build barebox and get it onto a Seagate FreeAgent
# DockStar or Iomega iConnect.
#
# Run "kirkwood-nas.sh help" for the command overview. The walkthrough
# is in Documentation/boards/mvebu/Kirkwood-NAS.rst.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/../../../.." && pwd)
BUILD=${BUILD:-$TOP/build-kirkwood-nas}
CROSS_COMPILE=${CROSS_COMPILE:-arm-linux-gnueabi-}
BAUD=115200

usage() {
	cat <<USAGE
usage: $(basename "$0") COMMAND [ARGS]

BOARD is "dockstar" or "iconnect".

Build and check
  build                       build both images into \$BUILD/images
                              (default $BUILD)
  check BOARD [IMAGE]         verify a kwbimage before flashing

Getting barebox running (pick one)
  uart BOARD TTY [NAKS]       boot barebox over the serial console with
                              kwboot, no JTAG needed. Power-cycle the box
                              when asked. NAKS defaults to 1, try 15 if the
                              BootROM does not pick up the image.
  uboot BOARD [SERVERIP]      print U-Boot commands to chainload and flash
  openocd-ram BOARD           JTAG: init DDR, load and start barebox in RAM
  openocd-nand BOARD          JTAG: write barebox to NAND directly
  openocd-backup BOARD FILE   JTAG: save first 1 MiB of NAND to FILE

Helpers
  tftp BOARD DIR              copy the images to a TFTP server directory
  regen-openocd               regenerate OpenOCD DDR tables from kwbimage.cfg

Environment
  BUILD           build directory (default: $BUILD)
  CROSS_COMPILE   toolchain prefix (default: arm-linux-gnueabi-)
  OPENOCD_ADAPTER OpenOCD adapter config, e.g.
                  "interface/ftdi/olimex-arm-usb-ocd-h.cfg" (required for
                  the openocd-* commands). "jlink" is a shorthand for
                  "interface/jlink.cfg" (Segger J-Link).
  OPENOCD_SPEED   JTAG clock in kHz (default: 2000)
  OPENOCD_SERIAL  serial number of the probe, if several are connected
USAGE
}

die() {
	echo "ERROR: $*" >&2
	exit 1
}

board_name() {
	case "${1:-}" in
	dockstar|seagate-dockstar)	echo seagate-dockstar ;;
	iconnect|iomega-iconnect)	echo iomega-iconnect ;;
	*) die "unknown board \"${1:-}\", use dockstar or iconnect" ;;
	esac
}

image() {
	local f="$BUILD/images/barebox-$1$2.img"
	[ -f "$f" ] || die "$f not found, run \"$(basename "$0") build\" first"
	echo "$f"
}

cmd_build() {
	command -v "${CROSS_COMPILE}gcc" >/dev/null ||
		die "${CROSS_COMPILE}gcc not found" \
		    "(Debian/Ubuntu: apt install gcc-arm-linux-gnueabi)"
	for t in lz4 lzop python3; do
		command -v $t >/dev/null || die "$t not found (apt install $t)"
	done

	local mk=(make -C "$TOP" O="$BUILD" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE")

	"${mk[@]}" mvebu_defconfig

	# The Armada 370/XP boards in mvebu_defconfig need proprietary DDR
	# training blobs (binary.0) that are not part of barebox. Kirkwood
	# needs none, so only keep the two boards we want.
	local cfg="$BUILD/.config" m
	for m in $(grep -o '^CONFIG_MACH_[A-Z0-9_]*=y' "$cfg" | cut -d= -f1); do
		case $m in
		CONFIG_MACH_SEAGATE_DOCKSTAR|CONFIG_MACH_IOMEGA_ICONNECT) ;;
		*) sed -i "s/^$m=y\$/# $m is not set/" "$cfg" ;;
		esac
	done
	"${mk[@]}" olddefconfig
	"${mk[@]}" -j"$(nproc)"

	echo
	local b
	for b in seagate-dockstar iomega-iconnect; do
		"$HERE/check-kwbimage.py" --board $b "$BUILD/images/barebox-$b.img"
	done
	echo
	ls -l "$BUILD"/images/barebox-seagate-dockstar*.img \
	      "$BUILD"/images/barebox-iomega-iconnect*.img
}

cmd_check() {
	local b; b=$(board_name "${1:-}")
	"$HERE/check-kwbimage.py" --board "$b" "${2:-$(image "$b" "")}"
}

cmd_uart() {
	local b tty naks img
	b=$(board_name "${1:-}")
	tty=${2:-}
	naks=${3:-1}
	[ -n "$tty" ] || die "usage: uart BOARD TTY [NAKS]"
	[ -c "$tty" ] || die "$tty is not a serial device"
	img=$(image "$b" "")
	"$HERE/check-kwbimage.py" --board "$b" "$img" >/dev/null ||
		die "$img failed the image check"

	cat <<MSG

 kwboot will now send the boot pattern on $tty.
 >>> Power-cycle the $b NOW (unplug power, plug it back in). <<<

 The image is uploaded via Xmodem (about 1 minute at $BAUD baud),
 then kwboot switches to a terminal. Press any key to stop autoboot.
 Leave the terminal with Ctrl-\\ followed by c.

MSG
	exec "$BUILD/scripts/kwboot" -b "$img" -n "$naks" -t -B "$BAUD" "$tty"
}

cmd_uboot() {
	local b ip
	b=$(board_name "${1:-}")
	ip=${2:-<tftp-server-ip>}
	cat <<MSG
# ---- Paste into U-Boot on the $b ----------------------------------------
#
# Copy the images to your TFTP server first:
#   $(basename "$0") tftp ${1} /srv/tftp
#
# Old Marvell/stock U-Boot uses "tftpboot", mainline U-Boot "tftp".
# Use "usb start; fatload usb 0:1 0x800000 <file>" to load from a FAT stick.

setenv serverip $ip
# setenv ipaddr <free-ip-in-your-lan>     (if there is no dhcp)

# Write down your MAC address, barebox does not read the U-Boot env:
printenv ethaddr

# 1) TEST FIRST: start barebox from RAM, NAND stays untouched.
#    U-Boot has already moved the register window to 0xf1000000, the
#    second word below tells barebox so (image offset 0x30).
tftp 0x800000 barebox-$b-2nd.img
mw.l 0x800030 0xf1000000
go 0x800000

# 2) If barebox came up fine, reset into U-Boot again and flash:
tftp 0x800000 barebox-$b.img
nand erase 0x0 0xc0000
nand write 0x800000 0x0 0xc0000
reset
# --------------------------------------------------------------------------
MSG
}

openocd_run() {
	local b=$1 adapter; shift
	local pre=()

	adapter=${OPENOCD_ADAPTER:-}
	[ -n "$adapter" ] ||
		die "set OPENOCD_ADAPTER to your adapter config," \
		    "e.g. jlink or interface/ftdi/olimex-arm-usb-ocd-h.cfg"
	case "$adapter" in
	jlink|j-link)	adapter=interface/jlink.cfg ;;
	esac
	command -v openocd >/dev/null || die "openocd not found"

	if [ -n "${OPENOCD_SERIAL:-}" ]; then
		pre+=(-c "adapter serial $OPENOCD_SERIAL")
	fi
	if [ -n "${OPENOCD_SPEED:-}" ]; then
		pre+=(-c "set KW_ADAPTER_SPEED $OPENOCD_SPEED")
	fi

	openocd -f "$adapter" "${pre[@]}" -f "$HERE/openocd/$b.cfg" \
		-c "init" "$@" -c "shutdown"
}

cmd_openocd_ram() {
	local b; b=$(board_name "${1:-}")
	echo "Starting barebox via JTAG. Watch the serial console, then run"
	echo "\"update-barebox\" (TFTP) or \"barebox_update -y /mnt/usb/barebox-$b.img\" there."
	openocd_run "$b" -c "kw_boot_ram $(image "$b" -2nd)"
}

cmd_openocd_nand() {
	local b img; b=$(board_name "${1:-}")
	img=$(image "$b" "")
	"$HERE/check-kwbimage.py" --board "$b" "$img" >/dev/null ||
		die "$img failed the image check"
	openocd_run "$b" -c "kw_flash_nand $img"
}

cmd_openocd_backup() {
	local b; b=$(board_name "${1:-}")
	[ -n "${2:-}" ] || die "usage: openocd-backup BOARD FILE"
	openocd_run "$b" -c "kw_dump_nand $(realpath -m "$2")"
}

cmd_tftp() {
	local b dir; b=$(board_name "${1:-}")
	dir=${2:-}
	[ -d "$dir" ] || die "usage: tftp BOARD DIR (DIR must exist)"
	cp -v "$(image "$b" "")" "$(image "$b" -2nd)" "$dir/"
}

cmd_regen_openocd() {
	local b
	for b in seagate-dockstar iomega-iconnect; do
		"$HERE/kwbimage2openocd.sh" "$TOP/arch/arm/boards/$b/kwbimage.cfg" \
			"${b//-/_}_ddr_init" > "$HERE/openocd/$b-ddr.tcl"
		echo "regenerated openocd/$b-ddr.tcl"
	done
}

cmd=${1:-help}
shift || true
case "$cmd" in
build)		cmd_build "$@" ;;
check)		cmd_check "$@" ;;
uart)		cmd_uart "$@" ;;
uboot)		cmd_uboot "$@" ;;
openocd-ram)	cmd_openocd_ram "$@" ;;
openocd-nand)	cmd_openocd_nand "$@" ;;
openocd-backup)	cmd_openocd_backup "$@" ;;
tftp)		cmd_tftp "$@" ;;
regen-openocd)	cmd_regen_openocd ;;
help|-h|--help)	usage ;;
*)		usage; exit 1 ;;
esac
