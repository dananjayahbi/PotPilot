"""PotPilot QR pairing payload generator (Doc 17).

Builds the frozen v1 pairing payload ``{v, host, ips, udp, ws, token}`` as
compact deterministic JSON and renders it as a high-contrast (level-H,
black-on-white) QR image for one-scan pairing. Stateless: the dashboard
re-invokes it on open and whenever Doc 16's ``on_ips_changed`` fires.
"""

from __future__ import annotations

import ipaddress
import json
import logging
import os
import re
import socket
from pathlib import Path
from typing import TYPE_CHECKING

import qrcode
from qrcode.constants import ERROR_CORRECT_H

from pc_agent.network.mdns_broadcaster import collect_lan_ipv4

if TYPE_CHECKING:
    from PIL import Image

    from pc_agent.core.auth_middleware import AuthMiddleware

logger = logging.getLogger("potpilot.core.qr_payload_gen")

PAYLOAD_VERSION: int = 1  # "v" field; bump on breaking payload changes
QR_BOX_SIZE: int = 8  # pixels per QR module
QR_BORDER: int = 4  # quiet-zone width in modules (spec minimum)
QR_MODULE_COLOR: str = "#000000"  # pure-black modules
QR_BG_COLOR: str = "#FFFFFF"  # pure-white background (maximum contrast)
DEFAULT_EXPORT_PATH: str = "%APPDATA%\\PotPilot\\pairing_qr.png"  # expanded at runtime

_MAX_PAYLOAD_CHARS = 300  # level-H capacity guard (version <= 10)
_TOKEN_HEX_RE = re.compile(r"[0-9a-f]{32}")


class NoLanAddressError(Exception):
    """No LAN IPv4 available — dashboard must show the connect-to-LAN state."""


def build_pairing_payload(
    *,
    ips: list[str],
    hostname: str,
    token_hex: str,
    udp_port: int = 50505,
    ws_port: int = 50506,
) -> str:
    """Assemble the frozen v1 payload as compact, deterministic JSON."""
    if not isinstance(token_hex, str) or _TOKEN_HEX_RE.fullmatch(token_hex) is None:
        raise ValueError(f"token_hex must be 32 lowercase hex chars, got {token_hex!r}")
    validated: list[str] = []
    for entry in ips:
        if not isinstance(entry, str):
            raise ValueError(f"invalid IPv4 address in payload ips: {entry!r}")
        try:
            ipaddress.IPv4Address(entry)
        except ValueError as exc:
            raise ValueError(f"invalid IPv4 address in payload ips: {entry!r}") from exc
        validated.append(entry)
    safe_host = "".join(ch for ch in hostname if ch.isprintable())
    payload = json.dumps(
        {
            "v": PAYLOAD_VERSION,
            "host": safe_host,
            "ips": sorted(set(validated)),
            "udp": udp_port,
            "ws": ws_port,
            "token": token_hex,
        },
        sort_keys=True,
        separators=(",", ":"),
    )
    assert len(payload) < _MAX_PAYLOAD_CHARS, "pairing payload exceeds size budget"
    return payload


def generate_qr_image(payload: str) -> Image.Image:
    """Render ``payload`` as a level-H, black-on-white RGB QR image."""
    qr = qrcode.QRCode(
        error_correction=ERROR_CORRECT_H,
        box_size=QR_BOX_SIZE,
        border=QR_BORDER,
    )
    qr.add_data(payload.encode("utf-8"))
    qr.make(fit=True)
    image = qr.make_image(fill_color=QR_MODULE_COLOR, back_color=QR_BG_COLOR)
    return image.convert("RGB")


def save_qr_png(image: Image.Image, path: str | Path | None = None) -> Path:
    """Write ``image`` as PNG (default: expanded ``DEFAULT_EXPORT_PATH``)."""
    raw = os.fspath(path) if path is not None else DEFAULT_EXPORT_PATH
    target = Path(os.path.expandvars(raw))
    target.parent.mkdir(parents=True, exist_ok=True)
    image.save(target, format="PNG")
    return target


def render_pairing_qr(
    *,
    auth: AuthMiddleware,
    hostname: str | None = None,
    udp_port: int = 50505,
    ws_port: int = 50506,
) -> Image.Image:
    """One-call convenience for Doc 24: collect IPs + token, build, render."""
    ips = collect_lan_ipv4()
    if not ips:
        raise NoLanAddressError("no LAN IPv4 address; connect the PC to the network")
    payload = build_pairing_payload(
        ips=ips,
        hostname=hostname if hostname is not None else socket.gethostname(),
        token_hex=auth.token_hex,
        udp_port=udp_port,
        ws_port=ws_port,
    )
    logger.debug("pairing payload built (%d chars)", len(payload))
    return generate_qr_image(payload)
