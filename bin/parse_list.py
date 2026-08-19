#!/usr/bin/env python3
"""Parse `herdr plugin list --json` (stdin) into tab-separated rows.

Plugin rows have 10 fields:
  1 plugin_id
  2 name
  3 version
  4 enabled (1/0)
  5 source_kind
  6 spec         owner/repo[/subdir] or "-"   (display)
  7 short_commit first 7 of resolved_commit or "-"  (display)
  8 repo_slug    owner/repo or "-"            (update check)
  9 ref          requested install ref or "-" (update check)
 10 full_commit  full resolved_commit or "-"  (update check)

Each plugin row is followed by one line per declared action:
  #action \t plugin_id \t action_id \t title \t command-joined

Empty values become "-" so bash can split on tabs safely.
"""
import json
import sys


def clean(value):
    return str(value).replace("\t", " ").replace("\n", " ").strip() or "-"


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
        # The registry names this source.requested_ref; "ref" is kept as a
        # fallback for older herdr versions.
        ref = src.get("requested_ref") or src.get("ref") or "-"
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
    return "\t".join(clean(f) for f in fields)


def action_rows(plugin):
    pid = plugin.get("plugin_id") or "?"
    for action in plugin.get("actions") or []:
        aid = action.get("id")
        if not aid:
            continue
        yield "\t".join([
            "#action",
            clean(pid),
            clean(aid),
            clean(action.get("title") or aid),
            clean(" ".join(action.get("command") or [])),
        ])


def main():
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 1
    plugins = (data.get("result") or {}).get("plugins") or []
    for plugin in plugins:
        print(row(plugin))
        for line in action_rows(plugin):
            print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
