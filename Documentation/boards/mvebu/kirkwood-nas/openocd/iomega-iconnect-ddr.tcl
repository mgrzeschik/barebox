# Generated from iomega-iconnect/kwbimage.cfg by kwbimage2openocd.sh
# DO NOT EDIT. Re-run the script after changing kwbimage.cfg.
proc iomega_iconnect_ddr_init {} {
	mww 0xd00100e0 0x1b1b1b9b
	mww 0xd0001400 0x43000c30   ;# DDR Configuration: refresh 0xc30 clks, exit SR on access
	mww 0xd0001404 0x37543000   ;# DDR Controller Control Low: CL=5, CL+2 STARTBURST
	mww 0xd0001408 0x22125451   ;# DDR Timing Low
	mww 0xd000140c 0x00000a33   ;# DDR Timing High
	mww 0xd0001410 0x000000cc   ;# DDR Address Control: CS0+CS1 x8, 1Gb devices
	mww 0xd0001414 0x00000000   ;# DDR Open Pages Control: enabled
	mww 0xd0001418 0x00000000   ;# DDR Operation: normal
	mww 0xd000141c 0x00000c52   ;# DDR Mode: BL=4, CL=5, WR=6
	mww 0xd0001420 0x00000040   ;# DDR Extended Mode: DLL on, ODT 150 Ohm disabled
	mww 0xd0001424 0x0000f17f   ;# DDR Controller Control High: write path sample stage
	mww 0xd0001428 0x00085520   ;# DDR2 ODT Read Timing
	mww 0xd000147c 0x00008552   ;# DDR2 ODT Write Timing
	mww 0xd0001500 0x00000000   ;# CS0 base 0x00000000
	mww 0xd0001504 0x0ffffff1   ;# CS0 size 256 MiB, window enabled
	mww 0xd0001508 0x00000000   ;# CS1 base (unused)
	mww 0xd000150c 0x00000000   ;# CS1 window disabled
	mww 0xd0001514 0x00000000   ;# CS2 window disabled
	mww 0xd000151c 0x00000000   ;# CS3 window disabled
	mww 0xd0001494 0x00030000   ;# DDR ODT Control Low
	mww 0xd0001498 0x00000000   ;# DDR ODT Control High
	mww 0xd000149c 0x0000e803   ;# CPU ODT Control
	mww 0xd0001480 0x00000001   ;# DDR Initialization Control: start init
	sleep 100
}
