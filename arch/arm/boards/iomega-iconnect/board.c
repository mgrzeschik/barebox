// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2018 Michael Grzeschik <m.grzeschik@pengutronix.de>

#include <common.h>
#include <init.h>
#include <envfs.h>
#include <mach/mvebu/bbu.h>

static int iomega_iconnect_devices_init(void)
{
	if (!of_machine_is_compatible("iom,iconnect"))
		return 0;

	/*
	 * The BootROM loads the kwbimage from NAND offset 0. Write through
	 * the bad block aware device so barebox_update behaves like
	 * "nand write" in U-Boot or nandwrite(8) in Linux.
	 */
	mvebu_bbu_flash_register_handler("nand", "/dev/nand0.barebox.bb",
					 0, true);

	defaultenv_append_directory(defaultenv_iomega_iconnect);

	return 0;
}
device_initcall(iomega_iconnect_devices_init);
