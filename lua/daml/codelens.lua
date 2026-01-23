---@class Sengoku11.Daml.CodeLens
local M = {}

local config = { render = true }

-- Global registry to map Virtual URIs -> Neovim Buffer IDs
_G.DamlVirtualBuffers = _G.DamlVirtualBuffers or {}

-- Helper: Format & Align text tables into valid Markdown
local function format_markdown_tables(text)
  local lines = vim.split(text, '\n')
  local result = {}
  local buffer = {}

  local function flush_buffer()
    if #buffer == 0 then
      return
    end

    -- 1. Normalize Rows: ensure they are wrapped in pipes
    local rows = {}
    for _, line in ipairs(buffer) do
      local l = vim.trim(line)
      if l:sub(1, 1) ~= '|' then
        l = '| ' .. l
      end
      if l:sub(-1) ~= '|' then
        l = l .. ' |'
      end
      table.insert(rows, l)
    end

    -- 2. Parse & Calculate Column Widths
    local col_widths = {}
    local parsed_rows = {}

    for _, row in ipairs(rows) do
      -- Split by pipe. Note: split("|a|b|", "|") gives {"", "a", "b", ""}
      local cells = vim.split(row, '|')
      if cells[1] == '' then
        table.remove(cells, 1)
      end
      if cells[#cells] == '' then
        table.remove(cells, #cells)
      end

      local clean_cells = {}
      for i, cell in ipairs(cells) do
        local c = vim.trim(cell)
        table.insert(clean_cells, c)
        -- Track max width (min 3 for "---")
        local w = vim.fn.strdisplaywidth(c)
        col_widths[i] = math.max(col_widths[i] or 3, w)
      end
      table.insert(parsed_rows, clean_cells)
    end

    -- 3. Render Header (Row 1)
    if #parsed_rows > 0 then
      local header_cells = parsed_rows[1]
      local header_line = {}
      local separator_line = {}

      for i = 1, #col_widths do
        local cell = header_cells[i] or ''
        local w = col_widths[i]
        -- Pad content
        table.insert(header_line, cell .. string.rep(' ', w - vim.fn.strdisplaywidth(cell)))
        -- Create separator (e.g., "-------")
        table.insert(separator_line, string.rep('-', w))
      end

      table.insert(result, '| ' .. table.concat(header_line, ' | ') .. ' |')
      table.insert(result, '| ' .. table.concat(separator_line, ' | ') .. ' |')
    end

    -- 4. Render Body (Row 2+)
    for r = 2, #parsed_rows do
      local body_cells = parsed_rows[r]
      local line_parts = {}
      for i = 1, #col_widths do
        local cell = body_cells[i] or ''
        local w = col_widths[i]
        table.insert(line_parts, cell .. string.rep(' ', w - vim.fn.strdisplaywidth(cell)))
      end
      table.insert(result, '| ' .. table.concat(line_parts, ' | ') .. ' |')
    end

    buffer = {}
  end

  for _, line in ipairs(lines) do
    -- Heuristic: Only capture lines with ASCII pipes '|'.
    -- Transaction trees use Unicode '│', so they are ignored here.
    if line:find('|', 1, true) then
      table.insert(buffer, line)
    else
      flush_buffer()
      table.insert(result, line)
    end
  end
  flush_buffer()

  return table.concat(result, '\n')
end

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

  -- Handle Table Titles (h1) with Proximity Theory + Markdown Header
  -- 1. \n\n\n\n adds 3 blank lines BEFORE the title (strong separation from prev section)
  -- 2. Adds # prefix
  -- 3. </h1> -> '' keeps it close to the table (no extra newline)
  text = text:gsub('<h1[^>]*>', '\n\n\n\n# '):gsub('</h1>', '')

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

  -- 10. Fix Artifacts (Tooltips merged by tag stripping)
  text = text:gsub('WWitness', 'W')
  text = text:gsub('SSignatory', 'S')
  text = text:gsub('OObserver', 'O')
  text = text:gsub('DDivulged', 'D')

  -- 11. Final Polish
  -- Add extra newline before Transactions header for better separation
  local count = 0
  text, count = text:gsub('Transactions:', '\n\n\n##' .. ' Transactions:\n```haskell')
  if count > 0 then
    text = text .. '\n```'
  end

  -- Remove leading whitespace
  text = text:gsub('^%s+', '')

  -- 12. MARKDOWN MAGIC: Convert loose tables to valid Markdown syntax
  text = format_markdown_tables(text)

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
      local plain_text = config.render and render_daml_html(content) or content
      local lines = vim.split(plain_text, '\n')

      -- Unlock, Write, Lock
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].modifiable = false
      vim.bo[buf].filetype = 'markdown'

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
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    '⏳ Waiting for Daml Server notification...',
    'URI: ' .. raw_uri,
  })
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = 'markdown'

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

function M.setup(opts)
  if opts then
    config = vim.tbl_deep_extend('force', config, opts)
  end
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
