local function run_ruff_check()
  local filepath = vim.api.nvim_buf_get_name(0)
  if filepath == '' then
    vim.notify('No file saved in the buffer', vim.log.levels.WARN)
    return
  end

  vim.system({ 'ruff', 'check', filepath, '--output-format', 'concise' }, { text = true }, function(result)
    vim.schedule(function()
      local output = result.stdout
      if output == '' then
        output = result.stderr
      end
      if output == '' then
        output = "Ruff didn't return any output (no errors? :3)"
      end

      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].filetype = 'ruff-output'

      local lines = vim.split(output, '\n')
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

      vim.cmd 'split'
      vim.api.nvim_win_set_buf(0, buf)
    end)
  end)
end

vim.keymap.set('n', '<leader>rr', run_ruff_check, { desc = '[R]un [R]uff check on current file' })

return {}
