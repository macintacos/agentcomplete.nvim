# Editing CLAUDE.md

- **Target:** [`CLAUDE.md`](../../../CLAUDE.md)
- **Reader of that file:** agents (Claude Code and peers) working in this repo. It is
  loaded into every session — write for an assistant, not a human, and keep it lean.
- **This reference is for:** agents (and maintainers) about to change CLAUDE.md.

## What belongs in CLAUDE.md

Agent guidance only, in two kinds:

- The **Routing** digraph — the on-demand router. Each edge points at a `doc/agents/*.md`
  reference and is labeled with the task that should load it. Detailed material lives in
  the reference, not inline; the digraph just decides which to read.
- **Always-on project context** that every task needs — currently the CodeGraph habit and
  the "Verifying changes" gate. Keep this short; anything task-specific belongs behind a
  routing edge instead.

## When to edit

Add a routing edge when you add a new `doc/agents/*.md` reference (point the digraph at it
with a task-shaped label). Update the always-on sections only when a project-wide habit
changes (e.g. a new preflight gate). If you are documenting plugin behavior or contributor
steps, you are in the wrong file — see [`vimdoc.md`](vimdoc.md) and
[`contributing.md`](contributing.md).

## How to edit

Use the `/doc-coauthoring` skill when it is available. Keep the graphviz blocks valid and
in the existing style (`digraph name { … }`, shaped nodes, labeled edges). Match the
existing wrap (rumdl `MD013`, line-length 90; code/digraph blocks exempt).

## Verify

Run `mise run lint` (rumdl must pass). Confirm every `doc/agents/*.md` path named in the
routing digraph exists.
