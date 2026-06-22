---Filesystem discovery of skills, commands, and files for completion.
---
---Pure of any Neovim editor state — every function takes explicit paths and
---returns plain tables, so the whole module is exercised under headless tests.
---@class AgentComplete.Scan
local M = {}

---@class AgentComplete.Skill
---@field name string Skill name (frontmatter `name`, else the directory name).
---@field description string|nil Frontmatter `description`, if present.
---@field path? string Absolute path to the SKILL.md (nil for built-in skills resolved via the CLI).

---@class AgentComplete.Command
---@field name string Command name; nested files join path segments with `:`.
---@field description string|nil Frontmatter `description`, if present.
---@field path? string Absolute path to the command markdown file (nil for built-in commands).
---@field hidden? boolean Built-in command not useful when composing in an editor buffer; completed only when the user opts in.

---Read a simple `key: value` YAML frontmatter block from a markdown file.
---Only the leading `---` … `---` block is parsed; values are unquoted.
---@param path string
---@return table<string, string>
local function read_frontmatter(path)
  local fm = {}
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or lines[1] ~= "---" then
    return fm
  end
  for i = 2, #lines do
    if lines[i] == "---" then
      break
    end
    local k, v = lines[i]:match "^([%w_%-]+):%s*(.*)$"
    if k then
      v = v:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
      fm[k] = v
    end
  end
  return fm
end

---Discover skills under each of `dirs` (one `<dir>/<name>/SKILL.md` per skill).
---When `namespaces[dir]` is set (a plugin-provided dir), discovered names are qualified
---as `<namespace>:<name>` to match Claude Code's `<plugin>:<skill>` slash form; dirs absent
---from the map (user/project, OpenCode) yield unqualified names.
---@param dirs string[]
---@param namespaces? table<string, string> Map of dir path → plugin namespace.
---@return AgentComplete.Skill[]
function M.skills(dirs, namespaces)
  namespaces = namespaces or {}
  local out = {}
  for _, dir in ipairs(dirs or {}) do
    if vim.fn.isdirectory(dir) == 1 then
      local ns = namespaces[dir]
      for name, kind in vim.fs.dir(dir) do
        if kind == "directory" then
          local skill_md = dir .. "/" .. name .. "/SKILL.md"
          if vim.fn.filereadable(skill_md) == 1 then
            local fm = read_frontmatter(skill_md)
            local base = fm.name or name
            local qualified = ns and (ns .. ":" .. base) or base
            table.insert(out, { name = qualified, description = fm.description, path = skill_md })
          end
        end
      end
    end
  end
  return out
end

---Discover command markdown files under each of `dirs`. Nested files are named
---by their path relative to the dir with `/` replaced by `:` (e.g. `git:commit`).
---@param dirs string[]
---@return AgentComplete.Command[]
function M.commands(dirs)
  local out = {}
  for _, dir in ipairs(dirs or {}) do
    if vim.fn.isdirectory(dir) == 1 then
      for relpath, kind in vim.fs.dir(dir, { depth = 32 }) do
        if kind == "file" and relpath:match "%.md$" then
          local name = relpath:gsub("%.md$", ""):gsub("/", ":")
          local fm = read_frontmatter(dir .. "/" .. relpath)
          table.insert(out, { name = name, description = fm.description, path = dir .. "/" .. relpath })
        end
      end
    end
  end
  return out
end

---List files under `cwd` as paths relative to it. Prefers `git ls-files`
---(gitignore-aware) inside a work-tree; otherwise a bounded recursive scandir
---that skips dotfiles and dot-directories.
---@param cwd string
---@return string[]
function M.files(cwd)
  local probe = vim.fn.systemlist { "git", "-C", cwd, "rev-parse", "--is-inside-work-tree" }
  if vim.v.shell_error == 0 and probe[1] == "true" then
    local tracked = vim.fn.systemlist { "git", "-C", cwd, "ls-files", "--cached", "--others", "--exclude-standard" }
    if vim.v.shell_error == 0 then
      return tracked
    end
  end
  local files = {}
  for relpath, kind in vim.fs.dir(cwd, { depth = 32 }) do
    if kind == "file" and not relpath:match "^%." and not relpath:match "/%." then
      table.insert(files, relpath)
    end
  end
  return files
