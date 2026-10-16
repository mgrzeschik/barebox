.. SPDX-License-Identifier: GPL-2.0-only

Seagate FreeAgent DockStar and Iomega iConnect
==============================================

Both devices are small Marvell Kirkwood (88F6281) network storage boxes that
boot directly from NAND. barebox replaces the vendor U-Boot completely: the
Kirkwood BootROM loads it from NAND offset 0, initialises the DDR2 memory from
the values in the image header and starts it.

============== ======================== ========================
               Seagate FreeAgent        Iomega iConnect
               DockStar
============== ======================== ========================
SoC            88F6281 @ 1.2 GHz        88F6281 @ 1.2 GHz
RAM            128 MiB DDR2             256 MiB DDR2
NAND           256 MiB, 2 KiB pages     512 MiB, 2 KiB pages
barebox config ``mvebu_defconfig``      ``mvebu_defconfig``
Image          ``barebox-seagate-       ``barebox-iomega-
               dockstar.img``           iconnect.img``
Second stage   ``barebox-seagate-       ``barebox-iomega-
               dockstar-2nd.img``       iconnect-2nd.img``
============== ======================== ========================

Everything mentioned below lives in
``Documentation/boards/mvebu/kirkwood-nas/``:

``kirkwood-nas.sh``
  Host helper: builds the images, checks them and drives kwboot or OpenOCD.
  Run ``kirkwood-nas.sh help`` for an overview.

``check-kwbimage.py``
  Verifies an image (header version, checksums, RAM size, size limit) before
  it goes anywhere near the flash.

``flash-barebox-from-linux.sh``
  Runs *on the device* under Linux and writes barebox with mtd-utils.

``openocd/``
  OpenOCD board files with the DDR set-up generated from ``kwbimage.cfg``.

The quick path
--------------

For readers who just want it done, with a 3.3 V USB serial adapter and no
JTAG:

.. code-block:: sh

  # on your PC, in the barebox source tree
  Documentation/boards/mvebu/kirkwood-nas/kirkwood-nas.sh build
  Documentation/boards/mvebu/kirkwood-nas/kirkwood-nas.sh tftp dockstar /srv/tftp
  Documentation/boards/mvebu/kirkwood-nas/kirkwood-nas.sh uart dockstar /dev/ttyUSB0
  # power-cycle the box when asked, press a key to stop autoboot, then:

.. code-block:: sh

  # in barebox on the box
  update-barebox
  saveenv
  reset

Replace ``dockstar`` by ``iconnect`` for the iConnect. The rest of this
document explains each step and the alternatives.

NAND layout
-----------

Both boards use the same layout. The first 1 MiB is the area the U-Boot
partition always occupied, so kernel and root filesystem stay where most
existing installations expect them.

=========== =========== ======================== =========================
Offset      Size        barebox device           Content
=========== =========== ======================== =========================
0x00000000  768 KiB     ``/dev/nand0.barebox``   barebox (kwbimage v0)
0x000c0000  256 KiB     ``/dev/nand0.barebox-``  barebox environment
                        ``environment``          (one spare erase block)
0x00100000  512 KiB     ``/dev/nand0.state``     barebox state (boot
                                                 counters for A/B)
0x00180000  3.5 MiB     ``/dev/nand0.kernel``    optional raw zImage
0x00500000  rest        ``/dev/nand0.root``      UBI
=========== =========== ======================== =========================

Each partition also has a ``.bb`` variant (for example
``/dev/nand0.barebox.bb``) that skips bad blocks. Always write through the
``.bb`` devices.

The partition table is passed to Linux in the device tree when barebox boots
the kernel, so Linux sees the same four MTD partitions (``mtd0`` .. ``mtd3``).

Building
--------

You need an ARM cross compiler (Debian/Ubuntu: ``gcc-arm-linux-gnueabi``) and
the ``lz4``, ``lzop`` and ``python3`` host tools. Then:

.. code-block:: sh

  Documentation/boards/mvebu/kirkwood-nas/kirkwood-nas.sh build

