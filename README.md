# agentcomplete.nvim

Context-aware completion of files, skills, and commands for Neovim — usable from
[blink.cmp](https://github.com/Saghen/blink.cmp),
[nvim-cmp](https://github.com/hrsh7th/nvim-cmp), and the builtin completion.

> Status: early scaffolding.

## Getting started (development)

Tooling is managed by [mise](https://mise.jdx.dev) (tool versions) and
[hk](https://hk.jdx.dev) (format/lint git hooks). Install
[mise](https://mise.jdx.dev/getting-started.html), then:

```sh
mise trust
mise run setup      # install pinned tools, fetch test deps, register git hooks
```

Day-to-day:

| Command              | What it does                                       |
| -------------------- | -------------------------------------------------- |
| `mise run format`    | Format all files (stylua + baseline), write mode   |
| `mise run lint`      | Lint + type-check (selene, lua-language-server, …) |
| `mise run test`      | Run the test suite (headless Neovim + mini.test)   |
| `mise run preflight` | `lint` + `test` — run before pushing               |

The Lua toolchain: **stylua** (format), **selene** (lint hygiene), **lua-language-server**
(LuaCATS type-check), **mini.test** (tests). A `pre-commit` hook formats and lints staged
files; a `pre-push` hook runs the tests.
