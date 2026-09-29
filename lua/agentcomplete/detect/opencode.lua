---OpenCode detector.
---
---OpenCode opens its prompt via `/editor`: it writes the prompt to `<tmpdir>/<epoch-millis>.md`
---and opens that file in `$VISUAL`/`$EDITOR`. That name is not OpenCode-specific, so detection
---also requires evidence that OpenCode launched this Neovim: v1 exports `OPENCODE=1` (and
---`OPENCODE_PID`) to the editor, while v2 exports nothing, leaving an `opencode` process among
---Neovim's ancestors as the only signal. The cwd is OpenCode's project root, overridable via
---`$AGENTCOMPLETE_CWD` (per-launch) or `vim.g.agentcomplete_cwd` (static config).
local M = { name = "opencode" }

---@type integer|false|nil
local launcher

---The OpenCode process that launched this Neovim, or nil when none did. Looked up once: blink
---detects on every keystroke, and a process's launcher never changes.
---@return integer|nil
function M.launcher()
  if launcher == nil then
    launcher = require("agentcomplete.context.proc").find_ancestor(
      vim.loop.os_getppid(),
      "opencode",
      vim.fn.system
    ) or false
  end
  return launcher or nil
end

---Whether the buffer is OpenCode's external-editor prompt: its `<epoch-millis>.md` temp file, in
---a Neovim OpenCode launched. The name is checked first so other buffers never cost a `ps`.
---@param bufnr integer
---@return boolean
local function is_opencode_prompt(bufnr)
  local base = vim.api.nvim_buf_get_name(bufnr):match("[^/]+$") or ""
  if not base:match("^%d+%.md$") then
    return false
  end
  return vim.env.OPENCODE == "1" or M.launcher() ~= nil
end

---Resolve the project cwd: explicit override (env, then `vim.g`) else the editor cwd.
---@return string
local function resolve_cwd()
  local env = vim.env.AGENTCOMPLETE_CWD
  if env and env ~= "" then
    return env
  end
  if vim.g.agentcomplete_cwd and vim.g.agentcomplete_cwd ~= "" then
    return vim.g.agentcomplete_cwd
  end
  return vim.loop.cwd() or vim.fn.getcwd()
end

---@param bufnr integer
---@return AgentComplete.Session|nil
function M.detect(bufnr)
  if not is_opencode_prompt(bufnr) then
    return nil
  end
  local cwd = resolve_cwd()
  local scan = require("agentcomplete.scan")
  local skill_dirs, command_dirs = scan.opencode_dirs(cwd)
  -- Config-map commands first so a user's own command wins the name-dedup in `sources.items`
  -- over a built-in of the same name; OpenCode's built-in TUI commands fill in the rest.
  local extra_commands = scan.opencode_commands(cwd)
  vim.list_extend(extra_commands, scan.opencode_builtin_commands())
  -- OpenCode's authoritative skill and command sets, resolved asynchronously from its running
  -- server (config is read at call-time, mirroring backends/blink.lua, because setup() replaces
  -- the config wholesale). Opt-out via `opencode.resolve_via_cli = false`. The first detect
  -- kicks off the background jobs and returns the empty cache; later detects read the result.
  -- The lists are handed over by reference, not copied, because the jobs fill them in place
  -- after this returns.
  local extra_skills, cli_commands
  local oc_config = require("agentcomplete").config.opencode or {}
  if oc_config.resolve_via_cli ~= false then
    local resolved = require("agentcomplete.opencode_cli").get(cwd)
    extra_skills, cli_commands = resolved.skills, resolved.commands
  end
  return {
    tool = "opencode",
    cwd = cwd,
    session_id = vim.env.OPENCODE_PID,
    agent_pid = tonumber(vim.env.OPENCODE_PID) or M.launcher(),
    skill_dirs = skill_dirs,
    command_dirs = command_dirs,
    extra_commands = extra_commands,
    cli_commands = cli_commands,
    extra_skills = extra_skills,
  }
end

return M
