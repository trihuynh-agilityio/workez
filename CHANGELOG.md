# Changelog

Every notable change to the workez plugin. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html):

- **major**: a change that needs action in projects already using the plugin, such as a renamed or removed `workflow.json` key, skill or agent, or a new required key;
- **minor**: a new skill, agent, script or optional `workflow.json` key;
- **patch**: a fix or wording change that keeps every project working as it is.

Add each change under `Unreleased` as you make it. `tools/release.sh` turns that section into a version (see README).

## [Unreleased]

### Added
- Opt-in `auto_merge` in `workflow.json` (`task_prs`, `false` by default; `method`, only `merge`). With `task_prs` on, the build watch merges each ready task PR into the feature's integration branch with a merge commit; the final PR and `build-task` PRs are never auto-merged. `scripts/merge-task-pr.sh <feature> <task-id> --sha <sha> [--pr <n>] [--dry-run]` does the merge and refuses unless every guard holds (feature task only, integration branch target, local review PASS and UI check, head unchanged, mergeable, every check green); on the local tracker it merges with `--no-ff` in a throwaway worktree and pushes the integration branch when there is a remote. It appends an `auto-merged` line to the feature's `notes.md`. `gh-watch.sh --ready` prints `READY` lines for a PR with no new feedback, no failed or pending check and no conflict (exit 30 when only READY lines are new). `build-feature` step 4 merges ready task PRs when it is on, and `doctor.sh` reports it.
- `scripts/note.sh` and the per-feature `notes.md` (`.claude/workflow/<feature>/`, git-ignored): one line per decision point (review blocker and major findings and their fix, wontfix, flaky or infra checks, conflicts, used-up fix budget, UI check FAIL, blocked tasks, spec deviations, verify FAIL, UNVERIFIED and major findings), never routine passes.
- A short `## Notable issues` section (at most 8 bullets, condensed from `notes.md`) in the final PR (`build-feature` step 5, refreshed by `verify-feature`) and in `build-task` PRs.
- Structure standard: `workez:project-context` also finds where code goes (folders, layers, import boundaries) in `CLAUDE.md`, `AGENTS.md` at any depth and `ARCHITECTURE*`, and accepts a task description. A missing structure standard returns the warning `No structure rules found for <area>; placement cannot be checked` instead of a question.
- Plans (`write-plan`, `build-task`) have a `## Standards` section and a required task field `Placement`; `create-task-issues` and the `build-task` approval show them. `code-reviewer` runs a structure checklist on every review (reuse, layer boundaries, `as`/`any`, duplication) and the `implementer` follows `Placement`.
- README section "Turn hard rules into lint rules or tests", with `tests/test-structure-rules.sh` and fixtures.
- Optional `task_limits.skip_tests_docs` (default `true`) and `task_limits.tests_docs` in `workflow.json`: tests and docs that come with the change no longer count toward `max_files` in `check-task.sh` (their lines still count toward `max_lines`).
- `scripts/worktree.sh`: the one way the workflow makes a task worktree. `create <branch> [--from <start>]` fetches the start branch (the base by default), cuts from `<remote>/<start>` and runs a preflight (`git merge-base --is-ancestor <remote>/<start> HEAD`); a failing preflight names the base, the HEAD and how many commits are missing, and never resets (a fresh worktree is removed, an existing one must be recreated). `check` runs the preflight alone; `base` prints the base branch.
- `doctor.sh` checks the base branch the plugin really uses: plans whose PR target is not `branches.base` (standalone tasks) or is a protected branch, task worktrees not cut from their PR target, and (online) a remote default branch that differs from `branches.base`.

