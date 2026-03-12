-- telescope.lua: telescope.nvim adapter for grip_picker.open() opts shape.
-- Translates grip's {items, display, on_select, preview, on_delete} into
-- telescope's pickers.new / finders / previewers / actions API.

require("telescope.pickers")

local M = {}

function M.open(opts)
  local pickers    = require("telescope.pickers")
  local finders    = require("telescope.finders")
  local conf       = require("telescope.config").values
  local actions    = require("telescope.actions")
  local act_state  = require("telescope.actions.state")
  local previewers = require("telescope.previewers")

  local display_fn = opts.display or tostring
  local items      = opts.items or {}

  local previewer = nil
  if opts.preview then
    previewer = previewers.new_buffer_previewer({
      title = "Preview",
      define_preview = function(self, entry)
        local lines = opts.preview(entry.value) or {}
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
      end,
    })
  end

  pickers.new({}, {
    prompt_title = opts.title or "Grip Picker",
    finder = finders.new_table({
      results = items,
      entry_maker = function(item)
        local text = display_fn(item)
        return {
          value   = item,
          display = text,
          ordinal = text,
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    previewer = previewer,
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local entry = act_state.get_selected_entry()
        if entry and opts.on_select then
          opts.on_select(entry.value)
        end
      end)

      if opts.on_delete then
        map("n", "D", function()
          local entry = act_state.get_selected_entry()
          if not entry then return end
          opts.on_delete(entry.value, function()
            actions.close(prompt_bufnr)
          end)
        end)
      end

      return true
    end,
  }):find()
end

return M
