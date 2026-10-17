"""PotPilot mDNS/DNS-SD broadcaster (Doc 16).

Announces ``_potpilot._tcp.local.`` on the LAN with the WebSocket control
port (50506) plus TXT records for the UDP port and protocol version, and
re-announces addresses every ``IP_REFRESH_INTERVAL_S`` so the Flutter app can
follow DHCP-driven IP changes without re-scanning the pairing QR. The pairing
secret never touches mDNS — discovery is unauthenticated by design (Doc 15
authenticates at the WS handshake).

``collect_lan_ipv4()`` lives here as the single IP-enumeration implementation
shared repo-wide (Docs 16/17).  mDNS itself advertises only the **primary**
(default-route) address via :func:`primary_lan_ipv4` — multiple A records
flipped the phone's resolver between NICs and caused reconnect storms
(2026-10-17); the full list stays available for QR/UDP pairing candidates.
"""

from __future__ import annotations

import asyncio
import ipaddress
import logging
import re
import socket
import unicodedata
from collections.abc import Callable

from zeroconf import ServiceInfo
from zeroconf.asyncio import AsyncZeroconf

logger = logging.getLogger("potpilot.network.mdns_broadcaster")

SERVICE_TYPE: str = "_potpilot._tcp.local."  # frozen service type
SERVICE_PORT: int = 50506  # advertised port = WS control port (frozen)
TXT_UDP: str = "udp"  # TXT key -> "50505"
TXT_WS: str = "ws"  # TXT key -> "50506"
TXT_VERSION: str = "ver"  # TXT key -> "1"
IP_REFRESH_INTERVAL_S: int = 60

_DEFAULT_HOSTNAME_FALLBACK = "potpilot-pc"
_INVALID_LABEL_CHARS = re.compile(r"[^A-Za-z0-9-]+")
_LABEL_COLLAPSE = re.compile(r"-{2,}")
_MAX_LABEL_LEN = 63


def _is_usable_ipv4(ip: str) -> bool:
    """True for a concrete host IPv4: not loopback, link-local, or unspecified."""
    try:
        addr = ipaddress.IPv4Address(ip)
    except ValueError:
        return False
    return not (addr.is_loopback or addr.is_link_local or addr.is_unspecified)


def collect_lan_ipv4() -> list[str]:
    """All usable LAN IPv4s of this machine: sorted, deduped, IPv4-only.

    Resolves the machine hostname first; falls back to a UDP-socket routing
    probe when that yields nothing (cable unplugged, odd resolver config).
    """
    found: set[str] = set()
    try:
        results = socket.getaddrinfo(socket.gethostname(), None, family=socket.AF_INET)
    except OSError:
        results = []
    for family, _type, _proto, _canon, sockaddr in results:
        if family != socket.AF_INET:
            continue
        ip = sockaddr[0]
        if _is_usable_ipv4(ip):
            found.add(ip)
    if not found:
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
                probe.connect(("1.1.1.1", 80))
                ip = probe.getsockname()[0]
                if _is_usable_ipv4(ip):
                    found.add(ip)
        except OSError:
            logger.debug("UDP probe for LAN IPv4 failed", exc_info=True)
    return sorted(found)


def primary_lan_ipv4(fallback_ips: list[str] | None = None) -> str | None:
    """Single best LAN IPv4 to *advertise* over mDNS (Doc 16).

    The default-route source IP (UDP probe) wins when usable — it is the
    address peers on the home LAN can actually reach, and it is stable even
    when virtual adapters (Hyper-V/WSL, VirtualBox, hotspots) come and go.
    Falls back to the first usable entry of ``fallback_ips`` (usually
    :func:`collect_lan_ipv4`).  Advertising exactly one address stops the
    multi-A-record flip-flop that made the phone's resolver oscillate and
    tear down live sessions (connection-flapping root cause, 2026-10-17).
    """
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            probe.connect(("1.1.1.1", 80))
            ip = probe.getsockname()[0]
            if _is_usable_ipv4(ip):
                return ip
    except OSError:
        logger.debug("UDP probe for primary LAN IPv4 failed", exc_info=True)
    for ip in fallback_ips or ():
        if _is_usable_ipv4(ip):
            return ip
    return None


def sanitize_hostname(name: str) -> str:
    """Reduce ``name`` to a DNS-label-safe service instance label."""
    normalized = unicodedata.normalize("NFKD", name) if name else ""
    ascii_name = normalized.encode("ascii", "ignore").decode("ascii")
    cleaned = _INVALID_LABEL_CHARS.sub("-", ascii_name)
    cleaned = _LABEL_COLLAPSE.sub("-", cleaned).strip("-")
    cleaned = cleaned[:_MAX_LABEL_LEN].strip("-")
    return cleaned or _DEFAULT_HOSTNAME_FALLBACK


