# SPDX-License-Identifier: GPL-2.0-only
#
# Common OpenOCD support for barebox on Kirkwood NAS boxes
# (Seagate FreeAgent DockStar, Iomega iConnect).
#
# Do not use this file directly, use seagate-dockstar.cfg or
# iomega-iconnect.cfg which set KW_BOARD and source this file.
#
# Provided commands (run them with -c "...", see kirkwood-nas.sh):
#
#   kw_boot_ram IMAGE     load barebox-<board>-2nd.img into DDR and start it
#                         (recommended: then update NAND from within barebox)
#   kw_boot_ram_update IMAGE NANDIMAGE [ADDR]
#                         like kw_boot_ram, but also preload the NAND image
#                         barebox-<board>.img to ADDR (default 0x00800000),
#                         so barebox can write it with update-barebox-ram
#   kw_flash_nand IMAGE   write barebox-<board>.img to NAND offset 0 using
#                         the BootROM's native Reed-Solomon ECC layout
#   kw_dump_nand FILE [auto|full|LENGTH]
#                         save the bootloader from NAND with live progress.
#                         auto (default): only the kwbimage found at offset 0,
#                         full: the first 1 MiB, LENGTH: that many bytes

# The Feroceon core only has JTAG. Adapters that also do SWD (Segger J-Link,
# CMSIS-DAP, ...) would otherwise pick SWD as their default transport.
transport select jtag

source [find target/feroceon.cfg]

# Most adapters need both reset lines for a reliable "reset halt".
# Change to "srst_only" or "trst_only" if your adapter lacks one.
# A J-Link drives nTRST (pin 3) and nRESET (pin 15) of the 20-pin connector.
reset_config trst_and_srst

# JTAG clock in kHz. KW_ADAPTER_SPEED is used for reset, halt and DDR set-up,
# KW_FAST_SPEED once the CPU is halted and DDR is running, for the bulk
# transfers. Override with -c "set KW_ADAPTER_SPEED <kHz>" or
# -c "set KW_FAST_SPEED <kHz>" before this file (kirkwood-nas.sh:
# OPENOCD_SPEED / OPENOCD_FAST_SPEED). Lower them if transfers fail with
# long or unshielded wires.
if {![info exists KW_ADAPTER_SPEED]} {
	set KW_ADAPTER_SPEED 2000
}
if {![info exists KW_FAST_SPEED]} {
	set KW_FAST_SPEED 6000
}
adapter speed $KW_ADAPTER_SPEED

# Without these, OpenOCD transfers every 32-bit word through the ARM9 debug
# logic, which makes load_image, verify_image and NAND writes very slow:
#
#  - DCC downloads stream data through the debug communication channel to a
#    small helper running on the CPU.
#  - The working area holds that helper and the checksum code verify_image
#    uses instead of reading everything back.
#
# The orion NAND driver would also run its block write code in the working
# area. That code ends on a hardware breakpoint, and on the Feroceon (one
# usable breakpoint comparator, non-ARM926 debug details) the CPU does not
# halt there: "nand write" fails with "timed out while waiting for target
# halted". kw_flash_nand therefore removes the working area while writing,
# so the driver falls back to plain memory accesses.
#
# The working area is in DDR, so it can only be used after kw_halt_init.
# 0x00f00000 is inside the 128 MiB of the smallest board and below the
# barebox load address 0x01000000.
$_TARGETNAME configure -work-area-phys 0x00f00000 -work-area-size 0x10000 \
	-work-area-backup 0
arm7_9 dcc_downloads enable

# Kirkwood NAND controller, chip select window at its reset default.
nand device kirkwood.nand orion $_TARGETNAME 0xd8000000

# barebox images are linked to run from DDR, the BootROM loads the kwbimage
# payload to the same address (KWBOPTS "-d 0x1000000 -e 0x1000000").
set KW_LOAD_ADDR 0x01000000

proc kw_mpp_init {} {
	global KW_MPP_CTRL0 KW_MPP_CTRL1 KW_MPP_CTRL2
	# MPP0..7: NAND IO2..7, SYSRST_OUTn, GPO
	mww 0xd0010000 $KW_MPP_CTRL0
	# MPP8..15: board specific, MPP10/11 = UART0 TXD/RXD
	mww 0xd0010004 $KW_MPP_CTRL1
	# MPP16..23: MPP18/19 = NAND IO0/1
	mww 0xd0010008 $KW_MPP_CTRL2
}

proc kw_halt_init {} {
	global KW_BOARD

	echo "kirkwood-nas: resetting and halting $KW_BOARD"
	reset halt
	# MMU, D-cache and I-cache off, alignment checking off,
	# exception vectors high (BootROM)
	arm mcr 15 0 1 0 0 0x00052078
	kw_mpp_init
	echo "kirkwood-nas: initialising DDR2 (same values as kwbimage.cfg)"
	${KW_BOARD}_ddr_init

	# simple pattern test at the barebox load address
	mww 0x01000000 0x12345678
	mww 0x01000004 0x9abcdef0
	set ok [kw_memtest_word 0x01000000 0x12345678]
	set ok [expr {$ok && [kw_memtest_word 0x01000004 0x9abcdef0]}]
	if {!$ok} {
		error "kirkwood-nas: DDR test failed, check JTAG wiring and board selection"
	}
	echo "kirkwood-nas: DDR test passed"

	kw_speed_up
}