This builds out of tree into ``build-kirkwood-nas/`` (set ``BUILD=`` to
change that), verifies both images and lists them::

  build-kirkwood-nas/images/barebox-seagate-dockstar.img      <- for NAND / kwboot
  build-kirkwood-nas/images/barebox-seagate-dockstar-2nd.img  <- for RAM (U-Boot, JTAG)
  build-kirkwood-nas/images/barebox-iomega-iconnect.img
  build-kirkwood-nas/images/barebox-iomega-iconnect-2nd.img

The helper starts from ``mvebu_defconfig`` and disables the Armada 370/XP
boards in it, because those need proprietary DDR training blobs
(``binary.0``) that are not part of barebox. Kirkwood needs no blob. If you
build by hand, do the same or the build stops at
``No rule to make target 'arch/arm/boards/globalscale-mirabox/binary.0'``.

Which image to use where:

``barebox-<board>.img``
  The complete kwbimage with the BootROM header and DDR set-up. Goes into
  NAND at offset 0, and is what ``kwboot`` sends over UART.

``barebox-<board>-2nd.img``
  Only barebox, without BootROM header. For starting from RAM when something
  else (U-Boot, OpenOCD) has already initialised the DDR. Never write this one
  to NAND offset 0, the BootROM cannot boot it.

Transferring files to barebox
-----------------------------

barebox has no driver for the USB host controller of the Kirkwood SoC
(``marvell,orion-ehci``), so it cannot read USB sticks on these boards.
U-Boot and Linux can. In barebox, files come from a TFTP server, which barebox
mounts on first access at ``/mnt/tftp``:

.. code-block:: sh

  dhcp                                  # or: eth0.ipaddr=… eth0.netmask=…
  global.net.server=192.168.1.10        # if DHCP does not name the server
  ls /mnt/tftp/barebox-iomega-iconnect.img

Requirements on the TFTP server, which ``tftpd-hpa`` and ``dnsmasq`` both
meet:

- **File sizes:** the ``tsize`` option must be supported. ``ubiupdatevol``
  and ``barebox_update`` need to know the file size before they write.
- **Large files:** the block counter must wrap around. barebox uses
  1432-byte blocks, so files over about 94 MB need block numbers beyond
  65535.
- **Backups:** uploads must be allowed (``tftpd-hpa --create``) for writing
  backups from barebox to the server.

``ubiupdatevol`` streams from TFTP, so images larger than the RAM are fine.

Before you start
----------------

Serial console
^^^^^^^^^^^^^^

All methods except the Linux one need the serial console. Both boards have a
serial header on the main board with **3.3 V TTL levels**, 115200 baud, 8N1.
Use a 3.3 V USB serial adapter (not RS232 levels, not 5 V) and connect only
GND, RX and TX, crossing RX and TX. Do not connect the adapter's VCC pin.
The device pages in the OpenWrt wiki show where the header is and its pinout.

Write down the MAC address
^^^^^^^^^^^^^^^^^^^^^^^^^^

barebox does not read the old U-Boot environment. Note the MAC address from
the label on the bottom of the box or with ``printenv ethaddr`` in U-Boot. You
will set it in barebox later.

Back up the old bootloader
^^^^^^^^^^^^^^^^^^^^^^^^^^

Keep a copy of the first 1 MiB of NAND so you can go back.

From a running U-Boot (FAT formatted USB stick in the box):

.. code-block:: none

  nand read 0x800000 0x0 0x100000
  usb start
  fatwrite usb 0:1 0x800000 bootloader-backup.bin 0x100000

(Old vendor U-Boots have no ``fatwrite``. Use the Linux or JTAG way then.)

From Linux on the box:

.. code-block:: sh

  nanddump -f /tmp/bootloader-backup.bin -l 0x100000 /dev/mtd0

Via JTAG:

.. code-block:: sh

  OPENOCD_ADAPTER=jlink kirkwood-nas.sh openocd-backup dockstar bootloader-backup.bin

OpenOCD's NAND driver for Kirkwood reads every byte with its own JTAG access,
so this is slow no matter which adapter or clock you use. The helper
therefore reads the kwbimage header of the old bootloader at NAND offset 0
and only dumps that image (typically well under half of the 1 MiB). It shows
progress, rate and remaining time while it runs. Add ``full`` to dump the
whole first 1 MiB including the old environment, or give a length in bytes:

