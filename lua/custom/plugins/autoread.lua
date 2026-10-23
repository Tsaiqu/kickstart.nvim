-- Automatyczne przeladowanie buforow, gdy plik zmieni sie na dysku
-- (np. gdy Claude Code edytuje go w tle).
--
-- 'autoread' jest domyslnie wlaczony, ale sam z siebie nie sprawdza plikow
-- w tle - robi to dopiero po komendzie powloki, przy odzyskaniu fokusu
-- lub po recznym :checktime. Ponizsze autokomendy dokladaja te brakujace
-- momenty. Zobacz :h timestamp

vim.o.updatetime = 1000

local group = vim.api.nvim_create_augroup('custom-autoread', { clear = true })

vim.api.nvim_create_autocmd({ 'FocusGained', 'BufEnter', 'CursorHold', 'CursorHoldI' }, {
  group = group,
  pattern = '*',
  desc = 'Sprawdz, czy plik zmienil sie na dysku',
  callback = function()
    -- :checktime wysypuje sie w trybie komend i w oknie cmdline
    if vim.fn.mode():match '[crt!]' or vim.fn.getcmdwintype() ~= '' then
      return
    end
    -- bufory bez pliku (terminale, neo-tree, panele) nie maja czego sprawdzac
    if vim.bo.buftype ~= '' then
      return
    end
    vim.cmd 'checktime'
  end,
})

vim.api.nvim_create_autocmd('FileChangedShellPost', {
  group = group,
  pattern = '*',
  desc = 'Powiadom o przeladowaniu z dysku',
  callback = function()
    vim.notify('Plik zmieniony na dysku, przeladowano bufor', vim.log.levels.WARN)
  end,
})

-- Nie jest to specyfikacja wtyczki - lazy dostaje pusta liste.
return {}
