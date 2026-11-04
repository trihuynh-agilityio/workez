---
name: office
description: Use when asked to open, show or launch the office board, the live view of the workflow (which step each feature and task is in, which agent works on it, what waits on you), or to stop it.
model: haiku
allowed-tools: Bash(*/scripts/office.sh*)
---

# Open the office board

Run `${CLAUDE_PLUGIN_ROOT}/scripts/office.sh` from the project folder. It starts the project's office server (or reuses the one already running) and opens the page in the browser. Add `stop` if the user asks to stop it, or `--demo` if they want to see it with sample data. Run nothing else.

Reply with one line: the URL it printed, or its error message. Do not describe the board; the page shows it.

To open the board without a Claude turn, run `bash <plugin>/scripts/office.sh` from a terminal.
