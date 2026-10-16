"""PotPilot PC dashboard window (Doc 24).

Dark-mode CustomTkinter control surface for the PC agent: pairing QR panel,
4-state connection badge, connected-device info, and watched-folder pickers.

Threading model (doc §4): widgets are touched only on the Tk thread (T0).
``post()`` is the sole cross-thread entry point and only touches a
:class:`queue.Queue`; backend threads push :class:`UiEvent` values and a
``root.after(UI_POLL_MS)`` pump drains them.  The pystray thread calls
``show()``/``focus_qr()``/``hide()``/``close()``, which marshal onto T0 via
``root.after(0, ...)`` (or run inline when already on T0).
"""

from __future__ import annotations

import enum
import logging
import os
import queue
import socket
import threading
import time
import tkinter
from collections.abc import Awaitable, Callable, Sequence
from concurrent.futures import Future
from dataclasses import dataclass
from tkinter import filedialog, messagebox
from typing import Any

import customtkinter as ctk

from pc_agent.core.config_manager import ConfigManager

logger = logging.getLogger("potpilot.gui.dashboard_window")

# Event-pump cadence: badge animates at most 10 Hz (doc §4.5 / §7).
UI_POLL_MS: int = 100
QR_REFRESH_S: int = 300  # event-driven refresh + this interval (doc §4.6)
QR_RETRY_MS: int = 15_000  # auto-retry after a failed QR render (doc §7)
QR_IMAGE_PX: int = 260
NOTICE_MS: int = 5_000
WINDOW_MIN_SIZE: tuple[int, int] = (960, 640)
APP_TITLE: str = "PotPilot"
APP_VERSION: str = "0.1.0"

EVENT_CONNECTION: str = "connection"
EVENT_QR_REFRESH: str = "qr_refresh"
EVENT_NOTICE: str = "notice"
EVENT_FOLDERS: str = "folders"

# Chrome cosmetics (doc §10): crimson/amber accents matching the Flutter palette.
_TEXT_PRIMARY: str = "#D6CEC9"
_TEXT_DIM: str = "#9C948E"
_TEXT_MISSING: str = "#7A7269"
_ACCENT_CRIMSON: str = "#5E1F27"
_ACCENT_CRIMSON_HOVER: str = "#A63240"
_ACCENT_GRAY: str = "#3A3A3E"
_NOTICE_AMBER: str = "#D9A441"


class BadgeState(enum.Enum):
    """Badge state machine (doc §4): ``STARTING → IDLE → CONNECTED | ERROR``."""

    STARTING = "starting"
    IDLE = "idle"
    CONNECTED = "connected"
    ERROR = "error"


@dataclass(frozen=True)
class ConnectionInfo:
    """Snapshot behind one badge update; ``detail`` is the ERROR text/tooltip."""

    state: BadgeState
    device_ip: str | None
    client_count: int
    detail: str = ""


@dataclass(frozen=True)
class UiEvent:
    """Cross-thread GUI event (doc §4, kinds table): ``connection`` carries a
    :class:`ConnectionInfo`, ``notice``/``qr_refresh`` may carry ``message``."""

    kind: str
    connection: ConnectionInfo | None = None
    message: str | None = None


@dataclass(frozen=True)
class BadgeSpec:
    """Rendered badge colors + caption (doc §5 badge table)."""

    fill: str
    text: str
    caption: str


def render_badge(info: ConnectionInfo) -> BadgeSpec:
    """Map ``info`` to the exact fill/text/caption of doc §5's badge table."""
    if info.state is BadgeState.STARTING:
        return BadgeSpec("#3A3A3E", "#D6CEC9", "Starting…")
    if info.state is BadgeState.IDLE:
        return BadgeSpec("#5E1F27", "#D6CEC9", "Waiting for phone")
    if info.state is BadgeState.CONNECTED:
        ip = info.device_ip or "unknown"
        return BadgeSpec(
            "#6E5016",
            "#F0E6DC",
            f"Connected · {ip} · {info.client_count} device(s)",
        )
    return BadgeSpec("#A63240", "#FFF3EE", info.detail or "Error")


