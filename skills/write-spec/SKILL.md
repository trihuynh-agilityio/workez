---
name: write-spec
description: Use when asked to write, draft or start a spec for a change that already has an intent document, before any code exists.
allowed-tools: Bash(ls *) Read Write Glob Grep
---

# Write a spec

A spec turns an approved intent into numbered requirements, a design, and a check that every intent constraint is met. It is short and plain. It says what will be built and what is still unsettled, and it never hides a conflict.

## 1. Collect the inputs

- **Intent**: the `intent.md` the spec answers. Take it from the request. If the request names none, run `ls intent/` and ask which one. If the project has no intent, stop and offer to run `workez:write-intent` first.
- **Skills to apply**: the project skills (`.claude/skills/`) and any the user names that bear on this change. Read each one before you design. Record only the ones you actually applied.
- **Project guidance**: read `CLAUDE.md` and any design spec it points to, so the design follows the stack and rules already decided.

Read the whole intent before writing anything. If its status is still `draft`, tell the user and carry on only if they say so.

## 2. Name and place the file

```
intent/yyyy-mm-dd-[intent-name]/spec.md
```

- It sits in the same folder as the intent it answers, with the same date and name.
- If `spec.md` already exists, read it and offer to update it. Never overwrite it.

## 3. File content

The layout is fixed. Lines 1 to 3 are exactly these, then the five headings in this order. Do not rename, reorder, add or drop a heading.

```markdown
# Spec: <name of the change>
From: intent.md (<author>, <team>). Status: ready for product owner review.
Skills applied: <skill>, <skill>.

## Requirements

## Design

## How each constraint in the intent is met

## Open questions from the intent

## Areas of concern
```

- Line 1 is `# Spec: ` plus the change name in sentence case, as in the intent.
- Line 2 takes the author and team from line 2 of the intent. The status is always `ready for product owner review.` when the file is first written.
- Line 3 lists the skills from step 1, comma separated. If none were applied, write `Skills applied: none.`.

## 4. Fill the sections

- **Requirements**: a list numbered `R1.`, `R2.` and so on. Each is one testable statement of what must be true, taken from the intent's proposed outcome. Write the exact values the intent left to the spec (thresholds, limits, states, field lists, time bounds). One requirement, one fact. Do not add a requirement the intent does not support.
- **Design**: the smallest design that meets the requirements, in short bullets. Name the parts it touches (endpoints, services, screens, stored data) and how they connect. Follow the stack and rules in `CLAUDE.md`. Say what is new and what is reused. Show no code.
- **How each constraint in the intent is met**: a two-column table, `Constraint | Met by`. One row per constraint in the intent, in the intent's order, worded as the intent words it. In the second column cite the requirement or design choice that meets it (`R3`, "the gateway JWT"). If a constraint cannot be met as written, put `See concern N.` and raise it under Areas of concern. Never drop a constraint or restate it more loosely.
- **Open questions from the intent**: every open question in the intent, with what became of it: answered (say how), or `Not answered. Carried forward as concern N.`. If the intent has none, write `None.`.
- **Areas of concern**: a numbered list of everything the spec cannot settle alone. Raise a concern when a requirement is left out of scope, when two skills or rules contradict each other, when a constraint cannot be met as written, or when a risk is untested. Each concern says what the problem is, what the spec does about it, and ends with `Owner: <who decides>.` Propose a way out when you have one. If you have none, write `None.`.

Never invent facts to fill a section. A named concern beats a confident guess. If two inputs conflict, do not pick one silently. State both and raise a concern.

Keep the spec to what the intent asked for. Anything the intent puts out of scope stays out, and goes under Areas of concern only if a reader might expect it.

## 5. Finish

Tell the user the path of the file and which concerns need a decision first, with the owner of each. Do not commit; leave that to the user's branch workflow.