# Effective JTAG clock in kHz; adapters clamp requests to their maximum.
proc kw_adapter_khz {fallback} {
	if {[catch {adapter speed} s] || ![regexp {([0-9]+)} $s -> khz]} {
		return $fallback
	}
	return $khz
}

proc kw_speed_up {} {
	global KW_FAST_SPEED
	adapter speed $KW_FAST_SPEED
	set khz [kw_adapter_khz $KW_FAST_SPEED]
	if {$khz != $KW_FAST_SPEED} {
		echo "kirkwood-nas: JTAG clock now $khz kHz for transfers (adapter maximum, $KW_FAST_SPEED requested)"
	} else {
		echo "kirkwood-nas: JTAG clock now $khz kHz for transfers"
	}
}

proc kw_work_area {enable} {
	set t [target current]
	if {$enable} {
		$t configure -work-area-phys 0x00f00000 -work-area-size 0x10000
	} else {
		$t configure -work-area-size 0
	}
}

# Printed as the very last step of every top-level command. kirkwood-nas.sh
# looks for it to tell success from failure, because OpenOCD 0.12 always
# aborts on exit with a Feroceon target ("free(): invalid pointer":
# arm9tdmi_deinit_target() frees the arm7_9_common member embedded in
# struct arm926ejs_common), so its exit status is meaningless.
proc kw_done {} {
	echo "kirkwood-nas: DONE"
}

proc kw_report {what file t0} {
	set ms [expr {[ms] - $t0}]
	if {$ms < 1} {
		set ms 1
	}
	set kib [expr {[file size $file] / 1024}]
	echo [format "kirkwood-nas: %s %d KiB in %.1f s (%.0f KiB/s)" \
		$what $kib [expr {$ms / 1000.0}] [expr {$kib * 1000.0 / $ms}]]
}

proc kw_memtest_word {addr expected} {
	set val [read_memory $addr 32 1]
	return [expr {[lindex $val 0] == $expected}]
}

proc kw_load_verified {image addr} {
	echo "kirkwood-nas: loading $image to $addr"
	set t0 [ms]
	load_image $image $addr bin
	kw_report "loaded" $image $t0
	set t0 [ms]
	verify_image $image $addr bin
	kw_report "verified" $image $t0
}

proc kw_boot_ram {image} {
	global KW_LOAD_ADDR

	kw_halt_init
	kw_load_verified $image $KW_LOAD_ADDR
	echo "kirkwood-nas: starting barebox, watch the serial console (115200 8N1)"
	resume $KW_LOAD_ADDR
	kw_done
}

# Where a NAND image may be preloaded. barebox places itself, its stack and
# its malloc area in the upper half of RAM; the first page may hold the
# exception vectors. Below the OpenOCD working area at 0x00f00000 is free.
set KW_PRELOAD_MIN 0x00001000
set KW_PRELOAD_END 0x00f00000

proc kw_boot_ram_update {image nandimage {addr 0x00800000}} {
	global KW_LOAD_ADDR KW_PRELOAD_MIN KW_PRELOAD_END

	set size [file size $nandimage]
	if {$addr < $KW_PRELOAD_MIN || $addr + $size > $KW_PRELOAD_END} {
		error [format "kirkwood-nas: %s at 0x%08x does not fit between 0x%08x and 0x%08x" \
			$nandimage $addr $KW_PRELOAD_MIN $KW_PRELOAD_END]
	}

	kw_halt_init
	kw_load_verified $nandimage $addr
	kw_load_verified $image $KW_LOAD_ADDR
	echo "kirkwood-nas: starting barebox, watch the serial console (115200 8N1)"
	resume $KW_LOAD_ADDR
	kw_done
}

proc kw_debug_level {} {
	if {[catch {debug_level} s] || ![regexp {(-?[0-9]+)} $s -> lvl]} {
		return 2
	}
	return $lvl
}

proc kw_nand_write_chunks {image size tmp t0} {
	global KW_DUMP_CHUNK

	set in [open $image rb]
	for {set off 0} {$off < $size} {incr off $KW_DUMP_CHUNK} {
		set f [open $tmp wb]
		$f puts -nonewline [$in read $KW_DUMP_CHUNK]
		$f close
		if {[catch {nand write 0 $tmp $off oob_softecc_kw} err]} {
			$in close
			error "kirkwood-nas: NAND write at offset $off failed: $err"
		}
		set done [expr {$off + $KW_DUMP_CHUNK}]
		if {$done > $size} {
			set done $size
		}
		kw_progress $done $size $t0
	}
	$in close
}

