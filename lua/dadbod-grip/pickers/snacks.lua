--- snacks.nvim adapter for grip_picker.open() opts shape.
--- Translates grip's {items, display, on_select, preview, on_delete}
--- into the Snacks.picker() API.

require("snacks")

local M = {}

function M.open(opts)
  local display_fn = opts.display or tostring
  local items = opts.items or {}

  local picker_opts = {
    source = "grip",
    title = opts.title or "Grip Picker",
    finder = function()
      local ret = {}
      for idx, item in ipairs(items) do
        ret[#ret + 1] = {
          idx = idx,
          text = display_fn(item),
          item = item,
        }
      end
      return ret
    end,
    format = function(picker_item)
      return { { picker_item.text } }
    end,
    actions = {
      confirm = function(picker, picker_item)
        picker:close()
        if picker_item and opts.on_select then
          vim.schedule(function()
            opts.on_select(picker_item.item)
          end)
        end
      end,
    },
  }

  if opts.preview then
    picker_opts.preview = function(ctx)
      local lines = opts.preview(ctx.item.item) or {}
      ctx.preview:set_lines(lines)
      ctx.preview:highlight({ ft = "sql" })
    end
  end

  if opts.on_delete then
    local delete_action = {
      "D",
      function(picker)
        local picker_item = picker:current()
        if not picker_item then return end
        opts.on_delete(picker_item.item, function()
          picker:close()
        end)
      end,
      desc = "Delete",
      mode = { "n" },
    }
    picker_opts.win = {
      input = { keys = { grip_delete = delete_action } },
      list = { keys = { grip_delete = delete_action } },
    }
  end

  Snacks.picker.pick(picker_opts)
end

return M
