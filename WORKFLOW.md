# Feature workflow

An automated feature workflow for Claude Code, packaged as the `workez` plugin: an idea goes through intent, spec, plan, GitHub issues, parallel implementation with review and UI checks, task PRs, and a whole-feature verification. A human approves the intent, the spec and the plan, and merges every PR. Nothing in it merges, approves or force-pushes.

Everything that differs between projects lives in the project's **`.claude/workflow.json`**. The plugin's skills, agents, hooks and scripts read it; none of them names a repository, branch, command or port. In a project without that file the plugin's hooks do nothing. Skills and agents are namespaced: `workez:plan-feature`, `workez:github-ops`, and so on (the tables below use the short names).

## Phases

| Phase | Skill | Result | Human step |
|---|---|---|---|
| 1 Plan | `plan-feature` | `<docs_dir>/<feature>/intent.md`, a feature issue, the intent committed to the integration branch | approve the intent |
| 2 Design | `design-feature` (spec-reviewer loop) | `spec.md`, committed | approve the spec |
| 2b Plan | `write-plan` | `plan.md`: waves of at most two tasks, lanes A/B, size limits, AC coverage | — |
| 3a Tasks | `create-task-issues` | one sub-issue per task, numbers written back into the plan, plan committed | approve the plan |
| 3b Build | `build-feature` | per task: implementer, `check-task.sh`, `review-task` loop, `ui-verifier`, `create-task-pr`; a watch that starts the next wave after a merge, fixes PR feedback and failed checks, and reports conflicts; the final PR to the base branch | merge each wave |
| 4 Verify | `verify-feature` | checks, E2E, AC table and review on a throwaway merge with the base; report on the feature issue; `plan-fix.md` on FAIL; on PASS a watch on the final PR that, once it is merged, clears the local data and labels the feature issue `phase:done` (the issue stays open) | approve the fix plan (FAIL), merge the final PR (PASS) |

The `Stop` hook `next-phase.sh` moves from one phase to the next through `.claude/workflow/<feature-name>/state.json` (git-ignored, with `hook.log`). `review-task` and `create-task-pr` are user-run skills that the build lanes follow step by step.

**One small change.** `build-task` skips the phases for a change that fits in one task: it writes a one-task plan (`T1`, a `## Request` section in place of intent and spec) to the git-ignored `.claude/workflow/<slug>/plan.md`, asks for approval, opens a `task` issue (or reuses `#<n>`), runs the build lane on lane A with the full test suite added, and opens one PR to `branches.base` that closes the issue. Its state has phase `task`, which the `Stop` hook never advances; a watch takes it to the end once the PR is merged, and `cleanup-feature.sh <slug>` removes its local data but never the base branch. A change that needs more than one task goes to `plan-feature`.

**Several features.** Each feature keeps its runtime files (state, PR states, PR bodies) in its own `.claude/workflow/<feature-name>/`, so features can be planned or wait for review side by side. Only one feature (or `build-task`) runs lanes at a time, because the lanes share ports and Playwright browsers: `build-feature` and `build-task` refuse to start while another build is `in_progress`.

**Two lanes, A and B.** The number of lanes is fixed. Their names are written into the plugin's `.mcp.json` (`playwright-a`, `playwright-b`, whose tools are `mcp__plugin_workez_playwright-a__*` and `..._playwright-b__*`), into the tools of `ui-verifier` (both lanes) and `e2e-verifier` (lane A), and into `write-plan` (at most two tasks per wave). `workflow.json` only sets each lane's ports. A third lane means changing all of those, not just `lanes`.

**Local data is temporary.** A task's worktree and local branch are removed as soon as its PR is merged (`cleanup-feature.sh --task`, run by the build watch), and the merge of the final PR removes the rest (the verify watch, or a rerun of `verify-feature` after the merge): the local integration branch, `.claude/workflow/<feature-name>/`, the verify and evidence worktrees and the feature's local `evidence/` and `reviews/`. Everything removed is already on GitHub (report comment, evidence branch, PR bodies). A FAIL keeps it all for the fix round. A worktree with uncommitted work, a task branch neither the integration branch nor the base contains, or an integration branch the base does not contain (not merged yet, or squash-merged) is never removed; the script reports it as `KEPT`. Remote branches are never deleted by the workflow: whether merged branches disappear from the remote is the repository's own setting (on GitHub, "Automatically delete head branches").

**Watches live in the session.** The build watch (wave merges, PR feedback, failed checks, conflicts) and the verify watch (the final PR) are `CronCreate` jobs of the Claude Code session that started them: they run only while that session is open and idle, and for 7 days at most. When the session closes or a watch expires, nothing runs; GitHub keeps the state. To pick up again, run `/workez:build-feature <feature>` (it resumes from the PR states on GitHub) or `/workez:verify-feature <feature>` (after the final PR is merged, it goes straight to its Close step). A scheduled run that hits a permission prompt stops there too, which is why the script allow rules matter.

