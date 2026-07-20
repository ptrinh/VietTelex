#!/usr/bin/env python3
# pty-reader.py — run INSIDE the terminal being measured. Puts the tty in raw
# mode and logs one line per received byte: "<CLOCK_UPTIME_RAW ns> <hex byte>".
# CLOCK_UPTIME_RAW is mach_absolute_time's clock — the same one the poster
# (pty-poster.swift, DispatchTime.uptimeNanoseconds) stamps with, so the two
# logs subtract directly with no cross-clock skew.
#
# Usage:  python3 pty-reader.py /tmp/pty-arrivals.log   (Ctrl-C or 'q' to stop)
import sys, tty, termios, time, os

log = open(sys.argv[1], "w", buffering=1)
fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
try:
    tty.setraw(fd)
    while True:
        b = os.read(fd, 1)
        t = time.clock_gettime_ns(time.CLOCK_UPTIME_RAW)
        if not b or b == b"q":
            break
        log.write(f"{t} {b.hex()}\n")
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
