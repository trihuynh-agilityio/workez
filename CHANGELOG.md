# Changelog

Every notable change to the workez plugin. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html):

- **major**: a change that needs action in projects already using the plugin, such as a renamed or removed `workflow.json` key, skill or agent, or a new required key;
- **minor**: a new skill, agent, script or optional `workflow.json` key;
- **patch**: a fix or wording change that keeps every project working as it is.

Add each change under `Unreleased` as you make it. `tools/release.sh` turns that section into a version (see README).

## [Unreleased]

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

[Unreleased]: https://github.com/trihuynh-agilityio/workez/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/trihuynh-agilityio/workez/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/trihuynh-agilityio/workez/releases/tag/v0.1.0
