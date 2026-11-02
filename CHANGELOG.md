# Changelog

Every notable change to the workez plugin. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html):

- **major**: a change that needs action in projects already using the plugin, such as a renamed or removed `workflow.json` key, skill or agent, or a new required key;
- **minor**: a new skill, agent, script or optional `workflow.json` key;
- **patch**: a fix or wording change that keeps every project working as it is.

Add each change under `Unreleased` as you make it. `tools/release.sh` turns that section into a version (see README).

## [Unreleased]

## [0.1.0] - 2026-11-02

### Added

- The feature workflow: skills `plan-feature`, `design-feature`, `write-plan`, `create-task-issues`, `build-feature`, `verify-feature`, `review-task`, `create-task-pr`, `write-intent`, `write-spec` and `project-context`; agents `github-ops`, `implementer`, `code-reviewer`, `spec-reviewer`, `ui-verifier` and `e2e-verifier`; the guard, format and phase hand-off hooks; the Playwright servers `playwright-a` and `playwright-b`.
- `setup` skill and `scripts/setup-project.sh`: draft a project's `.claude/workflow.json`, merge the permission rules into `.claude/settings.json` and add the runtime folders to `.gitignore`.
- `doctor` skill and `scripts/doctor.sh`: a read-only check of the tools and versions, `workflow.json` (required keys, branch prefix, lanes, ports, command folders), the setup, the git remote and GitHub access.
- Requirements section in the README.
- Conventional Commits 1.0.0 for commits and branches: `conventions` in `workflow.json` (`commit_types`, `subject_max_length`), `{task_type}` and `{task_scope}` in `naming`, a **Type** and **Scope** per plan task, the `check-conventions.sh` hook for `git commit -m` and new branches, and checks in `check-task.sh` and `doctor.sh`. Workflow commits (`commit-feature-doc.sh`, `publish-evidence.sh`) use it too.
- `commit_trailers` in `workflow.json`: the trailer lines of every workflow commit (default `Co-Authored-By: Claude <noreply@anthropic.com>`).
- `templates/workflow.example.json` and `templates/github-workflows/claude-review.yml`.
- Project discovery: scripts use `$WF_PROJECT` or the nearest `.claude/workflow.json` at or above the current folder, mapped to the main checkout inside a worktree. Hooks do nothing in a project without `.claude/workflow.json`.
- Tests for project discovery, the hooks in projects without the workflow, `setup-project.sh` and `doctor.sh`.

[Unreleased]: https://github.com/trihuynh-agilityio/workez/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/trihuynh-agilityio/workez/releases/tag/v0.1.0
