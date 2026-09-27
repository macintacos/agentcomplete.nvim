---Where every window around a prompt buffer goes, and how big it is.
---
---The prompt stays a real window, so quitting it quits Neovim exactly as it always has. Around
---it sit blank splits: a margin on either side that holds the prompt at a readable measure, one
---above and one below that box it in the middle of the screen while there is no pane, and the
---spacer the context pane draws its message over. This module owns all of them, and is the one
---place that resizes any of them — two modules each answering the same resize would race.
---
---`M.plan` is the editor-state-free core the tests drive directly; the rest is the glue that
---applies a plan to windows.
---@class AgentComplete.Layout
local M = {}

---Columns the pane's frame adds around its text: a blank column either side, the border, and the
---pane's own two-column inset.
local PANE_FRAME = 6

---Rows the boxed prompt is never shorter than, however little it holds.
local BOX_HEIGHT = 10

---What every blank split turns off — a split copies the window options of the one it splits
---from, so anything the prompt draws on an empty line would be drawn here too. The highlight
---links make its separator, winbar, statusline and end-of-buffer rows read as the margin they
---are, rather than as an empty window. Not 'winfixwidth' here: a margin wants it, the spacer
---does not (see `M.reserve`).
local BLANK_OPTIONS = {
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  cursorline = false,
  cursorcolumn = false,
  colorcolumn = "",
  list = false,
  spell = false,
  statuscolumn = "",
  statusline = " ",
  fillchars = "eob: ,vert: ,horiz: ,horizup: ,horizdown: ,vertleft: ,vertright: ,verthoriz: ",
  winhighlight = table.concat({
    "Normal:AgentCompleteMargin",
    "EndOfBuffer:AgentCompleteMargin",
    "WinSeparator:AgentCompleteMargin",
    "WinBar:AgentCompleteMargin",
    "WinBarNC:AgentCompleteMargin",
    "StatusLine:AgentCompleteMargin",
    "StatusLineNC:AgentCompleteMargin",
  }, ","),
  winfixbuf = true,
}

---@class AgentComplete.Layout.Input
---@field columns integer Terminal width.
---@field measure integer Columns of text the prompt and the message each wrap at.
---@field min_width integer Terminal width at or above which the pane sits beside the prompt.
---@field pane boolean Whether the pane is open.
---@field margins boolean Whether the prompt is held at the measure between margins.
---@field inset integer Columns the prompt's own inset takes before its text.

---@class AgentComplete.Layout.Plan
---@field beside boolean Whether the pane sits beside the prompt rather than stacked with it.
---@field left? integer Left margin's width, when there are margins.
---@field right? integer Right margin's width, when there are margins.
---@field pane? integer Spacer's width, when the pane sits beside the prompt.
---@field prompt? integer Prompt window's width, when there are margins; stacked, the column's.

---Widths for every window around the prompt. With margins the content is centered and never
---wider than the measure; beside, the message and the reply share the width evenly once there
---is not room for both at full measure. Without margins only the pane is sized, and the prompt
---keeps whatever is left.
---@param input AgentComplete.Layout.Input
---@return AgentComplete.Layout.Plan
function M.plan(input)
  local columns, measure = input.columns, input.measure
  local beside = input.pane and columns >= input.min_width
  local frame = measure + PANE_FRAME
  if not input.margins then
    return { beside = beside, pane = beside and math.min(frame, math.floor((columns - 1) / 2)) or nil }
  end
  -- A margin is at least a column wide and draws a separator: four columns content never gets.
  local room = columns - 4
  local pane, prompt
  if beside then
    pane, prompt = frame, measure + input.inset
    if pane + 1 + prompt > room then
      pane = math.floor((room - 1 - PANE_FRAME - input.inset) / 2) + PANE_FRAME
      prompt = room - 1 - pane
    end
  else
    prompt = math.min(input.pane and frame or measure + input.inset, room)
  end
  local free = columns - 2 - prompt - (pane and pane + 1 or 0)
  local left = math.max(1, math.floor(free / 2))
  return { beside = beside, left = left, right = math.max(1, free - left), pane = pane, prompt = math.max(1, prompt) }
end

---@class AgentComplete.Layout.Heights
---@field top integer
---@field prompt integer
---@field bottom integer

