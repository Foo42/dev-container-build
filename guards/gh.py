#!/usr/bin/env python3
import os
import sys
from typing import Iterable, Iterator, Sequence, Tuple

sys.path.insert(0, os.path.dirname(__file__))
from _common import run


def parse_args(args: Iterable[str]) -> Tuple[dict[str, str], Sequence[str]]:
    it = args.__iter__()
    kv: dict[str, str] = {}
    positional: list[str] = []

    while (word := next(it, None)) is not None:
        if word.startswith("-"):
            key = word.strip("-")
            val = next(it)
            kv[key] = val
        else:
            positional.append(word)

    return kv, positional


def decide(argv: list[str]) -> bool:
    match argv:
        case ["pr", "view", *_] | ["pr", "list", *_] | ["pr", "diff", *_]:
            return True
        case ["issue", "view", *_] | ["issue", "list", *_]:
            return True
        case ["run", "list", *_] | ["run", "view", *_]:
            return True
        case ["repo", "view", *_]:
            return True
        case ["api", *rest]:
            match parse_args(rest):
                case ({"R": repo_name}, [resource]) if repo_name.startswith(
                    "HomelyEnergy/"
                ):
                    match resource.split("/"):
                        case ["actions", "jobs", _, "logs"]:
                            return True
                        case _:
                            return False
                case _:
                    return False
        case _:
            return False  # deny by default — widen deliberately, case by case


if __name__ == "__main__":
    from gh_config import TOOL_NAME, REAL_EXECUTABLE, LOG_PATH

    # gh's actual OAuth token (on macOS hosts, resolved via `gh auth
    # token` rather than reverse-engineering Keychain — see
    # rotate-credential.sh) is delivered as a plain file alongside the
    # copied hosts.yml/config.yml metadata. GH_TOKEN is gh's own
    # documented, non-interactive auth mechanism — set it for just this
    # one exec, not touching _common.py's exec logic at all.
    token_path = os.path.expanduser("~/.config/gh/.gh-token")
    if os.path.exists(token_path):
        with open(token_path) as f:
            os.environ["GH_TOKEN"] = f.read().strip()

    run(decide, REAL_EXECUTABLE, LOG_PATH, TOOL_NAME)