.. code-block:: sh

  kirkwood-nas.sh openocd-backup dockstar bootloader-full.bin full

``OPENOCD_FAST_MEM=1`` makes OpenOCD skip its per-access completion checks,
which speeds up the dump. If you use it, dump twice and compare the files
before relying on the backup.

The OpenOCD dump reads the NAND contents without any ECC processing, so the
backup is exactly what is stored, whichever ECC layout the old bootloader
was written with.

From barebox itself, if you have already got it running from RAM (the
first 1 MiB is covered by the two barebox partitions), onto a TFTP server
that accepts uploads (see `Transferring files to barebox`_):

.. code-block:: sh

  dhcp
  cp /dev/nand0.barebox /mnt/tftp/backup-0.bin
  cp /dev/nand0.barebox-environment /mnt/tftp/backup-1.bin

and join them on the PC with
``cat backup-0.bin backup-1.bin > bootloader-backup.bin``.

Step 1: get barebox running
---------------------------

Choose **one** of the methods below. All of them end with a barebox prompt on
the serial console. Methods A and D need no working software on the box at
all, so they also serve as recovery.

Method A: UART boot with kwboot (recommended, no JTAG)
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

The Kirkwood BootROM listens on the serial port for a short time after
power-on. ``kwboot`` (built together with barebox) sends a boot pattern,
uploads the image via Xmodem and starts it. Nothing is written to NAND.

.. code-block:: sh

  kirkwood-nas.sh uart dockstar /dev/ttyUSB0

Then unplug the power of the box and plug it back in. The upload takes about
a minute, after which barebox starts and ``kwboot`` acts as a terminal. Press
a key to stop the autoboot. Leave the terminal with ``Ctrl-\`` followed by
``c``.

``kwboot`` automatically patches the image header from NAND to UART boot,
there is no separate UART image.

If ``kwboot`` keeps sending the pattern but the upload never starts, or
starts and then fails, the BootROM reset once more after picking up the
pattern. Ask ``kwboot`` to wait for more NAKs before it sends the image:

.. code-block:: sh

  kirkwood-nas.sh uart dockstar /dev/ttyUSB0 15

Continue with `Step 2: write barebox to NAND`_.

Method B: from an existing U-Boot
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Works with the stock Seagate/Iomega U-Boot as well as with mainline U-Boot.
``kirkwood-nas.sh uboot dockstar 192.168.1.10`` prints the commands below
with the right file names. Put the images on a TFTP server first
(``kirkwood-nas.sh tftp dockstar /srv/tftp``).

First start barebox from RAM to see that it works on your box. U-Boot has
already moved the internal register window from 0xd0000000 to 0xf1000000.
barebox cannot detect that, so it is written into the image at offset 0x30
before starting it:

.. code-block:: none

  setenv serverip 192.168.1.10
  tftp 0x800000 barebox-seagate-dockstar-2nd.img
  mw.l 0x800030 0xf1000000
  go 0x800000

Old vendor U-Boots call the command ``tftpboot``. From a FAT USB stick use
``usb start; fatload usb 0:1 0x800000 barebox-seagate-dockstar-2nd.img``.

If barebox comes up you can either continue with
`Step 2: write barebox to NAND`_ from within barebox (preferred), or reset
back into U-Boot and flash from there:

.. code-block:: none

  tftp 0x800000 barebox-seagate-dockstar.img
  nand erase 0x0 0xc0000
  nand write 0x800000 0x0 0xc0000
  reset

Method C: from Linux running on the box
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

If the box runs Linux (OpenWrt, Debian, ...) and ``/dev/mtd0`` is the
bootloader area at NAND offset 0, barebox can be written directly. This does
not need the serial console, but if anything goes wrong you need Method A
or D to recover.

.. code-block:: sh

  # on the box, mtd-utils installed
  scp you@pc:barebox-seagate-dockstar.img /tmp/
  scp you@pc:flash-barebox-from-linux.sh /tmp/
  sh /tmp/flash-barebox-from-linux.sh -n /tmp/barebox-seagate-dockstar.img   # dry run
  sh /tmp/flash-barebox-from-linux.sh /tmp/barebox-seagate-dockstar.img