---Heights for the prompt boxed in the middle of its column: as tall as its text but never under
---`min`, centered, and a row short of either edge.
---@param rows integer Rows the top margin, the prompt and the bottom margin share.
---@param content integer Rows the prompt's text takes at its width.
---@param min integer
---@return AgentComplete.Layout.Heights
function M.box(rows, content, min)
  local prompt = math.max(1, math.min(math.max(content, min), rows - 2))
  local top = math.max(1, math.floor((rows - prompt) / 2))
  return { top = top, prompt = prompt, bottom = math.max(1, rows - prompt - top) }
end

---@class AgentComplete.Layout.Options
---@field measure integer Columns of text the prompt and the message each wrap at.
---@field margins boolean Whether to hold the prompt at the measure between margins.
---@field inset integer Columns the prompt's own inset takes before its text.

---@class AgentComplete.Layout.Placement
---@field min_width integer Terminal width at or above which the pane sits beside the prompt.
---@field stacked "above"|"below" Edge of the prompt the pane takes below that width.

---@class AgentComplete.Layout.Box
---@field top integer Margin above the prompt.
---@field bottom integer Margin below it.
---@field winhighlight string The prompt's local 'winhighlight' from before the box tinted it.

---@class AgentComplete.Layout.State
---@field host integer Window showing the prompt.
---@field opts AgentComplete.Layout.Options
---@field group integer Augroup the layout's autocmds live in.
---@field left? integer Left margin.
---@field right? integer Right margin.
---@field box? AgentComplete.Layout.Box While the prompt is boxed: between margins, with no pane.
---@field spacer? integer Split the pane draws over.
---@field placement? AgentComplete.Layout.Placement How the spacer is placed, while there is one.
---@field beside? boolean Where the spacer sits now.
---@field arranging? boolean Set while `arrange` resizes, which raises the events that call it.

---@type table<integer, AgentComplete.Layout.State>
M._layouts = {}

---Define the margin and box highlight groups. `default = true` so a user's own `nvim_set_hl`
---wins; the links survive a colorscheme's `:hi clear`, as `highlight.ensure_groups` explains.
local function ensure_groups()
  vim.api.nvim_set_hl(0, "AgentCompleteMargin", { link = "Normal", default = true })
  vim.api.nvim_set_hl(0, "AgentCompletePrompt", { link = "NormalFloat", default = true })
end

---A blank split on `split` edge of `host`, holding a throwaway buffer.
---@param host integer
---@param split "left"|"right"|"above"|"below"
---@return integer
local function blank(host, split)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local win = vim.api.nvim_open_win(buf, false, { split = split, win = host })
  for option, value in pairs(BLANK_OPTIONS) do
    vim.wo[win][option] = value
  end
  -- An empty local winbar falls back to a global one, so that is blanked rather than emptied.
  vim.wo[win].winbar = vim.go.winbar == "" and "" or " "
  return win
end

---@param win integer|nil
---@return boolean
local function valid(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

---Whether `win` is the only non-floating window in its tabpage. Margins frame the whole screen,
---which is only the prompt's to take when nothing else is on it.
---@param win integer
---@return boolean
local function alone(win)
  for _, other in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(win))) do
    if other ~= win and vim.api.nvim_win_get_config(other).relative == "" then
      return false
    end
  end
  return true
end

---@param win integer
---@param value string
local function set_winhighlight(win, value)
  vim.api.nvim_set_option_value("winhighlight", value, { win = win, scope = "local" })
end

---Box the prompt in the middle of its column, tinted so it reads as a box against the margins.
---@param state AgentComplete.Layout.State
local function open_box(state)
  local winhighlight = vim.api.nvim_get_option_value("winhighlight", { win = state.host, scope = "local" })
  state.box = { top = blank(state.host, "above"), bottom = blank(state.host, "below"), winhighlight = winhighlight }
  -- The separator is left the margins' colour so the box's right edge meets the padding row's.
  local tint = "Normal:AgentCompletePrompt,WinSeparator:AgentCompleteMargin"
  set_winhighlight(state.host, winhighlight == "" and tint or (winhighlight .. "," .. tint))
  -- The top margin's statusline is the row above the prompt: tinted, it pads the box's top edge.
  -- A later entry overrides an earlier one for the same group.
  local top = state.box.top
  vim.wo[top].winhighlight = vim.wo[top].winhighlight
    .. ",StatusLine:AgentCompletePrompt,StatusLineNC:AgentCompletePrompt"
