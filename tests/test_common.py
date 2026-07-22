import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent / "guards"))
from _common import decide_and_log


def test_logs_allowed_decision(tmp_path):
    log_path = tmp_path / "tool.log"
    result = decide_and_log(["pr", "view"], lambda argv: True, str(log_path), "gh")
    assert result is True
    entry = json.loads(log_path.read_text().splitlines()[0])
    assert entry["tool"] == "gh"
    assert entry["argv"] == ["pr", "view"]
    assert entry["allowed"] is True


def test_logs_denied_decision(tmp_path):
    log_path = tmp_path / "tool.log"
    result = decide_and_log(["repo", "delete"], lambda argv: False, str(log_path), "gh")
    assert result is False
    entry = json.loads(log_path.read_text().splitlines()[0])
    assert entry["allowed"] is False


def test_appends_rather_than_overwrites(tmp_path):
    log_path = tmp_path / "tool.log"
    decide_and_log(["a"], lambda argv: True, str(log_path), "gh")
    decide_and_log(["b"], lambda argv: False, str(log_path), "gh")
    assert len(log_path.read_text().splitlines()) == 2
