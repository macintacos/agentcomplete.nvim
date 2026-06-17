---Per-tool detector registry.
---
---Each agent CLI (Claude Code today; OpenCode/Codex later) registers a detector
---with a uniform interface, and Neovim calls `detect()` the same way regardless
---of which tool launched it. Adding a new tool means registering another
---detector — nothing else in the plugin changes.
---@class AgentComplete.Detect
local M = {}

---@class AgentComplete.Session
---@field tool string Identifier of the detecting tool (e.g. "claude-code").
---@field cwd string The agent's project working directory.
---@field session_id string|nil Tool session id, when available.
---@field skill_dirs string[] Directories this tool keeps skills in.
---@field command_dirs string[] Directories this tool keeps commands in.
---@field extra_commands? AgentComplete.Command[] Tool-specific commands appended to those discovered from `command_dirs` (e.g. OpenCode's `opencode.json[c]` config-map commands).
---@field sources? { slash: boolean, file: boolean } Enabled source toggles (set by the orchestrator; both on if absent).
---@field show_all_builtin_commands? boolean When false/absent, built-in commands tagged `hidden` are filtered out of completion (set by the orchestrator from config).

---@class AgentComplete.Detector
---@field name string
---@field detect fun(bufnr: integer): AgentComplete.Session|nil Non-nil ⇒ "this buffer is mine".

---@type AgentComplete.Detector[]
M.detectors = {}

---Register a detector. Order is significant: the first match wins.
---@param detector AgentComplete.Detector
function M.register(detector)
  table.insert(M.detectors, detector)
end

---Remove all registered detectors.
function M.clear()
  M.detectors = {}
end

---Run detectors in registration order; return the first session produced.
---A detector that throws is skipped rather than aborting detection.
---@param bufnr integer
---@return AgentComplete.Session|nil
function M.detect(bufnr)
  for _, detector in ipairs(M.detectors) do
    local ok, session = pcall(detector.detect, bufnr)
    if ok and session then
      return session
    end
  end
  return nil
end

return M
