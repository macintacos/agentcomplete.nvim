-- Tests for agentcomplete.layout: the widths `plan` computes, and the margins and spacer it
-- opens, sizes, and closes around a prompt window.
local MiniTest = require("mini.test")
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
    inset = 2,
  }, input))
end

T["plan"] = new_set()

T["plan"]["centers the message and the reply side by side at full measure"] = function()
  expect.equality(
    plan({ columns = 200 }),
    { beside = true, left = 15, right = 16, pane = 84, prompt = 82 }
  )
end

-- Between min_width and room for both at full measure, neither column is starved for the other.
T["plan"]["shares a width too narrow for both measures evenly"] = function()
  local p = plan({ columns = 160 })
  expect.equality(p, { beside = true, left = 1, right = 1, pane = 78, prompt = 77 })
  -- Text either side of the pane's frame and the prompt's inset.
  expect.equality({ p.pane - 4, p.prompt - 2 }, { 74, 75 })
end

-- Stacked, the prompt shares the pane's column, so the column is the pane's frame wide and the
-- prompt's inset lines its text up with the message's.
T["plan"]["centers one column for the thread below min_width"] = function()
  expect.equality(
    plan({ columns = 120 }),
    { beside = false, left = 17, right = 17, prompt = 84 }
  )
end

T["plan"]["centers the prompt alone when there is no pane"] = function()
  expect.equality(
    plan({ columns = 200, pane = false }),
    { beside = false, left = 58, right = 58, prompt = 82 }
  )
end

T["plan"]["narrows the column to the terminal, keeping a column of margin either side"] = function()
  expect.equality(
    plan({ columns = 80 }),
    { beside = false, left = 1, right = 1, prompt = 76 }
  )
end

-- Without margins the prompt is not the layout's to size: only the pane gets a width.
T["plan"]["sizes only the pane when there are no margins"] = function()
  expect.equality(plan({ columns = 200, margins = false }), { beside = true, pane = 84 })
  expect.equality(plan({ columns = 120, margins = false }), { beside = false })
end

T["plan"]["never gives the pane more than half the terminal without margins"] = function()
  expect.equality(
    plan({ columns = 160, measure = 100, margins = false }),
    { beside = true, pane = 79 }
  )
end

T["box"] = new_set()

T["box"]["centers a prompt of the minimum height"] = function()
  expect.equality(
    require("agentcomplete.layout").box(36, 1, 10),
    { top = 13, prompt = 10, bottom = 13 }
  )
end

T["box"]["grows with the prompt's text, staying centered"] = function()
  expect.equality(
    require("agentcomplete.layout").box(36, 15, 10),
    { top = 10, prompt = 15, bottom = 11 }
  )
end

T["box"]["stops growing a row short of either edge"] = function()
  expect.equality(
    require("agentcomplete.layout").box(36, 50, 10),
    { top = 1, prompt = 34, bottom = 1 }
  )
end

T["frame"] = new_set()

-- The top edge covers the row above the prompt; the bottom sits a row out, so the prompt's own
-- statusline stays inside the frame.
T["frame"]["draws a rounded border right above the prompt"] = function()
  local frame =
    require("agentcomplete.layout").frame({ row = 10, col = 20, width = 4, height = 2 })
  local side = { "│", "│", "│" }
  expect.equality(
    frame.top,
    { row = 9, col = 19, width = 6, height = 1, lines = { "╭────╮" } }
  )
  expect.equality(frame.left, { row = 10, col = 19, width = 1, height = 3, lines = side })
  expect.equality(
    frame.right,
    { row = 10, col = 24, width = 1, height = 3, lines = side }
  )
  expect.equality(
    frame.bottom,
    { row = 13, col = 19, width = 6, height = 1, lines = { "╰────╯" } }
  )
end

T["windows"] = new_set({
  hooks = {
    pre_case = function()
      vim.cmd("silent! only")
    end,
    post_case = function()
      local layout = require("agentcomplete.layout")
      for buf in pairs(layout._layouts) do
        layout.detach(buf)
      end
      vim.cmd("silent! only")
      vim.o.columns = 80
      vim.o.lines = 24
    end,
  },
})

