---Filesystem discovery of skills, commands, and files for completion.
---
---Pure of any Neovim editor state — every function takes explicit paths and
---returns plain tables, so the whole module is exercised under headless tests.
---@class AgentComplete.Scan
local M = {}

---@class AgentComplete.Skill
---@field name string Skill name (frontmatter `name`, else the directory name).
---@field description string|nil Frontmatter `description`, if present.
---@field path string Absolute path to the SKILL.md.

---@class AgentComplete.Command
---@field name string Command name; nested files join path segments with `:`.
---@field description string|nil Frontmatter `description`, if present.
---@field path string Absolute path to the command markdown file.

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
---@param dirs string[]
---@return AgentComplete.Skill[]
function M.skills(dirs)
  local out = {}
  for _, dir in ipairs(dirs or {}) do
    if vim.fn.isdirectory(dir) == 1 then
      for name, kind in vim.fs.dir(dir) do
        if kind == "directory" then
          local skill_md = dir .. "/" .. name .. "/SKILL.md"
          if vim.fn.filereadable(skill_md) == 1 then
            local fm = read_frontmatter(skill_md)
            table.insert(out, { name = fm.name or name, description = fm.description, path = skill_md })
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

---Install paths of every enabled plugin, read from
---`<home>/plugins/installed_plugins.json` (`{ plugins = { "<name>@<mp>" = { { installPath } } } }`).
---This is the authoritative source for enabled plugins; a `marketplaces/*` glob would
---over-include disabled plugins and duplicate cached versions. Missing/garbled file ⇒ `{}`.
---@param home string
---@return string[]
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
  for _, records in pairs(data.plugins) do
    if type(records) == "table" then
      for _, record in ipairs(records) do
        if type(record) == "table" and type(record.installPath) == "string" and record.installPath ~= "" then
          table.insert(roots, record.installPath)
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
---listed at two scopes) does not double its completions. Names are unqualified (not
---`plugin:skill`-namespaced); matching Claude Code's exact slash-menu namespacing is a future
---refinement. Absent dirs are harmless — `M.skills`/`M.commands` skip them.
---@param cwd string
---@return string[] skill_dirs
---@return string[] command_dirs
function M.claude_dirs(cwd)
  local home = claude_home()
  local skill_dirs = { home .. "/skills" }
  local command_dirs = { home .. "/commands" }
  for _, root in ipairs(enabled_plugin_roots(home)) do
    table.insert(skill_dirs, root .. "/skills")
    table.insert(command_dirs, root .. "/commands")
  end
  table.insert(skill_dirs, cwd .. "/.claude/skills")
  table.insert(command_dirs, cwd .. "/.claude/commands")
  return dedup(skill_dirs), dedup(command_dirs)
end

return M
