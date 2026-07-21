#!/usr/bin/env python3
"""Parse `herdr plugin list --json` (stdin) into tab-separated rows.

Fields (10, tab-separated):
  1 plugin_id
  2 name
  3 version
  4 enabled (1/0)
  5 source_kind
  6 spec         owner/repo[/subdir] or "-"   (display)
  7 short_commit first 7 of resolved_commit or "-"  (display)
  8 repo_slug    owner/repo or "-"            (update check)
  9 ref          install ref or "-"           (update check)
 10 full_commit  full resolved_commit or "-"  (update check)

Empty values become "-" so bash can split on tabs safely.
"""
import json
import sys


def row(plugin):
    src = plugin.get("source") or {}
    kind = src.get("kind") or "?"
    spec, short_commit, slug, ref, full_commit = "-", "-", "-", "-", "-"
    if kind == "github":
        slug = "{}/{}".format(src.get("owner", "?"), src.get("repo", "?"))
        spec = slug
        if src.get("subdir"):
            spec = "{}/{}".format(spec, src["subdir"])
        full_commit = src.get("resolved_commit") or "-"
        short_commit = full_commit[:7] if full_commit != "-" else "-"
        ref = src.get("ref") or "-"
    fields = [
        plugin.get("plugin_id") or "?",
        plugin.get("name") or "?",
        plugin.get("version") or "?",
        "1" if plugin.get("enabled") else "0",
        kind,
        spec,
        short_commit,
        slug,
        ref,
        full_commit,
    ]
    return "\t".join(str(f).replace("\t", " ") for f in fields)


def main():
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 1
    plugins = (data.get("result") or {}).get("plugins") or []
    for plugin in plugins:
        print(row(plugin))
    return 0


if __name__ == "__main__":
    sys.exit(main())