def coalesce(pending: UiEvent, incoming: UiEvent) -> UiEvent:
    """Return the survivor when two events collide in one queue slot.

    Connection telemetry churns every ~250 ms, so the pump keeps a single
    connection slot per drain tick and the newest event wins
    (last-write-wins, doc §4.5).  Callers never mix kinds; mixed pairs raise.
    """
    if pending.kind != incoming.kind:
        raise ValueError(
            f"cannot coalesce UiEvent kinds {pending.kind!r} and {incoming.kind!r}"
        )
    return incoming


def ensure_tk_thread(expected: threading.Thread) -> None:
    """Debug guard: widget mutations are legal only on the Tk thread (doc §7)."""
    current = threading.current_thread()
    if current is not expected:
        raise RuntimeError(
            f"Tk widget mutation from {current.name!r}; Tk thread is {expected.name!r}"
        )


class UiEventPump:
    """Thread-safe ``post()`` queue drained on the Tk thread (doc §4.5).

    ``post()`` must never touch Tk objects: it is called from the asyncio
    loop, the tray thread, and callbacks, where touching Tk would raise
    ``RuntimeError: main thread is not in main loop``.
    """

    def __init__(self) -> None:
        self._queue: queue.Queue[UiEvent] = queue.Queue()
        self._handlers: dict[str, Callable[[UiEvent], None]] = {}

    def register(self, kind: str, handler: Callable[[UiEvent], None]) -> None:
        """Route ``kind`` events to ``handler`` on the next :meth:`drain`."""
        self._handlers[kind] = handler

    def post(self, event: UiEvent) -> None:
        """Enqueue ``event`` from any thread — never touches Tk objects."""
        if not isinstance(event, UiEvent):
            raise TypeError(f"UiEvent expected, got {type(event).__name__!r}")
        self._queue.put(event)

    def pending(self) -> int:
        """Number of queued events awaiting the next drain."""
        return self._queue.qsize()

    def drain(self) -> int:
        """Dispatch queued events; returns the number handled (call on T0).

        Connection events coalesce last-write-wins per drain tick so 250 ms
        telemetry churn never floods Tk (at most one connection dispatch per
        tick).  Unknown kinds are dropped with a warning.
        """
        latest_connection: UiEvent | None = None
        dispatched = 0
        while True:
            try:
                event = self._queue.get_nowait()
            except queue.Empty:
                break
            if event.kind == EVENT_CONNECTION:
                if latest_connection is None:
                    latest_connection = event
                else:
                    latest_connection = coalesce(latest_connection, event)
                continue
            if self._dispatch(event):
                dispatched += 1
        if latest_connection is not None and self._dispatch(latest_connection):
            dispatched += 1
        return dispatched

    def _dispatch(self, event: UiEvent) -> bool:
        handler = self._handlers.get(event.kind)
        if handler is None:
            logger.warning("dropping UiEvent kind %r: no handler registered", event.kind)
            return False
        handler(event)
        return True


@dataclass(frozen=True)
class FolderRowModel:
    """One watched-folder row: normalized path + on-disk existence flag (doc §7)."""

    path: str
    missing: bool = False

    @staticmethod
    def normalize(path: str) -> str:
        """Expand ``~``/env vars, collapse separators, strip trailing ones."""
        expanded = os.path.expandvars(os.path.expanduser(str(path).strip()))
        if not expanded:
            raise ValueError("folder path is empty")
        return os.path.normpath(expanded)

    @property
    def key(self) -> str:
        """Case-folded identity for duplicate detection (Windows paths)."""
        return os.path.normcase(self.path)


@dataclass(frozen=True)
class FolderChange:
    """Outcome of a folder-list mutation; ``notice`` is user-facing text."""

    changed: bool
    duplicate: bool = False
    notice: str | None = None


