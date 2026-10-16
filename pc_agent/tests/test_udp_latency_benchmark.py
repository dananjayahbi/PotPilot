"""Doc 46 M2/M3/M7/M8/M9 — UDP round-trip latency benchmark + auth rejection + mDNS.

Benchmark file (Doc 46 §5): select it alone with
``pytest pc_agent/tests/test_udp_latency_benchmark.py``.

* **M2 (PC-side, blocking)** — 500 timed probes + 50 warm-up against the REAL
  ``start_udp_server`` with a fake echo sink; p95 < 5.0 ms, one re-run allowed
  and both runs must pass (Doc 46 §7/§10). The phone-originated M2 leg runs
  only when an Android device is attached (§7: CI-safe ``pytest.skip``).
* **M3 (blocking)** — 20 wrong-auth probes: zero echoed, zero agent
  side-effects (real server + responder variants).
* **M7 (blocking)** — real ``_potpilot._tcp.local.`` browse resolves in <= 10 s.
* **M8/M9 (report)** — RTT stability and PC-local loopback numbers, printed
  with no threshold gate.
"""

from __future__ import annotations

import asyncio
import json
import re
import shutil
import socket
import subprocess
import time
from typing import Any

import pytest

from pc_agent.network.mdns_broadcaster import SERVICE_TYPE, MdnsBroadcaster, collect_lan_ipv4
from pc_agent.network.udp_packet_codec import PacketType, pack_packet
from pc_agent.network.udp_server import start_udp_server
from pc_agent.tests.conftest import (
    AUTH_BYTE,
    REPO_ROOT,
    TOKEN_HEX,
    compute_stats,
    evaluate,
    format_stats,
    stats_from_dict,
)

LOOPBACK_HOST = "127.0.0.1"
WARMUP = 50
SAMPLES = 500
LOOPBACK_SAMPLES = 1_000
RTT_P95_BUDGET_MS = 5.0  # frozen < 5 ms LAN/loopback target (Doc 46 §5 M2)
AUTH_PROBES = 20
MDNS_WINDOW_S = 10.0
MOBILE_APP_DIR = REPO_ROOT / "mobile_app"
BENCH_RESULT_RE = re.compile(r"BENCH_RESULT:(\{.*\})")

_FLUTTER_DEVICES_CACHE: list[dict[str, Any]] | None = None
_FLUTTER_DEVICES_RESOLVED = False


def _next_seq(current: int) -> int:
    return (current + 1) & 0xFFFF


class _FixedUdpAuth:
    """Doc 15 seam: accepts exactly the harness auth byte."""

    def __init__(self, ok_byte: int) -> None:
        self._ok_byte = ok_byte
        self.calls: list[int] = []

    def verify_udp_auth_byte(self, byte: int) -> bool:
        self.calls.append(byte)
        return byte == self._ok_byte


class _EchoMouse:
    """Fake sink (fast, deterministic): reflects the probe bytes back to the client."""

    def __init__(self) -> None:
        self.transport: asyncio.DatagramTransport | None = None
        self.peer: tuple[str, int] | None = None
        self.reply: bytes = b""
        self.moves: list[tuple[int, int]] = []

    def move_relative(self, dx: int, dy: int) -> None:
        self.moves.append((dx, dy))
        if self.transport is not None and self.peer is not None and self.reply:
            self.transport.sendto(self.reply, self.peer)

    def scroll(self, vertical: int, horizontal: int) -> None:
        del vertical, horizontal

    def button(self, button_id: int, state: int) -> None:
        del button_id, state


class _RecordingMouse:
    """Fake sink recording accepted moves; never replies."""

    def __init__(self) -> None:
        self.moves: list[tuple[int, int]] = []

    def move_relative(self, dx: int, dy: int) -> None:
        self.moves.append((dx, dy))

    def scroll(self, vertical: int, horizontal: int) -> None:
        del vertical, horizontal

    def button(self, button_id: int, state: int) -> None:
        del button_id, state


# ---------------------------------------------------------------------------
# M9 — Python client <-> echo responder on loopback (report-only)
# ---------------------------------------------------------------------------


def _measure_echo_rtt(
    *, host: str, port: int, warmup: int, samples: int, budget_s: float = 2.0
) -> Any:
    rtts: list[float] = []
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(budget_s)
    sock.bind((host, 0))
    seq = 0
    try:
        for index in range(warmup + samples):
            seq = _next_seq(seq)
            packet = pack_packet(
                int(PacketType.MOUSE_MOVE),
                AUTH_BYTE,
                (index % 64) - 32,
                (index % 32) - 16,
                seq,
            )
            started = time.perf_counter_ns()
            sock.sendto(packet, (host, port))
            try:
                data, _addr = sock.recvfrom(64)
            except TimeoutError as exc:
                raise AssertionError(
                    f"echo probe {index} lost after {budget_s}s — responder not replying"
                ) from exc
            if data != packet:
                raise AssertionError(
                    f"echo mismatch at probe {index}: {data.hex(' ')} != {packet.hex(' ')}"
                )
            if index >= warmup:
                rtts.append((time.perf_counter_ns() - started) / 1_000_000.0)
    finally:
        sock.close()
    return compute_stats(rtts)


