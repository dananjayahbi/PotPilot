"""Doc 26 §9 — corrupt-file quarantine and backup pruning."""

from pc_agent.core.config_manager import AppConfig, ConfigManager


def test_garbage_file_quarantined_and_defaults_returned(tmp_path):
    path = tmp_path / "PotPilot" / "config.json"
    path.parent.mkdir(parents=True)
    path.write_text("{ this is not valid json !!!", encoding="utf-8")

    cfg = ConfigManager(path).load()

    assert cfg == AppConfig()
    backups = list(path.parent.glob("config.json.corrupt-*"))
    assert len(backups) == 1
    assert "not valid json" in backups[0].read_text(encoding="utf-8")
    assert not path.exists()


def test_corrupt_backups_pruned_to_three(tmp_path):
    path = tmp_path / "PotPilot" / "config.json"
    path.parent.mkdir(parents=True)

    for index in range(6):
        path.write_text(f"garbage-{index} {{", encoding="utf-8")
        ConfigManager(path).load()

    backups = sorted(path.parent.glob("config.json.corrupt-*"))
    assert len(backups) == 3
    retained = [backup.read_text(encoding="utf-8") for backup in backups]
    assert any("garbage-5" in text for text in retained)
    assert not any("garbage-0" in text for text in retained)