### Changed
- `append-pr-section` (`github-ops` and `local-ops.sh`) replaces an existing section in place instead of moving it to the end of the body.
- The final PR body has a `## Tasks` heading over the task PR table.
- One resolver for the base branch, `wf_base` in `lib/config.sh` (`branches.base`, else the remote's default branch), used by every script and hook; the skills and the implementer read it from `worktree.sh base` and make worktrees only through `worktree.sh create`, so a project whose base is `dev` never gets a worktree cut from `main`.
- `check-task.sh` reads the task's **Files** as one line or a bullet list under it, with or without backticks; stray backticks, quotes, trailing commas and notes like `(new)` are dropped.
- `check-task.sh` finds moves with `git diff -M` on the whole work, staged or not, so a moved file counts once and only its new path needs to be in **Files**.
- Every `check-task.sh` failure names the plan line or path at fault, the rule it broke and a correct example.

### Fixed
- `lib/config.sh` resolves symlinks in the project and repository paths (`pwd -P`), so a project reached through a symlink (macOS `/var` → `/private/var`) no longer gets a wrong project prefix; `format-on-edit.sh` resolves the edited file's path the same way.
- `local-ops.sh create-pr` exits 0 on success when it has no merge request link to print (no remote, or not GitLab).

## [0.6.0] - 2026-11-11

### Added
- Local tracker: `"tracker": "local"` in `workflow.json` runs every phase without `gh` or GitHub, for projects on GitLab, another host, or with no remote. Features are tracked in `.claude/workflow/`, task PRs become merge request files the user opens (with a GitLab "new merge request" link), and merges are read from git. New `scripts/local-ops.sh` (the `github-ops` operations without `gh`) and `scripts/mark-merged.sh` (marks a squash-merged or closed merge request). See "Local tracker" in `WORKFLOW.md`.
- Optional top-level `remote` in `workflow.json` (else `github.remote`); `""` means no remote with the local tracker.
- `/workez:setup` suggests the tracker from `gh` and the remotes, and asks for the base branch with `dev` as the default, offering the repository's default branch when `dev` does not exist.

### Changed
- `doctor.sh` needs `gh` and `github.*` only with the GitHub tracker, and fails when the local tracker's `naming` still uses `{feature_issue}` or `{task_issue}`.
- `setup-project.sh` writes `gh` permission rules only with the GitHub tracker, and `git fetch`/`git push` rules only when there is a remote.

## [0.5.0] - 2026-11-10

### Added
- Optional `task_limits.exclude` in `workflow.json`: globs of files that `check-task.sh` leaves out of the `max_lines` and `max_files` counts. When absent, common lock files (`package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, `Cargo.lock`, `go.sum`, `Package.resolved` ...), snapshots (`*.snap`) and `*.svg` are left out; `[]` counts every file as before.

### Changed
- `check-task.sh` counts changed lines without whitespace-only changes, counts only the edits of a renamed or moved file, and no longer counts the lines of a deleted file (it still counts toward `max_files`).

## [0.4.0] - 2026-11-04

### Added
- Features run in parallel Claude sessions in one project. The `claim-feature.sh` hook records which session owns a feature (`.claude/workflow/<feature>/owner`), `dev-servers.sh start <lane> <path> <feature>` gives each feature its own port slot and state folder, and `build-lock.sh` replaces the one-build-per-project rule with one build per session.

### Fixed
- `next-phase.sh` no longer hands one session's feature to another session that happens to stop first; that feature used to be marked handed off and then never started.
- `next-phase.sh` now hands off a phase that finishes inside a turn the hook itself started (`stop_hook_active`), so `write-plan` goes on to `create-task-issues` without a nudge.
- `block-forbidden-command.sh` no longer blocks pushing a feature branch while the checkout is on a protected branch, which stopped `build-feature` before wave 0; merging on a protected branch is still blocked.

## [0.3.0] - 2026-11-03

### Added

- The build watches (`build-feature`, `build-task`) now see failed CI checks and merge conflicts on an open task PR. A failed check goes through the same triage and fix rounds as review feedback, with its CI log; a conflict is reported to you, never resolved by the workflow. `gh-watch.sh` prints `CHECKS` and `CONFLICT` lines, and `github-ops` has a `get-pr-checks` operation.
- `setup-project.sh` allows `gh api repos/<repo>/actions/jobs/*`, to read a failed job's log. Rerun it in projects already set up.
- A `notify` key turns the notifications off: `false` in `workflow.json` for everyone, or in the new, gitignored `.claude/workflow.local.json` for yourself (it wins). `workflow.local.json` holds only personal keys; `doctor.sh` warns about any other and about the file being committed. The `WF_NOTIFY` env var (`on`/`off`) wins over both, for every project. Rerun `setup-project.sh` to gitignore `workflow.local.json`.

### Fixed

- Notifications come only from sessions that ran a workez skill, so other Claude sessions in the same project stay quiet, and at most one per session every 15 seconds (`WF_NOTIFY_COOLDOWN`), so one wait that fires two events notifies once.

## [0.2.0] - 2026-11-03

### Added

- `build-task` skill: build one small, standalone change without the feature phases. It approves a one-task plan, opens a task issue (or reuses `#<n>`), runs the task pipeline with the full test suite, and opens one PR straight to the base branch.
- `scripts/status.sh`: run from a shell, without Claude, to see every feature's phase and status, who acts next and what to do, its tasks and its recorded PR states, features waiting on you first (`--short`: one line each). Read-only; reads only the local state files.
- README: a table of contents, a Notifications section, and demo GIFs for `status.sh` and the notifications.
- `github-ops` operations `get-issue` and `create-task-issue`; `swap-label` accepts `-` for no label to remove.
- A macOS notification when Claude waits for a permission, an answer or a plan approval.

### Fixed

- The "finished" notification no longer fires on phase hand-offs while Claude keeps working.
- `check-task.sh` compares with `<remote>/<base>` when the local copy is behind it, so other commits never count toward the task's size and files.

## [0.1.0] - 2026-11-02

First release of workez: a Claude Code plugin that takes a feature from intent to merged pull requests, with GitHub issues, review and verification along the way.

### Added

- The feature workflow in four phases (plan, design, build, verify), with an approval gate between them: skills `plan-feature`, `design-feature`, `write-plan`, `create-task-issues`, `build-feature`, `verify-feature`, `review-task`, `create-task-pr`, `write-intent`, `write-spec` and `project-context`.
- Agents `github-ops`, `implementer`, `code-reviewer`, `spec-reviewer`, `ui-verifier` and `e2e-verifier`.
- Two build lanes that run tasks in parallel worktrees, each with its own Playwright server (`playwright-a`, `playwright-b`).
- Hooks: guards against forbidden commands and pushes to protected branches, format on edit, the phase hand-off, Conventional Commits checks, and a macOS notification when Claude finishes.
- `setup` skill to configure a project (`.claude/workflow.json`, permissions, `.gitignore`) and `doctor` skill to check tools, configuration and GitHub access.
- Project configuration in `.claude/workflow.json`: naming, Conventional Commits rules (`conventions`) and commit trailers (`commit_trailers`); see `templates/workflow.example.json`.

[Unreleased]: https://github.com/trihuynh-agilityio/workez/compare/v0.6.0...HEAD
[0.6.0]: https://github.com/trihuynh-agilityio/workez/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/trihuynh-agilityio/workez/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/trihuynh-agilityio/workez/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/trihuynh-agilityio/workez/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/trihuynh-agilityio/workez/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/trihuynh-agilityio/workez/releases/tag/v0.1.0