end

---Give the box's rows back to the prompt's column, and the prompt its own highlights.
---@param state AgentComplete.Layout.State
local function close_box(state)
  local box = state.box
  if not box then
    return
  end
  state.box = nil
  for _, win in ipairs { box.top, box.bottom } do
    pcall(vim.api.nvim_win_close, win, true)
  end
  if valid(state.host) then
    set_winhighlight(state.host, box.winhighlight)
  end
end

---Size the box to the prompt's text at the width it has just been given. Only the margins are
---set: the prompt is the one window between them, so it takes the rows they leave.
---@param box AgentComplete.Layout.Box
---@param host integer
local function fit_box(box, host)
  local height = vim.api.nvim_win_get_height
  local rows = height(box.top) + height(host) + height(box.bottom)
  local content = vim.api.nvim_win_text_height(host, {}).all
  local heights = M.box(rows, content, BOX_HEIGHT)
  vim.api.nvim_win_set_height(box.top, heights.top)
  vim.api.nvim_win_set_height(box.bottom, heights.bottom)
  if content > heights.prompt then
    return
  end
  -- A window shrunk under its text scrolls to keep the cursor in view, and growing it back does
  -- not always scroll back, which would leave the fitted text part-hidden above empty rows.
  vim.api.nvim_win_call(host, function()
    local view = vim.fn.winsaveview()
    if view.topline > 1 or view.skipcol > 0 then
      vim.fn.winrestview { topline = 1, skipcol = 0 }
    end
  end)
end

---Resize every window around the prompt for the terminal as it is now. The margins and the
---spacer are set explicitly and the prompt last, so whatever a resize took from one is given
---back to the one it was meant for.
---@param buf integer
function M.arrange(buf)
  local state = M._layouts[buf]
  if not state or state.arranging or not valid(state.host) then
    return
  end
  state.arranging = true
  -- Guarded so a raise mid-resize cannot leave the flag set and the layout frozen where it is.
  pcall(function()
    local plan = M.plan {
      columns = vim.o.columns,
      measure = state.opts.measure,
      min_width = state.placement and state.placement.min_width or 0,
      pane = valid(state.spacer),
      margins = valid(state.left),
      inset = state.opts.inset,
    }
    if valid(state.spacer) and plan.beside ~= state.beside then
      state.beside = plan.beside
      local split = plan.beside and "left" or state.placement.stacked
      vim.api.nvim_win_set_config(state.spacer, { split = split, win = state.host })
    end
    if plan.left then
      vim.api.nvim_win_set_width(state.left, plan.left)
      vim.api.nvim_win_set_width(state.right, plan.right)
    end
    if plan.pane then
      vim.api.nvim_win_set_width(state.spacer, plan.pane)
    end
    if plan.prompt then
      vim.api.nvim_win_set_width(state.host, plan.prompt)
    end
    if state.box then
      fit_box(state.box, state.host)
    end
  end)
  state.arranging = false
end

---Close both margins and let the prompt take their room. Every route out of a margin ends here:
---they frame the prompt as a pair, and one alone would only push it off center.
---@param buf integer
local function dismiss_margins(buf)
  local state = M._layouts[buf]
  if not state or not (state.left or state.right) then
    return
  end
  close_box(state)
  local left, right = state.left, state.right
  state.left, state.right = nil, nil
  for _, win in ipairs { left, right } do
    pcall(vim.api.nvim_win_close, win, true)
  end
  M.arrange(buf)
end

