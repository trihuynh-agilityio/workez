---
name: release
description: Release a new version of the workez plugin, from the Unreleased changelog notes to a tagged GitHub Release marked Latest. Run with major, minor, patch or X.Y.Z, or with nothing to pick the bump from the notes or resume.
disable-model-invocation: true
---

# Release workez

A release moves through four gates. The user merges both PRs; every other step is yours. Each step ends on a state you can read back from git or GitHub, so a re-run starts at the first step whose state is not reached yet. Find it before doing anything:

| Step | Reached when |
| --- | --- |
| 1. Release PR into `dev` | an open or merged PR from `chore/release-<next>` into `dev` |
| 2. Sync PR `dev` → `main` | an open or merged PR from `dev` into `main` that contains the release commit |
| 3. Tag | `git ls-remote --tags origin v<next>` prints a line |
| 4. GitHub Release | `gh release list` shows `v<next>` as `Latest` |

`<next>` is the argument's version, or the version in `.claude-plugin/plugin.json` on `origin/dev` when it is ahead of the newest tag (a release already in flight).

## 1. Release PR into `dev`

1. Pick the bump. With no argument, read `## [Unreleased]` in `CHANGELOG.md` against the rules at its top: the biggest change decides (a new optional `workflow.json` key or a new skill makes it minor even beside fixes). Show the user the bump, one line of reason per entry, and wait for their yes.
2. `git fetch origin`, then `git ls-remote --heads origin dev`. When `dev` is missing, ask the user, then recreate it with `git push origin origin/main:refs/heads/dev`.
3. With a clean working tree, `git checkout -b chore/release-<next> origin/dev`.
4. `tools/release.sh <bump> --dry-run`, then `tools/release.sh <bump>`. The diff is two files: the changelog section and the `version` line of `plugin.json`.
5. `tools/check-version.sh` and `bash tests/run-all.sh` both pass.
6. Commit as `chore(release): v<next>`, push the branch, and `gh pr create --base dev` titled `chore(release): v<next>`. The body says why it is that bump and lists the released entries with their PR numbers.

Done when the PR exists. Give the user its link and stop: they merge it.

## 2. Sync PR `dev` → `main`

The release PR is merged. `gh pr create --base main --head dev` titled `release: sync dev into main (v<next>)`, with the released notes and, under "After merging", the tag command of step 3.

Done when the PR exists. Give the user its link and stop: they merge it. Merging may delete `dev` on GitHub; step 1 of the next release recreates it.

## 3. Tag

The sync PR is merged. Tag on `main`, which is what installed copies read:

```bash
git checkout main && git pull --ff-only origin main
```

`version` in `plugin.json` is `<next>` and `tools/check-version.sh` passes; then `git tag -a v<next> -m "v<next>"` and `git push origin v<next>`.

## 4. GitHub Release

A tag alone never shows on GitHub's Releases page; "Latest" belongs to a Release. Its notes are the `## [<next>]` section of `CHANGELOG.md`, without the heading and the link lines:

```bash
notes="$(awk -v h="## [<next>]" 'index($0, h) == 1 {f = 1; next} /^## \[/ {f = 0} f' CHANGELOG.md | sed '/^\[.*\]: http/d')"
gh release create v<next> --title v<next> --notes "$notes" --latest --verify-tag
```

Done when `gh release list` shows `v<next>` as `Latest`. Tell the user the release link and that installed copies update with `/plugin marketplace update workez`.
