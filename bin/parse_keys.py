#!/usr/bin/env python3
"""Extract plugin-action keybindings from a herdr config.toml (argv[1]).

Prints one line per `[[keys.command]]` entry with type = "plugin_action":
  <full_action_id> \t <key>

Deliberately a naive block parser instead of a TOML library — the target
shape is flat string assignments, and macOS pythons before 3.11 lack tomllib.
"""
import re
import sys

ASSIGN = re.compile(r'^(\w+)\s*=\s*"([^"]*)"')


def blocks(path):
    current = None
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if line.startswith("[["):
                if current:
                    yield current
                current = {} if line == "[[keys.command]]" else None
                continue
            if line.startswith("["):
                if current:
                    yield current
                current = None
                continue
            if current is None:
                continue
            match = ASSIGN.match(line)
            if match:
                current[match.group(1)] = match.group(2)
    if current:
        yield current


def main():
    if len(sys.argv) < 2:
        return 1
    try:
        for entry in blocks(sys.argv[1]):
            if entry.get("type") == "plugin_action" and entry.get("command") and entry.get("key"):
                print("{}\t{}".format(entry["command"], entry["key"]))
    except OSError:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
