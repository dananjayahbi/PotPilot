"""Doc 27 §9 — potpilot_agent.spec static contract (parsed with ast, never run)."""

from __future__ import annotations

import ast
from pathlib import Path

SPEC_PATH = Path(__file__).resolve().parents[2] / "installer" / "potpilot_agent.spec"

# Doc 27 §5 hidden-import table (every row's module names).
DOC5_MODULES = [
    "win32api",
    "win32con",
    "win32gui",
    "win32process",
    "win32ui",
    "pythoncom",
    "pywintypes",
    "win32com",
    "win32com.shell",
    "pystray._win32",
    "PIL",
    "PIL.Image",
    "PIL.ImageTk",
    "qrcode",
    "websockets",
    "zeroconf",
    "monitorcontrol",
    "comtypes",
    "pycaw",
]


def _tree() -> ast.Module:
    return ast.parse(SPEC_PATH.read_text(encoding="utf-8"))


def _module_constant(tree: ast.Module, name: str):
    for node in tree.body:
        if isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
            if node.target.id == name:
                return ast.literal_eval(node.value)
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name) and target.id == name:
                    return ast.literal_eval(node.value)
    raise AssertionError(f"spec constant {name!r} not found")


def _module_assignment_source(tree: ast.Module, name: str) -> str:
    for node in tree.body:
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name) and target.id == name:
                    return ast.unparse(node.value)
    raise AssertionError(f"spec assignment {name!r} not found")


def _function_list_return(tree: ast.Module, func_name: str) -> list[str]:
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and node.name == func_name:
            for statement in node.body:
                if isinstance(statement, ast.Return) and statement.value is not None:
                    return list(ast.literal_eval(statement.value))
    raise AssertionError(f"spec function {func_name!r} with literal return not found")


def _calls(tree: ast.Module, func_name: str) -> list[ast.Call]:
    return [
        node
        for node in ast.walk(tree)
        if isinstance(node, ast.Call)
        and isinstance(node.func, ast.Name)
        and node.func.id == func_name
    ]


def test_onefile_default_is_false_and_onedir_is_canonical() -> None:
    assert _module_constant(_tree(), "ONEFILE") is False


def test_app_name_constant() -> None:
    assert _module_constant(_tree(), "APP_NAME") == "PotPilotAgent"


def test_icon_path_relative_to_spec_dir() -> None:
    assert _module_constant(_tree(), "ICON_PATH") == "../assets/potpilot_icon.ico"


def test_hidden_imports_cover_doc5_table() -> None:
    hidden = _function_list_return(_tree(), "hidden_imports")
    missing = [name for name in DOC5_MODULES if name not in hidden]
    assert missing == [], f"missing Doc 27 §5 hidden imports: {missing}"


def test_hidden_imports_include_monitorcontrol_backend() -> None:
    hidden = _function_list_return(_tree(), "hidden_imports")
    assert any(
        name.startswith("monitorcontrol.") for name in hidden
    ), "monitorcontrol's VCP/hid backend must be listed (Doc 27 §5)"


def test_analysis_entry_excludes_and_datas() -> None:
    tree = _tree()
    calls = _calls(tree, "Analysis")
    assert len(calls) == 1
    call = calls[0]
    assert ast.unparse(call.args[0]) == "[_ENTRY]"  # entry anchored via SPECPATH
    assert "main.py" in _module_assignment_source(tree, "_ENTRY")
    keywords = {kw.arg: kw.value for kw in call.keywords}
    excludes = list(ast.literal_eval(keywords["excludes"]))
    assert excludes == ["tkinter.test", "unittest", "pydoc"]
    # datas come from the data_files() seam (asserted in test_spec_data_files)
    assert isinstance(keywords["datas"], ast.Call)
    assert isinstance(keywords["datas"].func, ast.Name)
    assert keywords["datas"].func.id == "data_files"
    assert isinstance(keywords["hiddenimports"], ast.Call)
    assert isinstance(keywords["hiddenimports"].func, ast.Name)
    assert keywords["hiddenimports"].func.id == "hidden_imports"


def test_console_false_single_exe_call_with_collect_onedir() -> None:
    tree = _tree()
    exe_calls = _calls(tree, "EXE")
    assert len(exe_calls) == 1
    console = [kw for kw in exe_calls[0].keywords if kw.arg == "console"]
    assert len(console) == 1
    assert ast.literal_eval(console[0].value) is False
    upx = [kw for kw in exe_calls[0].keywords if kw.arg == "upx"]
    assert ast.literal_eval(upx[0].value) is False
    # onedir topology: a COLLECT branch guarded by ``if not ONEFILE``
    assert len(_calls(tree, "COLLECT")) == 1
    guard = [
        node
        for node in tree.body
        if isinstance(node, ast.If) and "not ONEFILE" in ast.unparse(node.test)
    ]
    assert len(guard) == 1
