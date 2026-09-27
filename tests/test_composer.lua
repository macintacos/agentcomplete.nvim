-- Tests for agentcomplete.composer: the prompt window's options, applied, held against plugins
-- that re-set them, and restored.
local MiniTest = require "mini.test"
local new_set = MiniTest.new_set
local expect = MiniTest.expect

local T = new_set {
  hooks = {
    pre_case = function()
      vim.cmd "silent! only"
    end,
    post_case = function()
      local composer = require "agentcomplete.composer"
      for buf in pairs(composer._composers) do
        composer.detach(buf)
      end
      vim.cmd "silent! only"
    end,
  },
}

---A prompt buffer, focused, in a window with a code buffer's gutter.
local function prompt()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  local win = vim.api.nvim_get_current_win()
  vim.wo[win][0].number = true
  vim.wo[win][0].relativenumber = true
  vim.wo[win][0].winbar = "%f"
  return buf, win
end

T["fillchars"] = new_set()

T["fillchars"]["blanks the separators and end-of-buffer rows after the window's own"] = function()
  local merged = require("agentcomplete.composer").fillchars "fold:x,eob:~"
  expect.equality(vim.startswith(merged, "fold:x,eob:~,eob: ,vert: "), true)
end

T["fillchars"]["stands alone when the window has none of its own"] = function()
  expect.equality(vim.startswith(require("agentcomplete.composer").fillchars "", "eob: ,"), true)
end

T["attach"] = new_set()

T["attach"]["drops the gutter and wraps prose inside an inset"] = function()
  local buf, win = prompt()
  require("agentcomplete.composer").attach(buf)
  expect.equality(vim.wo[win].number, false)
  expect.equality(vim.wo[win].relativenumber, false)
  expect.equality(vim.wo[win].signcolumn, "no")
  expect.equality(vim.wo[win].cursorline, false)
  expect.equality(vim.wo[win].winbar, "")
  expect.equality(vim.wo[win].statuscolumn, "    ")
  expect.equality({ vim.wo[win].wrap, vim.wo[win].linebreak, vim.wo[win].breakindent }, { true, true, true })
end

T["attach"]["keeps the window's other fill characters"] = function()
  vim.o.fillchars = "fold:x"
  local buf, win = prompt()
  require("agentcomplete.composer").attach(buf)
  local fcs = vim.api.nvim_win_call(win, function()
    return vim.opt_local.fillchars:get()
  end)
  vim.o.fillchars = ""
  expect.equality({ fcs.fold, fcs.eob, fcs.vert }, { "x", " ", " " })
end

T["attach"]["leaves the statusline alone"] = function()
  local buf, win = prompt()
  vim.wo[win][0].statusline = "mine"
  require("agentcomplete.composer").attach(buf)
  expect.equality(vim.wo[win].statusline, "mine")
end

-- dropbar re-attaches its winbar on every write, from whichever window is current.
T["attach"]["takes the winbar back off when a plugin sets it again"] = function()
  local buf, win = prompt()
  require("agentcomplete.composer").attach(buf)
  vim.cmd "vsplit"
  vim.wo[win].winbar = "%{%v:lua.dropbar()%}"
  expect.equality(vim.wo[win].winbar, "")
end

-- dropbar re-attaches from inside its own `BufWritePost` handler, where `OptionSet` never fires:
-- autocmds do not nest.
T["attach"]["takes the winbar back off when a plugin sets it from its own autocmd"] = function()
  local buf, win = prompt()
  local grp = vim.api.nvim_create_augroup("AgentCompleteComposerDropbarTest", { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = grp,
    callback = function()
      vim.wo[win][0].winbar = "%{%v:lua.dropbar()%}"
    end,
  })
  require("agentcomplete.composer").attach(buf)
  vim.api.nvim_exec_autocmds("BufWritePost", { buffer = buf })
  vim.api.nvim_del_augroup_by_id(grp)
  vim.wait(100, function()
    return vim.wo[win].winbar == ""
  end)
  expect.equality(vim.wo[win].winbar, "")
end

-- A user who sets the number column in the prompt meant to.
T["attach"]["lets the number column be turned back on"] = function()
  local buf, win = prompt()
  require("agentcomplete.composer").attach(buf)
  vim.wo[win][0].number = true
  expect.equality(vim.wo[win].number, true)
end

T["attach"]["holds nothing on another window"] = function()
  local buf = prompt()
  require("agentcomplete.composer").attach(buf)
  vim.cmd "vnew"
  vim.wo.winbar = "other"
  expect.equality(vim.wo.winbar, "other")
end

T["attach"]["is idempotent, so a second attach cannot save its own values as the user's"] = function()
  local buf, win = prompt()
  local composer = require "agentcomplete.composer"
  composer.attach(buf)
  composer.attach(buf)
  composer.detach(buf)
  expect.equality(vim.wo[win].number, true)
end

T["detach"] = new_set()

T["detach"]["restores the window's own options"] = function()
  local buf, win = prompt()
  local composer = require "agentcomplete.composer"
  composer.attach(buf)
  composer.detach(buf)
  expect.equality({ vim.wo[win].number, vim.wo[win].relativenumber, vim.wo[win].winbar }, { true, true, "%f" })
  expect.equality(vim.wo[win].statuscolumn, "")
  expect.equality(vim.api.nvim_get_option_value("fillchars", { win = win, scope = "local" }), "")
end

T["detach"]["stops holding the winbar"] = function()
  local buf, win = prompt()
  local composer = require "agentcomplete.composer"
  composer.attach(buf)
  composer.detach(buf)
  vim.wo[win].winbar = "back"
  expect.equality(vim.wo[win].winbar, "back")
end

T["detach"]["forgets a buffer that was wiped"] = function()
  local buf = prompt()
  local composer = require "agentcomplete.composer"
  composer.attach(buf)
  vim.cmd "vnew"
  vim.api.nvim_buf_delete(buf, { force = true })
  expect.equality(composer._composers[buf], nil)
end

return T
