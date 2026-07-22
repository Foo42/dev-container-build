import json
import os
import sys
import time


def decide_and_log(argv, decide, log_path, tool_name):
    allowed = decide(argv)
    with open(log_path, "a") as f:
        f.write(json.dumps({
            "ts": time.time(),
            "tool": tool_name,
            "argv": argv,
            "allowed": allowed,
        }) + "\n")
    return allowed


def run(decide, real_executable, log_path, tool_name):
    argv = sys.argv[1:]
    allowed = decide_and_log(argv, decide, log_path, tool_name)
    if not allowed:
        print(f"blocked by guard policy: {tool_name} {' '.join(argv)}", file=sys.stderr)
        sys.exit(1)
    os.execv(real_executable, [real_executable] + argv)
