# Shared by the workflow tests. Source it from a test-*.sh file; it sets:
#   SRC    the plugin folder under test (the one that holds this tests/ folder)
#   T      a fresh temporary folder for this test, removed on exit (KEEP=1 keeps it)
#   ok / ko <name>  print PASS or FAIL; FAILS counts the failures
# Tests build throwaway repositories in $T and never touch the project, its remotes or GitHub.
set -u
export SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/wf-test.XXXXXX")" && pwd -P)"
[[ "${KEEP:-0}" == 1 ]] && echo "work folder: $T" || trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=t@example.com \
  GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=t@example.com
# Hooks print their notification instead of showing it.
export WF_NOTIFY_DRY_RUN=1
FAILS=0
ok() { printf 'PASS  %s\n' "$1"; }
ko() { printf 'FAIL  %s\n' "$1"; FAILS=$((FAILS + 1)); }
# done_tests: prints the count and exits non-zero on any failure.
done_tests() { echo; echo "failures: $FAILS"; ((FAILS == 0)); }
