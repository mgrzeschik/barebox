// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2018 Michael Grzeschik <m.grzeschik@pengutronix.de>

#include <common.h>
#include <linux/sizes.h>
#include <asm/barebox-arm.h>
#include <mach/mvebu/barebox-arm-head.h>
#include <mach/mvebu/lowlevel.h>

extern char __dtb_kirkwood_dockstar_bb_start[];

/*
 * Entry point for both the BootROM (kwbimage, internal registers still at
 * 0xd0000000) and second stage starts (pblb, see the "-2nd" image).
 *
 * ENTRY_FUNCTION_MVEBU places the current internal register window base at
 * offset 0x30 of the image. kirkwood_barebox_entry() reads it from there,
 * moves the window to 0xf1000000 and derives the RAM size from the SDRAM
 * decoding windows that the BootROM programmed from kwbimage.cfg.
 */
ENTRY_FUNCTION_MVEBU(start_seagate_dockstar, r0, r1, r2)
{
	void *fdt;

	arm_cpu_lowlevel_init();

	fdt = __dtb_kirkwood_dockstar_bb_start + get_runtime_offset();

	kirkwood_barebox_entry(fdt);
}
