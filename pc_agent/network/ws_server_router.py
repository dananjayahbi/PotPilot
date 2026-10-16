"""PC WebSocket server + async action router — Doc 14.

``websockets`` server bound to TCP 50506 with a frozen-envelope async router.
Envelope parsing, ack/error frame shapes and the action registry live in the
Wave 1.A conformance codec ``ws_message_codec.py`` (Doc 03 authority); this
module owns transport, handshake gating, routing, and the connected-client
registry.

Injected seams (never imported at module level):
- ``auth`` — Doc 15 middleware exposing ``verify_ws_token(presented: str) -> bool``;
- ``on_client_connected`` / ``on_client_disconnected`` — hooks ``main.py`` wires
  to Doc 18's ``TelemetryBroadcaster.register_client`` / ``unregister_client``
  with the raw ``websockets`` connection object.

Error-code mapping (Doc 03 §5.8 / Doc 14 §7): ``E_BAD_JSON`` and
``E_BAD_ENVELOPE`` close the connection with 4400 after delivering the error
frame; ``E_UNAUTHORIZED`` is HTTP 401 at upgrade (or 4401 mid-session);
``E_UNKNOWN_ACTION`` (wire 4002) and ``E_HANDLER`` (wire 4500) keep the
connection open.
"""

from __future__ import annotations

import asyncio
import inspect
import json
import logging
import time
import uuid
from collections.abc import Awaitable, Callable
from dataclasses import asdict, dataclass
from typing import Any, Protocol
from urllib.parse import parse_qs, urlsplit

from websockets.asyncio.server import ServerConnection, serve

from pc_agent.network.ws_message_codec import (
    WS_PORT,
    CloseCode,
    ErrorCode,
    WsSchemaError,
    WsType,
    build_auth_ok,
    build_message,
    parse_message,
)

log = logging.getLogger(__name__)

WS_HOST: str = "0.0.0.0"
MSG_TYPES: frozenset[str] = frozenset(str(member) for member in WsType)

# Doc 14 internal error signals (mapped to Doc 03 wire codes / close codes).
E_BAD_JSON = "E_BAD_JSON"
E_BAD_ENVELOPE = "E_BAD_ENVELOPE"
E_UNKNOWN_ACTION = "E_UNKNOWN_ACTION"
E_UNAUTHORIZED = "E_UNAUTHORIZED"
E_HANDLER = "E_HANDLER"

ERROR_WIRE_CODE: dict[str, int] = {
    E_UNKNOWN_ACTION: int(ErrorCode.UNKNOWN_ACTION),  # 4002
    E_HANDLER: int(ErrorCode.INTERNAL_ERROR),  # 4500
    E_BAD_JSON: int(CloseCode.PROTOCOL_ERROR),  # 4400 (also the close code)
    E_BAD_ENVELOPE: int(CloseCode.PROTOCOL_ERROR),  # 4400 (also the close code)
}
ERROR_CLOSE_CODE: dict[str, int] = {
    E_BAD_JSON: int(CloseCode.PROTOCOL_ERROR),
    E_BAD_ENVELOPE: int(CloseCode.PROTOCOL_ERROR),
    E_UNAUTHORIZED: int(CloseCode.UNAUTHORIZED),
}

SEND_TIMEOUT_S: float = 2.0  # per-client send budget (Doc 18 §4.5)
DEFAULT_MAX_SKEW_S: int = 3600  # generous clock-drift window (Doc 03 §5.1)
SHUTDOWN_CLOSE_CODE: int = 1001  # going away

_TYPE_ERROR_ACTION = "ERROR"  # parse-failure frames have no request action


@dataclass(frozen=True, slots=True)
class WsEnvelope:
    """One validated inbound Doc 03 envelope."""

    id: str
    type: str
    action: str
    payload: dict[str, Any]
    timestamp: int


Handler = Callable[["WsSession", WsEnvelope], Awaitable[dict[str, Any]]]


