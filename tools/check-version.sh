#!/usr/bin/env bash
# Checks that the version in .claude-plugin/plugin.json is a semantic version and has its own
# "## [X.Y.Z] - YYYY-MM-DD" section in CHANGELOG.md. Run by CI; exits 1 on a mismatch.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="$(jq -r '.version // empty' "$root/.claude-plugin/plugin.json")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "check-version: plugin.json version '$version' is not X.Y.Z" >&2; exit 1; }
grep -Eq "^## \[${version//./\\.}\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$" "$root/CHANGELOG.md" \
  || { echo "check-version: CHANGELOG.md has no '## [$version] - <date>' section" >&2; exit 1; }
grep -q '^## \[Unreleased\]$' "$root/CHANGELOG.md" \
  || { echo "check-version: CHANGELOG.md has no '## [Unreleased]' section" >&2; exit 1; }
echo "OK version $version"
