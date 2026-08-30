-- view/keymaps_tab_view.lua: Tab view keymaps.
-- Called by view._setup_keymaps() at a fixed position in KEYMAP_SECTIONS:
-- for a given lhs the last vim.keymap.set() wins, so that order is load
-- bearing.

local qmod   = require("dadbod-grip.query")

local M = {}

--- Tab view keys 1-9 plus ER diagram, help and the command palette.
function M.setup(bufnr, ctx)
  local view = ctx.view
  local VIEW_LABELS = ctx.VIEW_LABELS
  local kmap, km = ctx.kmap, ctx.km

  -- 1: schema sidebar (already in grid = always primary: open/focus sidebar)
  kmap("tab_1", function()
    local _s = ctx.session()
    view.close_all_floats(_s)
    local s_url = _s and _s.url
    require("dadbod-grip.schema").toggle(s_url)
  end, "Schema sidebar (key 1)")

  -- 2: open query pad (pre-filled with current query)
  kmap("tab_2", function()
    local session_2 = ctx.session()
    view.close_all_floats(session_2)
    local s_url = session_2 and session_2.url
    local initial_sql
    if session_2 and session_2.query_spec then
      initial_sql = qmod.clean_sql(session_2.query_spec)
    elseif session_2 and session_2.query_sql then
      initial_sql = session_2.query_sql
    end
    require("dadbod-grip.query_pad").open(s_url, initial_sql and { initial_sql = initial_sql } or nil)
  end, "Query pad (key 2)")

  -- 3: grid/records (already in non-records view = return to records; already on records = table picker)
  kmap("tab_3", function()
    local session_3 = ctx.session()
    view.close_all_floats(session_3)
    local cv = session_3 and session_3.current_view
    if cv and cv ~= "records" then
      view.switch_view(bufnr, "records")
    else
      local s_url = session_3 and session_3.url
      local picker = require("dadbod-grip.picker")
      picker.pick_table(s_url, function(name)
        require("dadbod-grip").open(name, s_url)
      end)
    end
  end, "Grid/records (key 3)")

  -- 4-9: view tabs (4=ER diagram float, 5-9=inline grid views)
  for n = 4, 9 do
    local view_name = km.TAB_VIEWS[n]
    if view_name then
      if view_name == "er_diagram" then
        kmap("tab_" .. n, function()
          local session = ctx.session()
          view.close_all_floats(session)
          local s_url = session and session.url
          if not s_url then s_url = require("dadbod-grip.db").get_url() end
          if not s_url then vim.notify("ER Diagram: no database connection", vim.log.levels.WARN); return end
          require("dadbod-grip.er_diagram").toggle(s_url)
        end, "ER diagram (key 4)")
      else
        kmap("tab_" .. n, function()
          view.close_all_floats(ctx.session())
          view.switch_view(bufnr, view_name)
        end, "View: " .. (VIEW_LABELS[view_name] or view_name))
      end
    end
  end

  -- gG: ER diagram float
  kmap("er_diagram", function()
    local session = ctx.session()
    local s_url = session and session.url
    if not s_url then s_url = require("dadbod-grip.db").get_url() end
    if not s_url then
      vim.notify("ER Diagram: no database connection", vim.log.levels.WARN)
      return
    end
    local focus_table = session and session.state and session.state.table_name
    require("dadbod-grip.er_diagram").toggle(s_url, focus_table, { focus = focus_table ~= nil })
  end, "ER diagram (FK relationships)")

  -- ?: help popup
  kmap("help", function()
    view.show_help({ readonly = not ctx.session_is_editable() })
  end, "Show help")

  -- <C-p>: command palette (discover all actions for this surface)
  kmap("palette", function()
    require("dadbod-grip.palette").open("grid")
  end, "Command palette")
end

return M