class WsAuthVerifier(Protocol):
    """Structural subset of the Doc 15 auth middleware (WS path)."""

    def verify_ws_token(self, presented: str) -> bool: ...


def parse_envelope(raw: str | bytes) -> WsEnvelope:
    """Validate one inbound frame; raises ``ValueError`` with a machine-readable reason."""
    try:
        msg = parse_message(raw)
    except WsSchemaError as exc:
        raise ValueError(exc.detail) from exc
    return WsEnvelope(
        id=msg.id,
        type=str(msg.type),
        action=msg.action,
        payload=dict(msg.payload),
        timestamp=msg.timestamp,
    )


def build_ack(envelope: WsEnvelope, **results: Any) -> dict[str, Any]:
    """Success reply per Doc 03 §5.8: ``<ACTION>_RESULT``, id echoed, ``ok: true`` merged."""
    payload: dict[str, Any] = {"ok": True}
    payload.update(results)
    return asdict(
        build_message(envelope.type, f"{envelope.action}_RESULT", payload, id_=envelope.id)
    )


def build_error(
    envelope_or_id: WsEnvelope | str | None,
    code: str,
    message: str,
) -> dict[str, Any]:
    """Error reply per Doc 03 §5.8.

    With a parsed envelope: ``<ACTION>_ERROR``, id echoed. With only an id
    (or ``None``) — the Doc 14 §7 parse-failure path — a generic
    ``CMD_SYSTEM/ERROR`` frame carries the recovered id (or JSON null).
    """
    wire_code = ERROR_WIRE_CODE.get(code, int(ErrorCode.INTERNAL_ERROR))
    if isinstance(envelope_or_id, WsEnvelope):
        return asdict(
            build_message(
                envelope_or_id.type,
                f"{envelope_or_id.action}_ERROR",
                {"code": wire_code, "message": message},
                id_=envelope_or_id.id,
            )
        )
    # Parse-failure path: no request envelope exists, so the frame carries the
    # recovered id (or JSON null) and a generic action (Doc 14 §7). Built by
    # hand because build_message would uuid-fill a None id.
    return {
        "id": envelope_or_id,
        "type": str(WsType.CMD_SYSTEM),
        "action": _TYPE_ERROR_ACTION,
        "payload": {"code": wire_code, "message": message},
        "timestamp": int(time.time()),
    }


class WsSession:
    """Per-connection state: uuid id, remote address, serialized text sends."""

    __slots__ = ("id", "remote", "ws", "_authenticated", "_lock")

    def __init__(self, ws: ServerConnection, *, id: str | None = None) -> None:
        self.id = id if id is not None else str(uuid.uuid4())
        self.ws = ws
        addr = getattr(ws, "remote_address", None)
        self.remote = f"{addr[0]}:{addr[1]}" if addr else "unknown"
        self._authenticated = True  # handshake gate already passed
        self._lock = asyncio.Lock()

    @property
    def is_authenticated(self) -> bool:
        return self._authenticated

    async def send_text(self, text: str) -> None:
        """Send one text frame; the lock keeps concurrent frames byte-atomic."""
        async with self._lock:
            await self.ws.send(text)