---A prompt buffer, focused, with a layout attached. `opts` overrides the default options.
local function attached(opts)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  require("agentcomplete.layout").attach(
    buf,
    vim.tbl_extend("force", { measure = 80, margins = true, inset = 2 }, opts or {})
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

---The windows in the prompt's column, top to bottom: the first column in the top-level row.
local function prompt_column()
  for _, node in
    ipairs(vim.fn.winlayout()[2] --[[@as table]])
  do
    if node[1] == "col" then
      return vim.tbl_map(function(leaf)
        return leaf[2]
      end, node[2])
    end
  end
  return {}
end

---The heights of the windows in the prompt's column, top to bottom.
local function column_heights()
  return vim.tbl_map(vim.api.nvim_win_get_height, prompt_column())
end

T["windows"]["holds the prompt at the measure between margins"] = function()
  vim.o.columns = 200
  local _, host = attached()
  expect.equality(row_widths(), { 58, 82, 58 })
  expect.equality(prompt_column()[2], host)
end

T["windows"]["boxes the prompt in the middle of the screen when there is no pane"] = function()
  vim.o.columns, vim.o.lines = 200, 40
  attached()
  expect.equality(column_heights(), { 13, 10, 13 })
end

T["windows"]["grows the box with the prompt's text"] = function()
  vim.o.columns, vim.o.lines = 200, 40
  local buf = attached()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(string.rep("line\n", 14), "\n"))
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
  expect.equality(column_heights(), { 10, 15, 11 })
end

-- The winbar is the composer's row of padding above the text, and takes a row of the window.
T["windows"]["fits the box to the text below a winbar"] = function()
  vim.o.columns, vim.o.lines = 200, 40
  local buf, host = attached()
  vim.wo[host][0].winbar = " "
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(string.rep("line\n", 14), "\n"))
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
  expect.equality(column_heights(), { 10, 16, 10 })
end

-- A terminal shrunk and grown again scrolls the prompt to keep its cursor in view, and growing
-- the window back does not scroll it back.
T["windows"]["shows the prompt from its first line whenever it all fits"] = function()
  vim.o.columns, vim.o.lines = 200, 40
  local buf, host = attached()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(string.rep("line\n", 14), "\n"))
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
  vim.api.nvim_win_set_cursor(host, { 15, 0 })
  vim.fn.winrestview({ topline = 8 })
  vim.api.nvim_exec_autocmds("VimResized", {})
  expect.equality(vim.fn.line("w0", host), 1)
end

---The floating windows on screen.
---@return integer[]
local function floats()
  return vim.tbl_filter(function(win)
    return vim.api.nvim_win_get_config(win).relative ~= ""
  end, vim.api.nvim_tabpage_list_wins(0))
end

T["windows"]["frames the box, and follows it as it grows"] = function()
  vim.o.columns, vim.o.lines = 200, 40
  local buf = attached()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(string.rep("line\n", 14), "\n"))
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
  local frame = floats()
  local heights = vim.tbl_map(vim.api.nvim_win_get_height, frame)
  table.sort(heights)
  expect.equality(heights, { 1, 1, 16, 16 })
  for _, win in ipairs(frame) do
    expect.equality(vim.api.nvim_win_get_config(win).focusable, false)
    expect.equality(vim.wo[win].winhighlight, "Normal:FloatBorder")
  end
end

-- So a plugin drawing over windows, such as a filename label, can leave the box alone.
T["windows"]["marks the prompt's window while it is boxed"] = function()
  vim.o.columns = 200
  local _, host = attached()
  expect.equality(vim.w[host].agentcomplete_box, true)
end

T["windows"]["tints the box against the margins"] = function()
  vim.o.columns = 200
  local _, host = attached()
  expect.equality(
    vim.wo[host].winhighlight,
    "Normal:AgentCompletePrompt,WinBar:AgentCompletePrompt,WinBarNC:AgentCompletePrompt"
  )
  expect.equality(
    vim.api.nvim_get_hl(0, { name = "AgentCompletePrompt" }).link,
    "NormalFloat"
  )
