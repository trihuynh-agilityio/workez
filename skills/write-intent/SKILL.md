---
name: write-intent
description: Use when asked to write, draft or start an intent document for a change, before any design or code exists.
model: sonnet
allowed-tools: Bash(git config *) Bash(date *) Bash(ls *) Bash(mkdir *) Read Write Glob
---

# Write an intent

An intent says what a change is for before anyone designs or builds it. It is short, in plain words, and carries no solution detail beyond the outcome.

## 1. Collect the inputs

- **Change name**: from the request. If it is missing, ask.
- **Author**: `git config user.name`.
- **Team**: from the request or the conversation. If unknown, ask once. Never guess a team.
- **Date**: today, from `date +%F`.

## 2. Name and place the file

```
intent/yyyy-mm-dd-[intent-name]/intent.md
```

- `intent/` sits at the root of the project you are working in (the git root, or the project folder if its `CLAUDE.md` says to keep changes inside it).
- `[intent-name]` is the change name in lowercase kebab-case, 2–5 words (`saved-searches`, not `Add the Saved Searches Feature`).
- If the folder already exists, read the file and offer to update it. Never overwrite it.

## 3. File content

The layout is fixed. Line 1 and line 2 are exactly these, then the five headings in this order. Do not rename, reorder, add or drop a heading.

```markdown
# Intent: <name of the change>
Author: <author> (<team>). Status: draft.

## Problem

## Proposed outcome

## Affected users and systems

## Constraints

## Open questions
```

Line 1 is `# Intent: ` plus the change name in sentence case (`# Intent: Saved searches`). Line 2 always says `Status: draft.` when the file is first written.

## 4. Fill the sections

- **Problem**: who hurts, when, and what it costs them today. Facts from the request or the repo only.
- **Proposed outcome**: what is true once the change lands, seen from the user's side. State results, not implementation.
- **Affected users and systems**: the people and the parts of the app it touches, named in plain words (for example "the Dashboard", "the API", "the stored data"), not as files or modules.
- **Constraints**: limits on the outcome that are already decided, such as scope cuts, deadlines, or rules the user must see enforced.
- **Open questions**: everything you had to guess or could not learn. Write each as a question. If nothing is open, write `None.`.

Never invent facts to fill a section. A thin section with an open question beats a confident guess.

Keep implementation out of every section. That means branches, the git or test workflow, file names and paths, the tech stack, and routes, tables or parameters. Refer to the design spec or the app in plain words instead. Exact values that a spec already holds, such as thresholds and limits, stay in the spec and the intent points to it.

## 5. Finish

Tell the user the path of the file and which open questions need their answer first. Do not commit; leave that to the user's branch workflow.
