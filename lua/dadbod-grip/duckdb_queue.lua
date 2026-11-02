-- Coordinate Grip's DuckDB CLI children by the physical files they open.
-- A result timeout is not proof that a child has released its native locks.
local M = {}
local adapters = require("dadbod-grip.adapters")
local pending, active, scheduled = {}, {}, false
local drain

local function defer_drain()
  if scheduled then return end
  scheduled = true
  vim.schedule(function() scheduled = false; drain() end)
end

local function stop_timer(job)
  if job.timer and not job.timer:is_closing() then job.timer:stop(); job.timer:close() end
  job.timer = nil
end

local function release(job)
  if job.reaped then return end
  job.reaped = true
  for _, key in ipairs(job.keys) do if active[key] == job then active[key] = nil end end
  defer_drain()
end

local function deliver(job, stdout, stderr, code)
  if job.delivered then return end
  job.delivered = true
  if job.callback then job.callback(stdout, stderr, code) end
end

local function not_started(job)
  if job.reaped then return end
  release(job)
  if job.opts and job.opts.on_spawn_error then pcall(job.opts.on_spawn_error) end
  if job.opts and job.opts.on_complete then pcall(job.opts.on_complete) end
end

local function refuse(job, message, code)
  if job.started or job.removed then return false end
  job.removed = true
  stop_timer(job)
  not_started(job) -- no child was admitted, so completion is already proved
  vim.schedule(function() deliver(job, "", message, code) end)
  defer_drain()
  return true
end

local function hooks(job, opts)
  local result = vim.tbl_extend("force", {}, opts or {})
  result.on_complete = function()
    release(job)
    if opts and opts.on_complete then pcall(opts.on_complete) end
  end
  result.on_start = function(process)
    job.process = process
    if opts and opts.on_start then pcall(opts.on_start, process) end
  end
  result.on_spawn_error = function()
    if opts and opts.on_spawn_error then pcall(opts.on_spawn_error) end
  end
  return result
end

drain = function()
  local blocked = {}
  local index = 1
  while index <= #pending do
    local job = pending[index]
    if job.removed then
      table.remove(pending, index)
    else
      local available = true
      for _, key in ipairs(job.keys) do
        if active[key] or blocked[key] then available = false end
      end
      if available then
        table.remove(pending, index)
        job.started = true
        stop_timer(job)
        for _, key in ipairs(job.keys) do active[key] = job end
        if job.callback then
          local ok, handle = pcall(adapters.run_cmd_async, job.args, job.timeout, function(stdout, stderr, code)
            deliver(job, stdout, stderr, code)
          end, hooks(job, job.opts))
          if ok then job.handle = handle
          else
            if not job.process then not_started(job) end
            vim.schedule(function() deliver(job, "", tostring(handle), 1) end)
          end
        end
        -- One admission per frame lets a synchronous caller actually spawn
        -- before another operation's on_start can re-enter the event loop.
        if #pending > 0 then defer_drain() end
        return
      else
        -- Preserve FIFO for each shared resource while unrelated files run.
        for _, key in ipairs(job.keys) do blocked[key] = true end
        index = index + 1
      end
    end
  end
end

--- Existing files share both canonical-path and inode keys. The path key also
--- bridges creation: a queued request made before a database exists still
--- conflicts with a later request after DuckDB creates it.
function M.keys(paths)
  local keys, seen = {}, {}
  local function add(key)
    if not seen[key] then seen[key] = true; keys[#keys + 1] = key end
  end
  for _, path in ipairs(paths) do
    if path and path ~= "" and path ~= ":memory:" then
      local absolute = vim.fn.fnamemodify(path, ":p")
      local canonical = vim.uv.fs_realpath(absolute)
      if not canonical then
        local parent = vim.uv.fs_realpath(vim.fn.fnamemodify(absolute, ":h"))
        canonical = parent and (parent .. "/" .. vim.fn.fnamemodify(absolute, ":t")) or absolute
      end
      add("path:" .. canonical)
      local stat = vim.uv.fs_stat(absolute)
      if stat then add("inode:" .. tostring(stat.dev) .. ":" .. tostring(stat.ino)) end
    end
  end
  table.sort(keys)
  return keys
end

local function enqueue(job)
  pending[#pending + 1] = job
  drain()
end

function M.run(keys, args, timeout, opts)
  local job = { keys = keys, opts = opts }
  enqueue(job)
  if not job.started then
    local ok, admitted, reason = pcall(vim.wait, (timeout or 30000) + adapters._exit_grace_ms,
      function() return job.started end, 1)
    if not ok or not admitted then
      local interrupted = not ok or reason == -2
      refuse(job, interrupted and "query interrupted before execution" or "database queue timed out", interrupted and 130 or 124)
      return "", interrupted and "query interrupted before execution" or "database queue timed out", interrupted and 130 or 124
    end
  end
  local call_opts = hooks(job, opts)
  call_opts.terminate_on_interrupt = true
  local ok, stdout, stderr, code = pcall(adapters.run_cmd, args, timeout, call_opts)
  if not ok then
    -- A Lua exception does not prove that a started child exited. Leave its
    -- lane owned until the real lifecycle hook arrives.
    if not job.process then not_started(job) end
    return "", tostring(stdout), 1
  end
  return stdout, stderr, code
end

function M.run_async(keys, args, timeout, callback, opts)
  local job = { keys = keys, args = args, timeout = timeout, callback = callback, opts = opts }
  job.timer = vim.defer_fn(function() refuse(job, "database queue timed out", 124) end,
    (timeout or 30000) + adapters._exit_grace_ms)
  enqueue(job)
  return {
    cancel = function()
      if not job.started then return refuse(job, "query interrupted before execution", 130) end
      return job.handle and job.handle.cancel() or false
    end,
    reaped = function() return job.reaped == true end,
  }
end

return M
