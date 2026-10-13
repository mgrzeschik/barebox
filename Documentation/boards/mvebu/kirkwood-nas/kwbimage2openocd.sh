#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# kwbimage2openocd.sh KWBIMAGE_CFG PROCNAME > OUTPUT.tcl
#
# Convert the DATA lines of a Kirkwood kwbimage.cfg into an OpenOCD Tcl
# procedure, so JTAG bring-up uses exactly the same DDR settings as the
# BootROM. The BootROM header addresses 0xffdXXXXX are mapped to the reset
# location of the internal register window 0xd00XXXXX.

set -e

cfg="$1"
proc="$2"

if [ -z "$cfg" ] || [ -z "$proc" ]; then
	echo "usage: $0 KWBIMAGE_CFG PROCNAME" >&2
	exit 1
fi

echo "# Generated from $(basename "$(dirname "$cfg")")/$(basename "$cfg") by kwbimage2openocd.sh"
echo "# DO NOT EDIT. Re-run the script after changing kwbimage.cfg."
echo "proc $proc {} {"
awk '
	$1 == "DATA" {
		addr = $2; val = $3
		sub(/^0[xX]/, "", addr); sub(/^0[xX]/, "", val)
		addr = tolower(addr); val = tolower(val)
		if (addr !~ /^ffd[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]$/) {
			printf "unsupported register address %s\n", addr > "/dev/stderr"
			exit 1
		}
		comment = ""
		if (index($0, "#")) {
			comment = substr($0, index($0, "#") + 1)
			sub(/^[ \t]+/, "", comment)
		}
		line = sprintf("\tmww 0xd00%s 0x%s", substr(addr, 4), val)
		if (comment != "")
			line = sprintf("%-28s ;# %s", line, comment)
		print line
	}
' "$cfg"
echo "	sleep 100"
echo "}"
