#!/usr/bin/env bash
# Opens the office board of this project in the browser: the workflow drawn as an office, live. Reuses the
# project's office server when it runs, else starts one in the background (node office/server.js, on
# 127.0.0.1 and a free port). Read-only; the board never calls a model. Run it from anywhere inside the
# project (or prefix WF_PROJECT=<project>).
#   office.sh [--no-open]   start or reuse the server, open the page (--no-open: only print the URL)
#   office.sh stop          stop this project's office server
#   office.sh --demo        a server with sample data, no project needed
# Prints the page's URL. The server stops by itself after 30 minutes with no page open and no new event.

open_url() {
  [[ "$no_open" == 1 || "${WF_OFFICE_NO_OPEN:-}" == 1 ]] && return 0
  if command -v open >/dev/null 2>&1; then open "$1" >/dev/null 2>&1
  elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$1" >/dev/null 2>&1
  fi
}
healthy() { curl -s --max-time 1 "http://127.0.0.1:$1/api/health" 2>/dev/null; }

no_open=0; cmd=start
for a in "$@"; do
  case "$a" in
    --no-open) no_open=1 ;;
    stop) cmd=stop ;;
    --demo) cmd=demo ;;
    *) echo "office: unknown argument $a (use --no-open, stop or --demo)" >&2; exit 2 ;;
  esac
done

HOME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v node >/dev/null 2>&1 || { echo "office: node is required (Node 18 or newer)" >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "office: curl is required" >&2; exit 2; }
major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null)"
((${major:-0} >= 18)) || { echo "office: Node 18 or newer is required (found $(node --version 2>/dev/null))" >&2; exit 2; }

if [[ "$cmd" == demo ]]; then
  log="$(mktemp "${TMPDIR:-/tmp}/workez-office-demo.XXXXXX")"
  nohup node "$HOME_DIR/office/server.js" --demo --idle-min 30 >"$log" 2>&1 &
  for _ in $(seq 30); do grep -q '^http' "$log" 2>/dev/null && break; sleep 0.1; done
  url="$(grep -m1 '^http' "$log")"
  [[ -n "$url" ]] || { echo "office: the demo server did not start: $(cat "$log")" >&2; exit 1; }
  open_url "$url"; echo "$url (demo data)"; exit 0
fi

source "$HOME_DIR/scripts/lib/config.sh" || exit 2
info="$WF_PROJECT/.claude/workflow/office/server.json"

# The project's server, if it runs and answers for this project: its port, else empty.
running() {
  [[ -f "$info" ]] || return 1
  local port h
  port="$(jq -r '.port // empty' "$info" 2>/dev/null)"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  h="$(healthy "$port")" || return 1
  [[ "$(jq -r '.project // empty' <<<"$h" 2>/dev/null)" == "$WF_PROJECT" ]] || return 1
  echo "$port"
}

if [[ "$cmd" == stop ]]; then
  if port="$(running)"; then
    kill "$(jq -r .pid "$info")" 2>/dev/null
    for _ in $(seq 30); do [[ -f "$info" ]] || break; sleep 0.1; done
    echo "office: stopped the server on port $port"
  else
    rm -f "$info"; echo "office: no server running for $WF_PROJECT"
  fi
  exit 0
fi

if ! port="$(running)"; then
  rm -f "$info"
  mkdir -p "$WF_PROJECT/.claude/workflow/office"
  nohup node "$HOME_DIR/office/server.js" --project "$WF_PROJECT" --port 0 >>"$WF_PROJECT/.claude/workflow/office/server.log" 2>&1 &
  for _ in $(seq 30); do port="$(running)" && break; sleep 0.1; done
  [[ -n "$port" ]] || { echo "office: the server did not start; see $WF_PROJECT/.claude/workflow/office/server.log" >&2; exit 1; }
fi
url="http://127.0.0.1:$port/"
open_url "$url"
echo "$url"
