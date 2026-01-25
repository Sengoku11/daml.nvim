---@class Sengoku11.Daml
local M = {}

local defaults = {
  treesitter_map = true, -- map daml -> haskell TS parser
  keep_haskell_indent = true, -- set indentexpr to GetHaskellIndent() if available
  daml_script = { render = true }, -- set to false if you prefer raw html output
  lsp = {
    enable = true,
    -- Create a new config for DAML LSP.
    cmd = { 'daml', 'ide', '--RTS', '+RTS', '-M4G', '-N' },
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

local function tbl_deep_extend(dst, src)
  -- Polyfill for older Neovim versions (< 0.10)
  ---@diagnostic disable-next-line: deprecated
  local is_list = vim.islist or vim.tbl_islist

  for k, v in pairs(src or {}) do
    -- Check if dst[k] is a list to avoid merging arrays element-wise
    if type(v) == 'table' and type(dst[k]) == 'table' and not is_list(dst[k]) then
      tbl_deep_extend(dst[k], v)
    else
      dst[k] = v
    end
  end
  return dst
end

local function jump_to_codelens(direction)
  local lenses = vim.lsp.codelens.get(0)
  if not lenses or #lenses == 0 then
    return
  end

  table.sort(lenses, function(a, b)
    return a.range.start.line < b.range.start.line
  end)

  local current_line = vim.api.nvim_win_get_cursor(0)[1] - 1 -- 0-indexed
  local target_lens = nil

  if direction == 1 then
    -- Find next
    for _, lens in ipairs(lenses) do
      if lens.range.start.line > current_line then
        target_lens = lens
        break
      end
    end
    -- Wrap around to first if none found
    if not target_lens then
      target_lens = lenses[1]
    end
  else
    -- Find prev
    for i = #lenses, 1, -1 do
      local lens = lenses[i]
      if lens.range.start.line < current_line then
        target_lens = lens
        break
      end
    end
    -- Wrap around to last if none found
    if not target_lens then
      target_lens = lenses[#lenses]
    end
  end

  if target_lens then
    vim.api.nvim_win_set_cursor(0, { target_lens.range.start.line + 1, target_lens.range.start.character })
  end
end

local function run_smart_codelens()
  local lenses = vim.lsp.codelens.get(0)
  if not lenses or #lenses == 0 then
    -- Let standard run handle the "No CodeLens" message or behavior
    vim.lsp.codelens.run()
    return
  end

  local current_line = vim.api.nvim_win_get_cursor(0)[1] - 1 -- 0-indexed

  -- 1. Check for lens on current line
  for _, lens in ipairs(lenses) do
    if lens.range.start.line == current_line then
      vim.lsp.codelens.run()
      return
    end
  end

  -- 2. Find nearest previous lens
  -- Sort lenses by line number
  table.sort(lenses, function(a, b)
    return a.range.start.line < b.range.start.line
  end)

  local target_lens = nil
  for i = #lenses, 1, -1 do
    local lens = lenses[i]
    if lens.range.start.line < current_line then
      target_lens = lens
      break
    end
  end

  if target_lens then
    -- Move cursor to the lens line so execution context is correct
    vim.api.nvim_win_set_cursor(0, { target_lens.range.start.line + 1, target_lens.range.start.character })
    vim.lsp.codelens.run()
  else
    -- Fallback: just try running (e.g. if cursor is above all lenses)
    vim.lsp.codelens.run()
  end
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

  -- 3) LSP: configure daml via native Neovim LSP
  if opts.lsp and opts.lsp.enable then
    local capabilities = opts.lsp.capabilities
    if not capabilities then
      local ok_blink, blink = pcall(require, 'blink.cmp')
      if ok_blink and blink.get_lsp_capabilities then
        capabilities = blink.get_lsp_capabilities()
      else
        capabilities = vim.lsp.protocol.make_client_capabilities()
      end
    end

    -- Setup CodeLens (Always enabled)
    local codelens = require 'daml.codelens'
    -- Register the client-side command that the server requests
    local lsp_commands = {
      ['daml.showResource'] = codelens.on_show_resource,
    }
    -- Register the notification handler for results
    local lsp_handlers = {
      ['daml/virtualResource/didChange'] = codelens.on_virtual_resource_change,
    }
    -- Setup autocommands and user commands
    codelens.setup(opts.daml_script)

    vim.lsp.config('daml', {
      cmd = opts.lsp.cmd,
      filetypes = opts.lsp.filetypes,
      -- use root_markers instead of a root_dir function
      root_markers = opts.lsp.root_markers,
      single_file_support = opts.lsp.single_file_support,
      capabilities = capabilities,
      commands = lsp_commands,
      handlers = lsp_handlers,
    })
    vim.lsp.enable 'daml'
  end

  local bufopts = opts.buffer_opts

  vim.api.nvim_create_user_command('DamlRunScript', function()
    run_smart_codelens()
  end, {})

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

      -- CodeLens Navigation
      vim.keymap.set('n', ']l', function()
        jump_to_codelens(1)
      end, { buffer = true, desc = 'Next CodeLens' })
      vim.keymap.set('n', '[l', function()
        jump_to_codelens(-1)
      end, { buffer = true, desc = 'Prev CodeLens' })
    end,
  })
end

return M
