-- Tests for agentcomplete.layout: the widths `plan` computes, and the margins and spacer it
-- opens, sizes, and closes around a prompt window.
local MiniTest = require "mini.test"
local new_set = MiniTest.new_set
local expect = MiniTest.expect

local T = new_set()

---A plan for the default measure and inset, overridden by `input`.
local function plan(input)
  return require("agentcomplete.layout").plan(vim.tbl_extend("force", {
    measure = 80,
    min_width = 160,
    pane = true,
    margins = true,
    inset = 4,
  }, input))
end

T["plan"] = new_set()

T["plan"]["centers the message and the reply side by side at full measure"] = function()
  expect.equality(plan { columns = 200 }, { beside = true, left = 13, right = 14, pane = 86, prompt = 84 })
end

-- Between min_width and room for both at full measure, neither column is starved for the other.
T["plan"]["shares a width too narrow for both measures evenly"] = function()
  local p = plan { columns = 160 }
  expect.equality(p, { beside = true, left = 1, right = 1, pane = 78, prompt = 77 })
  -- Text either side of the pane's frame and the prompt's inset.
  expect.equality({ p.pane - 6, p.prompt - 4 }, { 72, 73 })
end

-- Stacked, the prompt shares the pane's column, so the column is the pane's frame wide and the
-- prompt's inset lines its text up with the message's.
T["plan"]["centers one column for the thread below min_width"] = function()
  expect.equality(plan { columns = 120 }, { beside = false, left = 16, right = 16, prompt = 86 })
end

T["plan"]["centers the prompt alone when there is no pane"] = function()
  expect.equality(plan { columns = 200, pane = false }, { beside = false, left = 57, right = 57, prompt = 84 })
end

T["plan"]["narrows the column to the terminal, keeping a column of margin either side"] = function()
  expect.equality(plan { columns = 80 }, { beside = false, left = 1, right = 1, prompt = 76 })
end

-- Without margins the prompt is not the layout's to size: only the pane gets a width.
T["plan"]["sizes only the pane when there are no margins"] = function()
  expect.equality(plan { columns = 200, margins = false }, { beside = true, pane = 86 })
  expect.equality(plan { columns = 120, margins = false }, { beside = false })
end

T["plan"]["never gives the pane more than half the terminal without margins"] = function()
  expect.equality(plan { columns = 160, measure = 100, margins = false }, { beside = true, pane = 79 })
end

T["windows"] = new_set {
  hooks = {
    pre_case = function()
      vim.cmd "silent! only"
    end,
    post_case = function()
      local layout = require "agentcomplete.layout"
      for buf in pairs(layout._layouts) do
        layout.detach(buf)
      end
      vim.cmd "silent! only"
      vim.o.columns = 80
    end,
  },
}

---A prompt buffer, focused, with a layout attached. `opts` overrides the default options.
local function attached(opts)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  require("agentcomplete.layout").attach(
    buf,
    vim.tbl_extend("force", { measure = 80, margins = true, inset = 4 }, opts or {})
  )
  return buf, vim.api.nvim_get_current_win()
end

local PLACEMENT = { min_width = 160, stacked = "above" }