proc kw_flash_nand {image} {
	global KW_NAND_PAGE KW_DUMP_CHUNK

	set size [file size $image]
	if {$size > 0xc0000} {
		error "kirkwood-nas: $image is larger than the barebox partition"
	}

	kw_halt_init
	nand probe 0

	# see the comment at "arm7_9 dcc_downloads" above
	kw_work_area 0

	echo "kirkwood-nas: erasing barebox partition (0x0 - 0xc0000)"
	nand erase 0 0x0 0xc0000

	set tmp "$image.part"
	echo [format "kirkwood-nas: writing %s (%d KiB) with Kirkwood BootROM ECC" \
		$image [expr {$size / 1024}]]

	# Without working area OpenOCD warns "not enough working area available
	# (requested 2068)" for every page before it falls back to plain memory
	# writes, which is exactly what is wanted here. Show only errors while
	# writing, unless OpenOCD runs with debug output (-d3 and higher).
	set lvl [kw_debug_level]
	if {$lvl < 3} {
		debug_level 0
	}
	set t0 [ms]
	set failed [catch {kw_nand_write_chunks $image $size $tmp $t0} err]
	debug_level $lvl
	file delete $tmp
	if {$failed} {
		kw_work_area 1
		error $err
	}

	kw_work_area 1
	kw_report "written" $image $t0
	echo "kirkwood-nas: power cycle the board"
	kw_done
}

# OpenOCD's orion NAND driver has a fast on-target routine for writing, but
# reads every byte with a separate JTAG memory access, and "nand dump" only
# reports when it is done. Dump in chunks to show progress, and by default
# only as much as the bootloader image at offset 0 occupies.
set KW_NAND_PAGE 0x800
set KW_DUMP_CHUNK 0x8000

proc kw_append_file {dst src} {
	set in [open $src rb]
	set data [$in read]
	$in close
	set out [open $dst ab]
	$out puts -nonewline $data
	$out close
}

# Length of the kwbimage at NAND offset 0, rounded up to full pages, or 0
# if there is none.
proc kw_nand_kwbimage_length {tmp} {
	global KW_NAND_PAGE

	nand dump 0 $tmp 0x0 $KW_NAND_PAGE
	set f [open $tmp rb]
	set hdr [$f read 32]
	$f close
	file delete $tmp

	set blockid [unpack $hdr -uintle 0 8]
	set blocksize [unpack $hdr -uintle 32 32]
	set srcaddr [unpack $hdr -uintle 96 32]

	if {$blockid != 0x8b || $blocksize == 0 || $srcaddr == 0 ||
	    $srcaddr + $blocksize > 0x100000} {
		return 0
	}

	set len [expr {$srcaddr + $blocksize}]
	return [expr {($len + $KW_NAND_PAGE - 1) / $KW_NAND_PAGE * $KW_NAND_PAGE}]
}

proc kw_fmt_time {s} {
	return [format "%d:%02d" [expr {int($s) / 60}] [expr {int($s) % 60}]]
}

proc kw_progress {done total t0} {
	set ms [expr {[ms] - $t0}]
	if {$ms < 1} {
		set ms 1
	}
	set secs [expr {$ms / 1000.0}]
	set rate [expr {$done / 1024.0 / $secs}]
	set eta [expr {($total - $done) / 1024.0 / $rate}]
	echo [format "kirkwood-nas: %4d / %4d KiB  %3d%%  %6.1f KiB/s  elapsed %s  left %s" \
		[expr {$done / 1024}] [expr {$total / 1024}] \
		[expr {$done * 100 / $total}] $rate \
		[kw_fmt_time $secs] [kw_fmt_time $eta]]
}

proc kw_dump_nand {file {length auto}} {
	global KW_NAND_PAGE KW_DUMP_CHUNK KW_DUMP_FAST_MEM

	kw_halt_init
	nand probe 0

	set tmp "$file.part"
	file delete $tmp

	if {$length eq "full"} {
		set length 0x100000
	} elseif {$length eq "auto"} {
		set length [kw_nand_kwbimage_length $tmp]
		if {$length == 0} {
			echo "kirkwood-nas: no kwbimage at NAND offset 0, dumping 1 MiB"
			set length 0x100000
		} else {
			echo [format "kirkwood-nas: bootloader image at NAND offset 0 is %d KiB" \
				[expr {$length / 1024}]]
		}
	}
	set length [expr {($length + $KW_NAND_PAGE - 1) / $KW_NAND_PAGE * $KW_NAND_PAGE}]

	if {[info exists KW_DUMP_FAST_MEM] && $KW_DUMP_FAST_MEM} {
		echo "kirkwood-nas: using fast memory access for the dump"
		arm7_9 fast_memory_access enable
	}

	set out [open $file wb]
	$out close

	echo [format "kirkwood-nas: dumping %d KiB of NAND to %s" \
		[expr {$length / 1024}] $file]
	set t0 [ms]
	for {set off 0} {$off < $length} {incr off $KW_DUMP_CHUNK} {
		set n [expr {$length - $off}]
		if {$n > $KW_DUMP_CHUNK} {
			set n $KW_DUMP_CHUNK
		}
		set r [nand dump 0 $tmp $off $n]
		kw_append_file $file $tmp
		file delete $tmp

		kw_progress [expr {$off + $n}] $length $t0
	}

	arm7_9 fast_memory_access disable
	kw_report "dumped" $file $t0
	kw_done
}
