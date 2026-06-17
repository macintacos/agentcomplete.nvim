--- @module 'blink.cmp'

---blink.cmp v2 source adapter.
---
---The source self-gates via the detector registry (`enabled`/`get_completions`
---only produce items in a detected buffer), so a user registers it once and it
---stays dormant elsewhere. Items are returned UNFILTERED — blink.cmp does the
---fuzzy filtering against `filterText` — and replacement uses an explicit
---`textEdit` range so file paths containing `/` complete correctly.
---
---`kind` is mapped through `vim.lsp.protocol.CompletionItemKind` (the same
---integers blink uses) so this module loads even when blink is not installed.
---@class AgentComplete.Backend.Blink
local M = {}

local sources = require "agentcomplete.sources"
local CIK = vim.lsp.protocol.CompletionItemKind

local KIND = { skill = CIK.Module, command = CIK.Keyword, file = CIK.File }

---Pure: build blink completion items for a line + cursor (row/col 0-based).
---@param session AgentComplete.Session
---@param line string
---@param row integer 0-based line number
---@param col integer 0-based byte cursor column
---@return { items: table[] }
function M.build(session, line, row, col)
  local ctx = sources.context(line, col)
  if not ctx then
    return { items = {} }
  end
  -- query="" → return everything for the trigger; blink filters via filterText.
  local all = sources.items(session, { trigger = ctx.trigger, query = "", start_col = ctx.start_col })
  local items = {}
  for _, it in ipairs(all) do
    table.insert(items, {
      label = it.label,
      filterText = it.insert_text,
      detail = it.detail,
      kind = KIND[it.kind],
      textEdit = {
        newText = it.insert_text,
        range = {
          start = { line = row, character = ctx.start_col },
          ["end"] = { line = row, character = col },
        },
      },
    })
  end
  return { items = items }
end

-- ── source suppression: make agentcomplete the only source in detected buffers ──

---Pure: compute the constrained source list and the dropped (unregistered) names.
---`agentcomplete` is always first; each `allowed` entry is kept only if it is a
---registered blink provider, so suppression can re-permit but never register.
---@param allowed string[] Source ids the user opted back in via `allowed_sources`.
---@param registered table<string, any> Blink's `sources.providers` (keys are provider ids).
---@return string[] effective `{ "agentcomplete", <registered allowed ids> }`.
---@return string[] dropped Allowed ids that are not registered providers.
function M.constrain(allowed, registered)
  local effective = { "agentcomplete" }
  local dropped = {}
  for _, id in ipairs(allowed) do
    if id ~= "agentcomplete" then
      if registered[id] ~= nil then
        table.insert(effective, id)
      else
        table.insert(dropped, id)
      end
    end
  end
  return effective, dropped
end