class WsRouter:
    """Async ``(type, action)`` registry; dispatch returns a Doc 03 reply frame."""

    def __init__(self) -> None:
        self._handlers: dict[tuple[str, str], Handler] = {}

    def register(self, msg_type: str, action: str, handler: Handler) -> None:
        """Register one handler; duplicates are a programming error."""
        if msg_type not in MSG_TYPES:
            raise ValueError(f"unknown message type: {msg_type!r}")
        key = (msg_type, action)
        if key in self._handlers:
            raise ValueError(f"handler already registered for {msg_type}/{action}")
        self._handlers[key] = handler

    def lookup(self, msg_type: str, action: str) -> Handler | None:
        return self._handlers.get((msg_type, action))

    async def dispatch(self, session: WsSession, envelope: WsEnvelope) -> dict[str, Any]:
        """Await the matching handler and build the ack; errors become error frames."""
        if envelope.type == str(WsType.TELEMETRY_SYNC):
            # Telemetry is server-push only (Doc 14 §4.5 / Doc 03 §5.2).
            return build_error(envelope, E_UNKNOWN_ACTION, "telemetry is server-push only")
        handler = self.lookup(envelope.type, envelope.action)
        if handler is None:
            return build_error(envelope, E_UNKNOWN_ACTION, "unknown action")
        try:
            result = await handler(session, envelope)
        except Exception:
            log.exception(
                "handler for %s/%s (envelope %s) raised",
                envelope.type,
                envelope.action,
                envelope.id,
            )
            return build_error(envelope, E_HANDLER, "internal handler error")
        if not isinstance(result, dict):
            log.error(
                "handler for %s/%s returned %s, expected dict",
                envelope.type,
                envelope.action,
                type(result).__name__,
            )
            return build_error(envelope, E_HANDLER, "internal handler error")
        return build_ack(envelope, **result)