def test_m9_pc_local_loopback_rtt_report_only(echo_responder: Any) -> None:
    """M9 (Report): 1000 Python probes <-> responder on 127.0.0.1; no gate."""
    stats = _measure_echo_rtt(
        host=echo_responder.host,
        port=echo_responder.port,
        warmup=WARMUP,
        samples=LOOPBACK_SAMPLES,
    )
    print(format_stats("M9 PC-local loopback (report-only)", stats))
    assert len(stats.samples_ms) == LOOPBACK_SAMPLES
    assert echo_responder.probe_count == WARMUP + LOOPBACK_SAMPLES
    verdict = "PASS" if evaluate(stats, RTT_P95_BUDGET_MS) else "FAIL"
    print(f"M9 informational vs {RTT_P95_BUDGET_MS} ms p95 (not gated): {verdict}")


# ---------------------------------------------------------------------------
# M2 PC-side — real sockets against the REAL start_udp_server + fake sink
# ---------------------------------------------------------------------------


async def _measure_real_server_rtt(*, warmup: int, samples: int) -> Any:
    """Round trip through the REAL agent UDP hot path: parse -> auth -> seq -> sink echo."""
    mouse = _EchoMouse()
    handle = await start_udp_server(
        auth=_FixedUdpAuth(AUTH_BYTE), mouse=mouse, host=LOOPBACK_HOST, port=0
    )
    try:
        loop = asyncio.get_running_loop()
        client = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        client.setblocking(False)
        client.bind((LOOPBACK_HOST, 0))
        client_port = int(client.getsockname()[1])
        mouse.transport = handle.transport
        mouse.peer = (LOOPBACK_HOST, client_port)
        rtts: list[float] = []
        seq = 0
        try:
            for index in range(warmup + samples):
                seq = _next_seq(seq)
                packet = pack_packet(
                    int(PacketType.MOUSE_MOVE),
                    AUTH_BYTE,
                    (index % 64) - 32,
                    (index % 32) - 16,
                    seq,
                )
                mouse.reply = packet  # sink reflects exactly these bytes
                started = time.perf_counter_ns()
                await loop.sock_sendto(client, packet, (LOOPBACK_HOST, handle.port))
                try:
                    data, _addr = await asyncio.wait_for(
                        loop.sock_recvfrom(client, 64), timeout=2.0
                    )
                except TimeoutError as exc:
                    raise AssertionError(
                        f"real-server probe {index} lost (auth/seq/dispatch path stalled)"
                    ) from exc
                if data != packet:
                    raise AssertionError(
                        f"real-server echo mismatch at probe {index}: "
                        f"{data.hex(' ')} != {packet.hex(' ')}"
                    )
                if index >= warmup:
                    rtts.append((time.perf_counter_ns() - started) / 1_000_000.0)
        finally:
            client.close()
        return compute_stats(rtts)
    finally:
        await handle.stop()


def test_m2_pc_loopback_rtt_against_real_udp_server() -> None:
    """M2 PC-side (Blocking) + M8: p95 < 5 ms through the REAL ``start_udp_server``."""
    first = asyncio.run(_measure_real_server_rtt(warmup=WARMUP, samples=SAMPLES))
    print(format_stats("M2 real-server run 1/1", first))
    assert len(first.samples_ms) == SAMPLES

    attempts = [first]
    if not evaluate(first, RTT_P95_BUDGET_MS):
        # Doc 46 §7/§10: one re-run allowed; BOTH runs' p95 must pass.
        second = asyncio.run(_measure_real_server_rtt(warmup=WARMUP, samples=SAMPLES))
        print(format_stats("M2 real-server run 2/2 (re-run policy)", second))
        attempts.append(second)

    assert all(evaluate(attempt, RTT_P95_BUDGET_MS) for attempt in attempts), (
        "M2 FAIL: p95 must be < "
        f"{RTT_P95_BUDGET_MS} ms on every run; got "
        + "; ".join(f"p95={attempt.p95:.3f} ms" for attempt in attempts)
    )
    print(format_stats("M8 RTT stability (report-only)", first))


# ---------------------------------------------------------------------------
# M3 — auth rejection (blocking)
# ---------------------------------------------------------------------------