The script refuses to write if the image is not a NAND kwbimage v0, if
``mtd0`` does not start at offset 0, is too small or is read-only, and it
reads the data back to verify it. The upstream DockStar device tree marks the
bootloader partition read-only. With such a kernel the script stops and you
have to use another method.

After a reboot barebox starts from NAND. Continue with
`Step 3: first configuration`_.

Method D: JTAG with OpenOCD
^^^^^^^^^^^^^^^^^^^^^^^^^^^

Use this to recover a box that boots nothing at all. The OpenOCD files bring
up the DDR with exactly the values from ``kwbimage.cfg`` (they are generated
from it with ``kwbimage2openocd.sh``).

Tell the helper which JTAG adapter you use:

.. code-block:: sh

  export OPENOCD_ADAPTER=interface/ftdi/olimex-arm-usb-ocd-h.cfg

Fastest: preload the NAND image into RAM together with barebox, then let
barebox write it. No network is needed:

.. code-block:: sh

  kirkwood-nas.sh openocd-ram-update dockstar

OpenOCD loads and verifies ``barebox-<board>.img`` at 0x00800000 and
``barebox-<board>-2nd.img`` at 0x01000000, then starts barebox from RAM. The
helper then prints the command to run on the serial console, with the image
size and CRC32 filled in, for example:

.. code-block:: sh

  update-barebox-ram 0x00800000 0x903fc 0x667ca4fa

``update-barebox-ram`` checks the CRC32 of the RAM contents and writes
nothing if it does not match. It then copies the image into a RAM file and
hands it to ``barebox_update``, which only accepts Kirkwood kwbimage v0
files. A barebox without this command (for example one with an older saved
environment) can do the same by hand:

.. code-block:: sh

  crc32 -v 0x667ca4fa 0x00800000+0x903fc
  memcpy -d /barebox-ram.img 0x00800000 0 0x903fc
  barebox_update -y -t nand /barebox-ram.img

0x00800000 is safe because barebox keeps its image, stack and malloc area
in the upper half of RAM. The preload has to end below the OpenOCD working
area at 0x00f00000, and ``kw_boot_ram_update`` refuses addresses that do
not fit.

Alternatively, start only barebox from RAM and update from the network as in
`Step 2: write barebox to NAND`_:

.. code-block:: sh

  kirkwood-nas.sh openocd-ram dockstar

This resets and halts the CPU, disables MMU and caches, sets up the pin
multiplexing for UART and NAND, initialises the DDR, checks two memory words,
loads ``barebox-<board>-2nd.img`` to 0x1000000 and starts it. Continue on the
serial console with `Step 2: write barebox to NAND`_.

Alternative: write the NAND directly from OpenOCD:

.. code-block:: sh

  kirkwood-nas.sh openocd-nand dockstar

This uses OpenOCD's ``oob_softecc_kw`` mode, which writes the 4-bit
Reed-Solomon ECC in the layout the Kirkwood BootROM natively expects.

It is slow, but shows progress. OpenOCD's own on-target NAND write routine
does not work on the Feroceon core (it fails with ``timed out while waiting
for target halted``), so ``kw_flash_nand`` disables OpenOCD's working area
during the write and OpenOCD writes every byte with a separate JTAG access.
Loading barebox into RAM with ``openocd-ram`` and writing the NAND from
barebox is much faster.

To use the OpenOCD files without the helper:

.. code-block:: sh

  openocd -f interface/ftdi/olimex-arm-usb-ocd-h.cfg \
          -f Documentation/boards/mvebu/kirkwood-nas/openocd/seagate-dockstar.cfg \
          -c "init; kw_boot_ram build-kirkwood-nas/images/barebox-seagate-dockstar-2nd.img; shutdown"

If your adapter only has one of the reset lines, change ``reset_config`` in
``openocd/kirkwood-nas.tcl``.

Transfer speed
""""""""""""""

The OpenOCD files enable DCC downloads and a working area in DDR. Without
them, OpenOCD moves every word through the ARM9 debug logic, and loading
and verifying barebox takes many times longer. The JTAG clock is 2 MHz
during reset and DDR set-up. Once DDR runs it is raised to 6 MHz for the
transfers. OpenOCD prints the time and rate for every load, verify and NAND
write.