class FolderPickerModel:
    """Watched-folder list: normalize → dedupe → persist once per change.

    Persistence goes through ``ConfigManager.update(movie_dirs=...)`` exactly
    once per change, then ``on_change`` fires (doc §4.4 ordering: persist
    first, then the injected rescan callback).
    """

    def __init__(
        self,
        config: ConfigManager,
        on_change: Callable[[list[str]], None] | None = None,
    ) -> None:
        self._config = config
        self._on_change = on_change
        self._rows: list[FolderRowModel] = []
        for raw in config.get().movie_dirs:
            row = self._row_from(raw)
            if row is not None and not self._contains(row.key):
                self._rows.append(row)

    @property
    def rows(self) -> list[FolderRowModel]:
        """Copy of the current rows in display order."""
        return list(self._rows)

    @property
    def paths(self) -> list[str]:
        """Normalized paths exactly as persisted to ``movie_dirs``."""
        return [row.path for row in self._rows]

    def add(self, path: str) -> FolderChange:
        """Append one folder; duplicates and invalid paths are ignored (doc §7)."""
        row = self._row_from(path)
        if row is None:
            return FolderChange(False, notice=f"Invalid folder: {path!r}")
        if self._contains(row.key):
            return FolderChange(False, duplicate=True, notice=f"Already watched: {row.path}")
        self._rows.append(row)
        self._commit()
        return FolderChange(True)

    def remove(self, path: str) -> FolderChange:
        """Drop one folder by (normalized) path; unknown paths are a no-op."""
        row = self._row_from(path)
        if row is None:
            return FolderChange(False)
        key = row.key
        for index, existing in enumerate(self._rows):
            if existing.key == key:
                del self._rows[index]
                self._commit()
                return FolderChange(True)
        return FolderChange(False)

    def set_paths(self, paths: Sequence[str]) -> FolderChange:
        """Replace the whole list (``set_folders`` / external ``folders`` event).

        Normalizes, dedupes preserving order, and persists at most once —
        no persist when the result equals the current list.
        """
        rows: list[FolderRowModel] = []
        seen: set[str] = set()
        duplicate = False
        invalid = False
        for raw in paths:
            row = self._row_from(raw)
            if row is None:
                invalid = True
                continue
            if row.key in seen:
                duplicate = True
                continue
            seen.add(row.key)
            rows.append(row)
        notice = None
        if duplicate:
            notice = "Duplicate folders ignored"
        elif invalid:
            notice = "Invalid folders ignored"
        if [row.path for row in rows] == self.paths:
            return FolderChange(False, duplicate=duplicate, notice=notice)
        self._rows = rows
        self._commit()
        return FolderChange(True, duplicate=duplicate, notice=notice)

    def refresh_missing(self) -> bool:
        """Re-check on-disk existence; True when any flag flipped (doc §7)."""
        changed = False
        for index, row in enumerate(self._rows):
            missing = not os.path.isdir(row.path)
            if missing != row.missing:
                self._rows[index] = FolderRowModel(row.path, missing=missing)
                changed = True
        return changed

    def _commit(self) -> None:
        """Persist exactly once per change, then notify (doc §4.4 ordering)."""
        self._config.update(movie_dirs=self.paths)
        if self._on_change is not None:
            self._on_change(self.paths)

    def _contains(self, key: str) -> bool:
        return any(row.key == key for row in self._rows)

    @staticmethod
    def _row_from(path: object) -> FolderRowModel | None:
        if not isinstance(path, str):
            return None
        try:
            normalized = FolderRowModel.normalize(path)
        except (OSError, ValueError):
            return None
        if not normalized or normalized == os.curdir:
            return None
        return FolderRowModel(normalized, missing=not os.path.isdir(normalized))