def test_m3_wrong_auth_never_reaches_agent_sinks() -> None:
    """M3 (Blocking): 20 wrong-auth probes -> 0 accepted, 0 sink side-effects."""

    async def scenario() -> tuple[Any, list[tuple[int, int]]]:
        mouse = _RecordingMouse()
        auth = _FixedUdpAuth(AUTH_BYTE)
        handle = await start_udp_server(
            auth=auth, mouse=mouse, host=LOOPBACK_HOST, port=0
        )
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.settimeout(1.0)
        try:
            wrong = AUTH_BYTE ^ 0xFF
            for index in range(AUTH_PROBES):
                sock.sendto(
                    pack_packet(int(PacketType.MOUSE_MOVE), wrong, 1, 1, 1 + index),
                    (LOOPBACK_HOST, handle.port),
                )
            good = pack_packet(int(PacketType.MOUSE_MOVE), AUTH_BYTE, 7, -3, AUTH_PROBES + 1)
            sock.sendto(good, (LOOPBACK_HOST, handle.port))
            await asyncio.sleep(0.2)  # let the loop drain the backlog
            stats = handle.stats
            moves = list(mouse.moves)
            await handle.stop()
            return stats, moves
        finally:
            sock.close()

    stats, moves = asyncio.run(scenario())
    assert stats.received == AUTH_PROBES + 1
    assert stats.auth_failures == AUTH_PROBES, stats
    assert stats.accepted == 1, stats
    # Zero side-effects from wrong-auth traffic: only the good probe moved the sink.
    assert moves == [(7, -3)], f"unexpected sink activity: {moves}"


