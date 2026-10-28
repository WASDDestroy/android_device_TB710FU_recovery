"""Probe the real terminal geometry.

TWRP's GUI terminal frequently leaves TIOCGWINSZ unset (0x0), which makes
ncurses fall back to the terminfo 24x80 -- drawing a 24x80 UI into a window
of a different size looks "misaligned".  If the kernel ioctl is useless we
ask the terminal itself with a DSR query (ESC[6n) after parking the cursor
at the bottom-right corner, then restore the screen.

Prints "<rows> <cols>" on success, nothing on failure.
"""
from __future__ import annotations

import os
import select
import sys
import termios
import time

try:
    import fcntl
    import struct
except Exception:  # pragma: no cover
    fcntl = None


def ioctl_size(fd: int) -> tuple[int, int]:
    if fcntl is None:
        return 0, 0
    try:
        data = fcntl.ioctl(fd, termios.TIOCGWINSZ, b"\0" * 8)
        rows, cols = struct.unpack("hhhh", data)[:2]
        return int(rows), int(cols)
    except Exception:
        return 0, 0


def dsr_size(fd: int) -> tuple[int, int]:
    try:
        old = termios.tcgetattr(fd)
    except Exception:
        return 0, 0
    new = list(old)
    new[3] &= ~(termios.ECHO | termios.ICANON)
    new[6][termios.VMIN] = 0
    new[6][termios.VTIME] = 0
    try:
        termios.tcsetattr(fd, termios.TCSANOW, new)
        os.write(fd, b"\x1b[999;999H\x1b[6n")
        deadline = time.time() + 0.35
        buf = b""
        while time.time() < deadline:
            r, _, _ = select.select([fd], [], [], 0.05)
            if not r:
                continue
            try:
                chunk = os.read(fd, 256)
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
            if b"R" in buf:
                break
        # cursor left at 999;999 -- clear and home
        os.write(fd, b"\x1b[H\x1b[J")
        import re

        m = re.search(rb"\x1b\[(\d+);(\d+)R", buf)
        if m:
            rows, cols = int(m.group(1)), int(m.group(2))
            if rows >= 5 and cols >= 20:
                return rows, cols
        return 0, 0
    except Exception:
        return 0, 0
    finally:
        try:
            termios.tcsetattr(fd, termios.TCSANOW, old)
        except Exception:
            pass


def main() -> int:
    for path in ("/dev/tty",):
        try:
            fd = os.open(path, os.O_RDWR | os.O_NOCTTY)
        except OSError:
            continue
        try:
            rows, cols = ioctl_size(fd)
            if rows and cols:
                print(rows, cols)
                return 0
            rows, cols = dsr_size(fd)
            if rows and cols:
                print(rows, cols)
                return 0
        finally:
            os.close(fd)
    return 1


if __name__ == "__main__":
    sys.exit(main())
