"""Doc 26 §9 — concurrent update()/get() stress: file always valid JSON."""

import json
import threading

from .helpers import make_manager

_WRITTEN_PORTS = set(range(20000, 20008))


def test_eight_threads_update_concurrently(tmp_path):
    mgr = make_manager(tmp_path)
    mgr.load()
    errors = []

    def worker(index: int) -> None:
        try:
            for _ in range(10):
                mgr.update(
                    udp_port=20000 + index,
                    movie_dirs=[str(tmp_path / f"Library{index}")],
                )
                mgr.get()
        except Exception as exc:
            errors.append(exc)

    threads = [threading.Thread(target=worker, args=(index,)) for index in range(8)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=60)

    assert errors == []
    assert not any(thread.is_alive() for thread in threads)

    data = json.loads(mgr.config_path().read_text(encoding="utf-8"))
    assert data["udp_port"] in _WRITTEN_PORTS  # one of the written snapshots
    assert len(data["movie_dirs"]) == 1
    assert data["ws_port"] == 50506
