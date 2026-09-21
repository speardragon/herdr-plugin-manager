#!/usr/bin/env bash
# Marketplace fetch failures name the real HTTP status, and the GitHub token
# resolves from the env with the gh CLI as fallback.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
load_fns market_error resolve_github_token

# A rate-limited body (what api.github.com returns on the 10/hour anonymous cap).
rate_body='{"message":"API rate limit exceeded for 1.2.3.4.","documentation_url":"https://docs.github.com/rest"}'
check "403 names the rate limit and GitHub's message" \
  "marketplace rate limit (HTTP 403) — API rate limit exceeded for 1.2.3.4." \
  "$(market_error 403 "$rate_body")"
check "a bare 503 stays a fetch failure" \
  "marketplace fetch failed (HTTP 503)" "$(market_error 503 '')"
check "no connection is reported as such" \
  "marketplace fetch failed — no network connection" "$(market_error 000 '')"
check "a mid-download timeout is named, not mistaken for offline" \
  "marketplace fetch timed out (HTTP 200) — retry with [r]" "$(market_error 200 '{"partial":1}' 28)"

gh() { printf 'cli-token\n'; }
unset GH_TOKEN GITHUB_TOKEN HERDR_PM_NO_TOKEN
check "gh CLI supplies the token when the env has none" "cli-token" "$(resolve_github_token; printf '%s' "$github_token")"

GH_TOKEN=env-token
check "GH_TOKEN wins over the gh CLI" "env-token" "$(resolve_github_token; printf '%s' "$github_token")"

unset GH_TOKEN
GITHUB_TOKEN=fallback-token
check "GITHUB_TOKEN is the second env source" "fallback-token" "$(resolve_github_token; printf '%s' "$github_token")"

unset GITHUB_TOKEN
HERDR_PM_NO_TOKEN=1
check "HERDR_PM_NO_TOKEN forces anonymous calls" "" "$(resolve_github_token; printf '%s' "$github_token")"

unset HERDR_PM_NO_TOKEN
unset -f gh
PATH=/nonexistent-herdr-pm-test
check "no token source leaves the call anonymous" "" "$(resolve_github_token; printf '%s' "$github_token")"

report