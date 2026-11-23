#!/usr/bin/env bash
# Fails when a file under src/routes/ imports the DB client. Run it from the project root.
bad="$(grep -rlE "from ['\"][^'\"]*db/client['\"]" src/routes 2>/dev/null || true)"
[[ -z "$bad" ]] || { echo "routes must not import the db client:"; echo "$bad"; exit 1; }