To go faster, raise ``OPENOCD_FAST_SPEED`` step by step (for example 10000,
then 12000 kHz) and keep the value at which ``verify_image`` still passes.
With short wires most adapters work well above 6 MHz. If transfers fail or
verification reports mismatches, lower it again.

Segger J-Link
"""""""""""""

OpenOCD drives a J-Link directly through libjaylink with Segger's normal
firmware. Under Linux only the udev rules shipped with OpenOCD are needed,
under Windows the J-Link has to be switched to the WinUSB driver (for
example with Zadig) for OpenOCD to see it. The Segger J-Link software is
not used.

.. code-block:: sh

  export OPENOCD_ADAPTER=jlink           # = interface/jlink.cfg
  kirkwood-nas.sh openocd-ram dockstar

  # optional: several probes connected, or unstable scan chain
  export OPENOCD_SERIAL=000123456789     # serial printed by "JLinkExe" or OpenOCD
  export OPENOCD_SPEED=500               # kHz during reset, default 2000
  export OPENOCD_FAST_SPEED=12000        # kHz for transfers, default 6000

Without the helper:

.. code-block:: sh

  openocd -f interface/jlink.cfg \
          -f Documentation/boards/mvebu/kirkwood-nas/openocd/seagate-dockstar.cfg \
          -c "init; kw_boot_ram build-kirkwood-nas/images/barebox-seagate-dockstar-2nd.img; shutdown"

The J-Link has the standard ARM 20-pin connector. Connect it to the
board's JTAG header as follows:

=============== =========== ==========================================
J-Link pin      Signal      Note
=============== =========== ==========================================
1               VTref       board I/O voltage (3.3 V), sense only
3               nTRST
5               TDI
7               TMS
9               TCK
13              TDO
15              nRESET      system reset (SRST)
4, 6, ... 20    GND         at least one, better several
=============== =========== ==========================================

VTref must be connected: the J-Link sets its output levels from it and
does not drive the target without it. Pin 19 (5 V supply) stays
unconnected. Power the box from its own supply. If OpenOCD reports
``JTAG scan chain interrogation failed: all ones``, check VTref, the box's
power and TDO first.

The OpenOCD configuration selects the JTAG transport explicitly, because a
J-Link would otherwise default to SWD, which the Feroceon core does not
have.

Step 2: write barebox to NAND
-----------------------------

At the barebox prompt, from a TFTP server:

.. code-block:: sh

  dhcp                      # or set eth0.ipaddr / eth0.serverip by hand
  update-barebox

``update-barebox`` fetches ``barebox-<board>.img`` from
``$global.net.server``. To use another server:
``global.net.server=192.168.1.10``.

barebox cannot read USB sticks on these boards, see
`Transferring files to barebox`_.

``update-barebox`` is a thin wrapper around

.. code-block:: sh

  barebox_update -y -t nand /mnt/tftp/barebox-seagate-dockstar.img

The ``nand`` update handler only accepts Kirkwood kwbimage v0 files, so a
``-2nd`` image or an image for an Armada SoC is refused. It writes to
``/dev/nand0.barebox.bb``, skipping bad blocks like ``nand write`` in U-Boot
and ``nandwrite`` in Linux do.

Step 3: first configuration
---------------------------

On the first start from NAND barebox reports that the environment partition
holds no valid barebox environment (it still contains the old U-Boot
environment) and uses the built-in default. Make your settings and save:

.. code-block:: sh

  # the MAC address you wrote down
  nv dev.eth0.ethaddr=00:10:75:xx:xx:xx

  # boot order, first match wins
  nv boot.default="bootchooser nand0.root.ubi.rootfs nand-ubi nand-raw"

  # extra kernel arguments, if any
  nv linux.bootargs.extra="..."

  saveenv
  reset

``nv`` variables are stored in the environment partition and survive
barebox updates. Use ``nv`` without arguments to list them,
``nv -r NAME`` to remove one.

LEDs
----

While barebox runs, one LED shows a heartbeat (200 ms on, 1 s off):
``power:blue`` on the iConnect and ``status:green:health`` on the DockStar.
``led`` without arguments lists all LEDs, ``trigger`` without arguments
shows which trigger drives which LED. The examples use the iConnect name.

