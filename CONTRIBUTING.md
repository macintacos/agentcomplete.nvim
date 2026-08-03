# Contributing to agentcomplete.nvim

> Audience: developers working on agentcomplete.nvim itself. If you only want to install
> and use the plugin, see the [README](README.md) and `:help agentcomplete`.

Thanks for hacking on agentcomplete. This is what you need to set up the project, run the
checks, and understand the test/diagnostics workflow.

## Prerequisites

Tooling is managed by [mise](https://mise.jdx.dev) (tool versions) and
[hk](https://hk.jdx.dev) (format/lint git hooks). Every tool the project needs — the Lua
toolchain, the markdown/TOML/shell formatters, and the headless Neovim used by the tests —
is pinned in [`mise.toml`](mise.toml) and installed by mise, so you do not install them by
hand.

Install [mise](https://mise.jdx.dev/getting-started.html), then from the repo root:

```sh
mise trust
mise run setup      # install pinned tools, fetch test deps, register git hooks
```

`mise run setup` is the one-time bootstrap: it installs the pinned tools, fetches the test
dependencies, and registers the git hooks.

## Day-to-day tasks

| Command              | What it does                                            |
| -------------------- | ------------------------------------------------------- |
| `mise run format`    | Format all files (stylua + baseline), write mode        |
| `mise run lint`      | Lint + type-check (selene, lua-language-server, …)      |
| `mise run test`      | Run the test suite (headless Neovim + mini.test)        |
| `mise run preflight` | `lint` + `test` — run before pushing                    |
| `mise run diag`      | Print a diagnostics report (headless: blink + OpenCode) |
| `mise run setup`     | One-time bootstrap (see above)                          |

Run a single test file with `mise run test -f <file>`, e.g.
`mise run test -f tests/test_detect.lua`.

`mise run preflight` is the pre-push gate: it runs `lint` then `test` and prints
`preflight: lint + test passed` when both succeed. When a task fails, run it directly to
see its full output and narrow the failure.

## The Lua toolchain

- **stylua** — Lua formatter (config in [`stylua.toml`](stylua.toml)).
- **selene** — Lua lint hygiene (config in [`selene.toml`](selene.toml)).
- **lua-language-server** — LuaCATS type-check (config in [`.luarc.json`](.luarc.json)).
- **mini.test** — the test framework, run under a headless Neovim.

Markdown, TOML, and shell are formatted/linted too (rumdl, taplo, shellcheck);
`mise run lint` covers all of them via `hk check --all`.

## Git hooks

The hooks are registered by `mise run setup` (via `hk install`):

- **pre-commit** — formats and lints staged files.
- **pre-push** — runs the tests.

## Diagnostics

When completion misbehaves inside a prompt buffer, the diagnostics module dumps the live
plugin state to a file you can read back. Two ways to run it:

From a live prompt buffer (the real one an agent CLI opened):

```vim
:AgentCompleteAttach    " optional: force a session if the buffer wasn't auto-detected
:luafile scripts/diagnostics.lua
```

It gathers the resolved backend, buffer detection and attach state, discovered
skills/commands/files, token-highlighting state (attached, tokens painted, what each
highlight group resolves to), and the blink only-source suppression diagnosis (with a
likely-cause line), prints it to `:messages`, and writes it to
`.tmp/agentcomplete-diagnostics.md` under the editor's working directory.

Headless, with no live buffer:

```sh
mise run diag
```

This runs the same flow in two passes: a Claude Code / blink pass against a real blink
setup (with `path` as a source) in a simulated prompt buffer — validating that only-source
suppression removes `path` (it uses a pinned blink v1; v2 needs the compiled `blink.lib`,
which can't build in CI, but the suppression wrap reads the same config on both) — and an
OpenCode pass that sets `OPENCODE=1` on a `<digits>.md` buffer and confirms detection
reports `session.tool: opencode` with the resolved OpenCode search dirs.

## Working with an agent in this repo

agentcomplete carries agent-facing guidance for assistants like Claude Code: see
[`CLAUDE.md`](CLAUDE.md) for the routing entry point and [`doc/agents/`](doc/agents/) for
the on-demand references (diagnostics, documentation upkeep, and more).