class DashboardWindow:
    """Dark-mode PotPilot control window (doc §4); owns the Tk thread (T0).

    ``config`` is a ConfigManager (26), ``qr_image_factory`` a ``() -> CTkImage``
    callable (17), and ``submit`` an ``(Awaitable) -> concurrent.futures.Future``
    dispatcher onto the asyncio loop wired by ``main.py``.  The optional
    keyword callbacks let Session 3 wiring marshal the folder rescan (20),
    the coordinated shutdown, the tray-alive probe, and the tray's
    first-minimize balloon notification (25).
    """

    def __init__(
        self,
        config: ConfigManager,
        qr_image_factory: Callable[[], ctk.CTkImage],
        submit: Callable[[Awaitable[Any]], Future[Any]],
        *,
        rescan_factory: Callable[[], Awaitable[Any]] | None = None,
        shutdown_callback: Callable[[], None] | None = None,
        tray_alive: Callable[[], bool] | None = None,
        hide_callback: Callable[[], None] | None = None,
    ) -> None:
        self._config = config
        self._qr_image_factory = qr_image_factory
        self._submit = submit
        self._rescan_factory = rescan_factory
        self._shutdown_callback = shutdown_callback
        self._tray_alive = tray_alive
        self._hide_callback = hide_callback

        self._tk_thread = threading.current_thread()
        self._closed = False
        self._pump = UiEventPump()
        self._badge_info = ConnectionInfo(BadgeState.STARTING, None, 0, "")
        self._qr_image: ctk.CTkImage | None = None
        self._qr_rendered = False
        self._last_qr_refresh = 0.0
        self._first_show_done = False
        self._notice_token = 0
        self._folder_row_widgets: list[Any] = []
        self._rows_frame: Any = None

        self._folders = FolderPickerModel(config, on_change=self._on_folders_changed)

        self._build()

        for kind, handler in (
            (EVENT_CONNECTION, self._handle_connection),
            (EVENT_QR_REFRESH, self._handle_qr_refresh),
            (EVENT_NOTICE, self._handle_notice),
            (EVENT_FOLDERS, self._handle_folders),
        ):
            self._pump.register(kind, handler)

        self._rebuild_rows()
        self._apply_connection(self._badge_info)
        self._refresh_qr()

    # ------------------------------------------------------------------
    # Public contract (doc §3)
    # ------------------------------------------------------------------

    def run(self) -> None:
        """Enter the Tk mainloop (blocks the calling Tk thread)."""
        ensure_tk_thread(self._tk_thread)
        self._schedule_poll()
        self._root.mainloop()

    def post(self, event: UiEvent) -> None:
        """Thread-safe: enqueue from the asyncio loop, tray, or any thread."""
        self._pump.post(event)

    def show(self) -> None:
        """Deiconify, lift, focus; refreshes the QR on first show (doc §4.6)."""
        self._schedule(self._show_tk)

    def focus_qr(self) -> None:
        """Tray "Show QR" target: show() and raise the QR panel."""
        self._schedule(self._focus_qr_tk)

    def hide(self) -> None:
        """Withdraw to the tray; the mainloop keeps running."""
        self._schedule(self._hide_tk)

    def close(self) -> None:
        """Destroy the window during a coordinated exit."""
        self._schedule(self._close_tk)

    def set_folders(self, paths: list[str]) -> None:
        """Refresh the picker model and persist (doc §3)."""
        self._schedule(lambda paths=paths: self._apply_folders(list(paths)))

    # ------------------------------------------------------------------
    # Tk-thread entry points (doc §4 threading rules)
    # ------------------------------------------------------------------

    def _schedule(self, callback: Callable[[], None]) -> None:
        """Run ``callback`` on T0 — inline when already there, else ``after(0)``."""
        if self._closed:
            logger.debug("dashboard closed; dropping %s", self._callback_name(callback))
            return
        if threading.current_thread() is self._tk_thread:
            callback()
            return
        try:
            self._root.after(0, callback)
        except (RuntimeError, tkinter.TclError) as exc:
            logger.warning(
                "cannot schedule %s on the Tk thread: %s",
                self._callback_name(callback),
                exc,
            )

    def _schedule_after(self, delay_ms: int, callback: Callable[[], None]) -> None:
        """Timer on T0 that keeps running across tray hide/show cycles."""
        if self._closed:
            return
        try:
            self._root.after(delay_ms, callback)
        except (RuntimeError, tkinter.TclError) as exc:
            logger.debug("after(%d) dropped: %s", delay_ms, exc)

    @staticmethod
    def _callback_name(callback: Callable[[], None]) -> str:
        return getattr(callback, "__name__", repr(callback))

    def _show_tk(self) -> None:
        ensure_tk_thread(self._tk_thread)
        if self._closed:
            return
        self._root.deiconify()
        self._root.lift()
        self._root.focus_force()
        if not self._first_show_done or not self._qr_rendered:
            self._first_show_done = True
            self._refresh_qr()

    def _focus_qr_tk(self) -> None:
        ensure_tk_thread(self._tk_thread)
        if self._closed:
            return
        self._show_tk()
        self._qr_card.lift()
        self._qr_card.focus_force()

    def _hide_tk(self) -> None:
        ensure_tk_thread(self._tk_thread)
        if self._closed:
            return
        self._root.withdraw()

    def _close_tk(self) -> None:
        ensure_tk_thread(self._tk_thread)
        if self._closed:
            return
        self._closed = True
        self._root.destroy()

    def _on_close_request(self) -> None:
        """WM_DELETE_WINDOW: hide to tray, else confirm and exit (doc §4.7)."""
        ensure_tk_thread(self._tk_thread)
        if self._closed:
            return
        config = self._config.get()
        tray_up = False
        if self._tray_alive is not None:
            try:
                tray_up = bool(self._tray_alive())
            except Exception as exc:
                logger.warning("tray_alive probe failed: %s", exc)
        if config.minimize_to_tray and tray_up:
            self.hide()
            if self._hide_callback is not None:
                try:
                    self._hide_callback()
                except Exception as exc:
                    logger.warning("hide callback failed: %s", exc)
            return
        if not messagebox.askyesno(
            "Quit PotPilot",
            "The tray icon cannot keep PotPilot running.\nClose it entirely?",
        ):
            return
        self._request_shutdown()

    def _request_shutdown(self) -> None:
        if self._shutdown_callback is None:
            self.close()
            return
        try:
            self._shutdown_callback()
        except Exception as exc:
            logger.warning("shutdown callback failed: %s", exc)
            self.close()

    # ------------------------------------------------------------------
    # Event pump handlers (doc §4 UiEvent kinds)
    # ------------------------------------------------------------------

    def _handle_connection(self, event: UiEvent) -> None:
        ensure_tk_thread(self._tk_thread)
        if event.connection is None:
            logger.warning("connection UiEvent without ConnectionInfo dropped")
            return
        self._apply_connection(event.connection)

    def _apply_connection(self, info: ConnectionInfo) -> None:
        ensure_tk_thread(self._tk_thread)
        self._badge_info = info
        spec = render_badge(info)
        self._badge_frame.configure(fg_color=spec.fill)
        self._badge_label.configure(text=spec.caption, text_color=spec.text)
        self._conn_ip_label.configure(text=f"Device IP: {info.device_ip or '—'}")
        self._conn_count_label.configure(text=f"Clients: {info.client_count}")
        self._conn_detail_label.configure(text=info.detail or "—")

    def _handle_qr_refresh(self, event: UiEvent) -> None:
        ensure_tk_thread(self._tk_thread)
        self._refresh_qr()

    def _handle_notice(self, event: UiEvent) -> None:
        ensure_tk_thread(self._tk_thread)
        if event.message:
            self._show_notice(event.message)

    def _handle_folders(self, event: UiEvent) -> None:
        ensure_tk_thread(self._tk_thread)
        change = self._folders.set_paths(self._config.get().movie_dirs)
        self._rebuild_rows()
        if change.notice:
            self._show_notice(change.notice)

    def _show_notice(self, text: str) -> None:
        ensure_tk_thread(self._tk_thread)
        if self._closed or not text:
            return
        self._notice_token += 1
        token = self._notice_token
        self._notice_label.configure(text=text, text_color=_NOTICE_AMBER)
        self._schedule_after(NOTICE_MS, lambda token=token: self._clear_notice(token))

    def _clear_notice(self, token: int) -> None:
        ensure_tk_thread(self._tk_thread)
        if self._closed or token != self._notice_token:
            return
        self._notice_label.configure(text="")

    # ------------------------------------------------------------------
    # QR panel (doc §4.6)
    # ------------------------------------------------------------------

    def _refresh_qr(self) -> None:
        ensure_tk_thread(self._tk_thread)
        if self._closed:
            return
        self._last_qr_refresh = time.monotonic()
        self._qr_caption_label.configure(text=self._build_qr_caption())
        image: ctk.CTkImage | None = None
        failure: str | None = None
        try:
            image = self._qr_image_factory()
        except Exception as exc:
            failure = str(exc) or type(exc).__name__
        if image is None:
            logger.warning("QR render failed: %s", failure or "factory returned no image")
            detail = f"No network\n{failure}" if failure else "No network"
            self._show_qr_placeholder(detail)
            self._schedule_after(QR_RETRY_MS, self._refresh_qr)
            return
        self._qr_image = image
        self._qr_image_label.configure(image=image)
        self._qr_placeholder.grid_remove()
        self._qr_rendered = True

    def _show_qr_placeholder(self, reason: str) -> None:
        ensure_tk_thread(self._tk_thread)
        self._qr_placeholder_text.configure(text=reason)
        self._qr_placeholder.grid()
        self._qr_rendered = False

    def _on_refresh_clicked(self) -> None:
        ensure_tk_thread(self._tk_thread)
        self._refresh_qr()

    def _build_qr_caption(self) -> str:
        config = self._config.get()
        return f"Host: {socket.gethostname()}\nUDP {config.udp_port}  ·  WS {config.ws_port}"

    # ------------------------------------------------------------------
    # Watched folders (doc §4.4)
    # ------------------------------------------------------------------

    def _on_add_folder(self) -> None:
        ensure_tk_thread(self._tk_thread)
        path = filedialog.askdirectory(title="Add watched folder")
        if not path:
            return
        self._apply_change(self._folders.add(path))

    def _on_remove_folder(self, path: str) -> None:
        ensure_tk_thread(self._tk_thread)
        self._apply_change(self._folders.remove(path))

    def _apply_change(self, change: FolderChange) -> None:
        if change.notice:
            self._show_notice(change.notice)

    def _apply_folders(self, paths: list[str]) -> None:
        ensure_tk_thread(self._tk_thread)
        if self._closed:
            return
        change = self._folders.set_paths(paths)
        self._rebuild_rows()
        if change.notice:
            self._show_notice(change.notice)

    def _on_folders_changed(self, paths: list[str]) -> None:
        """Model hook: rows persisted → refresh widgets, then request rescan."""
        self._rebuild_rows()
        self._trigger_rescan()

    def _trigger_rescan(self) -> None:
        if self._rescan_factory is None:
            return
        try:
            self._submit(self._rescan_factory())
        except Exception as exc:
            logger.warning("folder rescan submit failed: %s", exc)

    def _rebuild_rows(self) -> None:
        ensure_tk_thread(self._tk_thread)
        frame = self._rows_frame
        if frame is None or self._closed:
            return
        for widget in self._folder_row_widgets:
            widget.destroy()
        self._folder_row_widgets.clear()
        self._folders.refresh_missing()
        for row in self._folders.rows:
            self._folder_row_widgets.append(self._make_row(frame, row))

    def _make_row(self, frame: Any, row: FolderRowModel) -> Any:
        row_frame = ctk.CTkFrame(frame, fg_color="transparent")
        text = row.path + (" (missing)" if row.missing else "")
        label = ctk.CTkLabel(
            row_frame,
            text=text,
            anchor="w",
            justify="left",
            wraplength=440,
            text_color=_TEXT_MISSING if row.missing else _TEXT_PRIMARY,
        )
        label.grid(row=0, column=0, sticky="w", padx=8, pady=3)
        remove = ctk.CTkButton(
            row_frame,
            text="Remove",
            width=78,
            height=26,
            fg_color=_ACCENT_GRAY,
            hover_color=_ACCENT_CRIMSON_HOVER,
            command=lambda path=row.path: self._on_remove_folder(path),
        )
        remove.grid(row=0, column=1, padx=8, pady=3)
        row_frame.grid(row=len(self._folder_row_widgets), column=0, sticky="ew")
        frame.grid_columnconfigure(0, weight=1)
        return row_frame

    # ------------------------------------------------------------------
    # Event pump loop
    # ------------------------------------------------------------------

    def _schedule_poll(self) -> None:
        self._schedule_after(UI_POLL_MS, self._poll)

    def _poll(self) -> None:
        if self._closed:
            return
        self._pump.drain()
        if time.monotonic() - self._last_qr_refresh >= QR_REFRESH_S:
            self._refresh_qr()
        self._schedule_poll()

    # ------------------------------------------------------------------
    # Widget construction (doc §4 layout wireframe)
    # ------------------------------------------------------------------

    def _build(self) -> None:
        ctk.set_appearance_mode("Dark")
        ctk.set_default_color_theme("dark-blue")
        root = ctk.CTk()
        root.title(APP_TITLE)
        root.geometry(f"{WINDOW_MIN_SIZE[0]}x{WINDOW_MIN_SIZE[1]}")
        root.minsize(*WINDOW_MIN_SIZE)
        root.protocol("WM_DELETE_WINDOW", self._on_close_request)
        self._root = root
        root.grid_columnconfigure(1, weight=1)
        root.grid_rowconfigure(1, weight=1)

        title_font = ctk.CTkFont(size=20, weight="bold")
        card_font = ctk.CTkFont(size=15, weight="bold")
        badge_font = ctk.CTkFont(size=13, weight="bold")
        small_font = ctk.CTkFont(size=12)

        # Header: title, version, right-aligned badge.
        header = ctk.CTkFrame(root)
        header.grid(row=0, column=0, columnspan=2, sticky="ew", padx=12, pady=(12, 6))
        header.grid_columnconfigure(1, weight=1)
        ctk.CTkLabel(header, text=APP_TITLE, font=title_font).grid(
            row=0, column=0, padx=14, pady=8, sticky="w"
        )
        ctk.CTkLabel(header, text=f"v{APP_VERSION}", text_color=_TEXT_DIM).grid(
            row=0, column=1, padx=8, pady=8, sticky="w"
        )
        self._badge_frame = ctk.CTkFrame(header, corner_radius=12)
        self._badge_frame.grid(row=0, column=2, padx=14, pady=8, sticky="e")
        self._badge_label = ctk.CTkLabel(
            self._badge_frame,
            text="",
            fg_color="transparent",
            font=badge_font,
        )
        self._badge_label.grid(padx=14, pady=5)

        # Body: left QR card, right stacked cards.
        body = ctk.CTkFrame(root, fg_color="transparent")
        body.grid(row=1, column=0, columnspan=2, sticky="nsew", padx=12, pady=6)
        body.grid_columnconfigure(0, weight=0)
        body.grid_columnconfigure(1, weight=1)
        body.grid_rowconfigure(0, weight=1)

        qr_card = ctk.CTkFrame(body)
        qr_card.grid(row=0, column=0, sticky="nsew", padx=(0, 8))
        self._qr_card = qr_card
        ctk.CTkLabel(qr_card, text="Pairing QR", font=card_font).grid(
            row=0, column=0, padx=16, pady=(12, 4), sticky="w"
        )
        # The image label stays gridded as the 260x260 cell sizer; the
        # placeholder overlays it while the factory has no LAN address.
        self._qr_image_label = ctk.CTkLabel(
            qr_card, text="", width=QR_IMAGE_PX, height=QR_IMAGE_PX
        )
        self._qr_image_label.grid(row=1, column=0, padx=16, pady=8)
        placeholder = ctk.CTkFrame(qr_card)
        placeholder.grid(row=1, column=0, padx=16, pady=8, sticky="nsew")
        placeholder.grid_remove()
        placeholder.grid_columnconfigure(0, weight=1)
        self._qr_placeholder = placeholder
        self._qr_placeholder_text = ctk.CTkLabel(
            placeholder,
            text="No network",
            justify="center",
            wraplength=QR_IMAGE_PX - 32,
            text_color=_TEXT_PRIMARY,
        )
        self._qr_placeholder_text.grid(row=0, column=0, padx=12, pady=(84, 8))
        ctk.CTkButton(
            placeholder,
            text="Retry",
            width=110,
            fg_color=_ACCENT_CRIMSON,
            hover_color=_ACCENT_CRIMSON_HOVER,
            command=self._on_refresh_clicked,
        ).grid(row=1, column=0, pady=(4, 24))
        self._qr_caption_label = ctk.CTkLabel(
            qr_card,
            text=self._build_qr_caption(),
            justify="left",
            anchor="w",
            text_color=_TEXT_DIM,
            font=small_font,
        )
        self._qr_caption_label.grid(row=2, column=0, padx=16, pady=(0, 6), sticky="w")
        ctk.CTkButton(
            qr_card,
            text="Refresh QR",
            fg_color=_ACCENT_CRIMSON,
            hover_color=_ACCENT_CRIMSON_HOVER,
            command=self._on_refresh_clicked,
        ).grid(row=3, column=0, padx=16, pady=(4, 14), sticky="ew")

        # Right column: Connection card + Watched Folders card.
        right = ctk.CTkFrame(body, fg_color="transparent")
        right.grid(row=0, column=1, sticky="nsew")
        right.grid_columnconfigure(0, weight=1)
        right.grid_rowconfigure(1, weight=1)

        conn_card = ctk.CTkFrame(right)
        conn_card.grid(row=0, column=0, sticky="ew", pady=(0, 8))
        conn_card.grid_columnconfigure(1, weight=1)
        ctk.CTkLabel(conn_card, text="Connection", font=card_font).grid(
            row=0, column=0, columnspan=2, padx=14, pady=(12, 6), sticky="w"
        )
        self._conn_ip_label = ctk.CTkLabel(conn_card, text="Device IP: —", anchor="w")
        self._conn_count_label = ctk.CTkLabel(conn_card, text="Clients: 0", anchor="w")
        mdns_label = ctk.CTkLabel(
            conn_card,
            text=f"mDNS: {socket.gethostname()}.local",
            anchor="w",
            text_color=_TEXT_DIM,
        )
        self._conn_detail_label = ctk.CTkLabel(
            conn_card, text="—", anchor="w", text_color=_TEXT_DIM, wraplength=440
        )
        self._conn_ip_label.grid(row=1, column=0, columnspan=2, padx=14, pady=2, sticky="w")
        self._conn_count_label.grid(row=2, column=0, columnspan=2, padx=14, pady=2, sticky="w")
        mdns_label.grid(row=3, column=0, columnspan=2, padx=14, pady=2, sticky="w")
        self._conn_detail_label.grid(
            row=4, column=0, columnspan=2, padx=14, pady=(2, 12), sticky="w"
        )

        folders_card = ctk.CTkFrame(right)
        folders_card.grid(row=1, column=0, sticky="nsew")
        folders_card.grid_rowconfigure(1, weight=1)
        folders_card.grid_columnconfigure(0, weight=1)
        ctk.CTkLabel(folders_card, text="Watched Folders", font=card_font).grid(
            row=0, column=0, padx=14, pady=(12, 6), sticky="w"
        )
        scroll = ctk.CTkScrollableFrame(folders_card, height=260)
        scroll.grid(row=1, column=0, sticky="nsew", padx=10, pady=4)
        scroll.grid_columnconfigure(0, weight=1)
        self._rows_frame = scroll
        ctk.CTkButton(
            folders_card,
            text="Add Folder…",
            fg_color=_ACCENT_CRIMSON,
            hover_color=_ACCENT_CRIMSON_HOVER,
            command=self._on_add_folder,
        ).grid(row=2, column=0, padx=14, pady=(6, 14), sticky="ew")

        self._notice_label = ctk.CTkLabel(root, text="", anchor="w", text_color=_NOTICE_AMBER)
        self._notice_label.grid(row=2, column=0, columnspan=2, sticky="ew", padx=16)

        config = self._config.get()
        tray_note = "Close minimizes to tray" if config.minimize_to_tray else "Close quits PotPilot"
        footer = f"Config: {self._config.config_path()}  ·  {tray_note}"
        ctk.CTkLabel(
            root, text=footer, anchor="w", text_color=_TEXT_DIM, font=small_font
        ).grid(row=3, column=0, columnspan=2, sticky="ew", padx=16, pady=(2, 10))
