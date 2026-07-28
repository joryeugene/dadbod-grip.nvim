-- view/sticky_header.lua: mirror the grid's column-name row into 'winbar'.
--
-- The header row scrolls off the top on any table taller than the window, which
-- leaves the cursor in an unlabelled column. A winbar stays put while the
-- buffer scrolls, so the header row is re-rendered there on every cursor move
-- and scroll. It does NOT follow the buffer's horizontal scroll, hence the
-- manual slice at the window's leftcol.

local ui = require("dadbod-grip.ui")

local M = {}

--- Build the 'winbar' value for a header row.
--- @param hdr_line string  header row exactly as rendered in the buffer
--- @param leftcol integer  window's horizontal scroll (display cells, 0-based)
--- @param width integer    display cells available to the winbar
--- @param active_bp table|nil  {start,finish} byte range of the cursor's column
---                             in hdr_line (0-based, finish inclusive), as
---                             render() records it in hdr_byte_positions
--- @param badges table|nil  list of {text,hl}, rendered right-aligned
--- @return string
function M.build(hdr_line, leftcol, width, active_bp, badges)
  -- Badges keep the right edge (that is where they already were before the
  -- header moved in), so they come off the header's budget first.
  local badge_str, badge_w = "", 0
  for _, b in ipairs(badges or {}) do
    badge_str = badge_str .. "%#" .. b.hl .. "#  " .. b.text
    badge_w = badge_w + 2 + vim.fn.strdisplaywidth(b.text)
  end
  width = math.max(0, width - badge_w)

  -- Split into (before, active, after) so the cursor's column can carry its own
  -- highlight group, then slice each piece in turn: a winbar has no extmarks,
  -- highlights are inline %#Group# tokens, so the slice has to be aware of them.
  local segments
  if active_bp then
    segments = {
      { text = hdr_line:sub(1, active_bp.start),                    hl = "GripHeader" },
      { text = hdr_line:sub(active_bp.start + 1, active_bp.finish + 1), hl = "GripHeaderActive" },
      { text = hdr_line:sub(active_bp.finish + 2),                  hl = "GripHeader" },
    }
  else
    segments = { { text = hdr_line, hl = "GripHeader" } }
  end

  local out, seg_start, used = {}, 0, 0
  for _, seg in ipairs(segments) do
    local dw = vim.fn.strdisplaywidth(seg.text)
    -- How far into this segment the visible window starts.
    local from = math.max(0, leftcol - seg_start)
    if from < dw and used < width then
      local piece = ui.slice_display(seg.text, from, width - used)
      if piece ~= "" then
        out[#out + 1] = "%#" .. seg.hl .. "#" .. piece:gsub("%%", "%%%%")
        used = used + vim.fn.strdisplaywidth(piece)
      end
    end
    seg_start = seg_start + dw
  end
  if badge_str ~= "" then
    return table.concat(out) .. "%=" .. badge_str .. "%*"
  end
  return table.concat(out) .. "%*"
end

--- Keep the winbar in step with the cursor's column and the window's scroll.
--- CursorMoved covers both in practice (horizontal scroll happens through
--- reveal_col_edge on column motions), WinScrolled catches <C-e>/<C-y>/zz and
--- mouse wheel, VimResized a changed window width.
function M.setup(bufnr, ctx)
  local update = ctx.update_winbar
  vim.api.nvim_create_autocmd({ "CursorMoved", "WinScrolled" }, {
    group  = ctx.augroup,
    buffer = bufnr,
    callback = function() update(bufnr) end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group    = ctx.augroup,
    callback = function()
      if vim.api.nvim_buf_is_valid(bufnr) then update(bufnr) end
    end,
  })
end

return M
