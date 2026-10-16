"""Doc 46 §4.2 — verbatim 8-byte UDP echo responder (RTT benchmark target).

Binds one UDP port exclusively, validates every incoming datagram against the
frozen Doc 02 wire (exactly 8 bytes; byte 1 == the pairing token's XOR
checksum computed by Doc 15's pure ``xor_checksum``), and reflects valid
probes back verbatim. No new packet type, port, or schema is invented — the
echo is the same 8 bytes the sender transmitted.

Invalid datagrams are dropped and counted in :attr:`rejected` (never echoed),
which is what proves auth rejection (M3) from the client's point of view.
"""

from __future__ import annotations

import socket
import threading

_RECV_TIMEOUT_S = 0.2
_SOCKET_BUFFER_BYTES = 64
_PACKET_SIZE = 8
_AUTH_BYTE_OFFSET = 1
_STOP_JOIN_TIMEOUT_S = 3.0


class UdpEchoResponder:
    """Bind a UDP port and echo every auth-valid 8-byte probe verbatim."""

    def __init__(self, host: str, port: int, auth_byte: int) -> None:
        if not 0 <= int(auth_byte) <= 255:
            raise ValueError(f"auth_byte must be 0..255, got {auth_byte!r}")
        self._host = host
        self._requested_port = int(port)
        self._auth_byte = int(auth_byte)
        self._sock: socket.socket | None = None
        self._thread: threading.Thread | None = None
        self._stop = threading.Event()
        self._lock = threading.Lock()
        self._probe_count = 0
        self._rejected = 0
        self._bound_port = 0

    # ------------------------------------------------------------- lifecycle

    def start(self) -> None:
        """Bind + start the echo loop; raises RuntimeError with a clear hint on a busy port."""
        if self._thread is not None:
            return  # already running (idempotent)
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            sock.bind((self._host, self._requested_port))
        except OSError as exc:
            sock.close()
            raise RuntimeError(
                f"UDP {self._host}:{self._requested_port} unavailable — "
                f"stop the PotPilot agent before the RTT run ({exc})"
            ) from exc
        sock.settimeout(_RECV_TIMEOUT_S)
        self._sock = sock
        self._bound_port = int(sock.getsockname()[1])
        self._stop.clear()
        self._thread = threading.Thread(
            target=self._loop, name="potpilot-udp-echo", daemon=True
        )
        self._thread.start()

    def stop(self) -> None:
        """Signal the loop, join it, and close the socket; idempotent."""
        thread, self._thread = self._thread, None
        self._stop.set()
        if thread is not None:
            thread.join(_STOP_JOIN_TIMEOUT_S)
        sock, self._sock = self._sock, None
        if sock is not None:
            try:
                sock.close()
            except OSError:  # pragma: no cover - already-closed socket race
                pass

    # ------------------------------------------------------------- counters

    @property
    def probe_count(self) -> int:
        """Number of valid probes echoed back verbatim."""
        with self._lock:
            return self._probe_count

    @property
    def rejected(self) -> int:
        """Number of datagrams dropped (wrong length or auth mismatch)."""
        with self._lock:
            return self._rejected

    @property
    def host(self) -> str:
        return self._host

    @property
    def port(self) -> int:
        """Actual bound port (resolves 0 → ephemeral once started)."""
        return self._bound_port

    # --------------------------------------------------------------- internals

    def _loop(self) -> None:
        sock = self._sock
        if sock is None:  # pragma: no cover - defensive; start() sets it first
            return
        while not self._stop.is_set():
            try:
                data, addr = sock.recvfrom(_SOCKET_BUFFER_BYTES)
            except TimeoutError:
                continue
            except OSError:
                return  # socket closed during shutdown
            if len(data) != _PACKET_SIZE or data[_AUTH_BYTE_OFFSET] != self._auth_byte:
                with self._lock:
                    self._rejected += 1
                continue
            try:
                sock.sendto(data, addr)  # verbatim reflection — Doc 02 bytes unchanged
            except OSError:  # pragma: no cover - peer vanished mid-echo
                continue
            with self._lock:
                self._probe_count += 1
