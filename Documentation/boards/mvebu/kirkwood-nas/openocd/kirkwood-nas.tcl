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
#   kw_flash_nand IMAGE   write barebox-<board>.img to NAND offset 0 using
#                         the BootROM's native Reed-Solomon ECC layout
#   kw_dump_nand FILE     save the first 1 MiB of NAND (bootloader backup)

# The Feroceon core only has JTAG. Adapters that also do SWD (Segger J-Link,
# CMSIS-DAP, ...) would otherwise pick SWD as their default transport.
transport select jtag

source [find target/feroceon.cfg]

# Most adapters need both reset lines for a reliable "reset halt".
# Change to "srst_only" or "trst_only" if your adapter lacks one.
# A J-Link drives nTRST (pin 3) and nRESET (pin 15) of the 20-pin connector.
reset_config trst_and_srst

# JTAG clock in kHz, override with -c "set KW_ADAPTER_SPEED <kHz>" before
# this file (kirkwood-nas.sh: OPENOCD_SPEED=<kHz>). Lower it if the scan
# chain is unstable with long wires.
if {![info exists KW_ADAPTER_SPEED]} {
	set KW_ADAPTER_SPEED 2000
}
adapter speed $KW_ADAPTER_SPEED

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
	# exception vectors low
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
}

proc kw_memtest_word {addr expected} {
	set val [read_memory $addr 32 1]
	return [expr {[lindex $val 0] == $expected}]
}

proc kw_boot_ram {image} {
	global KW_LOAD_ADDR

	kw_halt_init
	echo "kirkwood-nas: loading $image to $KW_LOAD_ADDR"
	load_image $image $KW_LOAD_ADDR bin
	verify_image $image $KW_LOAD_ADDR bin
	echo "kirkwood-nas: starting barebox, watch the serial console (115200 8N1)"
	resume $KW_LOAD_ADDR
}

proc kw_flash_nand {image} {
	kw_halt_init
	nand probe 0
	echo "kirkwood-nas: erasing barebox partition (0x0 - 0xc0000)"
	nand erase 0 0x0 0xc0000
	echo "kirkwood-nas: writing $image with Kirkwood BootROM ECC"
	nand write 0 $image 0 oob_softecc_kw
	echo "kirkwood-nas: done, power cycle the board"
}

proc kw_dump_nand {file} {
	kw_halt_init
	nand probe 0
	echo "kirkwood-nas: dumping first 1 MiB of NAND to $file"
	nand dump 0 $file 0x0 0x100000
}
