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
