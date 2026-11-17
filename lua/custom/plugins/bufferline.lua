local function close_buffer()
  local buf_to_close = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()

  local alt = vim.fn.bufnr '#' -- alternate buffer

  if alt ~= -1 and alt ~= buf_to_close and vim.fn.buflisted(alt) == 1 then
    -- przełącz okno na alternatywny bufor ZANIM usuniemy stary
    vim.api.nvim_win_set_buf(win, alt)
  else
    -- brak sensownego alternate - spróbuj czegokolwiek innego z listy
    vim.cmd 'bnext'
  end

  -- Tylko chowamy bufor z listy (unlisted), zamiast go usuwać (`bdelete`).
  -- `bdelete` odłącza dołączone kliencie LSP od bufora, a przy częstym
  -- zamykaniu/otwieraniu tych samych plików powoduje ciągłe zatrzymywanie
  -- i restartowanie basedpyright/ruff (gdy zabraknie im ostatniego bufora).
  if vim.api.nvim_buf_is_valid(buf_to_close) then
    vim.bo[buf_to_close].buflisted = false
  end
end

-- Chowa z listy wszystkie bufory poza bieżącym (jak `close_buffer`: unlisted zamiast `bdelete`,
-- więc LSP się nie restartuje, a niezapisane zmiany zostają w buforach).
local function close_other_buffers()
  local current = vim.api.nvim_get_current_buf()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if buf ~= current and vim.bo[buf].buflisted then
      vim.bo[buf].buflisted = false
    end
  end
end

return {
  {
    'akinsho/bufferline.nvim',
    version = '*',
    dependencies = 'nvim-tree/nvim-web-devicons',
    event = 'VeryLazy',
    opts = {
      options = {
        mode = 'buffers', -- tabs / buffers
        diagnostics = 'nvim_lsp',
        show_buffer_close_icons = true,
        show_close_icon = false,
        separator_style = 'thin',
        offsets = {
          {
            filetype = 'neo-tree',
            text = 'File Explorer',
            highlight = 'Directory',
            separator = true,
          },
        },
      },
    },
    keys = {
      { '<Tab>', '<cmd>BufferLineCycleNext<CR>', desc = 'Next Buffer' },
      { '<S-Tab>', '<cmd>BufferLineCyclePrev<CR>', desc = 'Prev buffer' },
      { '<leader>bp', '<cmd>BufferLinePick<CR>', desc = 'Pick buffer' },
      { '<leader>bc', '<cmd>BufferLinePickClose<CR>', desc = 'Pick buffer to close' },
      { '<leader>bd', close_buffer, desc = 'Close current buffer' },
      { '<leader>bo', close_other_buffers, desc = 'Close other buffers' },
    },
  },
}
