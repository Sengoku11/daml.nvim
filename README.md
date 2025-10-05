Minimal **DAML** support for Neovim.

## Features

- **Filetype detection**: auto-detects `*.daml` via `ftdetect/`.
- **LSP out of the box**:
  - diagnostics (errors/warnings)
  - hover, go-to definition, references
  - rename, code actions, formatting (server-dependent)
  - completion (integrates with your completion plugin; auto-capabilities with `blink.cmp` if present)
- **Syntax highlighting**: maps DAML → **Haskell** Tree-sitter for broader coverage.
- **Indent (optional)**: reuses `GetHaskellIndent()` when available.
- **Startup-friendly**: safely lazy-loads; defers heavy work after UI when needed.
- **Native API**: uses Neovim 0.11+ `vim.lsp.config()` / `vim.lsp.enable()` (no lspconfig dependency).

## Requirements

- **Neovim 0.11+**
- **DAML SDK** (`daml` CLI on your `$PATH`) — required for the language server
- Optional:
  - **nvim-treesitter** (install the `haskell` parser)
  - **blink.cmp** (for richer LSP capabilities)

## Install (lazy.nvim)

> Ships `ftdetect/daml.vim`, so `ft = 'daml'` works out of the box.

```lua
{
  'Sengoku11/daml.nvim',
  ft = 'daml',
  opts = {},
  dependencies = {
    'nvim-treesitter/nvim-treesitter',
    'saghen/blink.cmp',
  },
}
```

> Defaults
```lua
opts = {
  treesitter_map = true, -- map daml -> haskell TS parser
  keep_haskell_indent = true, -- set indentexpr to GetHaskellIndent() if available
  lsp = {
    enable = true,
    -- Create a new config for DAML LSP.
    cmd = { 'daml', 'damlc', 'ide', '--scenarios=yes', '--RTS', '+RTS', '-M4G', '-N' },
    filetypes = { 'daml' },
    root_markers = { 'daml.yaml', '.git' },
    single_file_support = true,
    capabilities = nil, -- if nil, it’ll try blink.cmp and fall back to default
  },
  buffer_opts = {
    expandtab = true,
    shiftwidth = 2,
    tabstop = 2,
    softtabstop = 2,
  },
}
```
