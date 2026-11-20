-- Powiadamianie serwerow LSP o plikach zmienionych/dodanych poza Neovimem (np. przez Claude Code).
--
-- Na Linuksie Neovim domyslnie nie oglasza `workspace/didChangeWatchedFiles`, wiec basedpyright,
-- vtsls itd. nie wiedza o nowych plikach na dysku i pokazuja nieaktualne bledy (np. nierozwiazane
-- importy) az do :LspRestart. Wlaczamy to dla wszystkich serwerow; Neovim obserwuje pliki przez
-- `inotifywait` (pakiet inotify-tools), a bez niego przez wolniejszy watcher katalogow.
vim.lsp.config('*', {
  capabilities = {
    workspace = {
      didChangeWatchedFiles = { dynamicRegistration = true },
    },
  },
})

-- Nie jest to specyfikacja wtyczki - lazy dostaje pusta liste.
return {}