---Pure: resolve a wrapped blink source-list value for one completion.
---In a detected buffer the constrained list wins outright; otherwise the user's
---original value is returned untouched (evaluated first when it is a function,
---matching blink's own `type(...) == "function"` handling).
---@param original string[]|fun(): string[] Blink's original `default`/`per_filetype` value.
---@param effective string[] The constrained list from `M.constrain`.
---@param is_detected boolean Whether the current buffer is a detected prompt buffer.
---@return string[]
function M.resolve_sources(original, effective, is_detected)
  if is_detected then
    return effective
  end
  if type(original) == "function" then
    return original()
  end
  return original
end

---Glue: is the current buffer a detected prompt buffer? Stubbed in tests.
---@return boolean
function M._detected()
  local detect = require "agentcomplete.detect"
  return detect.detect(vim.api.nvim_get_current_buf()) ~= nil
end

---Resolve blink's live config module, or nil when blink is not installed.
---@return table|nil
local function blink_config()
  local ok, cfg = pcall(require, "blink.cmp.config")
  if not ok then
    return nil
  end
  return cfg
end

---Originals captured by the active wrap, so they can be restored exactly.
---@class AgentComplete.Backend.Blink.Saved
---@field default string[]|fun(): string[]
---@field per_filetype table<string, any>

---@type AgentComplete.Backend.Blink.Saved?
M._installed = nil

---Wrap blink's global `sources.default` and `per_filetype` entries so detected
---buffers resolve to agentcomplete only (plus registered `allowed_sources`),
---while every other buffer keeps the user's original lists. This mutates blink's
---global config by design (the v1 API has no per-buffer config); the wrap is
---behaviour-preserving for non-detected buffers and requires `setup()` to run
---after `blink.cmp.setup()`. Idempotent: a prior wrap is restored first so a
---re-run re-captures pristine originals. Returns false (no-op) when blink is
---absent or `agentcomplete` is not a registered provider.
---@param config { allowed_sources?: string[] }
---@param bcfg? table Injected blink config (tests); defaults to require "blink.cmp.config".
---@param detected_fn? fun(): boolean Detection predicate (tests); defaults to `M._detected`.
---@return boolean installed
function M.install_suppression(config, bcfg, detected_fn)
  bcfg = bcfg or blink_config()
  if not bcfg then
    return false
  end
  M.uninstall_suppression(bcfg)
  detected_fn = detected_fn or M._detected

  local registered = bcfg.sources.providers or {}
  if registered["agentcomplete"] == nil then
    vim.notify(
      "agentcomplete: blink source 'agentcomplete' is not registered; cannot suppress other sources (see README)",
      vim.log.levels.WARN
    )
    return false
  end

  local effective, dropped = M.constrain(config.allowed_sources or {}, registered)
  if #dropped > 0 then
    vim.notify(
      "agentcomplete: ignoring unregistered allowed_sources: " .. table.concat(dropped, ", "),
      vim.log.levels.WARN
    )
  end

  local orig_default = bcfg.sources.default
  ---@type AgentComplete.Backend.Blink.Saved
  local saved = { default = orig_default, per_filetype = {} }
  bcfg.sources.default = function()
    return M.resolve_sources(orig_default, effective, detected_fn())
  end
  for ft, entry in pairs(bcfg.sources.per_filetype) do
    saved.per_filetype[ft] = entry
    bcfg.sources.per_filetype[ft] = function()
      return M.resolve_sources(entry, effective, detected_fn())
    end
  end
  M._installed = saved
  return true
end

---Restore the source lists captured by the last `install_suppression`.
---@param bcfg? table Injected blink config (tests); defaults to require "blink.cmp.config".
function M.uninstall_suppression(bcfg)
  if not M._installed then
    return
  end
  bcfg = bcfg or blink_config()
  if bcfg then
    bcfg.sources.default = M._installed.default
    for ft, entry in pairs(M._installed.per_filetype) do
      bcfg.sources.per_filetype[ft] = entry
    end
  end
  M._installed = nil
end

-- ── blink.cmp source interface (thin glue; exercised via manual verification) ──

---@param opts table|nil
function M.new(opts)
  return setmetatable({ opts = opts or {} }, { __index = M })
end

function M:enabled()
  local detect = require "agentcomplete.detect"
  return detect.detect(vim.api.nvim_get_current_buf()) ~= nil
end

function M:get_trigger_characters()
  return { "/", "@" }
end

function M:get_completions(ctx, callback)
  local detect = require "agentcomplete.detect"
  local buf = (ctx and ctx.bufnr) or vim.api.nvim_get_current_buf()
  local session = detect.detect(buf)
  if not session then
    callback { items = {}, is_incomplete_backward = false, is_incomplete_forward = false }
    return
  end
  session.sources = require("agentcomplete").config.sources
  local cur = vim.api.nvim_win_get_cursor(0)
  local row = (ctx and ctx.cursor and ctx.cursor[1] or cur[1]) - 1
  local col = (ctx and ctx.cursor and ctx.cursor[2]) or cur[2]
  local line = (ctx and ctx.line) or vim.api.nvim_get_current_line()
  local res = M.build(session, line, row, col)
  callback { items = res.items, is_incomplete_backward = true, is_incomplete_forward = true }
end

return M
