# Editing the doc/agents references

- **Target:** the files under [`doc/agents/`](../) — the routing hub
  [`documentation.md`](../documentation.md), [`diagnostics.md`](../diagnostics.md), and
  the per-target files in [`references/`](.) (including this one).
- **Reader of those files:** agents. They load on demand via the CLAUDE.md routing
  digraph, so write for an assistant doing a specific task, not for a human reading top to
  bottom.
- **This reference is for:** agents (and maintainers) about to change a `doc/agents` file.

## What belongs in doc/agents

On-demand, task-scoped guidance that would bloat CLAUDE.md if always loaded. Each
reference opens by stating who it is for and what it covers, and (where it routes onward)
leads with a graphviz digraph for progressive disclosure — the pattern `diagnostics.md`
and `documentation.md` both follow. Keep references self-contained: an agent should be
able to act after loading just the one the router pointed it at.

## When to edit

- **Adding a reference:** create `doc/agents/<topic>.md`, then add a matching edge to the
  CLAUDE.md routing digraph (see [`claude-md.md`](claude-md.md)) — an unrouted reference
  is invisible.
- **Changing the documentation surface** (a new doc, a moved boundary): update the routing
  hub [`documentation.md`](../documentation.md) — its digraph, its audience table, and the
  matching `references/*.md` file.
- Keep this `references/` set in step with the docs it describes: if README, the vimdoc,
  CONTRIBUTING, or CLAUDE.md changes audience or scope, fix the pointer here too.

## How to edit

Use the `/doc-coauthoring` skill when it is available. Keep graphviz blocks valid and in
the existing style. Match the existing wrap (rumdl `MD013`, line-length 90; code/digraph
blocks exempt).

## Verify

Run `mise run lint` (rumdl must pass). Confirm any new reference is reachable from a
CLAUDE.md routing edge, and that paths named in the routing hub exist.
