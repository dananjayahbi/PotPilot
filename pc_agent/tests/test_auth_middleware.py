"""Doc 15 §9 — token auth middleware tests (in-memory fake ConfigManager)."""

import re
from types import SimpleNamespace

from pc_agent.core.auth_middleware import (
    CONFIG_KEY_TOKEN,
    TOKEN_BYTES,
    TOKEN_HEX_LEN,
    AuthMiddleware,
    extract_handshake_token,
    generate_token,
    process_handshake,
    xor_checksum,
)

_TOKEN_RE = re.compile(r"[0-9a-f]{32}")


class FakeConfig:
    """In-memory stand-in for the Doc 26 ConfigManager (no disk I/O)."""

    def __init__(self, token: str = "") -> None:
        self.token = token
        self.ensure_calls = 0
        self.load_calls = 0
        self.updates: list[str] = []

    def get(self):
        return SimpleNamespace(auth_token=self.token)

    def load(self):
        self.load_calls += 1
        return self.get()

    def ensure_auth_token(self, generator):
        self.ensure_calls += 1
        if self.token:
            return self.token
        self.token = generator()
        return self.token

    def update(self, **changes):
        if "auth_token" in changes:
            self.token = changes["auth_token"]
            self.updates.append(self.token)
        return self.get()


def test_load_or_create_generates_once():
    cfg = FakeConfig()
    auth = AuthMiddleware(cfg)

    first = auth.load_or_create()
    assert _TOKEN_RE.fullmatch(first)
    assert len(first) == TOKEN_HEX_LEN
    assert TOKEN_BYTES == 16
    assert CONFIG_KEY_TOKEN == "auth_token"
    # first call persists through ConfigManager
    assert cfg.token == first
    assert cfg.ensure_calls == 1
    # second call reuses the identical token (also across "restarts")
    assert auth.load_or_create() == first
    assert AuthMiddleware(cfg).load_or_create() == first
    assert cfg.ensure_calls == 1


def test_xor_checksum_known_vector():
    # hand-computed fold: 1^2^...^16 = (1^...^15)^16 = 0^16 = 16
    token = bytes(range(1, 17))
    assert xor_checksum(token) == 16
    assert xor_checksum(b"\xff" + b"\x00" * 15) == 0xFF
    assert xor_checksum(b"\xff\x00" * 8) == 0
    # property: always a valid uint8
    for _ in range(50):
        value = xor_checksum(generate_token())
        assert 0 <= value <= 255
    # same token => same byte across "restarts"
    token_hex = generate_token().hex()
    cfg = FakeConfig(token=token_hex)
    assert AuthMiddleware(cfg).udp_auth_byte == xor_checksum(bytes.fromhex(token_hex))
    assert AuthMiddleware(cfg).udp_auth_byte == xor_checksum(bytes.fromhex(token_hex))


def test_udp_byte_accept_reject_matrix():
    auth = AuthMiddleware(FakeConfig())
    auth.load_or_create()
    accepted = [value for value in range(256) if auth.verify_udp_auth_byte(value)]
    assert accepted == [auth.udp_auth_byte]
    # out-of-range / non-int inputs never crash nor accept
    assert auth.verify_udp_auth_byte(-1) is False
    assert auth.verify_udp_auth_byte(256) is False
    assert auth.verify_udp_auth_byte("5") is False


def test_ws_token_compare():
    auth = AuthMiddleware(FakeConfig())
    token = auth.token_hex
    assert len(token) == TOKEN_HEX_LEN
    # exact / lowercase / uppercase all accepted
    assert auth.verify_ws_token(token) is True
    assert auth.verify_ws_token(token.lower()) is True
    assert auth.verify_ws_token(token.upper()) is True
    # truncated, extended, flipped-character, and empty all rejected
    assert auth.verify_ws_token(token[:-1]) is False
    assert auth.verify_ws_token(token + "0") is False
    flipped = ("0" if token[0] != "0" else "1") + token[1:]
    assert auth.verify_ws_token(flipped) is False
    assert auth.verify_ws_token("") is False


def test_invalid_stored_token_regenerated():
    for bad in ("zz", "a" * 31, "", ("AB" * 16)):
        cfg = FakeConfig(token=bad)
        auth = AuthMiddleware(cfg)
        token = auth.load_or_create()
        assert _TOKEN_RE.fullmatch(token), f"regenerated token invalid for {bad!r}"
        assert token != bad
        # regenerated token persisted under the Doc 26 key path
        assert cfg.token == token
        assert auth.verify_ws_token(token) is True


def test_reload_rotates():
    cfg = FakeConfig()
    auth = AuthMiddleware(cfg)
    old_token = auth.load_or_create()
    old_byte = auth.udp_auth_byte

    # external rotation: config replaced with a different valid token
    cfg.token = "cd" * 16
    rotated = auth.reload()
    assert rotated == "cd" * 16
    assert auth.udp_auth_byte == xor_checksum(bytes.fromhex(rotated))
    assert auth.verify_ws_token(old_token) is False
    assert auth.verify_udp_auth_byte(old_byte) is False
    assert auth.verify_ws_token(rotated) is True

    # manual rotation via key deletion: reload() mints a fresh token
    cfg.token = ""
    fresh = auth.reload()
    assert _TOKEN_RE.fullmatch(fresh)
    assert fresh != rotated
    assert auth.verify_ws_token(rotated) is False
    assert auth.verify_ws_token(fresh) is True
    assert cfg.load_calls == 2


def test_extract_handshake_token_query():
    token = "ab" * 16

    class FakeRequest:
        def __init__(self, path: str) -> None:
            self.path = path

    assert extract_handshake_token(FakeRequest(f"/?auth={token}")) == token
    assert extract_handshake_token(f"/?auth={token.upper()}") == token.upper()
    assert extract_handshake_token(f"/?x=1&auth={token}&y=2") == token
    # bare query string and websockets-style .query attribute
    assert extract_handshake_token(f"auth={token}") == token
    assert extract_handshake_token(SimpleNamespace(query=f"auth={token}")) == token
    # missing / malformed shapes
    assert extract_handshake_token(FakeRequest("/")) is None
    assert extract_handshake_token("/?other=1") is None
    assert extract_handshake_token(FakeRequest(f"/?x={token}")) is None
    assert extract_handshake_token(None) is None


def test_process_handshake_accept_reject():
    auth = AuthMiddleware(FakeConfig())
    auth.load_or_create()
    token = auth.token_hex

    good = SimpleNamespace(path=f"/?auth={token}")
    bad = SimpleNamespace(path="/?auth=" + "0" * TOKEN_HEX_LEN)
    missing = SimpleNamespace(path="/")

    assert process_handshake(good, auth) == "accept"
    assert process_handshake(f"/?auth={token.upper()}", auth) == "accept"
    assert process_handshake(bad, auth) == "reject"
    assert process_handshake(missing, auth) == "reject"
    assert process_handshake(None, auth) == "reject"