end

---Resolve Claude Code's config home (honors `$CLAUDE_CONFIG_DIR`).
---@return string
local function claude_home()
  local base = vim.env.CLAUDE_CONFIG_DIR
  if not base or base == "" then
    base = vim.fn.expand "~/.claude"
  end
  return base
end

---Resolve a plugin's namespace (the `<plugin>` Claude Code uses to qualify its skills).
---Authoritative source is the plugin's `<installPath>/.claude-plugin/plugin.json` `name`;
---if that is unreadable, fall back to the `installed_plugins.json` key's `<plugin>` prefix
---(the substring before `@<marketplace>`).
---@param install_path string
---@param key string The `installed_plugins.json` entry key (`<plugin>@<marketplace>`).
---@return string
local function plugin_name(install_path, key)
  local manifest = install_path .. "/.claude-plugin/plugin.json"
  if vim.fn.filereadable(manifest) == 1 then
    local ok, data = pcall(function()
      return vim.json.decode(table.concat(vim.fn.readfile(manifest), "\n"))
    end)
    if ok and type(data) == "table" and type(data.name) == "string" and data.name ~= "" then
      return data.name
    end
  end
  return (key:match "^(.-)@") or key
end

---Every enabled plugin, read from `<home>/plugins/installed_plugins.json`
---(`{ plugins = { "<name>@<mp>" = { { installPath } } } }`). This is the authoritative source
---for enabled plugins; a `marketplaces/*` glob would over-include disabled plugins and duplicate
---cached versions. Each record carries the plugin's `name` (its namespace) alongside its install
---path. Missing/garbled file ⇒ `{}`.
---@param home string
---@return { name: string, path: string }[]
local function enabled_plugin_roots(home)
  local roots = {}
  local file = home .. "/plugins/installed_plugins.json"
  if vim.fn.filereadable(file) == 0 then
    return roots
  end
  local ok, data = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(file), "\n"))
  end)
  if not ok or type(data) ~= "table" or type(data.plugins) ~= "table" then
    return roots
  end
  for key, records in pairs(data.plugins) do
    if type(key) == "string" and type(records) == "table" then
      for _, record in ipairs(records) do
        if type(record) == "table" and type(record.installPath) == "string" and record.installPath ~= "" then
          table.insert(roots, { name = plugin_name(record.installPath, key), path = record.installPath })
        end
      end
    end
  end
  return roots
end

