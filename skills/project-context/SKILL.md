---
name: project-context
description: Use when a feature's intent is known and you need to find where this project documents the standards it must follow (architecture, security) before designing, implementing or reviewing it.
allowed-tools: Glob Grep Read AskUserQuestion
---

# Find the project's standards for a feature

Given an intent, report which core standards the feature needs and where this project already documents them. Never edit files; the caller reads the listed files itself.

## Input

The path of an intent file (for example `<docs_dir>/<name>/intent.md`). If none is given, ask for it.

## 1. Decide which standards apply

Read the intent whole. Core standards are architecture and security. Include only those the feature needs:

- **Architecture**: it adds or changes screens, components, routes, stored data or how parts talk to each other.
- **Security**: it handles personal or financial data, accepts new input, changes who can see or change what, or touches files, exports or external services.

If neither applies, say so and stop.

## 2. Locate where each standard lives

Do not assume file names. Search for each needed standard in:

- `CLAUDE.md`, `README.md`, `CONTRIBUTING.md`, `SECURITY.md`
- `docs/**`, `adr/**`, `design/**`
- any file those link to

Use Glob for names and Grep for headings and keywords (architecture, structure, layout, security, validation, authentication, privacy). A section inside `CLAUDE.md` counts as existing. Locate first, then read only enough of the hit to confirm it covers the topic. Do not read documents in full.

## 3. Report

A short list, one line per needed standard:

- `<standard>` → `<file>` (section `<heading>`), or `missing`.

Add one line on why the feature needs each standard.

## 4. Ask about the missing ones, once

For all missing standards together, ask once with `AskUserQuestion`: create it first, or skip. Then continue. If the user wants it created, tell the caller to pause until it exists, and re-run the search for that standard.

## Rules

- Write nothing: no manifest, no assumptions section, no saved "skipped" state. Each run checks fresh.
- Keep the report short.
