#!/usr/bin/env python3
"""Parse a GitHub `search/repositories` response (stdin) into TSV rows.

First line is "#total\t<total_count>" — a '#' can never start a GitHub owner
name, so it can't collide with a repo row. Then one row per repo: full_name,
stars, description (control chars stripped, truncated, "-" when empty), in
the API's order (sorted by stars).
"""
import json
import sys


def sanitize(text, limit):
    cleaned = "".join(c if c.isprintable() else " " for c in (text or ""))
    cleaned = cleaned.replace("\t", " ").strip()
    if len(cleaned) > limit:
        cleaned = cleaned[: limit - 1] + "…"
    return cleaned or "-"


def main():
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 1
    print("#total\t{}".format(data.get("total_count") or 0))
    items = data.get("items") or []
    for repo in items:
        full_name = repo.get("full_name")
        if not full_name:
            continue
        print("\t".join([
            full_name,
            str(repo.get("stargazers_count") or 0),
            sanitize(repo.get("description"), 64),
        ]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