---Order-preserving de-duplication of a path list.
---@param list string[]
---@return string[]
local function dedup(list)
  local seen, out = {}, {}
  for _, v in ipairs(list) do
    if not seen[v] then
      seen[v] = true
      out[#out + 1] = v
    end
  end
  return out
end

---Skill and command search dirs for a Claude Code session rooted at `cwd`:
---global (`<home>/{skills,commands}`), each enabled plugin's `<installPath>/{skills,commands}`,
---then project-local `<cwd>/.claude/{skills,commands}`. The lists are de-duplicated so a path
---reached two ways (e.g. claude launched from `~` ⇒ global == project-local, or a plugin
---listed at two scopes) does not double its completions. Absent dirs are harmless —
---`M.skills`/`M.commands` skip them. The third return is a `skill-dir path → plugin namespace`
---map so plugin skills complete as `<plugin>:<skill>` (matching Claude Code's slash form);
---global/project skill dirs are absent from the map and stay unqualified.
---@param cwd string
---@return string[] skill_dirs
---@return string[] command_dirs
---@return table<string, string> skill_namespaces
function M.claude_dirs(cwd)
  local home = claude_home()
  local skill_dirs = { home .. "/skills" }
  local command_dirs = { home .. "/commands" }
  local namespaces = {}
  for _, plugin in ipairs(enabled_plugin_roots(home)) do
    local skill_dir = plugin.path .. "/skills"
    table.insert(skill_dirs, skill_dir)
    table.insert(command_dirs, plugin.path .. "/commands")
    namespaces[skill_dir] = plugin.name
  end
  table.insert(skill_dirs, cwd .. "/.claude/skills")
  table.insert(command_dirs, cwd .. "/.claude/commands")
  return dedup(skill_dirs), dedup(command_dirs), namespaces
end

---OpenCode's config base directories for a session rooted at `cwd`: the global config
---home (`$XDG_CONFIG_HOME/opencode`, else `~/.config/opencode`), an optional extra base from
---`$OPENCODE_CONFIG_DIR`, and the project-local `<cwd>/.opencode`.
---@param cwd string
---@return string[]
local function opencode_config_dirs(cwd)
  local xdg = vim.env.XDG_CONFIG_HOME
  local global = (xdg and xdg ~= "") and (xdg .. "/opencode") or vim.fn.expand "~/.config/opencode"
  local bases = { global }
  local extra = vim.env.OPENCODE_CONFIG_DIR
  if extra and extra ~= "" then
    table.insert(bases, extra)
  end
  table.insert(bases, cwd .. "/.opencode")
  return bases
end

---Skill and command search dirs for an OpenCode session rooted at `cwd`. OpenCode keeps skills
---under `<base>/{skill,skills}/<name>/SKILL.md` and markdown commands under `<base>/command`,
---across the global config home, an optional `$OPENCODE_CONFIG_DIR`, and the project-local
---`<cwd>/.opencode`. `M.skills` discovers one level deep (`<base>/{skill,skills}/<name>/SKILL.md`,
---the same depth used for Claude), so OpenCode's deeper `**/SKILL.md` skill nesting is not found;
---`M.commands` recurses. Config-defined commands (the `opencode.json[c]` `command` map) are
---discovered separately by `M.opencode_commands`. Lists are de-duplicated so a base reached two
---ways (e.g. cwd's `.opencode` also set as `$OPENCODE_CONFIG_DIR`) is not doubled.
---@param cwd string
---@return string[] skill_dirs
---@return string[] command_dirs
function M.opencode_dirs(cwd)
  local skill_dirs, command_dirs = {}, {}
  for _, base in ipairs(opencode_config_dirs(cwd)) do
    table.insert(skill_dirs, base .. "/skill")
    table.insert(skill_dirs, base .. "/skills")
    table.insert(command_dirs, base .. "/command")
  end
  return dedup(skill_dirs), dedup(command_dirs)
end

---Strip `//` line and `/* */` block comments and trailing commas from a JSONC string
---so `vim.json.decode` can parse it. Single pass and string-aware: literals (including
---escapes) are copied verbatim, so a `//`, `/*`, or `,]` inside a value is never touched.
---A comma is buffered and only emitted once a following non-comment, non-whitespace token
---proves it isn't trailing — a `,` directly before `]`/`}` is dropped.
---@param s string
---@return string
local function strip_jsonc(s)
  local out, i, n, in_str = {}, 1, #s, false
  local pending_comma = false
  local function flush_comma()
    if pending_comma then
      out[#out + 1] = ","
      pending_comma = false
    end
  end
  while i <= n do
    local c = s:sub(i, i)
    if in_str then
      out[#out + 1] = c
      if c == "\\" then
        out[#out + 1] = s:sub(i + 1, i + 1) -- copy the escaped char verbatim
        i = i + 2
      else
        if c == '"' then
          in_str = false
        end
        i = i + 1
      end
    elseif c == '"' then
      flush_comma()
      in_str = true
      out[#out + 1] = c
      i = i + 1
    elseif c == "/" and s:sub(i + 1, i + 1) == "/" then
      local nl = s:find("\n", i)
      i = nl or (n + 1)
    elseif c == "/" and s:sub(i + 1, i + 1) == "*" then
      local close = s:find("*/", i + 2, true)
      i = close and (close + 2) or (n + 1)
    elseif c == "," then
      flush_comma() -- a prior comma followed by this one isn't trailing
      pending_comma = true
      i = i + 1
    elseif c == "}" or c == "]" then
      pending_comma = false -- drop the trailing comma
      out[#out + 1] = c
      i = i + 1
    elseif c:match "%s" then
      out[#out + 1] = c -- whitespace doesn't resolve a pending comma
      i = i + 1
    else
      flush_comma()
      out[#out + 1] = c
      i = i + 1
    end
  end
  flush_comma()
  return table.concat(out)
end

---OpenCode config files to read for config-defined commands: an explicit
---`$OPENCODE_CONFIG` file, the global config home's `opencode.json[c]`, and the
---project-root `opencode.json[c]`. Walk-up ancestors are not searched.
---@param cwd string
---@return string[]
local function opencode_config_files(cwd)
  local files = {}
  local explicit = vim.env.OPENCODE_CONFIG
  if explicit and explicit ~= "" then
    files[#files + 1] = explicit
  end
  local xdg = vim.env.XDG_CONFIG_HOME
  local home = (xdg and xdg ~= "") and (xdg .. "/opencode") or vim.fn.expand "~/.config/opencode"
  for _, base in ipairs { home, cwd } do
    files[#files + 1] = base .. "/opencode.json"
    files[#files + 1] = base .. "/opencode.jsonc"
  end
  return files
end

---Config-defined commands for an OpenCode session: the `command` map in
---`opencode.json` / `opencode.jsonc` (a name → spec table, whose `description` is
---surfaced). Complements the markdown command files discovered via `opencode_dirs`.
---De-duplicated by name (first file wins). A missing or malformed file is skipped.
---@param cwd string
---@return AgentComplete.Command[]
function M.opencode_commands(cwd)
  local out, seen = {}, {}
  for _, file in ipairs(opencode_config_files(cwd)) do
    if vim.fn.filereadable(file) == 1 then
      local ok, data = pcall(function()
        return vim.json.decode(strip_jsonc(table.concat(vim.fn.readfile(file), "\n")))
      end)
      if ok and type(data) == "table" and type(data.command) == "table" then
        for name, spec in pairs(data.command) do
          if type(name) == "string" and not seen[name] then
            seen[name] = true
            local desc = type(spec) == "table" and spec.description or nil
            out[#out + 1] = { name = name, description = desc, path = file }
          end
        end
      end
    end
  end
  return out
end

---OpenCode's built-in TUI slash commands. These are compiled into OpenCode, so they live
---in neither the command markdown files nor the `opencode.json` command map that the other
---OpenCode discovery helpers read — without this static list they never appear in completion.
---The list is hard-coded from the OpenCode TUI commands docs (https://opencode.ai/docs/tui#commands).
---`hidden = true` marks interactive TUI affordances — dialogs, pickers, display toggles, app
---navigation/lifecycle, and the external-editor command itself — that are not useful when
---composing a prompt in an editor buffer; `sources.items` filters them out unless the user opts
---in. Commands that perform a discrete action on the conversation/session are shown by default.
---@return AgentComplete.Command[]
function M.opencode_builtin_commands()
  return {
    { name = "compact", description = "Compact the current session." },
    { name = "connect", description = "Add a provider to OpenCode.", hidden = true },
    { name = "details", description = "Toggle tool execution details.", hidden = true },
    { name = "editor", description = "Open external editor for composing messages.", hidden = true },
    { name = "exit", description = "Exit OpenCode.", hidden = true },
    { name = "export", description = "Export the current conversation to Markdown." },
    { name = "help", description = "Show the help dialog.", hidden = true },
    { name = "init", description = "Guided setup for creating or updating AGENTS.md." },
    { name = "models", description = "List available models.", hidden = true },
    { name = "new", description = "Start a new session.", hidden = true },
    { name = "redo", description = "Redo a previously undone message." },
    { name = "sessions", description = "List and switch between sessions.", hidden = true },
    { name = "share", description = "Share the current session." },
    { name = "themes", description = "List available themes.", hidden = true },
    { name = "thinking", description = "Toggle visibility of thinking/reasoning blocks.", hidden = true },
    { name = "undo", description = "Undo the last message in the conversation." },
    { name = "unshare", description = "Unshare the current session." },
  }
end

return M
