#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""
Sanity check a Kirkwood kwbimage (v0) before writing it to a device.

  check-kwbimage.py [--board seagate-dockstar|iomega-iconnect] IMAGE...

Checks:
  * boot source is NAND (0x8b) or UART (0x69) and header version is 0
    (the Kirkwood BootROM does not understand v1 headers)
  * main header, extension header and payload checksums
  * header sizes match the file size
  * a barebox image is inside and its register window word is 0xd0000000
  * the RAM size programmed by the DDR DATA entries matches the board
  * the image fits into the 768 KiB barebox NAND partition

Exit status is 0 only if all checks pass.
"""
import struct
import sys

PART_SIZE = 0xc0000
RAM_MIB = {"seagate-dockstar": 128, "iomega-iconnect": 256}


def check(path, board):
    errors = []
    data = open(path, "rb").read()
    print(f"{path}: {len(data)} bytes")

    if len(data) < 0x200:
        return ["file too small for a kwbimage"]

    (blockid, ecc, pgsz, blocksize, _r1, src, dest, exe,
     _sata, _r3, _ddrdly, _r2, ext, csum) = \
        struct.unpack("<BBHIIIIIBBHHBB", data[:0x20])
    version = data[8]
    srcname = {0x8b: "NAND", 0x69: "UART", 0x5a: "SPI"}.get(blockid, "?")

    print(f"  boot source 0x{blockid:02x} ({srcname}), header version {version}")
    print(f"  NAND page size 0x{pgsz:x}, ECC mode {ecc}")
    print(f"  payload 0x{blocksize:x} bytes at 0x{src:x}, "
          f"load 0x{dest:08x}, exec 0x{exe:08x}")

    if version != 0:
        errors.append(f"header version {version}, Kirkwood needs version 0")
    if blockid not in (0x8b, 0x69):
        errors.append("boot source is neither NAND nor UART")
    if blockid == 0x8b and pgsz != 0x800:
        errors.append("NAND page size is not 2048")
    if sum(data[:0x1f]) & 0xff != csum:
        errors.append("main header checksum mismatch")
    if src + blocksize != len(data):
        errors.append("header size fields do not match file size")

    regs = []
    if ext:
        exthdr = data[0x20:0x200]
        if sum(exthdr[:-1]) & 0xff != exthdr[-1]:
            errors.append("extension header checksum mismatch")
        for off in range(0x20, 0x1d8, 8):
            addr, val = struct.unpack("<II", exthdr[off:off + 8])
            if addr == 0 and val == 0:
                break
            regs.append((addr, val))
        print(f"  {len(regs)} DDR/SoC register writes in extension header")
    else:
        errors.append("no extension header: DDR would not be initialised")

    cs0 = [v for a, v in regs if a == 0xffd01504]
    if cs0:
        ram = ((cs0[0] | 0x00ffffff) + 1) >> 20
        print(f"  CS0 SDRAM window: {ram} MiB")
        if board and RAM_MIB.get(board) and RAM_MIB[board] != ram:
            errors.append(f"RAM size {ram} MiB, {board} has {RAM_MIB[board]} MiB")
    if regs and regs[-1] != (0xffd01480, 1):
        errors.append("last DATA entry is not the DDR init trigger")

    payload = data[src:src + blocksize]
    if payload[0x20:0x27] != b"barebox":
        errors.append("payload is not a barebox image")
    else:
        regbase = struct.unpack("<I", payload[0x30:0x34])[0]
        print(f"  barebox register window word: 0x{regbase:08x}")
        if regbase != 0xd0000000:
            errors.append("register window word must be 0xd0000000 for BootROM start")

    words = (blocksize - 4) // 4
    calc = sum(struct.unpack(f"<{words}I", payload[:words * 4])) & 0xffffffff
    if calc != struct.unpack("<I", payload[words * 4:words * 4 + 4])[0]:
        errors.append("payload checksum mismatch")

    if len(data) > PART_SIZE:
        errors.append(f"image larger than barebox partition (0x{PART_SIZE:x})")
    else:
        print(f"  fits into barebox partition, {(PART_SIZE - len(data)) // 1024} KiB spare")

    return errors


def main():
    args = sys.argv[1:]
    board = None
    if len(args) >= 2 and args[0] == "--board":
        board = args[1]
        args = args[2:]
    if not args:
        print(__doc__)
        return 2

    rc = 0
    for path in args:
        errs = check(path, board)
        for e in errs:
            print(f"  ERROR: {e}")
        print("  RESULT:", "OK" if not errs else "FAILED")
        rc |= bool(errs)
    return rc


if __name__ == "__main__":
    sys.exit(main())
