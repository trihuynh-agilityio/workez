---
name: setup
description: Use when asked to set up, install, configure or re-check the feature workflow in a project. Writes the project's .claude/workflow.json, the permission rules in .claude/settings.json and the .gitignore lines the workflow needs, and checks the requirements. Re-run it after changing workflow.json.
allowed-tools: Read Write Edit Glob Grep AskUserQuestion Bash(*/scripts/doctor.sh*) Bash(git remote *) Bash(git branch*) Bash(git rev-parse *) Bash(git symbolic-ref *) Bash(gh auth status*) Bash(gh repo view *) Bash(command -v *) Bash(*/scripts/setup-project.sh*) Bash(bash */tests/run-all.sh*)
---

# Set up the feature workflow in a project

The workflow (`${CLAUDE_PLUGIN_ROOT}/WORKFLOW.md`) reads everything that differs between projects from `<project>/.claude/workflow.json`. Without that file every hook of this plugin does nothing. This skill writes it and the per-project files around it. It never commits, pushes or touches GitHub.

The project folder is the folder Claude was started in, unless the user names another (it may be a folder inside the repository, as in a monorepo).

## 1. Requirements

Run `${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh` from the project folder. Before `workflow.json` exists it checks only the machine: `git` 2.42+, `jq`, `gh`, `curl`, `lsof`, Node 18+ with `npx`, Google Chrome. Report what is missing with how to install it, and stop if `git`, `jq` or `gh` is missing. Also check `gh auth status`. The project must be inside a git repository whose issues and PRs live on GitHub.

## 2. workflow.json

If `<project>/.claude/workflow.json` exists, read it, say so, and ask the user whether to keep it as is (go to step 3) or revise it.

Otherwise draft it from `${CLAUDE_PLUGIN_ROOT}/templates/workflow.example.json` (a full, working example for a Vite + FastAPI project) and the key reference at the end of `${CLAUDE_PLUGIN_ROOT}/WORKFLOW.md`. Fill every value from the project, never from the example:

- `github.repo`: `gh repo view --json nameWithOwner`. `github.remote`: the remote in `git remote -v` that points at it. `github.feedback_authors`: the user's GitHub login plus any review bot. `github.review_trigger`: `"@claude review"` if they will use the review workflow of step 4, else `""`.
- `branches.base`: the branch features start from (ask; often `dev` or `main`). `branches.protected`: the base and the release branches.
- `conventions`: keep the example's [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) setup (`commit_types` and `subject_max_length` 72) unless the project already follows another commit convention; ask before dropping it. With it, branches are `<type>/<issue>-<slug>` and the `naming` patterns use `{task_type}` and `{task_scope}` as in the example. Without it, set `branches.prefix` (for example `feat/`), which every `naming` branch must start with.
- `docs_dir`: where feature docs go, for example `docs/features`.
- `commands`: read `package.json` scripts, `pyproject.toml`, `Makefile`, `CLAUDE.md` and CI files for install, build, lint, format check and test, each `{dir, run}` relative to the project. `commands.acceptance` runs given test files and writes a report file (`{output}`, `{files}`), in any format its test runner offers (JSON, JUnit XML).
- `format`: one rule per formatter actually configured in the project.
- `lanes` (exactly `A` and `B`), `dev_servers`, `app_url`, `dev_url`: how to start the app on two separate sets of ports, each with a `ready` URL. Ask if the project has no UI; the UI checks are then skipped by the plan.
- `blocked_commands`: the project's own "never run" rules from `CLAUDE.md` (wrong package manager, deleting the database, ...).

Show the draft and ask the user to approve it (`AskUserQuestion`) before writing it.

## 3. Settings and .gitignore

Run `${CLAUDE_PLUGIN_ROOT}/scripts/setup-project.sh --dry-run` from the project folder and show the user the result: the permission rules it merges into `.claude/settings.json` (gh and git rules for the repo, remote and branch prefixes, the project's commands, the plugin scripts, the two Playwright servers; deny rules for merges, force pushes, protected branches and approvals) and the lines it adds to `.gitignore`. After the user agrees, run it without `--dry-run`. It keeps every existing setting and adds each rule once.

## 4. Optional: PR review in CI

The build expects a reviewer on each task PR. Offer to copy `${CLAUDE_PLUGIN_ROOT}/templates/github-workflows/claude-review.yml` to `.github/workflows/` at the repository root, with `@claude review` replaced by `github.review_trigger` (keep `feat/`: it matches the integration branches, which are the task PRs' base; with `branches.prefix` instead of conventions, use that prefix). It needs the `CLAUDE_CODE_OAUTH_TOKEN` secret, which only the user can add.

## 5. Check and report

Run `${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh` again and fix what it reports as `FAIL` that this skill owns (`workflow.json`, permissions, `.gitignore`); list the rest for the user. Then tell the user:

- what was written, and that `.claude/workflow.json` and `.claude/settings.json` should be committed;
- that `CLAUDE.md` should describe the stack, rules and how to run one test, since every phase reads it;
- to run `/reload-plugins` (or start a new session) so the hooks see the new config;
- how to start: `/workez:plan-feature <idea>`.

Install the plugin per project (`claude plugin install workez@workez --scope project`) when the user does not want its Playwright servers in every project.