class MdnsBroadcaster:
    """Registers the PotPilot service and keeps its A records fresh.

    ``start`` / ``stop`` are idempotent; zeroconf failures are contained and
    retried on the next refresh tick so UDP/WS/QR pairing keep working.
    """

    def __init__(
        self,
        *,
        hostname: str | None = None,
        udp_port: int = 50505,
        ws_port: int = 50506,
        on_ips_changed: Callable[[list[str]], None] | None = None,
    ) -> None:
        self._hostname = hostname if hostname else socket.gethostname()
        self._udp_port = udp_port
        self._ws_port = ws_port
        self._on_ips_changed = on_ips_changed
        self._zc: AsyncZeroconf | None = None
        self._info: ServiceInfo | None = None
        self._registered = False
        self._ips: list[str] = []
        self._task: asyncio.Task[None] | None = None

    @property
    def service_name(self) -> str:
        """``<sanitized-hostname>._potpilot._tcp.local.`` (final name post-collision)."""
        if self._info is not None:
            return self._info.name
        return f"{sanitize_hostname(self._hostname)}.{SERVICE_TYPE}"

    @property
    def is_registered(self) -> bool:
        return self._registered

    async def start(self) -> None:
        """Register the service (best-effort) and begin the refresh loop."""
        if self._task is not None:
            return  # idempotent
        primary = primary_lan_ipv4(collect_lan_ipv4())
        await self._register_best_effort([primary] if primary else [])
        self._task = asyncio.create_task(self._refresh_loop())

    async def stop(self) -> None:
        """Unregister, close zeroconf, cancel the refresh loop (idempotent)."""
        if self._task is not None:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
            self._task = None
        try:
            if self._zc is not None and self._registered and self._info is not None:
                await self._zc.async_unregister_service(self._info)
        except Exception:
            logger.warning("mDNS unregister failed", exc_info=True)
        finally:
            self._registered = False
            self._info = None
            self._ips = []
        if self._zc is not None:
            try:
                await self._zc.async_close()
            except Exception:
                logger.warning("mDNS close failed", exc_info=True)
            self._zc = None

    async def refresh(self) -> bool:
        """Recompute the primary LAN IP; re-announce when it changed (True = changed)."""
        primary = primary_lan_ipv4(collect_lan_ipv4())
        if primary is None:
            logger.warning("no LAN IPv4 for mDNS; will retry next refresh tick")
            return False
        ips = [primary]
        if not self._registered or self._info is None:
            changed = await self._register_best_effort(ips)
            if changed:
                self._notify_ips_changed(ips)
            return changed
        if set(ips) == set(self._ips):
            return False
        assert self._zc is not None  # registered implies a live zeroconf
        new_info = self._build_service_info(ips)
        try:
            await self._zc.async_update_service(new_info)
        except Exception:
            logger.warning("mDNS service update failed", exc_info=True)
            return False
        self._info = new_info
        self._ips = list(ips)
        logger.info("mDNS addresses updated: %s", ", ".join(ips))
        self._notify_ips_changed(ips)
        return True

    # -- internal helpers ---------------------------------------------------

    def _build_service_info(self, ips: list[str]) -> ServiceInfo:
        return ServiceInfo(
            SERVICE_TYPE,
            f"{sanitize_hostname(self._hostname)}.{SERVICE_TYPE}",
            port=self._ws_port,
            addresses=[ipaddress.IPv4Address(ip).packed for ip in ips],
            properties={
                TXT_UDP: str(self._udp_port),
                TXT_WS: str(self._ws_port),
                TXT_VERSION: "1",
            },
        )

    async def _ensure_zeroconf(self) -> bool:
        if self._zc is not None:
            return True
        try:
            self._zc = AsyncZeroconf()
        except Exception:
            logger.warning(
                "mDNS init failed (no NIC / service conflict); "
                "will retry on next refresh tick",
                exc_info=True,
            )
            self._zc = None
            return False
        return True

    async def _register_best_effort(self, ips: list[str]) -> bool:
        if not ips:
            logger.warning("no LAN IPv4 yet; mDNS registration deferred")
            return False
        if not await self._ensure_zeroconf():
            return False
        info = self._build_service_info(ips)
        assert self._zc is not None
        try:
            await self._zc.async_register_service(info, allow_name_change=True)
        except Exception:
            logger.warning(
                "mDNS register failed; will retry on next refresh tick", exc_info=True
            )
            return False
        self._info = info
        self._registered = True
        self._ips = list(ips)
        logger.info("mDNS service registered as %s", info.name)
        return True

    def _notify_ips_changed(self, ips: list[str]) -> None:
        if self._on_ips_changed is None:
            return
        try:
            self._on_ips_changed(list(ips))
        except Exception:
            logger.warning("on_ips_changed callback failed", exc_info=True)

    async def _refresh_loop(self) -> None:
        while True:
            await asyncio.sleep(IP_REFRESH_INTERVAL_S)
            try:
                await self.refresh()
            except asyncio.CancelledError:
                raise
            except Exception:
                logger.warning("mDNS refresh tick failed", exc_info=True)
