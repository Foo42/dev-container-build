import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent / "guards"))
import gh


def test_allows_pr_view():
    assert gh.decide(["pr", "view", "42"]) is True


def test_allows_pr_list():
    assert gh.decide(["pr", "list"]) is True


def test_allows_pr_diff():
    assert gh.decide(["pr", "diff", "42"]) is True


def test_allows_issue_view_and_list():
    assert gh.decide(["issue", "view", "7"]) is True
    assert gh.decide(["issue", "list"]) is True


def test_allows_repo_view():
    assert gh.decide(["repo", "view"]) is True


def test_denies_repo_delete():
    assert gh.decide(["repo", "delete", "some/repo"]) is False


def test_denies_secret_set():
    assert gh.decide(["secret", "set", "TOKEN"]) is False


def test_denies_pr_merge():
    assert gh.decide(["pr", "merge", "42"]) is False


def test_denies_empty_argv():
    assert gh.decide([]) is False
