"""Doc 16 §9 — mDNS broadcaster tests (fake zeroconf + monkeypatched IPs)."""

import asyncio
import re
import socket

from pc_agent.network import mdns_broadcaster as mdns
from pc_agent.network.mdns_broadcaster import (
    IP_REFRESH_INTERVAL_S,
    SERVICE_PORT,
    SERVICE_TYPE,
    TXT_UDP,
    TXT_VERSION,
    TXT_WS,
    MdnsBroadcaster,
    collect_lan_ipv4,
    sanitize_hostname,
)

_TOKEN_HEX_RE = re.compile(r"[0-9a-f]{32}")
_DNS_LABEL_RE = re.compile(r"[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?")


class FakeAsyncZeroconf:
    """Recording stand-in for zeroconf.asyncio.AsyncZeroconf (no sockets)."""

    instances: list["FakeAsyncZeroconf"] = []

    def __init__(self) -> None:
        self.registered: list = []
        self.updated: list = []
        self.unregistered: list = []
        self.closed = False
        FakeAsyncZeroconf.instances.append(self)

    async def async_register_service(self, info, **kwargs) -> None:
        self.registered.append(info)

    async def async_update_service(self, info) -> None:
        self.updated.append(info)

    async def async_unregister_service(self, info) -> None:
        self.unregistered.append(info)

    async def async_close(self) -> None:
        self.closed = True


class ExplodingZeroconf:
    """Simulates zeroconf init failure (no NIC / service conflict)."""

    def __init__(self) -> None:
        raise RuntimeError("simulated zeroconf init failure")


def _install_fake(monkeypatch, ips):
    FakeAsyncZeroconf.instances.clear()
    monkeypatch.setattr(mdns, "AsyncZeroconf", FakeAsyncZeroconf)
    monkeypatch.setattr(mdns, "collect_lan_ipv4", lambda: list(ips))
    # The real primary_lan_ipv4() probes the default route; tests pin it to
    # the first simulated fallback so the single advertised A record stays
    # deterministic (the probe would return this machine's own NIC).
    monkeypatch.setattr(
        mdns, "primary_lan_ipv4", lambda fallbacks=None: next(iter(fallbacks or []), None)
    )
    return FakeAsyncZeroconf.instances


def test_service_info_fields(monkeypatch):
    ips = ["192.168.1.42", "10.0.0.7"]
    instances = _install_fake(monkeypatch, ips)

    async def scenario():
        broadcaster = MdnsBroadcaster(hostname="My Test_PC")
        await broadcaster.start()
        fake = instances[0]
        assert len(fake.registered) == 1
        info = fake.registered[0]
        # §5 frozen layout
        assert info.type == SERVICE_TYPE == "_potpilot._tcp.local."
        assert info.port == SERVICE_PORT == 50506
        assert info.decoded_properties == {
            TXT_UDP: "50505",
            TXT_WS: "50506",
            TXT_VERSION: "1",
        }
        assert info.name == "My-Test-PC._potpilot._tcp.local."
        # Single primary A record (multi-NIC flip-flop fix, 2026-10-17):
        assert info.parsed_addresses() == [ips[0]]
        # no secret of any kind in the advertised record
        assert set(info.decoded_properties) == {"udp", "ws", "ver"}
        assert broadcaster.is_registered
        assert broadcaster.service_name == info.name
        assert broadcaster.service_name == "My-Test-PC._potpilot._tcp.local."
        await broadcaster.stop()

    asyncio.run(scenario())


def test_sanitize_hostname():
    assert sanitize_hostname("") == "potpilot-pc"
    assert sanitize_hostname("   ") == "potpilot-pc"
    assert sanitize_hostname("!!") == "potpilot-pc"
    assert sanitize_hostname("My PC") == "My-PC"
    assert sanitize_hostname("under_score") == "under-score"
    assert sanitize_hostname("héllo") == "hello"
    assert sanitize_hostname("-leading") == "leading"
    assert sanitize_hostname("trailing-") == "trailing"
    # every result is a valid DNS label of at most 63 chars
    long_name = "x" * 100
    for value in ("My PC", "under_score", "héllo", long_name, "--a--b--"):
        sanitized = sanitize_hostname(value)
        assert _DNS_LABEL_RE.fullmatch(sanitized), sanitized
        assert len(sanitized) <= 63


def test_refresh_detects_change(monkeypatch):
    ips_state = {"value": ["10.0.0.2"]}
    instances = _install_fake(monkeypatch, ips_state["value"])
    monkeypatch.setattr(mdns, "collect_lan_ipv4", lambda: list(ips_state["value"]))
    seen: list[list[str]] = []

    async def scenario():
        broadcaster = MdnsBroadcaster(on_ips_changed=seen.append)
        await broadcaster.start()
        fake = instances[0]
        assert len(fake.registered) == 1

        ips_state["value"] = ["10.0.0.3", "10.0.0.4"]
        changed = await broadcaster.refresh()
        assert changed is True
        assert len(fake.updated) == 1
        # re-announces only the single new primary (first fallback)
        assert fake.updated[0].parsed_addresses() == ["10.0.0.3"]
        assert seen == [["10.0.0.3"]]
        await broadcaster.stop()

    asyncio.run(scenario())


