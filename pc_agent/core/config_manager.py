"""PotPilot configuration persistence (Doc 26).

Single source of truth for every user-editable PC-agent setting stored in
``%APPDATA%\\PotPilot\\config.json`` (schema v1, atomic writes, corrupt-file
recovery) plus the per-user HKCU ``Run`` mirror of the startup flag.
"""

from __future__ import annotations

import copy
import json
import logging
import os
import re
import sys
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, ClassVar

logger = logging.getLogger("potpilot.core.config_manager")

CONFIG_DIR_NAME: str = "PotPilot"
CONFIG_FILE_NAME: str = "config.json"
CURRENT_SCHEMA_VERSION: int = 1
RUN_REGISTRY_KEY: str = r"Software\Microsoft\Windows\CurrentVersion\Run"
RUN_VALUE_NAME: str = "PotPilot"

_DEFAULT_UDP_PORT = 50505
_DEFAULT_WS_PORT = 50506
_MIN_PORT = 1024
_MAX_PORT = 65535
_TOKEN_RE = re.compile(r"[0-9a-f]{32}")
_MAX_CORRUPT_BACKUPS = 3

_KNOWN_KEYS = frozenset(
    {
        "schema_version",
        "udp_port",
        "ws_port",
        "auth_token",
        "movie_dirs",
        "run_on_startup",
        "minimize_to_tray",
    }
)

# Ordered schema migration hooks (vN -> vN+1); none yet, schema v1 is current.
_MIGRATIONS: dict[int, Callable[[dict[str, Any]], dict[str, Any]]] = {}


class ConfigError(Exception):
    """Invalid or unreadable configuration surface."""


class StartupRegistrationError(Exception):
    """Registry write/delete denied."""


@dataclass
class AppConfig:
    """Validated snapshot of ``config.json`` (schema v1).

    Direct construction is only meant for defaults and tests; runtime code
    reads snapshots via :meth:`ConfigManager.get`.
    """

    schema_version: int = CURRENT_SCHEMA_VERSION
    udp_port: int = _DEFAULT_UDP_PORT
    ws_port: int = _DEFAULT_WS_PORT
    auth_token: str = ""
    movie_dirs: list[str] = field(default_factory=list)
    run_on_startup: bool = False
    minimize_to_tray: bool = True


def _coerce_port(value: Any, key: str) -> int:
    if isinstance(value, bool):
        raise ConfigError(f"{key} must be an integer, not a bool")
    try:
        port = int(value)
    except (TypeError, ValueError) as exc:
        raise ConfigError(f"{key} must be an integer") from exc
    return max(_MIN_PORT, min(_MAX_PORT, port))


def _coerce_bool(value: Any, key: str) -> bool:
    if not isinstance(value, bool):
        raise ConfigError(f"{key} must be a bool")
    return value


def _coerce_dirs(value: Any) -> list[str]:
    if not isinstance(value, list):
        raise ConfigError("movie_dirs must be a list of strings")
    result: list[str] = []
    seen: set[str] = set()
    for entry in value:
        if not isinstance(entry, str):
            raise ConfigError("movie_dirs entries must be strings")
        expanded = os.path.expandvars(os.path.expanduser(entry.strip()))
        if not expanded:
            continue
        absolute = os.path.abspath(expanded)
        key = os.path.normcase(absolute)
        if key in seen:
            continue
        seen.add(key)
        result.append(absolute)
    return result


def _build_config(raw: dict[str, Any]) -> tuple[AppConfig, dict[str, Any]]:
    """Validate raw JSON data into an ``AppConfig`` plus its forward-compat extras."""
    version = raw.get("schema_version", CURRENT_SCHEMA_VERSION)
    if isinstance(version, bool):
        raise ConfigError("schema_version must be an integer")
    try:
        version = int(version)
    except (TypeError, ValueError) as exc:
        raise ConfigError("schema_version must be an integer") from exc
    if version < 1:
        raise ConfigError("schema_version must be >= 1")

    udp_port = _coerce_port(raw.get("udp_port", _DEFAULT_UDP_PORT), "udp_port")
    ws_port = _coerce_port(raw.get("ws_port", _DEFAULT_WS_PORT), "ws_port")
    if udp_port == ws_port:
        raise ConfigError("udp_port and ws_port must differ")

    token = raw.get("auth_token", "")
    if not isinstance(token, str) or not _TOKEN_RE.fullmatch(token):
        if token not in ("", None):
            logger.warning("auth_token invalid format; treating as absent")
        token = ""

    config = AppConfig(
        schema_version=version,
        udp_port=udp_port,
        ws_port=ws_port,
        auth_token=token,
        movie_dirs=_coerce_dirs(raw.get("movie_dirs", [])),
        run_on_startup=_coerce_bool(raw.get("run_on_startup", False), "run_on_startup"),
        minimize_to_tray=_coerce_bool(raw.get("minimize_to_tray", True), "minimize_to_tray"),
    )
    extra = {key: value for key, value in raw.items() if key not in _KNOWN_KEYS}
    return config, extra


