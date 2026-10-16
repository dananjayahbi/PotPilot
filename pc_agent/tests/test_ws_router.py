"""Unit + integration tests for the Doc 14 WebSocket server router."""

from __future__ import annotations

import asyncio
import json
import re
import time
import uuid
from typing import Any

import pytest
from websockets.exceptions import ConnectionClosed, InvalidStatus

from pc_agent.network.ws_server_router import (
    E_HANDLER,
    E_UNKNOWN_ACTION,
    ERROR_WIRE_CODE,
    Handler,
    WsEnvelope,
    WsRouter,
    WsServer,
    WsSession,
    build_ack,
    build_error,
    parse_envelope,
)

TOKEN = "0123456789abcdef0123456789abcdef"
UUID4_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")


class FakeAuth:
    """Doc 15 seam: single fixed token."""

    def verify_ws_token(self, presented: str) -> bool:
        return presented == TOKEN


class FakeSocket:
    """Minimal ``websockets`` connection stand-in for registry/broadcast tests."""

    remote_address = ("127.0.0.1", 5555)

    def __init__(self, *, broken: bool = False) -> None:
        self.sent: list[str] = []
        self.broken = broken

    async def send(self, text: str) -> None:
        if self.broken:
            raise ConnectionResetError("simulated dead peer")
        self.sent.append(text)


def make_envelope(**overrides: Any) -> WsEnvelope:
    fields: dict[str, Any] = {
        "id": str(uuid.uuid4()),
        "type": "CMD_POTPLAYER",
        "action": "PLAY_PAUSE",
        "payload": {},
        "timestamp": int(time.time()),
    }
    fields.update(overrides)
    return WsEnvelope(**fields)


def frame_dict(envelope: WsEnvelope) -> dict[str, Any]:
    return {
        "id": envelope.id,
        "type": envelope.type,
        "action": envelope.action,
        "payload": envelope.payload,
        "timestamp": envelope.timestamp,
    }


# --- Unit: envelope parsing -------------------------------------------------


def test_envelope_parse_valid_and_missing_keys() -> None:
    frame = frame_dict(make_envelope())
    envelope = parse_envelope(json.dumps(frame))
    assert envelope == WsEnvelope(**frame)
    for key in ("id", "type", "action", "payload", "timestamp"):
        broken = dict(frame)
        del broken[key]
        with pytest.raises(ValueError, match=f"missing envelope key\\(s\\): {key}"):
            parse_envelope(json.dumps(broken))
    with pytest.raises(ValueError):
        parse_envelope("{not json")
    with pytest.raises(ValueError):
        parse_envelope(json.dumps([1, 2, 3]))


# --- Unit: router -----------------------------------------------------------


def test_register_duplicate_raises() -> None:
    router = WsRouter()

    async def handler(session: WsSession, envelope: WsEnvelope) -> dict[str, Any]:
        return {}

    router.register("CMD_SYSTEM", "REQUEST_STATE", handler)
    with pytest.raises(ValueError, match="already registered"):
        router.register("CMD_SYSTEM", "REQUEST_STATE", handler)
    with pytest.raises(ValueError, match="unknown message type"):
        router.register("CMD_BOGUS", "X", handler)


def test_dispatch_unknown_action() -> None:
    router = WsRouter()
    session = WsSession(FakeSocket())
    envelope = make_envelope(action="NO_SUCH_ACTION")
    reply = asyncio.run(router.dispatch(session, envelope))
    assert reply["action"] == "NO_SUCH_ACTION_ERROR"
    assert reply["id"] == envelope.id
    assert reply["payload"] == {"code": 4002, "message": "unknown action"}
    # Inbound TELEMETRY_SYNC is server-push only -> also 4002.
    telemetry = make_envelope(type="TELEMETRY_SYNC", action="STATE_DELTA")
    reply = asyncio.run(router.dispatch(session, telemetry))
    assert reply["payload"]["code"] == ERROR_WIRE_CODE[E_UNKNOWN_ACTION]


def test_ack_id_echo() -> None:
    router = WsRouter()

    async def handler(session: WsSession, envelope: WsEnvelope) -> dict[str, Any]:
        assert envelope.payload == {"level": 50}
        return {"ok": True, "level": 50}

    router.register("CMD_SYSTEM", "SET_BRIGHTNESS", handler)
    session = WsSession(FakeSocket())
    envelope = make_envelope(type="CMD_SYSTEM", action="SET_BRIGHTNESS", payload={"level": 50})
    reply = asyncio.run(router.dispatch(session, envelope))
    assert reply["id"] == envelope.id
    assert reply["type"] == "CMD_SYSTEM"
    assert reply["action"] == "SET_BRIGHTNESS_RESULT"
    assert reply["payload"] == {"ok": True, "level": 50}
    assert isinstance(reply["timestamp"], int)


