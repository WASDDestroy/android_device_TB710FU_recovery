#!/usr/bin/env python3
"""Print the packed boot image size of a boot header v3/v4 image.

The AVB footer needs room after the packed image, but tools such as ksud can
pad init_boot back to the full partition size and drop the footer.  Trimming
to this size (header + kernel + ramdisk + signature, page aligned) leaves the
room needed by avbtool add_hash_footer.

Usage:
    oneroot_bootimg.py [--page N] IMAGE
"""

import os
import struct
import sys

DEFAULT_PAGE = 4096


def usage():
    sys.stderr.write("usage: oneroot_bootimg.py [--page N] IMAGE\n")


def u32(data, offset):
    return struct.unpack_from("<I", data, offset)[0]


def align(value, page):
    return (value + page - 1) // page * page


def main(argv):
    page = DEFAULT_PAGE
    path = ""
    index = 1
    while index < len(argv):
        arg = argv[index]
        if arg == "--page":
            index += 1
            if index >= len(argv):
                usage()
                return 2
            try:
                page = int(argv[index])
            except ValueError:
                usage()
                return 2
        elif arg.startswith("--page="):
            try:
                page = int(arg.split("=", 1)[1])
            except ValueError:
                usage()
                return 2
        elif not path:
            path = arg
        else:
            usage()
            return 2
        index += 1

    if not path:
        usage()
        return 2
    if page <= 0 or page > 65536:
        sys.stderr.write("invalid page size: %d\n" % page)
        return 2

    try:
        file_size = os.path.getsize(path)
        with open(path, "rb") as handle:
            data = handle.read(8192)
    except OSError as exc:
        sys.stderr.write("cannot read %s: %s\n" % (path, exc))
        return 1

    if len(data) < 44 or data[:8] != b"ANDROID!":
        sys.stderr.write("%s is not an Android boot image\n" % path)
        return 1

    kernel = u32(data, 8)
    ramdisk = u32(data, 12)
    header_size = u32(data, 20)
    version = u32(data, 40)
    if version not in (3, 4):
        sys.stderr.write("unsupported boot header version: %d\n" % version)
        return 1
    if header_size <= 0 or header_size > page * 4:
        sys.stderr.write("implausible header size: %d\n" % header_size)
        return 1

    signature = 0
    if version == 4 and header_size >= 1584 and len(data) >= 1584:
        signature = u32(data, 1580)

    total = (
        align(header_size, page)
        + align(kernel, page)
        + align(ramdisk, page)
        + align(signature, page)
    )
    if total <= 0 or total > file_size:
        sys.stderr.write(
            "computed size %d does not fit the file (%d bytes)\n" % (total, file_size)
        )
        return 1

    print(total)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
