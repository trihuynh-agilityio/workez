---
name: project-context
description: Use when a feature's intent is known and you need to find where this project documents the standards it must follow (architecture, security, structure) before designing, implementing or reviewing it.
allowed-tools: Glob Grep Read AskUserQuestion
---

# Find the project's standards for a feature

Given an intent or a task description, report which core standards the change needs and where this project already documents them. Never edit files; the caller reads the listed files itself.

## Input

The path of an intent file (for example `<docs_dir>/<name>/intent.md`), or a task description or plan request in words (`workez:build-task` has no intent). If none is given, ask for it.

## 1. Decide which standards apply

Read the intent (or the description) whole. Core standards are architecture, security and structure. Include only those the feature needs:

- **Architecture**: it adds or changes screens, components, routes, stored data or how parts talk to each other.
- **Security**: it handles personal or financial data, accepts new input, changes who can see or change what, or touches files, exports or external services.

- **Structure**: where code goes: folders, layers, which layer may import which, where shared helpers live. It applies whenever the change creates or moves files or adds code to an existing layer, which is nearly always.

If none applies, say so and stop.

## 2. Locate where each standard lives

Do not assume file names. Search for each needed standard in:

- `CLAUDE.md`, `README.md`, `CONTRIBUTING.md`, `SECURITY.md`
- `docs/**`, `adr/**`, `design/**`
- any file those link to

For structure also search `AGENTS.md` at any depth (for example `apps/api/AGENTS.md`, `packages/*/CLAUDE.md`; a nested file is scoped to its own folder) and `docs/ARCHITECTURE*` / `ARCHITECTURE*`, and judge it per area (package, app or folder) the change touches.

Use Glob for names and Grep for headings and keywords (architecture, structure, layering, layers, folder, directory layout, "where code goes", imports, boundaries, layout, security, validation, authentication, privacy). A section inside `CLAUDE.md` counts as existing. Locate first, then read only enough of the hit to confirm it covers the topic. Do not read documents in full.

## 3. Report

A short list, one line per needed standard:

- `<standard>` → `<file>` (section `<heading>`), or `missing`. Structure gets one line per area: `structure → <file> (section <heading>)` or `structure (<area>) → missing`.

Add one line on why the feature needs each standard.

## 4. Ask about the missing ones, once

Structure is never asked about. When it is missing for an area, return exactly this warning, with `<area>` the package, app or folder (or `the project` for a single-package repo), and let the caller continue:

`No structure rules found for <area>; placement cannot be checked`

For the other missing standards together, ask once with `AskUserQuestion`: create it first, or skip. Then continue. If the user wants it created, tell the caller to pause until it exists, and re-run the search for that standard.

## Rules

- Write nothing: no manifest, no assumptions section, no saved "skipped" state. Each run checks fresh.
- Keep the report short.
