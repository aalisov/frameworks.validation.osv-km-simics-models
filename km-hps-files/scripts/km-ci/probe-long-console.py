#!/usr/bin/env python3
"""Probe a Simics UART telnet console for long-sim health.

Exit codes:
  0  OK
  1  UNHEALTHY (panic / abort / wrong state)
  2  DOWN (connect refused / timeout / empty)

Usage:
  probe-long-console.py --host 127.0.0.1 --port 9123 --expect uboot
  probe-long-console.py --port 9124 --expect linux --grace-ok
"""
from __future__ import annotations

import argparse
import re
import socket
import sys
import time
from typing import List, Optional, Tuple

BAD_RES = [
    re.compile(r"Synchronous Abort", re.I),
    re.compile(r"### ERROR ###", re.I),
    re.compile(r"Please RESET the board", re.I),
    re.compile(r"Kernel panic", re.I),
    re.compile(r"Internal error: Oops", re.I),
    re.compile(r"---\[ end Kernel panic", re.I),
    re.compile(r"Resetting CPU", re.I),
]

UBOOT_OK = [
    re.compile(r"SOCFPGA_KM\s*#"),
]

LINUX_OK = [
    re.compile(r"login:"),
    re.compile(r"root@\S+:\S+[#\$]"),
]


def classify(buf: str, expect: str, grace_ok: bool) -> Tuple[str, str]:
    """Return (OK|UNHEALTHY|DOWN, reason)."""
    if not buf.strip():
        return "DOWN", "no console data"

    for rx in BAD_RES:
        m = rx.search(buf)
        if m:
            return "UNHEALTHY", f"matched {rx.pattern!r}"

    if expect == "uboot":
        for rx in UBOOT_OK:
            if rx.search(buf):
                return "OK", "uboot prompt"
        return "UNHEALTHY", "no U-Boot prompt"

    if expect == "linux":
        for rx in LINUX_OK:
            if rx.search(buf):
                return "OK", "linux shell/login"
        if grace_ok:
            # Booting: not dead/panicked is enough during grace.
            return "OK", "grace (no panic)"
        return "UNHEALTHY", "no linux login/shell"

    # expect == any: alive + not bad
    return "OK", "console alive"


def read_console(host: str, port: int, seconds: float, poke: bool) -> Tuple[Optional[str], str]:
    try:
        s = socket.create_connection((host, port), timeout=5.0)
    except OSError as exc:
        return None, f"connect failed: {exc}"
    s.settimeout(1.0)
    chunks: List[bytes] = []
    deadline = time.time() + seconds
    try:
        if poke:
            try:
                s.sendall(b"\r")
            except OSError:
                pass
        while time.time() < deadline:
            try:
                data = s.recv(4096)
                if not data:
                    break
                chunks.append(data)
            except socket.timeout:
                continue
            except OSError as exc:
                return None, f"recv failed: {exc}"
    finally:
        try:
            s.close()
        except OSError:
            pass
    raw = b"".join(chunks)
    # Strip telnet IAC negotiations (IAC CMD [OPT]) and nulls
    cleaned = bytearray()
    i = 0
    while i < len(raw):
        if raw[i] == 0xFF and i + 1 < len(raw):
            cmd = raw[i + 1]
            if cmd in (0xFB, 0xFC, 0xFD, 0xFE) and i + 2 < len(raw):
                i += 3
                continue
            if cmd == 0xFF:  # escaped 0xFF
                cleaned.append(0xFF)
                i += 2
                continue
            i += 2
            continue
        if raw[i] == 0:
            i += 1
            continue
        cleaned.append(raw[i])
        i += 1
    text = cleaned.decode("utf-8", errors="replace")
    return text, "ok"


def main(argv: Optional[List[str]] = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, required=True)
    p.add_argument(
        "--expect",
        choices=("uboot", "linux", "any"),
        default="any",
        help="Expected healthy console state",
    )
    p.add_argument(
        "--seconds",
        type=float,
        default=3.0,
        help="How long to read the console",
    )
    p.add_argument(
        "--grace-ok",
        action="store_true",
        help="For --expect linux: OK if no panic even without login yet",
    )
    p.add_argument("--poke", action="store_true", help="Send CR to wake a prompt")
    p.add_argument("--dump", action="store_true", help="Print raw buffer to stderr")
    args = p.parse_args(argv)

    buf, note = read_console(args.host, args.port, args.seconds, args.poke)
    if buf is None:
        print(f"DOWN port={args.port} reason={note}", flush=True)
        return 2

    if args.dump:
        sys.stderr.write(buf[-4000:])
        if not buf.endswith("\n"):
            sys.stderr.write("\n")

    state, reason = classify(buf, args.expect, args.grace_ok)
    print(f"{state} port={args.port} expect={args.expect} reason={reason}", flush=True)
    if state == "OK":
        return 0
    if state == "UNHEALTHY":
        return 1
    return 2


if __name__ == "__main__":
    sys.exit(main())