def test_each_cmd_type_reaches_stubbed_handler() -> None:
    router = WsRouter()
    seen: list[tuple[str, str]] = []

    def stub(msg_type: str, action: str) -> Handler:
        async def handler(session: WsSession, envelope: WsEnvelope) -> dict[str, Any]:
            seen.append((msg_type, action))
            return {"ok": True}

        return handler

    routes = [
        ("CMD_POTPLAYER", "PLAY_PAUSE"),
        ("CMD_KEY", "SEND_KEY"),
        ("CMD_SYSTEM", "SET_BLACKOUT"),
        ("CMD_MEDIA", "LIST_MEDIA"),
    ]
    for msg_type, action in routes:
        router.register(msg_type, action, stub(msg_type, action))
    session = WsSession(FakeSocket())
    for msg_type, action in routes:
        envelope = make_envelope(type=msg_type, action=action)
        reply = asyncio.run(router.dispatch(session, envelope))
        assert reply["action"] == f"{action}_RESULT"
        assert reply["id"] == envelope.id
        assert reply["payload"] == {"ok": True}
    assert seen == routes  # every handler got its parsed WsEnvelope


def test_handler_exception_maps_to_e_handler() -> None:
    router = WsRouter()

    async def boom(session: WsSession, envelope: WsEnvelope) -> dict[str, Any]:
        raise RuntimeError("secret internal detail")

    router.register("CMD_MEDIA", "RESCAN_MEDIA", boom)
    session = WsSession(FakeSocket())
    envelope = make_envelope(type="CMD_MEDIA", action="RESCAN_MEDIA")
    reply = asyncio.run(router.dispatch(session, envelope))
    assert reply["action"] == "RESCAN_MEDIA_ERROR"
    assert reply["id"] == envelope.id
    assert reply["payload"]["code"] == ERROR_WIRE_CODE[E_HANDLER]
    assert "secret" not in reply["payload"]["message"]

    async def ok(session2: WsSession, envelope2: WsEnvelope) -> dict[str, Any]:
        return {"ok": True}

    router.register("CMD_MEDIA", "LIST_MEDIA", ok)
    request = make_envelope(type="CMD_MEDIA", action="LIST_MEDIA")
    second = asyncio.run(router.dispatch(session, request))
    assert second["action"] == "LIST_MEDIA_RESULT"  # connection continues to work


def test_build_helpers_shapes() -> None:
    envelope = make_envelope()
    ack = build_ack(envelope, value=7)
    assert ack["id"] == envelope.id
    assert ack["action"] == f"{envelope.action}_RESULT"
    assert ack["payload"] == {"ok": True, "value": 7}
    err = build_error(envelope, E_UNKNOWN_ACTION, "nope")
    assert err["payload"] == {"code": 4002, "message": "nope"}
    generic = build_error(None, "E_BAD_JSON", "malformed JSON: x")
    assert generic["id"] is None
    assert generic["action"] == "ERROR"
    recovered = build_error(str(uuid.uuid4()), "E_BAD_ENVELOPE", "missing keys")
    assert UUID4_RE.fullmatch(recovered["id"])


# --- Unit: broadcast --------------------------------------------------------


def test_broadcast_counts() -> None:
    async def scenario() -> int:
        router = WsRouter()
        server = WsServer(router=router, auth=FakeAuth())
        good1, good2, broken = FakeSocket(), FakeSocket(), FakeSocket(broken=True)
        for sock in (good1, good2, broken):
            server._sessions[sock] = WsSession(sock)
        delivered = await server.broadcast({"type": "TELEMETRY_SYNC", "action": "FULL_STATE"})
        assert json.loads(good1.sent[0])["action"] == "FULL_STATE"
        assert json.loads(good2.sent[0])["action"] == "FULL_STATE"
        assert broken.sent == []
        return delivered

    assert asyncio.run(scenario()) == 2


# --- Integration: real server + real client on an ephemeral port ------------


async def _wait_for_frame(ws: Any, max_wait: float = 2.0) -> dict[str, Any]:
    return json.loads(await asyncio.wait_for(ws.recv(), max_wait))


