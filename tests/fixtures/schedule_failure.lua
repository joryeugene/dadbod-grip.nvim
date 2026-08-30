vim.schedule(function()
  error("intentional scheduled callback failure")
end)

vim.wait(1000, function() return false end, 10)
vim.cmd("qall!")
