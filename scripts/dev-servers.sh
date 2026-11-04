#!/usr/bin/env bash
# Start or stop the dev servers of one UI-check lane, from a task worktree.
#   dev-servers.sh start <lane> <worktree-or-project-path> [feature]
#   dev-servers.sh stop  <lane> [feature]
# Lanes, ports, server commands, environment and ready URLs come from workflow.json ("lanes",
# "dev_servers", "app_url"). Placeholders: each lane key ({frontend_port}, ...) and {state_dir}, a
# fresh temp folder per lane, so two lanes never share a database or log. On success it prints
# APP_URL=<the lane's app URL>.
# With a feature, the lane runs on that feature's port slot (wf_lane_slot: the first feature to build
# gets the ports of workflow.json, a second one building at the same time gets them moved up by
# wf_lane_step) and in its own state folder, so features built in parallel sessions never share a port
# and `stop` never kills another feature's servers. Pass the same feature to start and stop.

source "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh" || exit 2

action="${1:-}"
lane="${2:-}"
case "$action" in
  start) target="${3:-}"; feature="${4:-}" ;;
  *) target=""; feature="${3:-}" ;;
esac
usage() { echo "usage: dev-servers.sh start <lane> <worktree-or-project-path> [feature] | stop <lane> [feature]" >&2; exit 2; }

slot=0
if [[ -n "$feature" ]]; then
  [[ "$feature" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "dev-servers: bad feature name '$feature'" >&2; usage; }
  slot="$(wf_lane_slot "$feature")" || { echo "dev-servers: no free port slot for '$feature'" >&2; exit 1; }
fi
vars=()
while IFS= read -r kv; do [[ -n "$kv" ]] && vars+=("$kv"); done < <(wf_lane_vars "$lane" "$slot")
((${#vars[@]})) || { echo "dev-servers: no lane '$lane' in workflow.json" >&2; usage; }
state="${TMPDIR:-/tmp}/ui-lane-$lane${feature:+-$feature}"
vars+=("state_dir=$state")
ports=()
for kv in "${vars[@]}"; do [[ "${kv#*=}" =~ ^[0-9]+$ ]] && ports+=("${kv#*=}"); done
servers="$(jq '.dev_servers // [] | length' "$WF_CONFIG")"

listeners() { lsof -ti ":$1" -sTCP:LISTEN 2>/dev/null; }

stop() {
  local f p pids
  for f in "$state"/*.pid; do
    [[ -f "$f" ]] && kill "$(cat "$f")" 2>/dev/null
  done
  for p in "${ports[@]}"; do
    pids="$(listeners "$p")"
    [[ -n "$pids" ]] && kill $pids 2>/dev/null
  done
  sleep 1
  for p in "${ports[@]}"; do
    pids="$(listeners "$p")"
    [[ -n "$pids" ]] && kill -9 $pids 2>/dev/null
  done
  echo "lane $lane${feature:+ of $feature} stopped (ports ${ports[*]})"
}

start() {
  local proj="$target" i p name dir run env_lines ready k v all_ready
  [[ -n "$proj" ]] || usage
  [[ -f "$proj/.claude/workflow.json" ]] || proj="$(wf_project_in "$proj")"
  [[ -d "$proj" ]] || { echo "dev-servers: no project folder at '$target'" >&2; exit 2; }
  for p in "${ports[@]}"; do
    [[ -n "$(listeners "$p")" ]] && { echo "port $p is already in use; stop it first" >&2; exit 1; }
  done
  rm -rf "$state"
  mkdir -p "$state"

  for ((i = 0; i < servers; i++)); do
    name="$(cfg ".dev_servers[$i].name")"; dir="$(cfg ".dev_servers[$i].dir")"
    run="$(wf_fill "$(cfg ".dev_servers[$i].run")" "${vars[@]}")"
    env_lines="$(jq -r ".dev_servers[$i].env // {} | to_entries[] | \"\(.key)=\(.value)\"" "$WF_CONFIG")"
    # exec + redirects: the servers must not keep this script's stdout open, or callers wait for them.
    (
      cd "$proj/${dir:-.}" || exit 1
      while IFS= read -r kv; do
        [[ -n "$kv" ]] && export "${kv%%=*}=$(wf_fill "${kv#*=}" "${vars[@]}")"
      done <<<"$env_lines"
      exec nohup bash -c "exec $run" >"$state/$name.log" 2>&1 </dev/null
    ) &
    echo $! >"$state/$name.pid"
  done

  for _ in $(seq 1 60); do
    all_ready=1
    for ((i = 0; i < servers; i++)); do
      ready="$(cfg ".dev_servers[$i].ready")"
      [[ -z "$ready" ]] || curl -sf "$(wf_fill "$ready" "${vars[@]}")" >/dev/null || { all_ready=0; break; }
    done
    if ((all_ready)); then
      echo "lane $lane${feature:+ of $feature} ready on slot $slot (state and logs in $state)"
      echo "APP_URL=$(wf_fill "$(cfg .app_url)" "${vars[@]}")"
      return 0
    fi
    sleep 1
  done
  echo "lane $lane was not ready after 60 s; see the logs in $state" >&2
  stop
  exit 1
}

case "$action" in
  start) start ;;
  stop) stop ;;
  *) usage ;;
esac