def test_m3_echo_responder_rejects_wrong_auth(echo_responder: Any) -> None:
    """M3 (Blocking): 20 wrong-auth probes -> 0 echoed, rejected == 20."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(0.3)
    wrong = AUTH_BYTE ^ 0xFF
    try:
        for index in range(AUTH_PROBES):
            sock.sendto(
                pack_packet(int(PacketType.MOUSE_MOVE), wrong, 1, 1, 1 + index),
                (echo_responder.host, echo_responder.port),
            )
        time.sleep(0.25)  # drain window for the responder thread
        with pytest.raises(TimeoutError):
            data, _addr = sock.recvfrom(64)
            raise AssertionError(f"wrong-auth probe was echoed back: {data.hex(' ')}")
        assert echo_responder.probe_count == 0
        assert echo_responder.rejected == AUTH_PROBES

        # Liveness: one auth-valid probe still round-trips afterwards.
        good = pack_packet(int(PacketType.MOUSE_MOVE), AUTH_BYTE, 5, 5, 100)
        sock.sendto(good, (echo_responder.host, echo_responder.port))
        data, _addr = sock.recvfrom(64)
        assert data == good
        assert echo_responder.probe_count == 1
    finally:
        sock.close()


# ---------------------------------------------------------------------------
# M7 — mDNS discoverability (blocking)
# ---------------------------------------------------------------------------


async def _discover_mdns(budget_s: float) -> tuple[str, int]:
    """Browse ``_potpilot._tcp.local.`` against the REAL broadcaster; resolve in budget."""
    from zeroconf import ServiceListener
    from zeroconf.asyncio import AsyncServiceBrowser, AsyncZeroconf

    loop = asyncio.get_running_loop()
    resolved: list[str] = []
    done: asyncio.Future[None] = loop.create_future()

    def _mark_found(name: str) -> None:
        if name not in resolved:
            resolved.append(name)
        if not done.done():
            done.set_result(None)

    class _ResolveListener(ServiceListener):
        """zeroconf dispatches these synchronously; bridge to the test loop."""

        def add_service(self, zc: Any, type_: str, name: str) -> None:
            del zc, type_
            loop.call_soon_threadsafe(_mark_found, name)

        def update_service(self, zc: Any, type_: str, name: str) -> None:
            del zc, type_, name

        def remove_service(self, zc: Any, type_: str, name: str) -> None:
            del zc, type_, name

    browse_zc = AsyncZeroconf()
    broadcaster = MdnsBroadcaster(hostname=f"potpilot-bench-{1000 + (time.time_ns() % 8999)}")
    browser: Any = None
    try:
        await broadcaster.start()
        browser = AsyncServiceBrowser(browse_zc.zeroconf, SERVICE_TYPE, _ResolveListener())
        try:
            await asyncio.wait_for(done, budget_s)
        except TimeoutError as exc:
            raise AssertionError(
                f"M7: no {SERVICE_TYPE} service resolved within {budget_s:.0f} s"
            ) from exc
        # Resolve outside the callback via the documented async API (test loop).
        for name in resolved:
            info = await browse_zc.async_get_service_info(SERVICE_TYPE, name, timeout=2000)
            if info is not None and info.port:
                return name, int(info.port)
        raise AssertionError(f"M7: service announced but unresolved: {resolved}")
    finally:
        if browser is not None:
            await browser.async_cancel()
        await broadcaster.stop()
        await browse_zc.async_close()


def test_m7_mdns_discoverability() -> None:
    """M7 (Blocking): browse resolves a real ``_potpilot._tcp.local.`` service <= 10 s."""
    started = time.perf_counter()
    name, port = asyncio.run(_discover_mdns(MDNS_WINDOW_S))
    elapsed = time.perf_counter() - started
    print(
        f"M7: resolved {name} -> port {port} in {elapsed:.2f} s "
        f"(window {MDNS_WINDOW_S:.0f} s)"
    )
    assert port == 50506, f"mDNS advertised port {port} != frozen WS port 50506"


# ---------------------------------------------------------------------------
# M2 phone leg — flutter device orchestration (skips without a device)
# ---------------------------------------------------------------------------


def _flutter_devices() -> list[dict[str, Any]] | None:
    """Parse ``flutter devices --machine`` once; None when flutter is unusable here."""
    global _FLUTTER_DEVICES_CACHE, _FLUTTER_DEVICES_RESOLVED
    if _FLUTTER_DEVICES_RESOLVED:
        return _FLUTTER_DEVICES_CACHE
    resolved: list[dict[str, Any]] | None = None
    flutter = shutil.which("flutter")
    if flutter is not None:
        try:
            proc = subprocess.run(
                [flutter, "devices", "--machine"],
                capture_output=True,
                text=True,
                timeout=60,
                cwd=MOBILE_APP_DIR,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            proc = None
        if proc is not None:
            start = (proc.stdout or "").find("[")
            if start >= 0:
                try:
                    data, _end = json.JSONDecoder().raw_decode(proc.stdout[start:])
                except ValueError:
                    data = None
                if isinstance(data, list):
                    resolved = [entry for entry in data if isinstance(entry, dict)]
    _FLUTTER_DEVICES_CACHE = resolved
    _FLUTTER_DEVICES_RESOLVED = True
    return resolved


def _run_device_bench(echo_responder: Any, device_id: str) -> Any:
    """Launch the Dart bench on-device and parse its BENCH_RESULT JSON line."""
    flutter = shutil.which("flutter")
    assert flutter is not None  # _flutter_devices() already proved availability
    lan_ips = collect_lan_ipv4()
    if not lan_ips:
        pytest.skip("no LAN IPv4 on this host — phone RTT bench impossible")
    cmd = [
        flutter,
        "test",
        "integration_test/udp_latency_bench_test.dart",
        "-d",
        device_id,
        f"--dart-define=PC_HOST={lan_ips[0]}",
        f"--dart-define=PC_PORT={echo_responder.port}",
        f"--dart-define=PC_TOKEN={TOKEN_HEX}",
        f"--dart-define=PC_SAMPLES={SAMPLES}",
    ]
    proc = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=150,
        cwd=MOBILE_APP_DIR,
        check=False,
    )
    output = f"{proc.stdout or ''}\n{proc.stderr or ''}"
    match = BENCH_RESULT_RE.search(output)
    if match is None:
        raise AssertionError(
            f"device bench produced no BENCH_RESULT (exit {proc.returncode}); "
            f"tail: {output[-1200:]}"
        )
    data = json.loads(match.group(1))
    stats = stats_from_dict(data)
    if len(stats.samples_ms) < SAMPLES and "samplesMs" in data:
        raise AssertionError(f"device bench incomplete: {len(stats.samples_ms)} samples")
    return stats


def test_m2_phone_udp_latency_bench(echo_responder: Any) -> None:
    """M2 phone leg: Dart probe -> responder -> Dart receive; p95 < 5 ms (§7 skip-safe)."""
    devices = _flutter_devices()
    if devices is None:
        pytest.skip("flutter unavailable or `flutter devices --machine` unparsable")
    android = [
        entry
        for entry in devices
        if entry.get("platform") == "android" and entry.get("id")
    ]
    if not android:
        pytest.skip("no Android device attached — M2 phone bench skipped (M9 covers CI)")

    stats = _run_device_bench(echo_responder, str(android[0]["id"]))
    print(format_stats("M2 phone bench run 1", stats))
    attempts = [stats]
    if not evaluate(stats, RTT_P95_BUDGET_MS):
        retry = _run_device_bench(echo_responder, str(android[0]["id"]))
        print(format_stats("M2 phone bench run 2 (re-run policy)", retry))
        attempts.append(retry)
    assert all(evaluate(attempt, RTT_P95_BUDGET_MS) for attempt in attempts), (
        "M2 phone FAIL: p95 must be < "
        f"{RTT_P95_BUDGET_MS} ms on every run; got "
        + "; ".join(f"p95={attempt.p95:.3f} ms" for attempt in attempts)
    )