def _request_frame(action: str, payload: dict[str, Any] | None = None) -> str:
    return json.dumps(
        {
            "id": str(uuid.uuid4()),
            "type": "CMD_SYSTEM",
            "action": action,
            "payload": payload or {},
            "timestamp": int(time.time()),
        }
    )


def test_ws_server_integration() -> None:
    from websockets.asyncio.client import connect

    router = WsRouter()

    async def request_state(session: WsSession, envelope: WsEnvelope) -> dict[str, Any]:
        return {"ok": True, "state": "snapshot"}

    router.register("CMD_SYSTEM", "REQUEST_STATE", request_state)
    connected: list[Any] = []
    disconnected: list[Any] = []
    server = WsServer(
        router=router,
        auth=FakeAuth(),
        on_client_connected=connected.append,
        on_client_disconnected=disconnected.append,
    )

    async def scenario() -> None:
        await server.start(host="127.0.0.1", port=0)
        port = server.port
        base = f"ws://127.0.0.1:{port}"

        # Handshake reject: missing token -> HTTP 401, no session created.
        with pytest.raises(InvalidStatus) as excinfo:
            await connect(f"{base}/")
        assert excinfo.value.response.status_code == 401
        assert server.handshake_rejections == 1
        assert server.client_count == 0

        # Handshake accept: AUTH_OK greeting, then a CMD_SYSTEM round trip.
        async with connect(f"{base}/?auth={TOKEN}") as first:
            greeting = await _wait_for_frame(first)
            assert greeting["type"] == "CMD_SYSTEM"
            assert greeting["action"] == "AUTH_OK"
            assert greeting["payload"] == {"ok": True}
            assert server.client_count == 1
            assert len(connected) == 1

            request_id = str(uuid.uuid4())
            await first.send(
                json.dumps(
                    {
                        "id": request_id,
                        "type": "CMD_SYSTEM",
                        "action": "REQUEST_STATE",
                        "payload": {},
                        "timestamp": int(time.time()),
                    }
                )
            )
            ack = await _wait_for_frame(first)
            assert ack["id"] == request_id
            assert ack["action"] == "REQUEST_STATE_RESULT"
            assert ack["payload"] == {"ok": True, "state": "snapshot"}

            # Unknown action -> *_ERROR frame, connection stays open.
            await first.send(_request_frame("NOT_A_REAL_ACTION"))
            error = await _wait_for_frame(first)
            assert error["action"] == "NOT_A_REAL_ACTION_ERROR"
            assert error["payload"]["code"] == 4002

            # Inbound TELEMETRY_SYNC -> rejected (4002), connection stays open.
            await first.send(
                json.dumps(
                    {
                        "id": str(uuid.uuid4()),
                        "type": "TELEMETRY_SYNC",
                        "action": "STATE_DELTA",
                        "payload": {},
                        "timestamp": int(time.time()),
                    }
                )
            )
            assert (await _wait_for_frame(first))["payload"]["code"] == 4002

            # Second client; broadcast reaches both exactly once.
            async with connect(f"{base}/?auth={TOKEN}") as second:
                await _wait_for_frame(second)  # greeting
                assert server.client_count == 2
                telemetry = {
                    "id": str(uuid.uuid4()),
                    "type": "TELEMETRY_SYNC",
                    "action": "STATE_DELTA",
                    "payload": {"position_ms": 1234},
                    "timestamp": int(time.time()),
                }
                delivered = await server.broadcast(telemetry)
                assert delivered == 2
                first_frame = await _wait_for_frame(first)
                second_frame = await _wait_for_frame(second)
                assert first_frame == telemetry
                assert second_frame == telemetry

            # Malformed JSON -> E_BAD_JSON frame then close 4400.
            await first.send("{broken json")
            bad_frame = await _wait_for_frame(first)
            assert bad_frame["action"] == "ERROR"
            assert bad_frame["payload"]["code"] == 4400
            with pytest.raises(ConnectionClosed):  # closed right after the error frame
                await asyncio.wait_for(first.recv(), 2.0)

        # Server-side disconnect hooks fire on the handler task; give them a beat.
        deadline = time.monotonic() + 2.0
        while len(disconnected) < 2 and time.monotonic() < deadline:  # noqa: ASYNC110
            await asyncio.sleep(0.01)
        assert len(disconnected) == 2
        await server.stop()
        assert server.client_count == 0
        # Port freed: immediate rebind succeeds.
        await server.start(host="127.0.0.1", port=port)
        await server.stop()

    asyncio.run(scenario())