.. code-block:: sh

  trigger -d power:blue                   # stop the heartbeat
  led power:blue 1                        # then: steady on (0 = off)
  led -b power:blue 100 1900              # or: blink, 100 ms on, 1900 ms off
  trigger -t heartbeat power:blue         # back to the heartbeat

These settings last until the next reset. To keep one, put the commands
into an init script, which barebox runs on every start, and save the
environment:

.. code-block:: sh

  edit /env/init/leds
  # contents, for example:
  #   #!/bin/sh
  #   trigger -d power:blue
  #   led power:blue 1
  saveenv

``rm /env/init/leds`` followed by ``saveenv`` restores the default.

Step 4: boot Linux
------------------

barebox passes its own device tree to the kernel: the upstream Linux device
tree for the board plus the partition table above. A recent multi-platform
ARMv5 kernel (``multi_v5_defconfig`` or a distribution kernel for Kirkwood) as
plain ``zImage`` is all you need, no ``uImage`` and no appended device tree.

The default boot order is
``bootchooser nand0.root.ubi.rootfs nand-ubi nand-raw``.

``bootchooser``
  A/B boot for RAUC managed systems. The UBI in the ``root`` partition holds
  two root filesystem volumes, ``rootfs0`` (target ``system0``) and
  ``rootfs1`` (target ``system1``), each booted via its Boot Loader
  Specification entries. Priorities and remaining boot attempts live in the
  barebox state in the ``state`` partition (``state.bootstate.system0`` and
  ``state.bootstate.system1``), which RAUC changes from Linux with
  ``barebox-state``. barebox passes ``bootchooser.active=<target>`` and, with
  ``global.bootm.appendroot``, the matching ``root=ubi0:rootfsN`` to the
  kernel, so both slots can hold the same image. Use ``bootchooser -i`` to
  see the current state.