## Parts

All paths below are inside the plugin (`${CLAUDE_PLUGIN_ROOT}`), except the project's own files.

- **Skills** (`skills/`): the phases above, plus `build-task` (one standalone task), `write-intent`, `write-spec`, `project-context`, `setup` (prepares a project) and `doctor` (checks it).
- **Agents** (`agents/`): `github-ops` (every GitHub call, Haiku; each start-up costs about 16k tokens, so callers send one numbered `batch:` per decision point), `implementer`, `code-reviewer`, `spec-reviewer`, `ui-verifier` (lanes A and B), `e2e-verifier` (lane A).
- **Scripts** (`scripts/`, all read `lib/config.sh`): `build-position.sh` (where the build stands), `check-task.sh` (size, files and format of one task), `check-review.sh` and `check-pr-ready.sh` (gates), `cleanup-feature.sh` (removes a merged task's or a merged feature's local data, never a remote branch; `--dry-run` lists it), `code-head.sh`, `commit-feature-doc.sh`, `gh-watch.sh` (read-only PR states, new feedback ids and failed checks or conflicts on an open PR's head commit, so the build and verify watches call no agent while nothing changed; `--no-feedback` for states only), `dev-servers.sh` (a lane's servers), `publish-evidence.sh` (screenshots to the `<integration branch>-evidence` branch), `verify-worktree.sh`, `verify-checks.sh`, `setup-project.sh` (permissions and `.gitignore` from `workflow.json`), `doctor.sh` (read-only readiness check), `status.sh` (read-only: each feature's phase, who acts next and its PR states, from the local state files). **Finding the project**: a script uses `$WF_PROJECT` when set, else the nearest folder at or above the current folder that holds `.claude/workflow.json`; found inside a linked worktree, it maps to the same folder of the main checkout. So run them from anywhere inside the project, or prefix `WF_PROJECT=<project>`.
- **Hooks** (`hooks/hooks.json`): `format-on-edit.sh` (the `format` rules, also in task worktrees), `block-forbidden-command.sh` (generic guards plus `blocked_commands`), `block-push-protected.sh` (blocks pushes to `branches.protected`), `check-conventions.sh` (Conventional Commits for `git commit -m` and new branch names, with `conventions`), `next-phase.sh`, `notify-on-finish.sh` (macOS only: a notification when Claude really finishes, not on a phase hand-off, and when it waits for a permission, an `AskUserQuestion` answer or a plan approval, only in sessions that ran a workez skill, at most once per session every `WF_NOTIFY_COOLDOWN` seconds; `notify` turns it off, see the reference below), `office-event.sh` (appends one JSON line per workflow event, such as a workez skill or agent starting or stopping, a question or a permission prompt, to `.claude/workflow/office/events-<session>.jsonl` for the office board; silent, about 15 ms, schema in `docs/office-events.md`; `office` turns it off). Each finds the project from the hook's `cwd`, then `$CLAUDE_PROJECT_DIR`, and exits quietly when there is none.
- **Tests** (`tests/`): `bash tests/run-all.sh` (`-v` for every line) runs the scripts and hooks in throwaway repositories, with a fake `gh`, and never touches a project, its remotes or GitHub. Run it after changing anything in `scripts/` or `hooks/`; `KEEP=1` keeps a test's work folder.
- **MCP** (`.mcp.json`): the headless, isolated Playwright servers `playwright-a` and `playwright-b`, one per lane. They start in every session where the plugin is enabled, so enable the plugin per project if that matters.
- **Templates** (`templates/`): `workflow.example.json` (a complete config for a Vite + FastAPI project) and `github-workflows/claude-review.yml` (reviews task PRs whose base starts with the branch prefix, and any `@claude review` comment from a trusted user).

Task ids (`T1`, `T2`) are keys inside the plan, the review reports (`<docs_dir>/<feature>/reviews/`), the evidence folders (`<docs_dir>/<feature>/evidence/`) and the state file. Issue, PR and commit titles come from `naming` and never carry them.

## Installing in a project

1. **Requirements**: `git` 2.42 or newer, `jq`, `gh` signed in to the GitHub repository (issues enabled, write access, sub-issues), `curl`, `lsof`, Node 18 or newer (`npx` for Playwright MCP), Google Chrome for the UI checks, bash 3.2 or newer. Issues and PRs live on GitHub; the code remote may be elsewhere. The full list is in the README; `/workez:doctor` (`scripts/doctor.sh`) checks it.
2. **Install the plugin**: `/plugin marketplace add trihuynh-agilityio/workez` then `/plugin install workez@workez` (add `--scope project` from the shell to enable it for one project only).
3. **Run `/workez:setup`** in the project. It drafts `.claude/workflow.json` from the project (reference below) for your approval, merges the permission rules into `.claude/settings.json` with `scripts/setup-project.sh` (permissions cannot read the config, so they are written out per project: the `gh api repos/<owner>/<repo>/...` rules, the remote and branch prefix, the project's commands, the plugin's scripts and Playwright servers, and the deny rules for merges, force pushes and protected branches), adds `.claude/workflow/`, `.claude/worktrees/`, `<docs_dir>/*/reviews/` and `<docs_dir>/*/evidence/` to `.gitignore`, and offers the CI review workflow. Rerun `setup-project.sh` after changing `workflow.json`. The script rules matter: a scheduled watch that hits a permission prompt stops there.
4. **Project content** stays the project's own: `CLAUDE.md` (stack, rules, how to run one test), and optionally a `pr-description` skill for PR bodies (without it the workflow writes a short summary).
5. **Commit** `.claude/workflow.json` and `.claude/settings.json`, then `/reload-plugins`.
6. **Check**: `/workez:doctor` reports no `FAIL`.

## `workflow.json` reference

| Key | Meaning |
|---|---|
| `github.repo` | `owner/name` of the GitHub repository for issues and PRs |
| `github.remote` | the git remote that points at it (pushes, fetches) |
| `github.feedback_authors` | PR feedback the build acts on comes only from these logins |
| `github.review_trigger` | the comment a user posts on a PR to ask the review bot for a review by hand; the workflow never posts it, and drops such comments from PR feedback. `""` for none |
| `branches.base` | the branch features start from and the final PR targets |
| `branches.protected` | never pushed to or merged on (hook and skills) |
| `branches.prefix` | without `conventions` only: every `naming` branch must start with it; the skills push only those |
| `conventions.commit_types` | turns on [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/): commit subjects `<type>[(scope)][!]: <description>` and branches `<type>/...`, with a type from this list. Checked by the `check-conventions.sh` hook (`git commit -m`, new branches), `check-task.sh` (the task's branch and commit subjects) and `doctor.sh` (the `naming` patterns). Without it, branches use `branches.prefix` and commit subjects are free |
| `conventions.subject_max_length` | the longest commit subject, 72 by default |
| `commit_trailers` | trailer lines added to every commit the workflow makes; `Co-Authored-By: Claude <noreply@anthropic.com>` when absent, `[]` for none |
| `docs_dir` | where `<feature>/intent.md`, `spec.md`, `plan.md`, reviews and evidence live, relative to the project |
| `task_limits` | `max_lines` and `max_files` of one task (the limit is "under") |
| `naming` | patterns for titles and branches; placeholders `{feature_name}`, `{feature_slug}`, `{feature_issue}`, `{task_title}`, `{task_slug}`, `{task_issue}`, `{round}`, and with `conventions` `{task_type}` (the task's **Type** in the plan) and `{task_scope}` (`(<scope>)`, or nothing). Changing `feature_issue_title` orphans existing feature issues, because `find-issue` matches it exactly |
| `commands.install`, `build`, `lint`, `format_check`, `test` | lists of `{dir, run}`, run in that order by `verify-checks.sh` and the integration check; `install` also prepares a new worktree |
| `commands.acceptance` | `{dir, run}` with `{output}` (the report path, in any format the test runner writes) and `{files}` (the plan's acceptance test files, relative to `dir`) |
| `format` | rules `{dir, match, exclude, write, check}`: globs relative to `dir`; `write` and `check` get absolute file paths appended and run in `dir` of the main checkout |
| `lanes` | exactly two, `A` and `B` (see "Two lanes"), each a map of named ports (`frontend_port`, ...) used as placeholders |
| `dev_servers` | `{name, dir, run, env, ready}` per server; placeholders are the lane's ports and `{state_dir}` (a fresh temp folder per lane) |
| `app_url` | the app URL of a lane (placeholders as above), printed by `dev-servers.sh` as `APP_URL=` |
| `dev_url` | the normal dev URL that plans may mention; the UI verifiers replace it with the lane's `app_url` |
| `blocked_commands` | project rules for the Bash hook: `{pattern, message}`, extended regex on the whole command |
| `notify` | `false` turns the macOS notifications off; `true` (the default) keeps them. A personal key: `.claude/workflow.local.json` may set it too and wins, and the `WF_NOTIFY` env var (`on`/`off`) wins over both |
| `office` | `false` stops recording the office board's events (`office-event.sh`); `true` (the default) records them. A personal key, like `notify`; the `WF_OFFICE` env var (`on`/`off`) wins over both files |

`.claude/workflow.local.json`, next to `workflow.json`, holds one person's overrides and is gitignored. It may set only personal keys (today `notify` and `office`), never the team's rules; `doctor.sh` warns about any other key, which is ignored, and about the file being committed.
