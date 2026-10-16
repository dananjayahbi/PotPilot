"""PotPilot token auth middleware (Doc 15).

Single source of truth for the PC agent's 128-bit pairing token: generation,
Doc 26 persistence under ``auth_token``, the frozen 1-byte UDP XOR checksum
(byte 1 of the Doc 02 ``<BBhhH>`` packet), and the WebSocket handshake
credential check (Doc 03 §4.2 ``?auth=`` query parameter).
"""

from __future__ import annotations

import hmac
import logging
import re
import secrets
import time
from typing import TYPE_CHECKING, Any, Literal
from urllib.parse import parse_qs

if TYPE_CHECKING:
    from pc_agent.core.config_manager import ConfigManager

logger = logging.getLogger("potpilot.core.auth_middleware")

TOKEN_BYTES: int = 16  # 128-bit token (frozen)
TOKEN_HEX_LEN: int = 32  # lowercase hex rendering
CONFIG_KEY_TOKEN: str = "auth_token"  # key inside ConfigManager (Doc 26)

HandshakeDecision = Literal["accept", "reject"]

_TOKEN_HEX_RE = re.compile(r"[0-9a-f]{32}")
_HANDSHAKE_QUERY_PARAM = "auth"
_WS_REJECT_LOG_INTERVAL_S = 1.0


def generate_token() -> bytes:
    """Mint a fresh 128-bit pairing token."""
    return secrets.token_bytes(TOKEN_BYTES)


def xor_checksum(token: bytes) -> int:
    """Fold the token bytes into an 8-bit XOR checksum (frozen by Doc 02)."""
    value = 0
    for b in token:
        value ^= b
    return value  # 0..255


def _is_valid_token_hex(value: object) -> bool:
    """True only for a 32-char lowercase-hex token string."""
    return isinstance(value, str) and _TOKEN_HEX_RE.fullmatch(value) is not None


class AuthMiddleware:
    """Token lifecycle + verification gate consumed by Docs 13/14/17/24.

    All secret comparisons go through :func:`hmac.compare_digest`; the UDP
    checksum is computed once at load so the packet hot path only performs a
    constant-time single-byte compare.
    """

    def __init__(self, config: ConfigManager) -> None:
        self._config = config
        self._token_hex = ""
        self._udp_auth_byte = 0
        self._expected_udp_byte = b"\x00"
        self._loaded = False
        self._ws_rejects = 0
        self._last_ws_reject_log = 0.0

    def load_or_create(self) -> str:
        """Return the stored ``token_hex``; generate + persist when missing/invalid."""
        return self._resolve(self._config.get().auth_token)

    def reload(self) -> str:
        """Re-read the token from config (supports manual rotation)."""
        return self._resolve(self._config.load().auth_token)

    def _resolve(self, stored: object) -> str:
        """Activate a valid stored token, else mint + persist a fresh one."""
        if _is_valid_token_hex(stored):
            self._activate(stored)
            return self._token_hex
        fresh = generate_token().hex()
        if stored:
            logger.warning(
                "stored auth_token invalid; regenerating (paired clients must re-pair)"
            )
            self._persist_overwrite(fresh)
            self._activate(fresh)
        else:
            logger.info("new pairing token generated")
            issued = self._persist_new(fresh)
            self._activate(issued)
        return self._token_hex

    @property
    def token_hex(self) -> str:
        """Current lowercase 32-char token (loads/creates on first access)."""
        if not self._loaded:
            self.load_or_create()
        return self._token_hex

    @property
    def udp_auth_byte(self) -> int:
        """Cached :func:`xor_checksum` result for the current token."""
        if not self._loaded:
            self.load_or_create()
        return self._udp_auth_byte

    def verify_udp_auth_byte(self, byte: int) -> bool:
        """Constant-time compare of the 1-byte UDP checksum (Doc 02 byte 1)."""
        if not self._loaded:
            self.load_or_create()
        if not isinstance(byte, int) or not 0 <= byte <= 255:
            return False
        return hmac.compare_digest(bytes([byte]), self._expected_udp_byte)

    def verify_ws_token(self, presented: str) -> bool:
        """Constant-time compare of the full ``token_hex`` (case-insensitive)."""
        if not self._loaded:
            self.load_or_create()
        if not isinstance(presented, str):
            self._note_ws_reject()
            return False
        accepted = hmac.compare_digest(
            presented.lower().encode("utf-8"), self._token_hex.encode("ascii")
        )
        if not accepted:
            self._note_ws_reject()
        return accepted

    # -- internal helpers ---------------------------------------------------

    def _activate(self, token_hex: str) -> None:
        """Cache the token plus its precomputed UDP checksum byte."""
        raw = bytes.fromhex(token_hex)
        self._token_hex = token_hex
        self._udp_auth_byte = xor_checksum(raw)
        self._expected_udp_byte = bytes([self._udp_auth_byte])
        self._loaded = True

    def _persist_new(self, fresh: str) -> str:
        """Persist via Doc 26's create-once hook; fall back to memory on error."""
        try:
            issued = self._config.ensure_auth_token(lambda: fresh)
        except Exception:
            logger.error(
                "cannot persist pairing token; keeping it in memory for this session",
                exc_info=True,
            )
            return fresh
        return issued if _is_valid_token_hex(issued) else fresh

    def _persist_overwrite(self, fresh: str) -> None:
        """Overwrite a corrupt stored token; fall back to memory on error."""
        try:
            self._config.update(auth_token=fresh)
        except Exception:
            logger.error(
                "cannot persist regenerated pairing token; keeping it in memory "
                "for this session",
                exc_info=True,
            )

    def _note_ws_reject(self) -> None:
        """Count WS rejections; log at most once per second."""
        self._ws_rejects += 1
        now = time.monotonic()
        if now - self._last_ws_reject_log >= _WS_REJECT_LOG_INTERVAL_S:
            self._last_ws_reject_log = now
            logger.warning("websocket handshake rejected (total: %d)", self._ws_rejects)


def _handshake_query(request: Any) -> str:
    """Extract the raw query string from any supported request shape."""
    if isinstance(request, str):
        candidate: str | None = request
    else:
        query = getattr(request, "query", None)
        if isinstance(query, str):
            return query
        candidate = None
        for attr in ("path", "request_target", "url"):
            value = getattr(request, attr, None)
            if isinstance(value, str):
                candidate = value
                break
    if not candidate:
        return ""
    if "?" in candidate:
        return candidate.split("?", 1)[1]
    if "=" in candidate:  # bare query string passed directly
        return candidate
    return ""


def extract_handshake_token(request: Any) -> str | None:
    """Pull the Doc 03 credential (``?auth=<token-hex>``) from a WS request."""
    query = _handshake_query(request)
    if not query:
        return None
    values = parse_qs(query, keep_blank_values=True).get(_HANDSHAKE_QUERY_PARAM)
    if not values:
        return None
    return values[0]


def process_handshake(request: Any, auth: AuthMiddleware) -> HandshakeDecision:
    """Extract → verify → accept/reject glue for ``websockets.process_request``."""
    token = extract_handshake_token(request)
    if token is None:
        return "reject"
    return "accept" if auth.verify_ws_token(token) else "reject"
