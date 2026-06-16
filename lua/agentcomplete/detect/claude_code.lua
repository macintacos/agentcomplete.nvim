---Claude Code detector.
---
---When Claude Code opens its prompt via `chat:externalEditor`, the editor it
---spawns inherits `CLAUDE_CODE_SESSION_ID`. The companion plugin's hooks write a
---per-session state file at `<cache>/agentcomplete/<session_id>.json`; its
---presence is what makes detection specific to "agentcomplete is installed for
---this session" rather than just "some Claude Code subprocess".
local M = { name = "claude-code" }

---Resolve the companion plugin's state directory (honors $XDG_CACHE_HOME).
---@return string
local function cache_dir()
  local base = vim.env.XDG_CACHE_HOME
  if not base or base == "" then
    base = vim.fn.expand "~/.cache"
  end
  return base .. "/agentcomplete"
end

---@param _bufnr integer
---@return AgentComplete.Session|nil
function M.detect(_bufnr)
  local sid = vim.env.CLAUDE_CODE_SESSION_ID
  if not sid or sid == "" then
    return nil
  end

  local state_file = cache_dir() .. "/" .. sid .. ".json"
  if vim.fn.filereadable(state_file) == 0 then
    return nil
  end

  -- The editor already inherits the project cwd; the state file's cwd (the
  -- session's working directory, refreshed by the companion hooks) is preferred
  -- when present.
  local cwd = vim.loop.cwd()
  local ok, data = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(state_file), "\n"))
  end)
  if ok and type(data) == "table" and type(data.cwd) == "string" and data.cwd ~= "" then
    cwd = data.cwd
  end

  local home_claude = vim.fn.expand "~/.claude"
  local proj_claude = cwd .. "/.claude"
  return {
    tool = "claude-code",
    cwd = cwd,
    session_id = sid,
    skill_dirs = { home_claude .. "/skills", proj_claude .. "/skills" },
    command_dirs = { home_claude .. "/commands", proj_claude .. "/commands" },
  }
end

return M
