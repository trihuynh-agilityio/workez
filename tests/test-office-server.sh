#!/usr/bin/env bash
# The office server on a real project: health, snapshot, the live stream (and a change reaching it), the
# page, the Host check, server.json, and --demo. Uses a random port; the server is stopped on exit.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null || { ko "node is required (Node 18 or newer)"; done_tests; exit; }
command -v curl >/dev/null || { ko "curl is required"; done_tests; exit; }

git init -q -b main "$T/app"; mkdir -p "$T/app/.claude/workflow/login"
cp "$SRC/templates/workflow.example.json" "$T/app/.claude/workflow.json"
docs="$(jq -r '.docs_dir' "$T/app/.claude/workflow.json")"; mkdir -p "$T/app/$docs/login"
printf '%s\n' '# Plan: login' '## Wave 1' '## T1: Login form' '- **Lane**: A' '- **Issue**: #11' >"$T/app/$docs/login/plan.md"
echo '{"feature":"login","phase":"build","status":"in_progress","handed_off":true,"wave":1,"tasks":{"T1":{"status":"todo"}}}' \
  >"$T/app/.claude/workflow/login/state.json"

pids=()
trap 'for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$T"' EXIT
node "$SRC/office/server.js" --project "$T/app" --port 0 >"$T/out" 2>&1 & pids+=($!)
info="$T/app/.claude/workflow/office/server.json"
for _ in $(seq 50); do [[ -s "$info" ]] && break; sleep 0.1; done
port="$(jq -r .port "$info" 2>/dev/null)"
[[ "$port" =~ ^[0-9]+$ && "$(jq -r .pid "$info")" == "${pids[0]}" ]] && ok "server.json has the pid and port" || ko "server.json: $(cat "$info" "$T/out" 2>&1)"
base="http://127.0.0.1:$port"

[[ "$(curl -s "$base/api/health" | jq -r '.ok')" == true ]] && ok "health" || ko "health"
s="$(curl -s "$base/api/snapshot")"
[[ "$(jq -r '.features[0].name + " " + .features[0].tasks[0].id' <<<"$s")" == "login T1" ]] && ok "snapshot: login with T1" || ko "snapshot: $s"
for f in / /app.js /scene.js /style.css; do
  [[ "$(curl -s -o /dev/null -w '%{http_code}' "$base$f")" == 200 ]] || ko "static $f"
done && ok "the page and its files"
[[ "$(curl -s -o /dev/null -w '%{http_code}' "$base/../server.js")" == 404 ]] && ok "no other file is served" || ko "path traversal"
[[ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: evil.example:80' "$base/api/snapshot")" == 403 ]] \
  && ok "another Host is refused (DNS rebinding)" || ko "host check"
[[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base/api/snapshot")" == 405 ]] && ok "read-only" || ko "POST allowed"

# The stream: the first snapshot at once, then a new one after a state change.
curl -sN --max-time 6 "$base/api/stream" >"$T/stream" & pids+=($!)
sleep 1.2
echo '{"feature":"login","phase":"build","status":"in_progress","handed_off":true,"wave":1,"tasks":{"T1":{"status":"waiting","pr":31}}}' \
  >"$T/app/.claude/workflow/login/state.json"
for _ in $(seq 40); do grep -q 'review and merge PR #31' "$T/stream" && break; sleep 0.1; done
(( $(grep -c '^event: snapshot' "$T/stream") >= 2 )) && grep -q 'review and merge PR #31' "$T/stream" \
  && ok "stream: a state change reaches the page" || ko "stream: $(head -c 300 "$T/stream")"

kill "${pids[0]}"; for _ in $(seq 30); do [[ -e "$info" ]] || break; sleep 0.1; done
[[ ! -e "$info" ]] && ok "server.json is removed on stop" || ko "server.json left behind"

(cd "$T" && node "$SRC/office/server.js" >/dev/null 2>&1); [[ $? == 2 ]] && ok "no project -> exit 2" || ko "no project"

node "$SRC/office/server.js" --demo --port 0 >"$T/demo" 2>&1 & pids+=($!)
for _ in $(seq 50); do grep -q '^http' "$T/demo" && break; sleep 0.1; done
d="$(head -1 "$T/demo")"
[[ "$(curl -s "${d}api/health" | jq -r .demo)" == true && "$(curl -s "${d}api/snapshot" | jq '.features | length')" -ge 5 ]] \
  && ok "--demo serves sample features without a project" || ko "demo: $(cat "$T/demo")"

done_tests
