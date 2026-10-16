"""Doc 17 §9 — QR pairing payload tests (no camera, no network, tmp dirs only)."""

import json
import socket
from types import SimpleNamespace

import pytest
from PIL import Image

from pc_agent.core import qr_payload_gen as qpg
from pc_agent.core.qr_payload_gen import (
    PAYLOAD_VERSION,
    NoLanAddressError,
    build_pairing_payload,
    generate_qr_image,
    render_pairing_qr,
    save_qr_png,
)

_TOKEN = "ab" * 16  # fake 32-hex token; never a real secret
_FROZEN_KEYS = {"v", "host", "ips", "udp", "ws", "token"}


def _build(**overrides) -> str:
    kwargs = {
        "ips": ["192.168.1.42"],
        "hostname": "BEDROOM-PC",
        "token_hex": _TOKEN,
    }
    kwargs.update(overrides)
    return build_pairing_payload(**kwargs)


def test_payload_roundtrip():
    payload = _build(ips=["192.168.1.42", "10.0.0.7"])
    data = json.loads(payload)
    assert data == {
        "v": PAYLOAD_VERSION,
        "host": "BEDROOM-PC",
        "ips": ["10.0.0.7", "192.168.1.42"],
        "udp": 50505,
        "ws": 50506,
        "token": _TOKEN,
    }
    assert set(data) == _FROZEN_KEYS
    # compact deterministic separators, keys sorted, byte-stable
    assert ", " not in payload
    assert ": " not in payload
    assert payload == _build(ips=["10.0.0.7", "192.168.1.42"])  # input order irrelevant
    assert payload.startswith('{"host":')
    assert len(payload) < 300


def test_payload_ports_default_and_override():
    default = json.loads(_build())
    assert default["udp"] == 50505
    assert default["ws"] == 50506
    overridden = json.loads(_build(udp_port=60001, ws_port=60002))
    assert overridden["udp"] == 60001
    assert overridden["ws"] == 60002


def test_token_validation():
    with pytest.raises(ValueError):
        _build(token_hex="a" * 31)  # wrong length
    with pytest.raises(ValueError):
        _build(token_hex="g" * 32)  # non-hex
    with pytest.raises(ValueError):
        _build(token_hex="")  # empty
    with pytest.raises(ValueError):
        _build(token_hex=(_TOKEN * 2))  # too long
    with pytest.raises(ValueError):
        _build(token_hex=_TOKEN.upper())  # uppercase rejected (lowercase enforced)


def test_ip_validation():
    with pytest.raises(ValueError) as excinfo:
        _build(ips=["999.1.1.1"])
    assert "999.1.1.1" in str(excinfo.value)
    with pytest.raises(ValueError) as excinfo:
        _build(ips=["not-an-ip"])
    assert "not-an-ip" in str(excinfo.value)
    with pytest.raises(ValueError) as excinfo:
        _build(ips=["192.168.1.42:50505"])
    assert "192.168.1.42:50505" in str(excinfo.value)
    # valid IPs preserved (sorted + deduped by the builder)
    data = json.loads(_build(ips=["192.168.1.5", "10.0.0.9", "192.168.1.5"]))
    assert data["ips"] == ["10.0.0.9", "192.168.1.5"]


def test_qr_image_properties():
    payload = _build()
    assert len(payload) < 300  # payload length guard
    image = generate_qr_image(payload)
    assert isinstance(image, Image.Image)
    assert image.mode == "RGB"
    # quiet-zone corner is pure background white
    assert image.getpixel((0, 0)) == (255, 255, 255)
    palette = {color for _count, color in (image.getcolors(maxcolors=1 << 16) or [])}
    assert (0, 0, 0) in palette  # pure-black modules present
    assert (255, 255, 255) in palette  # pure-white background present
    assert image.width > 0 and image.height == image.width


def test_render_uses_shared_ip_helper(monkeypatch):
    monkeypatch.setattr(qpg, "collect_lan_ipv4", lambda: ["10.1.2.3"])
    captured: dict[str, str] = {}
    real_generate = qpg.generate_qr_image

    def spy(payload: str) -> Image.Image:
        captured["payload"] = payload
        return real_generate(payload)

    monkeypatch.setattr(qpg, "generate_qr_image", spy)
    auth = SimpleNamespace(token_hex=_TOKEN)
    image = render_pairing_qr(auth=auth, hostname="TEST-PC")
    assert isinstance(image, Image.Image)
    data = json.loads(captured["payload"])
    assert data["ips"] == ["10.1.2.3"]  # the shared collect_lan_ipv4() output
    assert data["token"] == _TOKEN
    assert data["host"] == "TEST-PC"


def test_no_lan_address_raises(monkeypatch):
    monkeypatch.setattr(qpg, "collect_lan_ipv4", lambda: [])
    auth = SimpleNamespace(token_hex=_TOKEN)
    with pytest.raises(NoLanAddressError):
        render_pairing_qr(auth=auth)


def test_render_defaults_hostname(monkeypatch):
    monkeypatch.setattr(qpg, "collect_lan_ipv4", lambda: ["192.168.1.9"])
    captured: dict[str, str] = {}
    real_build = qpg.build_pairing_payload

    def spy(**kwargs) -> str:
        captured.update(kwargs)
        return real_build(**kwargs)

    monkeypatch.setattr(qpg, "build_pairing_payload", spy)
    render_pairing_qr(auth=SimpleNamespace(token_hex=_TOKEN))
    assert captured["hostname"] == socket.gethostname()


def test_save_qr_png_deterministic(tmp_path, monkeypatch):
    monkeypatch.setenv("APPDATA", str(tmp_path))
    payload = _build()
    first = save_qr_png(generate_qr_image(payload))
    assert first == tmp_path / "PotPilot" / "pairing_qr.png"
    first_bytes = first.read_bytes()
    assert first_bytes.startswith(b"\x89PNG\r\n\x1a\n")
    # second save of the same payload is byte-identical
    second = save_qr_png(generate_qr_image(payload))
    assert second == first
    assert second.read_bytes() == first_bytes
    # explicit path wins and parent dirs are created
    custom = save_qr_png(generate_qr_image(payload), tmp_path / "a" / "b" / "qr.png")
    assert custom == tmp_path / "a" / "b" / "qr.png"
    assert custom.exists()