def test_refresh_no_change_silent(monkeypatch):
    instances = _install_fake(monkeypatch, ["10.0.0.2"])
    seen: list[list[str]] = []

    async def scenario():
        broadcaster = MdnsBroadcaster(on_ips_changed=seen.append)
        await broadcaster.start()
        assert await broadcaster.refresh() is False
        assert instances[0].updated == []
        assert seen == []
        await broadcaster.stop()

    asyncio.run(scenario())


def test_collect_lan_ipv4_filters(monkeypatch):
    def fake_getaddrinfo(host, port, family=0, type=0, proto=0, flags=0):
        return [
            (socket.AF_INET, socket.SOCK_DGRAM, 0, "", ("127.0.0.1", 0)),
            (socket.AF_INET, socket.SOCK_DGRAM, 0, "", ("169.254.10.10", 0)),
            (socket.AF_INET, socket.SOCK_DGRAM, 0, "", ("0.0.0.0", 0)),
            (socket.AF_INET, socket.SOCK_DGRAM, 0, "", ("192.168.1.50", 0)),
            (socket.AF_INET, socket.SOCK_DGRAM, 0, "", ("10.0.0.7", 0)),
            (socket.AF_INET, socket.SOCK_DGRAM, 0, "", ("192.168.1.50", 0)),
            (socket.AF_INET6, socket.SOCK_DGRAM, 0, "", ("fe80::1", 0, 0, 0)),
        ]

    monkeypatch.setattr(socket, "getaddrinfo", fake_getaddrinfo)
    result = collect_lan_ipv4()
    assert result == ["10.0.0.7", "192.168.1.50"]  # filtered, sorted, deduped


class _ProbeSocket:
    """Fake UDP probe socket: with-statement protocol + routable getsockname."""

    def __init__(self, *args, **kwargs) -> None:
        del args, kwargs

    def __enter__(self) -> "_ProbeSocket":
        return self

    def __exit__(self, *exc) -> bool:
        return False

    def connect(self, addr) -> None:
        del addr

    def getsockname(self) -> tuple[str, int]:
        return ("203.0.113.9", 12345)

    def close(self) -> None:
        pass


def test_primary_lan_ipv4_prefers_default_route_probe(monkeypatch):
    monkeypatch.setattr(mdns.socket, "socket", _ProbeSocket)
    # The probe (default-route source IP) wins over hostname-derived fallbacks.
    assert mdns.primary_lan_ipv4(["192.168.1.5", "10.0.0.7"]) == "203.0.113.9"


def test_primary_lan_ipv4_falls_back_and_filters(monkeypatch):
    def _no_route(*args, **kwargs):
        del args, kwargs
        raise OSError("simulated no route")

    monkeypatch.setattr(mdns.socket, "socket", _no_route)
    # Unusable entries (link-local) are skipped; first usable fallback wins.
    assert mdns.primary_lan_ipv4(["169.254.1.2", "10.0.0.4"]) == "10.0.0.4"
    assert mdns.primary_lan_ipv4([]) is None
    assert mdns.primary_lan_ipv4(None) is None


def test_init_failure_does_not_raise(monkeypatch):
    instances = _install_fake(monkeypatch, ["10.0.0.5"])
    monkeypatch.setattr(mdns, "AsyncZeroconf", ExplodingZeroconf)

    async def scenario():
        broadcaster = MdnsBroadcaster()
        await broadcaster.start()  # must not propagate the init failure
        assert not broadcaster.is_registered

        # next refresh tick retries against a healthy zeroconf
        monkeypatch.setattr(mdns, "AsyncZeroconf", FakeAsyncZeroconf)
        assert await broadcaster.refresh() is True
        assert broadcaster.is_registered
        assert instances[0].registered  # registered on the retry
        await broadcaster.stop()
        assert not broadcaster.is_registered

    asyncio.run(scenario())


def test_start_stop_idempotent(monkeypatch):
    instances = _install_fake(monkeypatch, ["10.0.0.5"])

    async def scenario():
        broadcaster = MdnsBroadcaster(hostname="POTPILOT-PC")
        await broadcaster.start()
        await broadcaster.start()
        fake = instances[0]
        assert len(instances) == 1
        assert len(fake.registered) == 1

        await broadcaster.stop()
        await broadcaster.stop()
        assert fake.closed
        assert len(fake.unregistered) == 1
        assert not broadcaster.is_registered
        # refresh task fully cancelled — no leaked tasks on the loop
        current = asyncio.current_task()
        pending = [t for t in asyncio.all_tasks() if t is not current]
        assert pending == []

    asyncio.run(scenario())


def test_start_without_ips_defers_registration(monkeypatch):
    instances = _install_fake(monkeypatch, [])
    ips_state = {"value": []}
    monkeypatch.setattr(mdns, "collect_lan_ipv4", lambda: list(ips_state["value"]))

    async def scenario():
        broadcaster = MdnsBroadcaster()
        await broadcaster.start()  # no IPv4: refuses registration, keeps loop alive
        assert not broadcaster.is_registered

        ips_state["value"] = ["192.168.0.10"]
        assert await broadcaster.refresh() is True
        assert broadcaster.is_registered
        fake = instances[0]  # zeroconf created on the retry, not on start
        assert fake.registered[0].parsed_addresses() == ["192.168.0.10"]
        await broadcaster.stop()

    asyncio.run(scenario())


def test_refresh_interval_constant():
    assert IP_REFRESH_INTERVAL_S == 60