---Open the margins around `state.host` and wire the ways out of them.
---@param buf integer
---@param state AgentComplete.Layout.State
local function open_margins(buf, state)
  state.left = blank(state.host, "left")
  state.right = blank(state.host, "right")
  -- The prompt is the one window a resize should grow or shrink; the margins are set by `arrange`.
  vim.wo[state.left].winfixwidth = true
  vim.wo[state.right].winfixwidth = true
  -- The prompt's own window too, synchronously: closed without a quit (`:close`, `:bdelete`) it
  -- would otherwise leave the margins as the only windows, each locked to its blank buffer.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = state.group,
    pattern = { tostring(state.left), tostring(state.right), tostring(state.host) },
    callback = function()
      dismiss_margins(buf)
    end,
  })
  -- A margin holds nothing to read or edit, so landing in one — a `<C-w>` move, a mouse click —
  -- lands back in the prompt.
  vim.api.nvim_create_autocmd("WinEnter", {
    group = state.group,
    callback = function()
      local current, box = vim.api.nvim_get_current_win(), state.box
      local margin = current == state.left
        or current == state.right
        or (box ~= nil and (current == box.top or current == box.bottom))
      if margin and valid(state.host) then
        vim.api.nvim_set_current_win(state.host)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    group = state.group,
    buffer = buf,
    callback = function()
      M.arrange(buf)
    end,
  })
  -- Before the quit resolves, so the prompt is left the last window and `:q` leaves Neovim
  -- rather than a margin with nothing in it.
  vim.api.nvim_create_autocmd("QuitPre", {
    group = state.group,
    buffer = buf,
    callback = function()
      dismiss_margins(buf)
    end,
  })
  open_box(state)
end

---Take over the layout around `buf`'s window. Idempotent per buffer, and a no-op when the buffer
---is on no screen. Margins are opened only when `opts.margins` asks and the prompt's window is
---the only one there: wrapping a screen of the user's own splits would take it over.
---@param buf integer
---@param opts AgentComplete.Layout.Options
function M.attach(buf, opts)
  local host = vim.fn.bufwinid(buf)
  if M._layouts[buf] or host == -1 then
    return
  end
  ensure_groups()
  local group = vim.api.nvim_create_augroup("AgentCompleteLayout_" .. buf, { clear = true })
  local state = { host = host, opts = opts, group = group }
  M._layouts[buf] = state
  if opts.margins and alone(host) then
    open_margins(buf, state)
  end
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = group,
    callback = function()
      M.arrange(buf)
    end,
  })
  -- Deferred: closing a window from inside the autocmd that announces its buffer is going away
  -- is refused by Neovim.
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = group,
    buffer = buf,
    callback = function()
      vim.schedule(function()
        M.detach(buf)
      end)
    end,
  })
  M.arrange(buf)
end

---Open the split the context pane draws over, placed and sized for the terminal as it is now.
---Not 'winfixwidth': stacked, it shares the prompt's column, and a fixed window there would fix
---the whole column's width against the margins.
---@param buf integer
---@param placement AgentComplete.Layout.Placement
---@return integer|nil spacer nil when `buf` has no layout, or its window no longer shows it.
function M.reserve(buf, placement)
  local state = M._layouts[buf]
  if not state or not valid(state.host) or vim.api.nvim_win_get_buf(state.host) ~= buf then
    return nil
  end
  local plan = M.plan {
    columns = vim.o.columns,
    measure = state.opts.measure,
    min_width = placement.min_width,
    pane = true,
    margins = valid(state.left),
    inset = state.opts.inset,
  }
  close_box(state)
  state.spacer = blank(state.host, plan.beside and "left" or placement.stacked)
  state.placement, state.beside = placement, plan.beside
  M.arrange(buf)
  return state.spacer
end

---Close the pane's spacer and give its room back, boxing the prompt again between its margins.
---@param buf integer
function M.release(buf)
  local state = M._layouts[buf]
  if not state or not state.spacer then
    return
  end
  local spacer = state.spacer
  state.spacer, state.placement, state.beside = nil, nil, nil
  pcall(vim.api.nvim_win_close, spacer, true)
  if valid(state.left) and valid(state.host) then
    open_box(state)
  end
  M.arrange(buf)
end

---Close every window the layout opened and forget the buffer.
---@param buf integer
function M.detach(buf)
  local state = M._layouts[buf]
  if not state then
    return
  end
  M._layouts[buf] = nil
  pcall(vim.api.nvim_del_augroup_by_id, state.group)
  close_box(state)
  -- Keyed, because any of the three may be nil and `ipairs` would stop there.
  for _, win in pairs { spacer = state.spacer, left = state.left, right = state.right } do
    pcall(vim.api.nvim_win_close, win, true)
  end
end

return M
