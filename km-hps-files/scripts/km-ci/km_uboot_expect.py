#!/usr/bin/env python3
"""Telnet console helper for KM U-Boot gate scripts and Linux smoke.

Talks to Simics UART telnet (default 127.0.0.1:9123).

Critical: wait_for(..., after=N) only matches in NEW buffer data so a prior
prompt cannot satisfy the next wait (false-instant match).

gate-session: one connection — U-Boot .scr tests, then `run boot_mmc`, then
Linux smoke (avoids broken host-side booti injection).

Default U-Boot gate loads mkimage scripts from the SDMMC FAT partition:
  fatload mmc ${mmcdev}:1 ${scriptaddr} km-tests/<name>.scr
  source ${scriptaddr}
and expects a final line like ``KM_TEST: <stem> PASS``.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import time
import warnings
from pathlib import Path
from typing import Iterable, List, Optional, Tuple

warnings.filterwarnings("ignore", category=DeprecationWarning, module="telnetlib")
import telnetlib  # noqa: E402

DEFAULT_PROMPT = "SOCFPGA_KM # "
DEFAULT_LINUX_SHELL_RE = r"root@\S+:\S+[#$] "
FAIL_HINTS = (
    "Unknown command",
    "error:",
    "ERROR",
    "Failed",
    "failed",
    "No ethernet found",
    "Host controller not initialized",
    "Bad Linux ARM64 Image magic",
)


class ConsoleExpect:
    def __init__(
        self,
        host: str,
        port: int,
        prompt: str = DEFAULT_PROMPT,
        connect_timeout: float = 30.0,
        log_path: Optional[Path] = None,
    ) -> None:
        self.host = host
        self.port = port
        self.prompt = prompt
        self.log_path = log_path
        self._buf = bytearray()
        deadline = time.time() + connect_timeout
        last_err: Optional[BaseException] = None
        self.tn: Optional[telnetlib.Telnet] = None
        while time.time() < deadline:
            try:
                self.tn = telnetlib.Telnet(host, port, timeout=5)
                break
            except OSError as exc:
                last_err = exc
                time.sleep(1.0)
        if self.tn is None:
            raise ConnectionError(f"telnet {host}:{port} failed: {last_err}")
        self._log(f"=== connected {host}:{port} ===\n")

    def close(self) -> None:
        if self.tn is not None:
            try:
                self.tn.close()
            except OSError:
                pass
            self.tn = None

    def mark(self) -> int:
        return len(self._buf)

    def _log(self, text: str) -> None:
        sys.stdout.write(text)
        sys.stdout.flush()
        if self.log_path is not None:
            self.log_path.parent.mkdir(parents=True, exist_ok=True)
            with self.log_path.open("a", encoding="utf-8", errors="replace") as fh:
                fh.write(text)

    def _read_some(self, timeout: float) -> bytes:
        assert self.tn is not None
        chunk = self.tn.read_very_eager()
        if chunk:
            self._buf.extend(chunk)
            self._log(chunk.decode("utf-8", errors="replace"))
            return chunk
        try:
            chunk = self.tn.read_until(b"\n", timeout=min(timeout, 1.0))
        except EOFError as exc:
            raise ConnectionError("telnet EOF") from exc
        if chunk:
            self._buf.extend(chunk)
            self._log(chunk.decode("utf-8", errors="replace"))
        return chunk or b""

    def _compile(self, pattern: str) -> re.Pattern[bytes]:
        use_re = any(c in pattern for c in ".*+?[]()|\\^$")
        if use_re:
            return re.compile(pattern.encode("utf-8"))
        return re.compile(re.escape(pattern.encode("utf-8")))

    def wait_for(self, pattern: str, timeout: float, *, after: int = 0) -> Tuple[str, int]:
        deadline = time.time() + timeout
        cre = self._compile(pattern)
        after = max(0, after)
        while time.time() < deadline:
            data = bytes(self._buf)
            m = cre.search(data, after)
            if m:
                window = data[m.start() :].decode("utf-8", errors="replace")
                return window, m.end()
            remaining = max(0.1, deadline - time.time())
            self._read_some(remaining)
        raise TimeoutError(
            f"timeout waiting for {pattern!r} after={after} timeout={timeout}s "
            f"(buf_len={len(self._buf)})"
        )

    def send_line(self, line: str) -> None:
        assert self.tn is not None
        payload = (line + "\r").encode("utf-8")
        self._log(f">>> {line}\n")
        self.tn.write(payload)

    def drain(self, seconds: float = 0.5) -> None:
        deadline = time.time() + seconds
        while time.time() < deadline:
            self._read_some(0.2)

    def run_commands(
        self,
        commands: Iterable[str],
        cmd_timeout: float,
        fail_hints: Iterable[str] = FAIL_HINTS,
        expect_prompt: Optional[str] = None,
    ) -> Tuple[bool, List[dict]]:
        prompt = expect_prompt or self.prompt
        results: List[dict] = []
        ok_all = True
        try:
            _, end = self.wait_for(re.escape(prompt), cmd_timeout, after=0)
        except TimeoutError:
            self.send_line("")
            _, end = self.wait_for(re.escape(prompt), cmd_timeout, after=0)

        for raw in commands:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            before = self.mark()
            self.send_line(line)
            try:
                _, end = self.wait_for(re.escape(prompt), cmd_timeout, after=before)
            except TimeoutError as exc:
                ok_all = False
                results.append(
                    {
                        "cmd": line,
                        "pass": False,
                        "reason": str(exc),
                        "output": bytes(self._buf[before:]).decode("utf-8", errors="replace"),
                    }
                )
                continue
            out = bytes(self._buf[before:end]).decode("utf-8", errors="replace")
            bad = [h for h in fail_hints if h in out]
            passed = not bad
            if not passed:
                ok_all = False
            results.append(
                {
                    "cmd": line,
                    "pass": passed,
                    "reason": ("fail hints: " + ", ".join(bad)) if bad else "ok",
                    "output": out,
                }
            )
        return ok_all, results


def load_scr(path: Path) -> List[str]:
    return path.read_text(encoding="utf-8", errors="replace").splitlines()


def _interrupt_shell(ce: ConsoleExpect, shell_re: str, timeout: float = 10.0) -> None:
    """Best-effort Ctrl-C if a prior command wedged the shell (no prompt)."""
    assert ce.tn is not None
    ce._log(">>> <Ctrl-C>\n")
    ce.tn.write(b"\x03")
    try:
        ce.wait_for(shell_re, timeout, after=ce.mark())
    except TimeoutError:
        ce.send_line("")
        ce.wait_for(shell_re, timeout, after=ce.mark())


def linux_checks(
    ce: ConsoleExpect,
    *,
    shell_re: str,
    timeout: float,
    eth: bool,
    gateway: str,
    guest_ip: str,
) -> bool:
    ce.drain(0.3)
    # Keep commands SHORT — long lines with &&/||/redirects get truncated on
    # Simics UART telnet and leave bash waiting mid-parse (no prompt).
    checks: List[Tuple[str, str]] = [
        ("nproc", "4"),
        ("uname -a", "Linux"),
    ]
    if eth:
        checks.append(("ip link show", "eth0"))
        checks.append(("ip link set eth0 up", ""))
        checks.append((f"ip addr add {guest_ip}/24 dev eth0", ""))
        checks.append(("sleep 2", ""))
        # Require a reply — "1 packets transmitted" alone matches 100% loss too.
        checks.append((f"ping -c1 -W5 {gateway}", "1 received"))

    ok_all = True
    for cmd, expect in checks:
        before = ce.mark()
        ce.send_line(cmd)
        try:
            _, end = ce.wait_for(shell_re, timeout, after=before)
        except TimeoutError as exc:
            print(f"[FAIL] {cmd}: {exc}", file=sys.stderr)
            ok_all = False
            try:
                _interrupt_shell(ce, shell_re)
            except Exception as recover_exc:  # noqa: BLE001
                print(f"[FAIL] shell recover after {cmd!r}: {recover_exc}", file=sys.stderr)
                return False
            continue
        out = bytes(ce._buf[before:end]).decode("utf-8", errors="replace")
        flat = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", out)
        # ip addr add is ok if address already exists
        if cmd.startswith("ip addr add") and ("File exists" in flat or "file exists" in flat.lower()):
            print(f"[PASS] {cmd} (addr exists)", file=sys.stderr)
            continue
        if expect and expect not in flat and expect not in out:
            print(f"[FAIL] {cmd}: missing {expect!r} in {flat!r}", file=sys.stderr)
            ok_all = False
        else:
            print(f"[PASS] {cmd}", file=sys.stderr)
    return ok_all


def login_linux(
    ce: ConsoleExpect,
    *,
    login_re: str,
    shell_re: str,
    user: str,
    password: str,
    boot_timeout: float,
    timeout: float,
    after: int = 0,
) -> None:
    try:
        ce.wait_for(r"(Linux version|" + login_re + ")", boot_timeout, after=after)
    except TimeoutError:
        buf = bytes(ce._buf[-800:]).decode("utf-8", errors="replace")
        print(f"FAIL: no Linux/login within timeout. Tail:\n{buf}", file=sys.stderr)
        raise
    if login_re not in bytes(ce._buf).decode("utf-8", errors="replace"):
        ce.wait_for(login_re, boot_timeout, after=ce.mark())
    before = ce.mark()
    ce.send_line(user)
    matched, _end = ce.wait_for(r"(Password:|" + shell_re + ")", timeout, after=before)
    if re.search(r"Password:", matched):
        before = ce.mark()
        ce.send_line(password)
        ce.wait_for(shell_re, timeout, after=before)


def cmd_wait_prompt(args: argparse.Namespace) -> int:
    ce = ConsoleExpect(args.host, args.port, prompt=args.prompt, log_path=Path(args.log) if args.log else None)
    try:
        ce.wait_for(re.escape(args.prompt), args.timeout, after=0)
        print("OK: prompt seen", file=sys.stderr)
        return 0
    except Exception as exc:  # noqa: BLE001
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    finally:
        ce.close()


def cmd_run_scr(args: argparse.Namespace) -> int:
    scr = Path(args.scr)
    if not scr.is_file():
        print(f"FAIL: missing {scr}", file=sys.stderr)
        return 1
    ce = ConsoleExpect(args.host, args.port, prompt=args.prompt, log_path=Path(args.log) if args.log else None)
    try:
        ok, results = ce.run_commands(load_scr(scr), cmd_timeout=args.timeout)
        for r in results:
            status = "PASS" if r["pass"] else "FAIL"
            print(f"[{status}] {r['cmd']}: {r['reason']}", file=sys.stderr)
        return 0 if ok else 1
    except Exception as exc:  # noqa: BLE001
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    finally:
        ce.close()


def cmd_linux_smoke(args: argparse.Namespace) -> int:
    """Legacy: wait for login on an already-booting target (no U-Boot drive)."""
    ce = ConsoleExpect(
        args.host,
        args.port,
        prompt=args.prompt,
        log_path=Path(args.log) if args.log else None,
        connect_timeout=max(30.0, args.boot_timeout / 10),
    )
    try:
        login_linux(
            ce,
            login_re=args.login_re,
            shell_re=args.shell_re,
            user=args.user,
            password=args.password,
            boot_timeout=args.boot_timeout,
            timeout=args.timeout,
            after=0,
        )
        ok = linux_checks(
            ce,
            shell_re=args.shell_re,
            timeout=args.timeout,
            eth=args.eth,
            gateway=args.gateway,
            guest_ip=args.guest_ip,
        )
        return 0 if ok else 1
    except Exception as exc:  # noqa: BLE001
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    finally:
        ce.close()


def cmd_guest_eth(args: argparse.Namespace) -> int:
    """After Linux boot: login as root and run guest eth setup (long sims B/C)."""
    ce = ConsoleExpect(
        args.host,
        args.port,
        prompt=args.prompt,
        log_path=Path(args.log) if args.log else None,
        connect_timeout=max(30.0, args.boot_timeout / 10),
    )
    try:
        # Fresh boot → login:; already at shell → proceed without re-login.
        ce.drain(0.5)
        buf = bytes(ce._buf).decode("utf-8", errors="replace")
        if re.search(args.shell_re, buf):
            print("[guest-eth] already at shell", file=sys.stderr)
        else:
            print("[guest-eth] wait login / boot", file=sys.stderr)
            login_linux(
                ce,
                login_re=args.login_re,
                shell_re=args.shell_re,
                user=args.user,
                password=args.password,
                boot_timeout=args.boot_timeout,
                timeout=args.timeout,
                after=0,
            )
            print("[guest-eth] logged in", file=sys.stderr)

        # Prefer short commands — UART truncates long && chains.
        cmds = [args.setup_cmd]
        if args.ping:
            cmds.append(f"ping -c1 -W5 {args.gateway}")

        ok_all = True
        for cmd in cmds:
            before = ce.mark()
            print(f"[guest-eth] >>> {cmd}", file=sys.stderr)
            ce.send_line(cmd)
            try:
                _, end = ce.wait_for(args.shell_re, args.timeout, after=before)
            except TimeoutError as exc:
                print(f"[FAIL] {cmd}: {exc}", file=sys.stderr)
                ok_all = False
                try:
                    _interrupt_shell(ce, args.shell_re)
                except Exception as recover_exc:  # noqa: BLE001
                    print(f"[FAIL] shell recover: {recover_exc}", file=sys.stderr)
                    return 1
                continue
            out = bytes(ce._buf[before:end]).decode("utf-8", errors="replace")
            if cmd.startswith("ping") and "1 received" not in out:
                print(f"[FAIL] {cmd}: no reply in {out!r}", file=sys.stderr)
                ok_all = False
            else:
                print(f"[PASS] {cmd}", file=sys.stderr)
        return 0 if ok_all else 1
    except Exception as exc:  # noqa: BLE001
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    finally:
        ce.close()


def _scr_stem(name: str) -> str:
    return Path(name).stem.lower()


def run_fatload_scr(
    ce: ConsoleExpect,
    name: str,
    *,
    fat_dir: str,
    mmc_spec: str,
    scriptaddr: str,
    cmd_timeout: float,
    prompt: str,
) -> Tuple[bool, List[dict]]:
    """Load mkimage .scr from SDMMC FAT and ``source`` it; require KM_TEST PASS."""
    stem = _scr_stem(name)
    # dt.scr on host/plan maps to fdt.scr on the image
    fat_name = "fdt.scr" if stem == "dt" else name
    fat_stem = _scr_stem(fat_name)
    fat_path = f"{fat_dir.rstrip('/')}/{fat_name}"
    results: List[dict] = []

    load_cmd = f"fatload mmc {mmc_spec} {scriptaddr} {fat_path}"
    source_cmd = f"source {scriptaddr}"

    before = ce.mark()
    ce.send_line(load_cmd)
    try:
        _, end = ce.wait_for(re.escape(prompt), cmd_timeout, after=before)
    except TimeoutError as exc:
        results.append({"cmd": load_cmd, "pass": False, "reason": str(exc), "output": ""})
        return False, results
    load_out = bytes(ce._buf[before:end]).decode("utf-8", errors="replace")
    load_bad = [
        h
        for h in (
            "File not found",
            "No such file",
            "not found",
            "Failed",
            "error",
            "** Unrecognized",
        )
        if h.lower() in load_out.lower()
    ]
    # fatload prints "bytes read" / size on success
    load_ok = not load_bad and (
        "bytes read" in load_out.lower()
        or re.search(r"\b\d+\s+bytes\b", load_out, re.I) is not None
        or "reading" in load_out.lower()
    )
    if not load_ok and not load_bad:
        # Some U-Boot builds only reprint the prompt; treat empty error as ok if no fail hints
        load_ok = "Unknown command" not in load_out
    results.append(
        {
            "cmd": load_cmd,
            "pass": load_ok,
            "reason": ("fail: " + ", ".join(load_bad)) if load_bad else ("ok" if load_ok else "no load confirmation"),
            "output": load_out,
        }
    )
    if not load_ok:
        return False, results

    before = ce.mark()
    ce.send_line(source_cmd)
    try:
        _, end = ce.wait_for(re.escape(prompt), cmd_timeout, after=before)
    except TimeoutError as exc:
        results.append({"cmd": source_cmd, "pass": False, "reason": str(exc), "output": ""})
        return False, results
    src_out = bytes(ce._buf[before:end]).decode("utf-8", errors="replace")
    pass_re = re.compile(rf"KM_TEST:\s*{re.escape(fat_stem)}\s+PASS\b", re.I)
    fail_re = re.compile(rf"KM_TEST:\s*{re.escape(fat_stem)}\s+FAIL\b", re.I)
    if fail_re.search(src_out):
        ok = False
        reason = f"KM_TEST: {fat_stem} FAIL"
    elif pass_re.search(src_out):
        ok = True
        reason = f"KM_TEST: {fat_stem} PASS"
    else:
        ok = False
        reason = f"missing KM_TEST: {fat_stem} PASS"
    results.append({"cmd": source_cmd, "pass": ok, "reason": reason, "output": src_out})
    return ok, results


def cmd_gate_session(args: argparse.Namespace) -> int:
    """One telnet session: U-Boot scrs → run boot_mmc → Linux smoke."""
    scr_dir = Path(args.scr_dir) if args.scr_dir else None
    names = [s.strip() for s in args.scrs.split(",") if s.strip()]
    results = {
        "uboot": {},
        "linux_smoke": "FAIL",
        "boot_cmd": args.boot_cmd,
        "scr_mode": args.scr_mode,
    }
    ce = ConsoleExpect(
        args.host,
        args.port,
        prompt=args.prompt,
        log_path=Path(args.log) if args.log else None,
        connect_timeout=60.0,
    )
    try:
        print("[gate-session] wait U-Boot prompt", file=sys.stderr)
        ce.wait_for(re.escape(args.prompt), args.uboot_boot_timeout, after=0)
        print("OK: prompt seen", file=sys.stderr)

        uboot_ok = True
        if args.scr_mode == "fatload":
            # Ensure MMC ready once (matches boot_mmc path: mmc ${mmcdev}:1)
            print("[gate-session] mmc rescan for FAT km-tests", file=sys.stderr)
            ok_prep, prep_results = ce.run_commands(
                ["mmc rescan"],
                cmd_timeout=min(60.0, args.scr_timeout),
            )
            for r in prep_results:
                status = "PASS" if r["pass"] else "FAIL"
                print(f"[{status}] {r['cmd']}: {r['reason']}", file=sys.stderr)
            if not ok_prep:
                print("[FAIL] mmc rescan", file=sys.stderr)

            for name in names:
                print(
                    f"[gate-session] fatload {args.fat_dir}/{name} → source",
                    file=sys.stderr,
                )
                ok, cmd_results = run_fatload_scr(
                    ce,
                    name,
                    fat_dir=args.fat_dir,
                    mmc_spec=args.mmc_spec,
                    scriptaddr=args.scriptaddr,
                    cmd_timeout=args.scr_timeout,
                    prompt=args.prompt,
                )
                for r in cmd_results:
                    status = "PASS" if r["pass"] else "FAIL"
                    print(f"[{status}] {r['cmd']}: {r['reason']}", file=sys.stderr)
                results["uboot"][name] = "PASS" if ok else "FAIL"
                if not ok:
                    uboot_ok = False
        else:
            # Legacy: paste host-side plain-text uboot-scr/*.scr line by line
            if scr_dir is None:
                print("FAIL: --scr-mode paste requires --scr-dir", file=sys.stderr)
                return 1
            for name in names:
                path = scr_dir / name
                print(f"[gate-session] paste {name}", file=sys.stderr)
                if not path.is_file():
                    print(f"[FAIL] missing {path}", file=sys.stderr)
                    results["uboot"][name] = "FAIL"
                    uboot_ok = False
                    continue
                ok, cmd_results = ce.run_commands(load_scr(path), cmd_timeout=args.scr_timeout)
                for r in cmd_results:
                    status = "PASS" if r["pass"] else "FAIL"
                    print(f"[{status}] {r['cmd']}: {r['reason']}", file=sys.stderr)
                results["uboot"][name] = "PASS" if ok else "FAIL"
                if not ok:
                    uboot_ok = False

        print(f"[gate-session] {args.boot_cmd} (SDMMC Linux)", file=sys.stderr)
        before = ce.mark()
        ce.send_line(args.boot_cmd)
        login_linux(
            ce,
            login_re=args.login_re,
            shell_re=args.shell_re,
            user=args.user,
            password=args.password,
            boot_timeout=args.boot_timeout,
            timeout=args.timeout,
            after=before,
        )
        linux_ok = linux_checks(
            ce,
            shell_re=args.shell_re,
            timeout=args.timeout,
            eth=args.eth,
            gateway=args.gateway,
            guest_ip=args.guest_ip,
        )
        results["linux_smoke"] = "PASS" if linux_ok else "FAIL"
        overall = uboot_ok and linux_ok
        results["overall"] = "PASS" if overall else "FAIL"
        if args.results_json:
            Path(args.results_json).write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
        print(f"[gate-session] overall={results['overall']}", file=sys.stderr)
        return 0 if overall else 1
    except Exception as exc:  # noqa: BLE001
        print(f"FAIL: {exc}", file=sys.stderr)
        results["overall"] = "FAIL"
        results["error"] = str(exc)
        if args.results_json:
            Path(args.results_json).write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
        return 1
    finally:
        ce.close()


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=9123)
    p.add_argument("--prompt", default=DEFAULT_PROMPT)
    p.add_argument("--log", default="")
    sub = p.add_subparsers(dest="cmd", required=True)

    w = sub.add_parser("wait-prompt", help="Wait for U-Boot prompt")
    w.add_argument("--timeout", type=float, default=300)
    w.set_defaults(func=cmd_wait_prompt)

    r = sub.add_parser("run-scr", help="Paste and run a uboot-scr/*.scr file")
    r.add_argument("scr", help="Path to .scr (plain-text command list)")
    r.add_argument("--timeout", type=float, default=60, help="Per-command timeout")
    r.set_defaults(func=cmd_run_scr)

    l = sub.add_parser("linux-smoke", help="Login and run Linux smoke checks")
    l.add_argument("--boot-timeout", type=float, default=600)
    l.add_argument("--timeout", type=float, default=120)
    l.add_argument("--login-re", default="login:")
    l.add_argument("--shell-re", default=DEFAULT_LINUX_SHELL_RE)
    l.add_argument("--user", default="root")
    l.add_argument("--password", default="")
    l.add_argument("--eth", action="store_true", default=True)
    l.add_argument("--no-eth", action="store_false", dest="eth")
    l.add_argument("--gateway", default="10.10.0.1")
    l.add_argument("--guest-ip", default="10.10.0.100")
    l.set_defaults(func=cmd_linux_smoke)

    e = sub.add_parser(
        "guest-eth",
        help="Login after Linux boot and run guest eth setup (long sims)",
    )
    e.add_argument("--boot-timeout", type=float, default=600)
    e.add_argument("--timeout", type=float, default=120)
    e.add_argument("--login-re", default="login:")
    e.add_argument("--shell-re", default=DEFAULT_LINUX_SHELL_RE)
    e.add_argument("--user", default="root")
    e.add_argument("--password", default="")
    e.add_argument(
        "--setup-cmd",
        default="./setup-simics-eth0.sh",
        help="Guest command to bring up eth0 (default: ./setup-simics-eth0.sh)",
    )
    e.add_argument("--gateway", default="10.10.0.1")
    e.add_argument(
        "--ping",
        action="store_true",
        default=True,
        help="Ping gateway after setup (default: on)",
    )
    e.add_argument("--no-ping", action="store_false", dest="ping")
    e.set_defaults(func=cmd_guest_eth)

    g = sub.add_parser(
        "gate-session",
        help="U-Boot scrs then run boot_mmc + Linux smoke (one telnet session)",
    )
    g.add_argument(
        "--scr-mode",
        choices=("fatload", "paste"),
        default="fatload",
        help="fatload: SDMMC FAT km-tests/*.scr + source (default); paste: host uboot-scr/",
    )
    g.add_argument(
        "--scr-dir",
        default="",
        help="Host dir of plain-text .scr (paste mode only)",
    )
    g.add_argument(
        "--scrs",
        default="fdt.scr,i2c.scr,i3c.scr,usb.scr,eth.scr",
        help="Comma-separated script names (image has fdt.scr not dt.scr)",
    )
    g.add_argument(
        "--fat-dir",
        default="km-tests",
        help="FAT directory under mmc partition (default: km-tests)",
    )
    g.add_argument(
        "--mmc-spec",
        default="${mmcdev}:1",
        help="fatload mmc device:part (default: ${mmcdev}:1)",
    )
    g.add_argument(
        "--scriptaddr",
        default="${scriptaddr}",
        help="Load address for .scr (default: ${scriptaddr})",
    )
    g.add_argument("--boot-cmd", default="run boot_mmc", help="U-Boot cmd to reach Linux")
    g.add_argument("--uboot-boot-timeout", type=float, default=300)
    g.add_argument("--scr-timeout", type=float, default=300)
    g.add_argument("--boot-timeout", type=float, default=600)
    g.add_argument("--timeout", type=float, default=120)
    g.add_argument("--login-re", default="login:")
    g.add_argument("--shell-re", default=DEFAULT_LINUX_SHELL_RE)
    g.add_argument("--user", default="root")
    g.add_argument("--password", default="")
    g.add_argument("--eth", action="store_true", default=True)
    g.add_argument("--no-eth", action="store_false", dest="eth")
    g.add_argument("--gateway", default="10.10.0.1")
    g.add_argument("--guest-ip", default="10.10.0.100")
    g.add_argument("--results-json", default="")
    g.set_defaults(func=cmd_gate_session)
    return p


def main(argv: Optional[List[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    sys.exit(main())