---The widths of the windows in the top-level row, left to right.
local function row_widths()
  local widths = {}
  for _, node in
    ipairs(vim.fn.winlayout()[2] --[[@as table]])
  do
    -- A stacked column is as wide as its first window.
    local win = node[1] == "leaf" and node[2] or node[2][1][2]
    widths[#widths + 1] = vim.api.nvim_win_get_width(win)
  end
  return widths
end

T["windows"]["holds the prompt at the measure between margins"] = function()
  vim.o.columns = 200
  local _, host = attached()
  expect.equality(row_widths(), { 57, 84, 57 })
  expect.equality(vim.fn.winlayout()[2][2][2], host)
end

T["windows"]["opens no margins around a prompt sharing the screen"] = function()
  vim.o.columns = 200
  vim.cmd "vsplit"
  attached()
  expect.equality(#vim.api.nvim_tabpage_list_wins(0), 2)
end

T["windows"]["opens no margins when not asked to"] = function()
  vim.o.columns = 200
  attached { margins = false }
  expect.equality(#vim.api.nvim_tabpage_list_wins(0), 1)
end

T["windows"]["reserves the pane's room to the left of the prompt when wide"] = function()
  vim.o.columns = 200
  local buf, host = attached()
  local spacer = require("agentcomplete.layout").reserve(buf, PLACEMENT)
  expect.equality(row_widths(), { 13, 86, 84, 14 })
  local row = vim.fn.winlayout()[2]
  expect.equality({ row[2][2], row[3][2] }, { spacer, host })
end

T["windows"]["stacks the pane's room in the prompt's column when narrow"] = function()
  vim.o.columns = 120
  local buf, host = attached()
  local spacer = require("agentcomplete.layout").reserve(buf, PLACEMENT)
  local column = vim.fn.winlayout()[2][2]
  expect.equality(column[1], "col")
  expect.equality({ column[2][1][2], column[2][2][2] }, { spacer, host })
  expect.equality(row_widths(), { 16, 86, 16 })
end

T["windows"]["re-places the pane and the margins when the terminal is resized"] = function()
  vim.o.columns = 200
  local buf = attached()
  require("agentcomplete.layout").reserve(buf, PLACEMENT)
  vim.o.columns = 120
  vim.api.nvim_exec_autocmds("VimResized", {})
  expect.equality(row_widths(), { 16, 86, 16 })
  vim.o.columns = 200
  vim.api.nvim_exec_autocmds("VimResized", {})
  expect.equality(row_widths(), { 13, 86, 84, 14 })
end

T["windows"]["gives the pane's room back when it is released"] = function()
  vim.o.columns = 200
  local buf = attached()
  local layout = require "agentcomplete.layout"
  local spacer = assert(layout.reserve(buf, PLACEMENT), "no spacer reserved")
  layout.release(buf)
  expect.equality(vim.api.nvim_win_is_valid(spacer), false)
  expect.equality(row_widths(), { 57, 84, 57 })
end

T["windows"]["sizes the pane beside a prompt with no margins"] = function()
  vim.o.columns = 200
  local buf = attached { margins = false }
  require("agentcomplete.layout").reserve(buf, PLACEMENT)
  expect.equality(row_widths(), { 86, 113 })
end

T["windows"]["hands the cursor back to the prompt from a margin"] = function()
  vim.o.columns = 200
  local _, host = attached()
  vim.cmd "wincmd l"
  expect.equality(vim.api.nvim_get_current_win(), host)
  vim.cmd "wincmd h"
  expect.equality(vim.api.nvim_get_current_win(), host)
end

-- The margins frame the prompt as a pair; one left behind would only push it off center.
T["windows"]["closes both margins when one is closed"] = function()
  vim.o.columns = 200
  local _, host = attached()
  vim.api.nvim_win_close(vim.fn.win_getid(1), true)
  expect.equality(vim.api.nvim_tabpage_list_wins(0), { host })
end

-- Quitting the prompt is how the agent CLI is answered, so the margins must be gone before that
-- quit resolves: either one still standing is a window Neovim stays open for.
T["windows"]["closes the margins before the prompt's quit resolves"] = function()
  vim.o.columns = 200
  local buf, host = attached()
  vim.api.nvim_exec_autocmds("QuitPre", { buffer = buf })
  expect.equality(vim.api.nvim_tabpage_list_wins(0), { host })
end

T["windows"]["closes everything it opened on detach"] = function()
  vim.o.columns = 200
  local buf, host = attached()
  local layout = require "agentcomplete.layout"
  layout.reserve(buf, PLACEMENT)
  layout.detach(buf)
  expect.equality(vim.api.nvim_tabpage_list_wins(0), { host })
end

T["windows"]["closes its windows when the prompt buffer is wiped"] = function()
  vim.o.columns = 200
  local buf = attached()
  vim.cmd "botright new"
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.wait(500, function()
    return #vim.api.nvim_tabpage_list_wins(0) == 1
  end)
  expect.equality(#vim.api.nvim_tabpage_list_wins(0), 1)
  expect.equality(require("agentcomplete.layout")._layouts[buf], nil)
end

T["windows"]["hides the margins' separators, statuslines and end-of-buffer rows"] = function()
  vim.o.columns = 200
  attached()
  local margin = vim.fn.win_getid(1)
  expect.equality(vim.wo[margin].winhighlight:find("WinSeparator:AgentCompleteMargin", 1, true) ~= nil, true)
  expect.equality(vim.wo[margin].statusline, " ")
  expect.equality(vim.wo[margin].fillchars:find("eob: ", 1, true) ~= nil, true)
  expect.equality(vim.api.nvim_get_hl(0, { name = "AgentCompleteMargin" }).link, "Normal")
end

T["windows"]["reserves nothing for a buffer it was never attached to"] = function()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  expect.equality(require("agentcomplete.layout").reserve(buf, PLACEMENT), nil)
end

return T