class WsServer:
    """WebSocket transport on WS_HOST:WS_PORT with handshake gate + client registry."""

    def __init__(
        self,
        *,
        router: WsRouter,
        auth: WsAuthVerifier,
        on_client_connected: Callable[[ServerConnection], Any] | None = None,
        on_client_disconnected: Callable[[ServerConnection], Any] | None = None,
        max_skew_s: int = DEFAULT_MAX_SKEW_S,
    ) -> None:
        self._router = router
        self._auth = auth
        self._on_client_connected = on_client_connected
        self._on_client_disconnected = on_client_disconnected
        self._max_skew_s = max_skew_s
        self._server: Any = None
        self._sessions: dict[ServerConnection, WsSession] = {}
        self.handshake_rejections = 0

    # -- Lifecycle ---------------------------------------------------------
    async def start(self, *, host: str = WS_HOST, port: int = WS_PORT) -> None:
        """Bind and serve; ``OSError`` propagates to ``main.py`` (no silent retry)."""
        if self._server is not None:
            return
        self._server = await serve(
            self._handle_connection,
            host,
            port,
            process_request=self._process_request,
            # Phone-side reality: the remote's screen sleeps (bed mode) and its
            # WiFi dozes; default 20 s/20 s pings dropped the session mid-use
            # ("keepalive ping timeout" churn). Tolerate a dozed client while
            # still reaping genuinely dead peers.
            ping_interval=30,
            ping_timeout=60,
        )
        log.info("WS server listening on %s:%s", host, self.port)

    async def stop(self) -> None:
        """Close all sessions, unbind; idempotent."""
        server, self._server = self._server, None
        for session in list(self._sessions.values()):
            try:
                await session.ws.close(code=SHUTDOWN_CLOSE_CODE, reason="server shutdown")
            except Exception:  # pragma: no cover - dead peers during shutdown
                log.debug("session %s already gone at shutdown", session.id, exc_info=True)
        self._sessions.clear()
        if server is not None:
            server.close()
            await server.wait_closed()

    @property
    def client_count(self) -> int:
        return len(self._sessions)

    @property
    def port(self) -> int:
        """Actual bound port (0 before start / when bound with ``port=0``)."""
        if self._server is None or not self._server.sockets:
            return 0
        return int(self._server.sockets[0].getsockname()[1])

    async def broadcast(self, message: dict[str, Any]) -> int:
        """Send one frame to every connected client; returns the delivery count."""
        sessions = list(self._sessions.values())
        if not sessions:
            return 0
        text = json.dumps(message, separators=(",", ":"))
        results = await asyncio.gather(
            *(self._send_guarded(session, text) for session in sessions)
        )
        return sum(1 for delivered in results if delivered)

    # -- Handshake gate (Doc 03 §4.2: query param ``auth`` = 32 hex chars) --
    def _process_request(self, connection: ServerConnection, request: Any) -> Any:
        token = _extract_query_param(getattr(request, "path", ""), "auth")
        if token is not None and self._auth.verify_ws_token(token):
            return None  # proceed with the upgrade
        self.handshake_rejections += 1
        log.warning(
            "rejected WS handshake from %s: missing/invalid token", connection.remote_address
        )
        return connection.respond(401, "Unauthorized")

    # -- Connection lifecycle ---------------------------------------------
    async def _handle_connection(self, websocket: ServerConnection) -> None:
        session = WsSession(websocket)
        self._sessions[websocket] = session
        log.info("WS client connected: %s (%s)", session.id, session.remote)
        try:
            await session.send_text(
                json.dumps(asdict(build_auth_ok()), separators=(",", ":"))
            )
            await self._notify(self._on_client_connected, websocket)
            async for raw in websocket:
                await self._handle_frame(session, raw)
        except Exception:
            log.debug("WS session %s ended with error", session.id, exc_info=True)
        finally:
            self._sessions.pop(websocket, None)
            log.info("WS client disconnected: %s", session.id)
            await self._notify(self._on_client_disconnected, websocket)

    async def _handle_frame(self, session: WsSession, raw: str | bytes) -> None:
        try:
            envelope = parse_envelope(raw)
        except ValueError as exc:
            detail = str(exc)
            code = E_BAD_JSON if _is_bad_json(detail) else E_BAD_ENVELOPE
            log.warning("closing %s: %s (%s)", session.id, code, detail)
            error_frame = build_error(_recover_envelope_id(raw), code, detail)
            await session.send_text(json.dumps(error_frame, separators=(",", ":")))
            await session.ws.close(code=ERROR_CLOSE_CODE[code], reason=code)
            return
        if abs(int(time.time()) - envelope.timestamp) > self._max_skew_s:
            await session.send_text(
                json.dumps(
                    build_error(envelope, E_BAD_ENVELOPE, "timestamp skew out of tolerance"),
                    separators=(",", ":"),
                )
            )
            return
        reply = await self._router.dispatch(session, envelope)
        await session.send_text(json.dumps(reply, separators=(",", ":")))

    # -- Internals ---------------------------------------------------------
    async def _send_guarded(self, session: WsSession, text: str) -> bool:
        try:
            await asyncio.wait_for(session.send_text(text), timeout=SEND_TIMEOUT_S)
            return True
        except Exception:
            log.debug("broadcast send to %s failed", session.id, exc_info=True)
            return False

    async def _notify(self, hook: Callable[[ServerConnection], Any] | None, ws: Any) -> None:
        if hook is None:
            return
        try:
            result = hook(ws)
            if inspect.isawaitable(result):
                await result
        except Exception:
            log.exception("client hook raised")


def _extract_query_param(path: str, name: str) -> str | None:
    values = parse_qs(urlsplit(path).query).get(name)
    return values[0] if values else None


def _is_bad_json(detail: str) -> bool:
    return detail.startswith("malformed JSON") or "not valid UTF-8" in detail or "exceeds" in detail


def _recover_envelope_id(raw: str | bytes) -> str | None:
    """Best-effort id extraction from an otherwise-invalid frame (Doc 14 §7)."""
    try:
        text = raw.decode("utf-8") if isinstance(raw, bytes) else raw
        data = json.loads(text)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return None
    if isinstance(data, dict) and isinstance(data.get("id"), str):
        return data["id"]
    return None


__all__ = [
    "E_BAD_ENVELOPE",
    "E_BAD_JSON",
    "E_HANDLER",
    "E_UNAUTHORIZED",
    "E_UNKNOWN_ACTION",
    "MSG_TYPES",
    "WS_HOST",
    "WS_PORT",
    "Handler",
    "WsAuthVerifier",
    "WsEnvelope",
    "WsRouter",
    "WsServer",
    "WsSession",
    "build_ack",
    "build_error",
    "parse_envelope",
]
