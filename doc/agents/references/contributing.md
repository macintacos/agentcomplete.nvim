# Editing CONTRIBUTING.md

- **Target:** [`CONTRIBUTING.md`](../../../CONTRIBUTING.md)
- **Reader of that file:** human developers who want to build, test, and change the plugin
  from a checkout. Assume git and a terminal; do not assume they know this repo's tooling.
- **This reference is for:** agents (and maintainers) about to change CONTRIBUTING.

## What belongs in CONTRIBUTING

The contributor workflow: prerequisites (`mise`, `mise trust`, `mise run setup`), the
`mise run …` task catalog, how to run one test (`mise run test -f <file>`), the Lua
toolchain (stylua, selene, lua-language-server, mini.test), the git hooks (pre-commit
format/lint, pre-push test), and the developer-facing headless diagnostics flow
(`mise run diag`). Keep it in step with [`mise.toml`](../../../mise.toml) — when a task is
added, renamed, or removed, update the task table here.

## What does NOT belong here

End-user installation and usage (that is the README and the vimdoc). Deep architecture and
agent-assisted workflows are agent-facing — point at [`CLAUDE.md`](../../../CLAUDE.md) and
[`doc/agents/`](../) rather than restating them here.

## How to edit

Use the `/doc-coauthoring` skill when it is available. The in-buffer diagnostics command
(`:luafile scripts/diagnostics.lua`) is documented for users in the vimdoc too — if you
change how diagnostics run, update both, and check
[`../diagnostics.md`](../diagnostics.md) for the agent-facing angle. Match the existing
wrap (rumdl `MD013`, line-length 90; code blocks exempt).

## Verify

Run `mise run lint` (rumdl must pass). If you changed a documented command, run it to
confirm the description is accurate.