end

T["windows"]["boxes the prompt beside a pane that runs the full height"] = function()
  vim.o.columns, vim.o.lines = 200, 40
  local buf, host = attached()
  local spacer = assert(require("agentcomplete.layout").reserve(buf, PLACEMENT))
  expect.equality(column_heights(), { 13, 10, 13 })
  expect.equality(vim.api.nvim_win_get_height(spacer), 38)
  expect.equality(
    vim.wo[host].winhighlight,
    "Normal:AgentCompletePrompt,WinBar:AgentCompletePrompt,WinBarNC:AgentCompletePrompt"
  )
end

T["windows"]["opens no margins around a prompt sharing the screen"] = function()
  vim.o.columns = 200
  vim.cmd("vsplit")
  attached()
  expect.equality(#vim.api.nvim_tabpage_list_wins(0), 2)
end

T["windows"]["opens no margins when not asked to"] = function()
  vim.o.columns = 200
  attached({ margins = false })
  expect.equality(#vim.api.nvim_tabpage_list_wins(0), 1)
end

T["windows"]["reserves the pane's room to the left of the prompt when wide"] = function()
  vim.o.columns = 200
  local buf, host = attached()
  local spacer = require("agentcomplete.layout").reserve(buf, PLACEMENT)
  expect.equality(row_widths(), { 15, 84, 82, 16 })
  expect.equality({ vim.fn.winlayout()[2][2][2], prompt_column()[2] }, { spacer, host })
end

T["windows"]["stacks the pane's room in the prompt's column when narrow"] = function()
  vim.o.columns = 120
  local buf, host = attached()
  local spacer = require("agentcomplete.layout").reserve(buf, PLACEMENT)
  local column = prompt_column()
  expect.equality({ #column, column[1], column[3] }, { 4, spacer, host })
  expect.equality(row_widths(), { 17, 84, 17 })
  expect.equality(column_heights(), { 11, 1, 6, 1 })
end

-- Stacked below, the pane's split is the next window down from the box's bottom margin.
T["windows"]["grows the box without taking rows from a pane stacked below it"] = function()
  vim.o.columns, vim.o.lines = 120, 60
  local buf = attached()
  local placement = { min_width = 160, stacked = "below" }
  local spacer = assert(require("agentcomplete.layout").reserve(buf, placement))
  local height = vim.api.nvim_win_get_height(spacer)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(string.rep("line\n", 14), "\n"))
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
  expect.equality(prompt_column()[4], spacer)
  expect.equality(vim.api.nvim_win_get_height(spacer), height)
end

T["windows"]["re-places the pane and the margins when the terminal is resized"] = function()
  vim.o.columns = 200
  local buf = attached()
  require("agentcomplete.layout").reserve(buf, PLACEMENT)
  vim.o.columns = 120
  vim.api.nvim_exec_autocmds("VimResized", {})
  expect.equality(row_widths(), { 17, 84, 17 })
  vim.o.columns = 200
  vim.api.nvim_exec_autocmds("VimResized", {})
  expect.equality(row_widths(), { 15, 84, 82, 16 })
end

T["windows"]["keeps the prompt boxed as the pane restacks"] = function()
  vim.o.columns = 200
  local buf, host = attached()
  local spacer = require("agentcomplete.layout").reserve(buf, PLACEMENT)
  vim.o.columns = 120
  vim.api.nvim_exec_autocmds("VimResized", {})
  local column = prompt_column()
  expect.equality({ #column, column[1], column[3] }, { 4, spacer, host })
  vim.o.columns = 200
  vim.api.nvim_exec_autocmds("VimResized", {})
  expect.equality(vim.fn.winlayout()[2][2], { "leaf", spacer })
  expect.equality(prompt_column()[2], host)
end

T["windows"]["gives the pane's room back when it is released"] = function()
  vim.o.columns = 200
  local buf, host = attached()
  local layout = require("agentcomplete.layout")
  local spacer = assert(layout.reserve(buf, PLACEMENT), "no spacer reserved")
  layout.release(buf)
  expect.equality(vim.api.nvim_win_is_valid(spacer), false)
  expect.equality(row_widths(), { 58, 82, 58 })
  expect.equality(prompt_column()[2], host)
end

T["windows"]["sizes the pane beside a prompt with no margins"] = function()
  vim.o.columns = 200
  local buf = attached({ margins = false })
  require("agentcomplete.layout").reserve(buf, PLACEMENT)
  expect.equality(row_widths(), { 84, 115 })
end

T["windows"]["hands the cursor back to the prompt from a margin"] = function()
  vim.o.columns = 200
  local _, host = attached()
  vim.cmd("wincmd l")
  expect.equality(vim.api.nvim_get_current_win(), host)
  vim.cmd("wincmd h")
  expect.equality(vim.api.nvim_get_current_win(), host)
  vim.cmd("wincmd k")
  expect.equality(vim.api.nvim_get_current_win(), host)
  vim.cmd("wincmd j")
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

-- `:close`, `<C-w>c`, `:bdelete` close the window without the quit `QuitPre` announces. Left
-- behind, the margins would be the only windows, each locked to its blank buffer.
T["windows"]["leaves no margins behind when the prompt window is closed"] = function()
  vim.o.columns = 200
  local _, host = attached()
  pcall(vim.api.nvim_command, "close")
  expect.equality(vim.api.nvim_tabpage_list_wins(0), { host })
end

T["windows"]["leaves no margins behind when the prompt buffer is deleted"] = function()
  vim.o.columns = 200
  local buf = attached()
  pcall(vim.api.nvim_command, "bwipeout! " .. buf)
  vim.wait(100)
  local wins = vim.api.nvim_tabpage_list_wins(0)
  expect.equality(#wins, 1)
  expect.equality(vim.wo[wins[1]].winfixbuf, false)
end

-- A split copies the window options of the one it splits from.
T["windows"]["draws nothing of the prompt's own on the margins' empty lines"] = function()
  vim.o.columns = 200
  vim.wo.list = true
  vim.wo.colorcolumn = "10"
  attached()
  local margin = vim.fn.win_getid(1)
  expect.equality({ vim.wo[margin].list, vim.wo[margin].colorcolumn }, { false, "" })
end

-- An empty local winbar falls back to a global one, which would draw its row in each margin.
T["windows"]["blanks a global winbar in the margins"] = function()
  vim.o.columns = 200
  vim.go.winbar = "%f"
  attached()
  local margin = vim.fn.win_getid(1)
  vim.go.winbar = ""
  expect.equality(
    vim.api.nvim_get_option_value("winbar", { win = margin, scope = "local" }),
    " "
  )
  expect.equality(
    vim.wo[margin].winhighlight:find("WinBar:AgentCompleteMargin", 1, true) ~= nil,
    true
  )
end

T["windows"]["closes everything it opened on detach"] = function()
  vim.o.columns = 200
  local buf, host = attached()
  local layout = require("agentcomplete.layout")
  layout.reserve(buf, PLACEMENT)
  layout.detach(buf)
  expect.equality(vim.api.nvim_tabpage_list_wins(0), { host })
end

T["windows"]["closes its windows when the prompt buffer is wiped"] = function()
  vim.o.columns = 200
  local buf = attached()
  vim.cmd("botright new")
  vim.api.nvim_buf_delete(buf, { force = true })
  local layout = require("agentcomplete.layout")
  vim.wait(500, function()
    return layout._layouts[buf] == nil
  end)
  expect.equality(#vim.api.nvim_tabpage_list_wins(0), 1)
  expect.equality(layout._layouts[buf], nil)
end

T["windows"]["hides the margins' separators, statuslines and end-of-buffer rows"] = function()
  vim.o.columns = 200
  attached()
  local margin = vim.fn.win_getid(1)
  expect.equality(
    vim.wo[margin].winhighlight:find("WinSeparator:AgentCompleteMargin", 1, true) ~= nil,
    true
  )
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
