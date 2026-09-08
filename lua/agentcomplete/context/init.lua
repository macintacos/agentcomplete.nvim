---Per-tool resolver registry for the agent's last message.
---
---Mirrors `agentcomplete.detect`: each agent CLI registers a resolver, and the caller asks
---for the last message the same way regardless of which tool launched it. Resolution is
---callback-shaped because a resolver may have to ask the tool's own CLI for the answer;
---the Claude Code one happens to finish synchronously, and reports through `cb` anyway so
---an asynchronous sibling drops in without changing the contract.
---@class AgentComplete.Context
local M = {}

---@class AgentComplete.Context.Result
---@field ok boolean Whether the message was resolved.
---@field resolver string Name of the resolver that reported.
---@field text? string The agent's last message, when `ok`.
---@field session_id? string Session the message was read from, when `ok`.
---@field transcript? string File the message was read from, when `ok`.
---@field err? string Why resolution failed, when not `ok`.

---@class AgentComplete.Context.Resolver
---@field name string
---@field resolve fun(session: AgentComplete.Session, cb: fun(result: AgentComplete.Context.Result), opts?: table): true|nil Non-nil ⇒ "this session is mine", and `cb` reports the outcome.

---@type AgentComplete.Context.Resolver[]
M.resolvers = {}

---Register a resolver. Order is significant: the first to claim a session wins.
---@param resolver AgentComplete.Context.Resolver
function M.register(resolver)
  table.insert(M.resolvers, resolver)
end

---Remove all registered resolvers.
function M.clear()
  M.resolvers = {}
end

---Offer `session` to each resolver in registration order until one claims it.
---A resolver that throws is skipped rather than aborting the walk.
---@param session AgentComplete.Session
---@param cb fun(result: AgentComplete.Context.Result)
---@return string|nil name The claiming resolver, or nil when none took the session.
function M.resolve(session, cb)
  for _, resolver in ipairs(M.resolvers) do
    local ok, claimed = pcall(resolver.resolve, session, cb)
    if ok and claimed then
      return resolver.name
    end
  end
  return nil
end

return M
