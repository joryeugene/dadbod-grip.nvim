-- view/keymaps_results.lua: The live-result registry: pin and switcher.
-- Called by view._setup_keymaps() at a fixed position in KEYMAP_SECTIONS:
-- for a given lhs the last vim.keymap.set() wins, so that order is load
-- bearing.

local M = {}

--- The only two keys that look past this buffer at every other open grid:
--- pin/unpin (which the switcher sorts on) and the switcher itself.
function M.setup(bufnr, ctx)
  local update_winbar = ctx.update_winbar
  local kmap = ctx.kmap

  -- gL: pin / unpin this result (exclude from auto-reuse by query pad)
  kmap("grid_pin", function()
    local session = ctx.session()
    if not session then return end
    if not session.pinned then
      -- Check pinned_max cap before pinning
      local limit = require("dadbod-grip").get_opts().pinned_max
      if limit then
        local count = 0
        ctx.each_session(function(_, s)
          if s.pinned then count = count + 1 end
        end)
        if count >= limit then
          vim.notify(string.format("Pin limit reached (%d). Unpin a result first (gL).", limit), vim.log.levels.WARN)
          return
        end
      end
      session.pinned = true
      -- Append [pinned] to buffer name
      local cur_name = vim.api.nvim_buf_get_name(bufnr)
      if not cur_name:match("%[pinned%]") then
        pcall(vim.api.nvim_buf_set_name, bufnr, cur_name .. " [pinned]")
      end
      vim.notify("Result pinned (gL to unpin, gJ to switch)", vim.log.levels.INFO)
    else
      session.pinned = false
      -- Remove [pinned] suffix from buffer name
      local cur_name = vim.api.nvim_buf_get_name(bufnr)
      pcall(vim.api.nvim_buf_set_name, bufnr, cur_name:gsub("%s*%[pinned%]", ""))
      vim.notify("Result unpinned", vim.log.levels.INFO)
    end
    update_winbar(bufnr)
  end, "Pin/unpin result (exclude from auto-reuse)")

  -- gJ: result switcher: pick from all live grip grid sessions
  kmap("grid_results", function()
    local items = {}
    ctx.each_session(function(bnum, s)
      local win_id = nil
      for _, wid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_get_buf(wid) == bnum then
          win_id = wid
          break
        end
      end
      if not win_id then return end  -- bufhidden=wipe: no window means already wiped
      local name = vim.api.nvim_buf_get_name(bnum)
      local short = name:match("^grip://(.+)$") or name
      local rows = s.total_rows
      local row_label = rows and (" [" .. rows .. " rows]") or ""
      local pin_label = s.pinned and " [pinned]" or ""
      local elapsed = s.elapsed_ms and (" " .. s.elapsed_ms .. "ms") or ""
      table.insert(items, {
        bufnr   = bnum,
        win_id  = win_id,
        label   = short:gsub("%s*%[pinned%]", "") .. row_label .. elapsed .. pin_label,
        pinned  = s.pinned,
      })
    end)
    if #items == 0 then
      vim.notify("No open results", vim.log.levels.INFO)
      return
    end
    -- Sort: pinned first, then by bufnr descending (most recent)
    table.sort(items, function(a, b)
      if a.pinned ~= b.pinned then return a.pinned end
      return a.bufnr > b.bufnr
    end)
    require("dadbod-grip.grip_picker").open({
      title = "Results",
      items = items,
      display = function(item) return (item.pinned and "" or " ") .. " " .. item.label end,
      on_select = function(item)
        vim.api.nvim_set_current_win(item.win_id)
      end,
    })
  end, "Result switcher (all open results)")
end

return M
