-- Consent boundary for replacing a workspace. No database writes or retries.
local M = {}

local function staged()
  local view, data = require("dadbod-grip.view"), require("dadbod-grip.data")
  local found = {}
  for buf, session in pairs(view._sessions) do
    if vim.api.nvim_buf_is_valid(buf) then
      if session._write_pending or session._write_unknown then
        return nil, "Resolve the pending or uncertain write before switching connections."
      end
      local state = session.current_view and session.current_view ~= "records"
        and session._records_state or session.state
      if state and (data.has_changes(state) or session.pending_mutation) then
        found[buf] = { session = session, state = state, copy = vim.deepcopy(state),
          pending = session.pending_mutation, generation = session._refresh_generation }
      end
    end
  end
  return found
end

local function unchanged(original)
  local current = staged()
  if not current then return false end
  for buf, old in pairs(original) do
    local now = current[buf]
    if not now or now.session ~= old.session or now.state ~= old.state
        or now.pending ~= old.pending or now.generation ~= old.generation
        or not vim.deep_equal(now.state, old.copy) then return false end
    current[buf] = nil
  end
  return next(current) == nil
end

--- Return a prepared UI receipt only after consent and successful target reads.
--- File profiles with pending changes are deliberately refused: describing a
--- file cannot attest that its later full read will succeed.
function M.prepare(url, file_target, target_unchanged)
  local ui = require("dadbod-grip.ui")
  local snapshots, err = staged()
  if not snapshots then vim.notify("Grip: " .. err, vim.log.levels.ERROR); return false end
  if not next(snapshots) then return true end
  if file_target then
    vim.notify("Grip: apply or discard staged changes manually before opening a file connection.", vim.log.levels.WARN)
    return false
  end
  local count = 0
  for _ in pairs(snapshots) do count = count + 1 end
  if ui.confirm(string.format("Discard pending changes in %d result buffer(s) and switch connections? (y/N): ", count)) ~= true then
    return false
  end
  if not unchanged(snapshots) or (target_unchanged and not target_unchanged()) then
    vim.notify("Grip: pending results changed while confirming; connection was not switched.", vim.log.levels.WARN)
    return false
  end
  local schema = require("dadbod-grip.schema")
  local ok, result = pcall(function()
    return ui.blocking("checking target connection...", function()
      local receipt, problem = schema.prepare_switch(url)
      -- Keep nil/error pairs intact through blocking's Lua 5.1 result list.
      return { receipt = receipt, problem = problem }
    end)
  end)
  local prepared = ok and result.receipt
  if not prepared then
    local problem = ok and result.problem or result
    vim.notify("Grip: target connection failed; pending changes were retained. " .. tostring(problem or "target metadata unavailable"), vim.log.levels.ERROR)
    return false
  end
  if not unchanged(snapshots) or (target_unchanged and not target_unchanged()) then
    vim.notify("Grip: pending results changed while checking the target; connection was not switched.", vim.log.levels.WARN)
    return false
  end
  local state, expired = schema.use_prepared_switch(url, prepared)
  if not state then vim.notify("Grip: " .. expired, vim.log.levels.ERROR); return false end
  local view, data = require("dadbod-grip.view"), require("dadbod-grip.data")
  for buf, snapshot in pairs(snapshots) do
    local session = snapshot.session
    local clean = data.undo_all(snapshot.state)
    session._refresh_generation = (session._refresh_generation or 0) + 1
    session._undo_stack, session._redo_stack, session.pending_mutation = nil, nil, nil
    session.state = clean
    if session._records_state then session._records_state = clean end
    if session.current_view and session.current_view ~= "records" and session._meta_state then
      view.render(buf, session._meta_state)
      session.state = clean
    else
      view.render(buf, clean)
    end
  end
  view.close_all_floats()
  return true, prepared
end

return M
