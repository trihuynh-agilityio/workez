#!/usr/bin/env bash
# Cuts a release: moves the Unreleased notes of CHANGELOG.md under a new version heading, updates the
# compare links, and sets "version" in .claude-plugin/plugin.json. It never commits, tags or pushes;
# it prints those commands for you.
#   tools/release.sh major|minor|patch|X.Y.Z [--dry-run]
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="$root/.claude-plugin/plugin.json"; log="$root/CHANGELOG.md"
bump="${1:-}"; dry=0; [[ "${2:-}" == --dry-run ]] && dry=1
command -v jq >/dev/null || { echo "release: jq is required" >&2; exit 2; }

current="$(jq -r .version "$manifest")"
IFS=. read -r ma mi pa <<<"$current"
case "$bump" in
  major) next="$((ma + 1)).0.0" ;;
  minor) next="$ma.$((mi + 1)).0" ;;
  patch) next="$ma.$mi.$((pa + 1))" ;;
  [0-9]*.[0-9]*.[0-9]*) next="$bump" ;;
  *) echo "usage: tools/release.sh major|minor|patch|X.Y.Z [--dry-run]" >&2; exit 2 ;;
esac
[[ "$next" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "release: '$next' is not X.Y.Z" >&2; exit 2; }
[[ "$(printf '%s\n%s\n' "$current" "$next" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" == "$next" && "$next" != "$current" ]] \
  || { echo "release: $next is not newer than $current" >&2; exit 2; }
grep -q "^## \[$next\]" "$log" && { echo "release: CHANGELOG.md already has $next" >&2; exit 2; }

# The Unreleased notes: the lines between "## [Unreleased]" and the next "## [" heading.
notes="$(awk '/^## \[Unreleased\]$/{on=1; next} on && /^## \[/{exit} on' "$log" | grep -v '^[[:space:]]*$' || true)"
[[ -n "$notes" ]] || { echo "release: nothing under '## [Unreleased]' in CHANGELOG.md; add the changes first" >&2; exit 2; }

today="$(date +%F)"
repo="$(jq -r '.repository // empty' "$manifest" | sed 's#\.git$##')"
new_log="$(awk -v v="$next" -v d="$today" -v prev="$current" -v repo="$repo" '
  /^## \[Unreleased\]$/ { print; print ""; print "## [" v "] - " d; next }
  /^\[Unreleased\]: / && repo != "" {
    print "[Unreleased]: " repo "/compare/v" v "...HEAD"
    print "[" v "]: " repo "/compare/v" prev "...v" v
    next }
  { print }' "$log")"

if ((dry)); then
  echo "== $current -> $next ($today)"; echo "$notes"; exit 0
fi
printf '%s\n' "$new_log" >"$log"
tmp="$(mktemp)"; jq --arg v "$next" '.version = $v' "$manifest" >"$tmp" && mv "$tmp" "$manifest"
"$root/tools/check-version.sh" >/dev/null
echo "Released $current -> $next in CHANGELOG.md and .claude-plugin/plugin.json. Next:"
echo "  git commit -am \"Release v$next\""
echo "  git tag -a v$next -m \"v$next\""
echo "  git push --follow-tags"
