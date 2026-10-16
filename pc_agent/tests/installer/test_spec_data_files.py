"""Doc 27 §9 — data_files()/icon logic with PyInstaller collection mocked.

Executes the real spec inside a stubbed PyInstaller namespace (Analysis/PYZ/
EXE/COLLECT + ``SPECPATH``) so no build ever runs during the test.
"""

from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace

import pytest

hooks = pytest.importorskip("PyInstaller.utils.hooks")

REPO_ROOT = Path(__file__).resolve().parents[3]
SPEC_PATH = REPO_ROOT / "pc_agent" / "installer" / "potpilot_agent.spec"


def _exec_spec(monkeypatch: pytest.MonkeyPatch, spec_dir: Path) -> SimpleNamespace:
    collected: list[str] = []

    def fake_collect(name: str) -> list[tuple[str, str]]:
        collected.append(name)
        return [(f"fake_assets/{name}/asset.bin", name)]

    monkeypatch.setattr(hooks, "collect_data_files", fake_collect)

    calls = SimpleNamespace(analysis=None, exe=None, collect=None)

    def Analysis(*args: object, **kwargs: object) -> SimpleNamespace:
        calls.analysis = SimpleNamespace(args=args, kwargs=kwargs)
        return SimpleNamespace(
            pure=(),
            scripts=(),
            binaries=[],
            datas=list(kwargs.get("datas") or []),  # type: ignore[arg-type]
        )

    def PYZ(pure: object) -> SimpleNamespace:
        return SimpleNamespace(kind="pyz", pure=pure)

    def EXE(*args: object, **kwargs: object) -> SimpleNamespace:
        calls.exe = SimpleNamespace(args=args, kwargs=kwargs)
        return SimpleNamespace(kind="exe")

    def COLLECT(exe: object, binaries: object, datas: object, **kwargs: object) -> SimpleNamespace:
        calls.collect = SimpleNamespace(kwargs=kwargs)
        return SimpleNamespace(kind="collect")

    namespace: dict[str, object] = {
        "SPECPATH": str(spec_dir),
        "Analysis": Analysis,
        "PYZ": PYZ,
        "EXE": EXE,
        "COLLECT": COLLECT,
    }
    source = SPEC_PATH.read_text(encoding="utf-8")
    exec(compile(source, str(SPEC_PATH), "exec"), namespace)
    return SimpleNamespace(namespace=namespace, collected=collected, calls=calls)


def test_customtkinter_collection_feeds_analysis(monkeypatch) -> None:
    result = _exec_spec(monkeypatch, SPEC_PATH.parent)
    assert set(result.collected) == {"customtkinter"}
    datas = result.calls.analysis.kwargs["datas"]
    assert any(dest == "customtkinter" for _src, dest in datas)
    # repo shared_specs tables ride along (Doc 09/10 JSON tables, frozen path)
    assert any(dest == "shared_specs" for _src, dest in datas)


def test_icon_and_assets_included_when_asset_exists(monkeypatch, tmp_path) -> None:
    spec_dir = tmp_path / "installer"
    spec_dir.mkdir()
    assets = tmp_path / "assets"
    assets.mkdir()
    (assets / "potpilot_icon.ico").write_bytes(b"icon-bytes")

    result = _exec_spec(monkeypatch, spec_dir)
    icon = result.namespace["icon_or_none"]()
    assert icon == str((spec_dir / ".." / "assets" / "potpilot_icon.ico").resolve())
    datas = result.namespace["data_files"]()
    assert any(dest == "assets" for _src, dest in datas)
    # no shared_specs under this synthetic repo root -> skipped, no crash
    assert not any(dest == "shared_specs" for _src, dest in datas)


def test_icon_absent_falls_back_to_none(monkeypatch) -> None:
    result = _exec_spec(monkeypatch, SPEC_PATH.parent)
    assert result.namespace["icon_or_none"]() is None
    datas = result.namespace["data_files"]()
    assert not any(dest == "assets" for _src, dest in datas)  # pc_agent/assets absent


def test_onefile_and_onedir_topologies_both_build(monkeypatch) -> None:
    """ONEFILE=True flips the EXE payload; COLLECT disappears (Doc 27 §3)."""
    source = SPEC_PATH.read_text(encoding="utf-8")
    patched = source.replace("ONEFILE: bool = False", "ONEFILE: bool = True", 1)
    assert patched != source

    monkeypatch.setattr(
        hooks,
        "collect_data_files",
        lambda name: [(f"fake_assets/{name}/asset.bin", name)],
    )
    calls = SimpleNamespace(exe=None, collect_called=False)

    def Analysis(*args: object, **kwargs: object) -> SimpleNamespace:
        return SimpleNamespace(
            pure=(), scripts=(), binaries=[("b.dll", "b.dll", "BINARY")], datas=[]
        )

    def PYZ(pure: object) -> SimpleNamespace:
        return SimpleNamespace(kind="pyz")

    def EXE(*args: object, **kwargs: object) -> SimpleNamespace:
        calls.exe = SimpleNamespace(args=args, kwargs=kwargs)
        return SimpleNamespace(kind="exe")

    def COLLECT(*args: object, **kwargs: object) -> SimpleNamespace:
        calls.collect_called = True
        return SimpleNamespace(kind="collect")

    namespace: dict[str, object] = {
        "SPECPATH": str(SPEC_PATH.parent),
        "Analysis": Analysis,
        "PYZ": PYZ,
        "EXE": EXE,
        "COLLECT": COLLECT,
    }
    exec(compile(patched, str(SPEC_PATH), "exec"), namespace)
    assert calls.exe.kwargs["exclude_binaries"] is False
    # onefile embeds the Analysis payloads positionally
    assert len(calls.exe.args) == 4  # pyz, scripts, binaries, datas
    assert calls.collect_called is False
