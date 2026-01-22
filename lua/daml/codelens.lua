---@class Sengoku11.Daml.CodeLens
local M = {}

-- Global registry to map Virtual URIs -> Neovim Buffer IDs
_G.DamlVirtualBuffers = _G.DamlVirtualBuffers or {}

-- Helper: Poor man's HTML-to-Text converter (Lua only)
local function render_daml_html(html)
  local text = html

  -- 1. NEWLINE HACK: Lua patterns don't match newlines with '.',
  -- so we temporarily swap them to handle multi-line blocks like <head>...
  text = text:gsub('\r\n', '___NL___'):gsub('\n', '___NL___')

  -- 2. NUCLEAR OPTION: Remove entire blocks (Tags AND Content)
  text = text:gsub('<head>.-</head>', '') -- Kills CSS (.da-code) & Scripts
  text = text:gsub('<style>.-</style>', '') -- Kills inline styles
  text = text:gsub('<script>.-</script>', '') -- Kills inline JS
  text = text:gsub('<button.-</button>', '') -- Kills "Show transaction" buttons
  text = text:gsub('<label.-</label>', '') -- Kills "Show archived" labels

  -- 3. Restore Newlines
  text = text:gsub('___NL___', '\n')

  -- 4. Clean up specific UI text leftovers (if any remain outside tags)
  text = text:gsub('Show transaction view', '')
  text = text:gsub('Show table view', '')
  text = text:gsub('Show archived', '')
  text = text:gsub('Show detailed disclosure', '')

  -- 5. Format Table Rows (Active Contracts)
  text = text:gsub('<tr[^>]*>', '\n') -- Row start = Newline
  text = text:gsub('</tr>', '') -- Row end = nothing

  -- 6. Format Table Cells
  text = text:gsub('</t[hd]>', ' | ')
  text = text:gsub('<t[hd][^>]*>', ' ')

  -- 7. Formatting for Transactions (The Tree)
  text = text:gsub('<br%s*/?>', '\n')

  -- 8. Strip any remaining HTML tags (like <div>, <span>)
  text = text:gsub('<[^>]+>', '')

  -- 9. Decode HTML Entities
  local entities = {
    ['&quot;'] = '"',
    ['&apos;'] = "'",
    ['&#39;'] = "'",
    ['&lt;'] = '<',
    ['&gt;'] = '>',
    ['&amp;'] = '&',
    ['&nbsp;'] = ' ',
  }
  text = text:gsub('&%w+;', entities):gsub('&#%d+;', entities)

  -- 10. Final Polish
  text = text:gsub('Transactions:', '\n### Transactions:')
  text = text:gsub('\n%s*\n%s*\n', '\n\n')

  return text
end

--- Handler for 'daml/virtualResource/didChange'
function M.on_virtual_resource_change(_, result, ctx)
  if not result or not result.uri then
    return
  end

  local uri = result.uri
  local content = result.contents or result.text or ''
  local buf = _G.DamlVirtualBuffers[uri]

  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.schedule(function()
      local plain_text = render_daml_html(content)
      local lines = vim.split(plain_text, '\n')
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].filetype = 'daml'
      vim.notify('Daml: Results updated', vim.log.levels.INFO)
    end)
  end
end

--- Handler for 'daml.showResource' command
function M.on_show_resource(command, ctx)
  local args = command.arguments
  if not args or #args < 2 then
    return
  end
  local raw_uri = args[2]

  -- 1. Create Buffer
  local buf = vim.api.nvim_create_buf(false, true)
  _G.DamlVirtualBuffers[raw_uri] = buf

  -- 2. Open Window (Vertical Split)
  vim.cmd 'botright vsplit'
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)

  -- 3. WINDOW OPTIONS
  local wo = vim.wo[win]
  wo.wrap = false
  wo.virtualedit = 'all'
  wo.number = false
  wo.signcolumn = 'no'
  wo.foldcolumn = '0'
  wo.cursorline = true
  wo.spell = false
  wo.sidescrolloff = 0

  -- 4. MOUSE SCROLL MAPPINGS
  local map_opts = { buffer = buf, silent = true }
  vim.keymap.set({ 'n', 'i' }, '<ScrollWheelRight>', '20zl', map_opts)
  vim.keymap.set({ 'n', 'i' }, '<ScrollWheelLeft>', '20zh', map_opts)
  vim.keymap.set({ 'n', 'i' }, '<S-ScrollWheelDown>', '20zl', map_opts)
  vim.keymap.set({ 'n', 'i' }, '<S-ScrollWheelUp>', '20zh', map_opts)
  vim.keymap.set({ 'n', 'i' }, '<C-ScrollWheelDown>', '20zl', map_opts)
  vim.keymap.set({ 'n', 'i' }, '<C-ScrollWheelUp>', '20zh', map_opts)

  -- 5. Disable Diagnostics
  vim.diagnostic.enable(false, { bufnr = buf })

  -- Initial Content
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    '⏳ Waiting for Daml Server notification...',
    'URI: ' .. raw_uri,
  })

  -- Cleanup
  vim.keymap.set('n', 'q', function()
    _G.DamlVirtualBuffers[raw_uri] = nil
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    local client = vim.lsp.get_client_by_id(ctx.client_id)
    if client then
      -- FIX: Use colon :notify to pass self correctly
      client:notify('textDocument/didClose', { textDocument = { uri = raw_uri } })
    end
  end, { buffer = buf })

  -- Subscribe
  local client = vim.lsp.get_client_by_id(ctx.client_id)
  if client then
    vim.notify('Daml: Subscribing...', vim.log.levels.INFO)
    -- FIX: Use colon :notify to pass self correctly
    client:notify('textDocument/didOpen', {
      textDocument = { uri = raw_uri, languageId = 'daml', version = 1, text = '' },
    })
  end
end

function M.setup()
  -- Create command :DamlRunScript to run CodeLens on current line
  vim.api.nvim_create_user_command('DamlRunScript', function()
    vim.lsp.codelens.run()
  end, {})

  -- Force CodeLenses to refresh when you enter a buffer or pause typing
  vim.api.nvim_create_autocmd({ 'BufEnter', 'CursorHold', 'InsertLeave' }, {
    group = vim.api.nvim_create_augroup('daml_codelens_refresh', { clear = true }),
    pattern = '*.daml',
    callback = function()
      vim.lsp.codelens.refresh()
    end,
  })
end

return M
