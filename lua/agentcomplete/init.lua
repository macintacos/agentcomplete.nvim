---@class AgentComplete.Config
---@field enabled boolean Whether the completion sources are active.

---@class AgentComplete
local M = {}

---Default configuration.
---@type AgentComplete.Config
M.config = {
  enabled = true,
}

---Set up agentcomplete.nvim.
---@param opts? table User configuration overrides (see AgentComplete.Config).
---@return AgentComplete
function M.setup(opts)
  ---@type AgentComplete.Config
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  return M
end

return M
