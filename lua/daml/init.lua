---@class Sengoku11.Daml
local M = {}

local defaults = {
  filetype = true, -- register 'daml' filetype
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
  treesitter_ensure = { 'haskell' }, -- ensure Haskell is installed (if user uses nvim-treesitter)
}

local function tbl_deep_extend(dst, src)
  for k, v in pairs(src or {}) do
    if type(v) == 'table' and type(dst[k]) == 'table' then
      tbl_deep_extend(dst[k], v)
    else
      dst[k] = v
    end
  end
  return dst
end

---@param opts table|nil
function M.setup(opts)
  vim.g._daml_nvim_user_setup_done = true
  opts = tbl_deep_extend(vim.deepcopy(defaults), opts or {})

  -- 1) Tree-sitter: treat DAML as Haskell (for better highlight coverage)
  if opts.treesitter_map and vim.treesitter and vim.treesitter.language and vim.treesitter.language.register then
    pcall(vim.treesitter.language.register, 'haskell', 'daml')
  end

  -- 2) Optional: keep Haskell indentation for DAML buffers
  if opts.keep_haskell_indent then
    vim.api.nvim_create_autocmd('FileType', {
      group = vim.api.nvim_create_augroup('daml_nvim_indent', { clear = true }),
      pattern = 'daml',
      callback = function()
        -- Only set if function exists to avoid errors when haskell indent isn't present
        if vim.fn.exists '*GetHaskellIndent' == 1 then
          vim.bo.indentexpr = 'GetHaskellIndent()'
          vim.b.did_indent = 1
        end
      end,
    })
  end

  -- 3) LSP: configure daml via nvim-lspconfig
  if opts.lsp and opts.lsp.enable then
    local ok_configs, configs = pcall(require, 'lspconfig.configs')
    local ok_lspconfig, lspconfig = pcall(require, 'lspconfig')
    if ok_configs and ok_lspconfig then
      if not configs.daml then
        configs.daml = {
          default_config = {
            cmd = opts.lsp.cmd,
            filetypes = opts.lsp.filetypes,
            root_dir = require('lspconfig.util').root_pattern(unpack(opts.lsp.root_markers)),
            single_file_support = opts.lsp.single_file_support,
          },
        }
      end

      -- Capabilities: prefer blink.cmp if available; else fallback to vim.lsp
      local capabilities = opts.lsp.capabilities
      if not capabilities then
        local ok_blink, blink = pcall(require, 'blink.cmp')
        if ok_blink and blink.get_lsp_capabilities then
          capabilities = blink.get_lsp_capabilities()
        else
          capabilities = vim.lsp.protocol.make_client_capabilities()
        end
      end

      lspconfig.daml.setup {
        capabilities = capabilities,
      }
    else
      vim.schedule(function()
        vim.notify('[daml.nvim] nvim-lspconfig not found; skipping DAML LSP setup', vim.log.levels.WARN)
      end)
    end
  end

  local bufopts = opts.buffer_opts

  vim.api.nvim_create_autocmd('FileType', {
    group = vim.api.nvim_create_augroup('daml_nvim_ft', { clear = true }),
    pattern = 'daml',
    callback = function()
      -- optional Haskell indent
      if opts.keep_haskell_indent and vim.fn.exists '*GetHaskellIndent' == 1 then
        vim.bo.indentexpr = 'GetHaskellIndent()'
        vim.b.did_indent = 1
      end

      -- apply your ftplugin options
      if bufopts then
        for k, v in pairs(bufopts) do
          vim.bo[k] = v
        end
      end
    end,
  })
end

return M