def default_config_root() -> Path:
    """Resolve ``%APPDATA%\\PotPilot`` (Roaming-profile fallback when APPDATA is missing)."""
    appdata = os.environ.get("APPDATA")
    base = Path(appdata) if appdata else Path.home() / "AppData" / "Roaming"
    return base / CONFIG_DIR_NAME


class ConfigManager:
    """Thread-safe, process-wide configuration singleton.

    ``instance()`` is the only supported way to obtain the application manager;
    direct ``__init__`` exists for tests that need an isolated config path.
    """

    _instance: ClassVar[ConfigManager | None] = None
    _instance_lock: ClassVar[threading.Lock] = threading.Lock()

    def __init__(self, config_path: Path | None = None) -> None:
        self._explicit_path = Path(config_path) if config_path is not None else None
        self._lock = threading.RLock()
        self._config: AppConfig | None = None
        self._extra: dict[str, Any] = {}
        self._listeners: list[Callable[[AppConfig], None]] = []

    @classmethod
    def instance(cls) -> ConfigManager:
        """Return the lazy process-wide singleton."""
        if cls._instance is None:
            with cls._instance_lock:
                if cls._instance is None:
                    cls._instance = cls()
        return cls._instance

    def config_path(self) -> Path:
        """Absolute path of ``config.json`` (recomputed per call for testability)."""
        if self._explicit_path is not None:
            return self._explicit_path
        return default_config_root() / CONFIG_FILE_NAME

    def load(self) -> AppConfig:
        """Read-or-create config; quarantines corrupt files and migrates schemas."""
        with self._lock:
            return self._load_locked()

    def save(self) -> None:
        """Atomically persist the current snapshot."""
        with self._lock:
            if self._config is None:
                self._load_locked()
            self._save_locked()

    def get(self) -> AppConfig:
        """Return a deep, thread-safe snapshot copy."""
        with self._lock:
            if self._config is None:
                self._load_locked()
            return copy.deepcopy(self._config)

    def update(self, **changes: Any) -> AppConfig:
        """Validate, persist, then notify listeners; unknown keys land in extras."""
        with self._lock:
            if self._config is None:
                self._load_locked()
            known = {key: value for key, value in changes.items() if key in _KNOWN_KEYS}
            unknown = {key: value for key, value in changes.items() if key not in _KNOWN_KEYS}
            merged = {**self._as_dict(), **known}
            config, _ = _build_config(merged)
            previous_config, previous_extra = self._config, self._extra
            self._config = config
            self._extra = {**self._extra, **unknown}
            try:
                self._save_locked()
            except ConfigError:
                self._config, self._extra = previous_config, previous_extra
                raise
            snapshot = copy.deepcopy(config)
            self._notify_locked(snapshot)
            return snapshot

    def subscribe(self, callback: Callable[[AppConfig], None]) -> None:
        """Register a same-thread change hook fired after persistence succeeds."""
        with self._lock:
            self._listeners.append(callback)

    def ensure_auth_token(self, generator: Callable[[], str]) -> str:
        """Return the stored token, else call ``generator()`` once, persist and return it."""
        with self._lock:
            if self._config is None:
                self._load_locked()
            if self._config.auth_token:
                return self._config.auth_token
            token = generator()
            if not isinstance(token, str) or not _TOKEN_RE.fullmatch(token):
                raise ConfigError("auth token generator returned an invalid token")
            previous = self._config.auth_token
            self._config.auth_token = token
            try:
                self._save_locked()
            except ConfigError:
                self._config.auth_token = previous
                raise
            return token

    def is_startup_enabled(self) -> bool:
        """Ground truth: presence of the HKCU Run value ``PotPilot``."""
        try:
            import winreg
        except ImportError:
            return False
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_REGISTRY_KEY) as key:
                winreg.QueryValueEx(key, RUN_VALUE_NAME)
            return True
        except FileNotFoundError:
            return False
        except OSError as exc:
            logger.warning("cannot read HKCU Run value: %s", exc)
            return False

    def set_startup_enabled(self, enabled: bool, exe_path: Path) -> None:
        """Write/delete the HKCU Run value first, then persist ``run_on_startup``.

        Raises :class:`StartupRegistrationError` on registry ``OSError`` and rolls
        the in-memory flag back to the registry's actual state.
        """
        with self._lock:
            if self._config is None:
                self._load_locked()
            try:
                if enabled:
                    self._write_startup_value(Path(exe_path))
                else:
                    self._delete_startup_value()
            except StartupRegistrationError:
                self._config.run_on_startup = self.is_startup_enabled()
                raise
            self._config.run_on_startup = enabled
            try:
                self._save_locked()
            except ConfigError:
                logger.error("startup flag persisted to registry but not to config file")
                raise

    def resync_startup(self) -> None:
        """Best-effort boot pass: rewrite the Run value when the flag is true but the
        value is missing (no-op otherwise)."""
        with self._lock:
            if self._config is None:
                self._load_locked()
            if not self._config.run_on_startup or self.is_startup_enabled():
                return
            try:
                self._write_startup_value(Path(sys.executable))
            except StartupRegistrationError as exc:
                logger.warning("resync_startup skipped: %s", exc)

    # ------------------------------------------------------------------
    # internals
    # ------------------------------------------------------------------

    def _as_dict(self) -> dict[str, Any]:
        assert self._config is not None
        return {
            "schema_version": self._config.schema_version,
            "udp_port": self._config.udp_port,
            "ws_port": self._config.ws_port,
            "auth_token": self._config.auth_token,
            "movie_dirs": list(self._config.movie_dirs),
            "run_on_startup": self._config.run_on_startup,
            "minimize_to_tray": self._config.minimize_to_tray,
        }

    def _load_locked(self) -> AppConfig:
        path = self.config_path()
        if not path.exists():
            self._config, self._extra = _build_config({})
            return copy.deepcopy(self._config)
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
            if not isinstance(raw, dict):
                raise ConfigError("config root must be a JSON object")
            raw = self._migrate_locked(raw)
            config, extra = _build_config(raw)
        except (
            OSError,
            json.JSONDecodeError,
            KeyError,
            TypeError,
            ValueError,
            ConfigError,
        ) as exc:
            logger.warning("config unreadable (%s); quarantining and using defaults", exc)
            self._quarantine_locked(path)
            self._config, self._extra = _build_config({})
            return copy.deepcopy(self._config)
        if config.schema_version > CURRENT_SCHEMA_VERSION:
            logger.warning(
                "config schema v%s is newer than supported v%s; loading best-effort",
                config.schema_version,
                CURRENT_SCHEMA_VERSION,
            )
        self._config, self._extra = config, extra
        return copy.deepcopy(config)

    def _migrate_locked(self, raw: dict[str, Any]) -> dict[str, Any]:
        version = raw.get("schema_version", CURRENT_SCHEMA_VERSION)
        try:
            version = int(version)
        except (TypeError, ValueError) as exc:
            raise ConfigError("schema_version must be an integer") from exc
        while version < CURRENT_SCHEMA_VERSION and version in _MIGRATIONS:
            raw = _MIGRATIONS[version](raw)
            version += 1
        return raw

    def _quarantine_locked(self, path: Path) -> None:
        stamp = time.strftime("%Y%m%d-%H%M%S")
        backup = path.with_name(f"{path.name}.corrupt-{stamp}")
        counter = 1
        while backup.exists():
            backup = path.with_name(f"{path.name}.corrupt-{stamp}-{counter}")
            counter += 1
        try:
            os.replace(path, backup)
        except OSError as exc:
            logger.warning("cannot quarantine %s: %s", path, exc)
            return
        try:
            # Prune by age, not name: quarantine names may be recycled within a
            # second after an older backup was pruned.
            backups = list(path.parent.glob(f"{path.name}.corrupt-*"))
            backups.sort(key=lambda item: (item.stat().st_mtime, item.name))
            for stale in backups[: max(0, len(backups) - _MAX_CORRUPT_BACKUPS)]:
                stale.unlink()
        except OSError as exc:
            logger.warning("cannot prune old config backups: %s", exc)

    def _save_locked(self) -> None:
        assert self._config is not None
        payload = self._as_dict()
        payload.update(self._extra)
        text = json.dumps(payload, indent=2, sort_keys=True) + "\n"
        path = self.config_path()
        tmp = path.with_name(path.name + ".tmp")
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            with open(tmp, "w", encoding="utf-8") as handle:
                handle.write(text)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(tmp, path)
        except OSError as exc:
            raise ConfigError(f"cannot write config to {path}: {exc}") from exc

    def _notify_locked(self, snapshot: AppConfig) -> None:
        for callback in list(self._listeners):
            try:
                callback(copy.deepcopy(snapshot))
            except Exception:
                logger.exception("config listener failed")

    def _write_startup_value(self, exe_path: Path) -> None:
        try:
            import winreg
        except ImportError as exc:
            raise StartupRegistrationError("winreg unavailable on this host") from exc
        data = f'"{exe_path}" --minimized'
        try:
            key = winreg.CreateKeyEx(
                winreg.HKEY_CURRENT_USER, RUN_REGISTRY_KEY, 0, winreg.KEY_SET_VALUE
            )
            try:
                winreg.SetValueEx(key, RUN_VALUE_NAME, 0, winreg.REG_SZ, data)
            finally:
                winreg.CloseKey(key)
        except OSError as exc:
            raise StartupRegistrationError(f"cannot write HKCU Run value: {exc}") from exc

    def _delete_startup_value(self) -> None:
        try:
            import winreg
        except ImportError as exc:
            raise StartupRegistrationError("winreg unavailable on this host") from exc
        try:
            key = winreg.OpenKey(
                winreg.HKEY_CURRENT_USER, RUN_REGISTRY_KEY, 0, winreg.KEY_SET_VALUE
            )
            try:
                winreg.DeleteValue(key, RUN_VALUE_NAME)
            finally:
                winreg.CloseKey(key)
        except FileNotFoundError:
            return
        except OSError as exc:
            raise StartupRegistrationError(f"cannot delete HKCU Run value: {exc}") from exc