``nand0.root.ubi.rootfs``
  Boot Loader Specification entries in the UBIFS volume ``rootfs``: barebox
  reads ``/loader/entries/*.conf`` in that volume and boots the newest entry.
  systemd's ``kernel-install`` writes these entries with ``layout=bls`` and
  ``BOOT_ROOT=/``, so kernels installed by the package manager are picked up
  without touching barebox. An entry without ``devicetree`` line gets
  barebox's own device tree. At startup ``/env/init/ubi-root`` attaches the
  UBI in the ``root`` partition, but only if the partition contains UBI.

The other two boot targets use fixed file names:

``nand-ubi``
  UBIFS volume ``rootfs`` in the ``root`` partition. Expects
  ``/boot/zImage``, optional ``/boot/initrd.img`` and ``/boot/board.dtb``
  (to override barebox's device tree).

``nand-raw``
  Raw ``zImage`` in the ``kernel`` partition, root filesystem in the UBIFS
  volume ``rootfs``.

Run one explicitly with ``boot nand-ubi`` and so on. Add
``-v`` for more output. The scripts are in ``/env/boot/`` and can be changed
with ``edit`` and saved with ``saveenv``.

Setting up NAND for ``nand-ubi`` from barebox:

.. code-block:: sh

  ubiformat /dev/nand0.root
  ubiattach /dev/nand0.root
  ubimkvol /dev/nand0.root.ubi rootfs 0
  ubiupdatevol /dev/nand0.root.ubi.rootfs /mnt/tftp/rootfs.ubifs

``rootfs.ubifs`` is created on your PC with

.. code-block:: sh

  mkfs.ubifs -m 2048 -e 129024 -c 4096 -r rootfs/ rootfs.ubifs

``-e`` is the logical erase block size. ``ubiattach`` prints it, use that
value if it differs. ``-c 4096`` is large enough for the root partition of
both boards.

Writing a kernel for ``nand-raw``:

.. code-block:: sh

  erase /dev/nand0.kernel.bb
  cp /mnt/tftp/zImage /dev/nand0.kernel.bb

Updating barebox later
----------------------

Build the new version, put it on the TFTP server and run
``update-barebox`` in barebox (see `Step 2: write barebox to NAND`_). The
environment is not touched. Check the new image on the PC first:

.. code-block:: sh

  kirkwood-nas.sh build
  kirkwood-nas.sh check dockstar

From Linux, ``flash-barebox-from-linux.sh`` works as long as ``mtd0``
(``barebox``) is writable, which it is with barebox's device tree.

Recovery
--------

If the box does not come up any more, use Method A (``kwboot``) or Method D
(JTAG). Both work independently of the NAND content.

To go back to the old bootloader, start barebox with ``kwboot`` and write the
1 MiB backup over both barebox partitions in one go through the bad block
aware device of the whole chip:

.. code-block:: sh

  dhcp
  erase /dev/nand0.bb 0+1M
  cp /mnt/tftp/bootloader-backup.bin /dev/nand0.bb
  reset

From Linux, the same is
``flash_erase /dev/mtd0 0 0 && flash_erase /dev/mtd1 0 0`` followed by
``nandwrite -p /dev/mtd0`` with the first 768 KiB and ``nandwrite -p
/dev/mtd1`` with the remaining 256 KiB of the backup (split it with
``dd``).

Troubleshooting
---------------

No output at all after power-on
  Normal for the BootROM, it prints nothing. barebox prints within a second.
  If not, check that the image passes ``kirkwood-nas.sh check``, and use
  Method A to see whether the BootROM accepts the image over UART.

``kwboot`` sends the pattern forever
  Power-cycle while it is sending. If the board resets twice during power
  up, use more NAKs: ``kirkwood-nas.sh uart dockstar /dev/ttyUSB0 15``.
  Check the RX/TX wiring and that nothing else uses the serial port.

barebox works with kwboot but not from NAND
  Look at ``nand0`` bad blocks in the barebox log. The first blocks of NAND
  should be good, a bad block inside the first 768 KiB moves the image.

Kernel hangs right after ``Starting kernel``
  Check that the kernel has ``CONFIG_ARCH_MULTI_V5`` and ``CONFIG_MACH_KIRKWOOD``
  and uses ``ttyS0`` at 115200 baud (``console=ttyS0,115200`` is set by
  barebox automatically).

Wrong RAM size in ``meminfo``
  barebox takes the RAM size from the SDRAM decoding windows programmed by
  ``kwbimage.cfg``. 128 MiB for the DockStar, 256 MiB for the iConnect.

Technical background
--------------------

These notes explain the details the board support has to get right. They
also explain why earlier, out-of-tree versions of this port needed manual
memory addresses to boot a kernel.

BootROM header version
  Kirkwood only understands version 0 kwbimage headers. Version 1 is for
  Armada 370/XP. ``kwbimage.cfg`` must therefore say ``VERSION 0``. U-Boot's
  Kirkwood configs have no ``VERSION`` line, which also means 0.

DDR set-up and RAM size
  The BootROM executes the ``DATA`` register writes from the header before it
  loads barebox. barebox derives the RAM size from the resulting SDRAM window
  registers (``kirkwood_memory_find()``), so these are the single source of
  truth for the memory size handed to Linux. The values are identical to the
  ones in U-Boot.

Register window
  At reset the internal registers are at 0xd0000000. barebox moves them to
  0xf1000000, where Linux expects them. The current location is read from
  the word at offset 0x30 of the barebox image. It defaults to 0xd0000000
  for BootROM, kwboot and JTAG starts. U-Boot has already moved the window,
  so for chainloading from U-Boot the word has to be set to 0xf1000000.
  barebox does that itself when it starts another barebox.

iConnect initrd addresses
  The upstream Linux device tree for the iConnect hardcodes
  ``linux,initrd-start = <0x4500040>`` and ``linux,initrd-end`` in
  ``/chosen``, matching where the stock Iomega loader used to put its
  initrd. barebox only replaces these properties when an initrd is booted,
  so the barebox device tree deletes them. If you pass your own device tree
  with ``/boot/board.dtb``, make sure it does not contain them either.

NAND ECC
  For 2 KiB page NAND, the BootROM's native ECC is a 4-bit Reed-Solomon code
  computed backwards over the data, which OpenOCD writes with
  ``oob_softecc_kw``. barebox, Linux and U-Boot use 1-bit software Hamming
  ECC on Kirkwood. The BootROM accepts NAND images written that way. This is
  how U-Boot has always been installed and updated on these devices.
