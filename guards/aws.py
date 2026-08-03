#!/usr/bin/env python3
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from _common import run


def decide(argv: list[str]) -> bool:
    match argv:
        case ["sts", "get-caller-identity", *_]:
            return True
        case _:
            return False  # deny by default — widen deliberately, case by case


if __name__ == "__main__":
    from aws_config import TOOL_NAME, REAL_EXECUTABLE, LOG_PATH
    run(decide, REAL_EXECUTABLE, LOG_PATH, TOOL_NAME)
