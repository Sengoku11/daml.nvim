---@class Sengoku11.Daml.CodeLens
local M = {}

local config = { render = true }

-- Global registry to map Virtual URIs -> Neovim Buffer IDs
_G.DamlVirtualBuffers = _G.DamlVirtualBuffers or {}

-- View State Management
local active_view = 'table' -- 'table' or 'transaction'
local fold_maps = true -- Toggle for folding long Map[...] structures
local raw_content_cache = {} -- Store raw HTML per URI for re-rendering

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

  -- 0. View Filtering (Table vs Transaction)
  local tx_marker = '<div class="da%-code transaction">'
  local table_marker = '<div class="table">'

  local s_tx = text:find(tx_marker)
  local s_table = text:find(table_marker)

  if active_view == 'table' then
    -- Hide transactions
    if s_tx then
      text = text:sub(1, s_tx - 1)
    end

    -- COMPACT MODE for Tables:
    -- Remove all newlines and tabs to ensure cells are single-line.
    -- This fixes issues where Map[...] parsing breaks table structure.
    text = text:gsub('[\r\n\t]', ' ')
    -- Replace <br> with space in tables
    text = text:gsub('<br%s*/?>', ' ')
    -- Trim excessive spaces (more than 2 -> 2) to fix "tabs-like breaks"
    text = text:gsub('%s%s%s+', '  ')
  elseif active_view == 'transaction' then
    -- Hide table
    if s_table and s_tx and s_table < s_tx then
      text = text:sub(1, s_table - 1) .. text:sub(s_tx)
    end

    -- Transaction view relies on original newlines/br
    text = text:gsub('\r\n', '___NL___'):gsub('\n', '___NL___')
  end

  -- 2. Remove entire blocks (Tags AND Content)
  text = text:gsub('<head>.-</head>', '')
  text = text:gsub('<style>.-</style>', '')
  text = text:gsub('<script>.-</script>', '')
  text = text:gsub('<button.-</button>', '')
  text = text:gsub('<label.-</label>', '')

  -- 3. Restore Newlines (Only for Transaction view effectively, as Table view stripped them)
  text = text:gsub('___NL___', '\n')

  -- 4. Clean up UI text
  text = text:gsub('Show transaction view', '')
  text = text:gsub('Show table view', '')
  text = text:gsub('Show archived', '')
  text = text:gsub('Show detailed disclosure', '')

  -- Handle Headers
  text = text:gsub('<h1[^>]*>', '\n\n\n\n# '):gsub('</h1>', '')

  -- 5. Format Table Rows (Active Contracts)
  -- Since we stripped newlines in Table view, this is the ONLY place that creates rows.
  text = text:gsub('<tr[^>]*>', '\n') -- Row start = Newline
  text = text:gsub('</tr>', '') -- Row end = nothing

  -- 6. Format Table Cells
  text = text:gsub('</t[hd]>', ' | ')
  text = text:gsub('<t[hd][^>]*>', ' ')

  -- 7. Formatting for Transactions (The Tree) - if any remain
  text = text:gsub('<br%s*/?>', '\n')

  -- 8. Strip remaining HTML
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

  -- 10. Fix Artifacts
  text = text:gsub('WWitness', 'W')
  text = text:gsub('SSignatory', 'S')
  text = text:gsub('OObserver', 'O')
  text = text:gsub('DDivulged', 'D')

  -- 11. MAP FOLDING (Only in Table View)
  if active_view == 'table' and fold_maps then
    local map_refs = {}
    local map_count = 0

    -- Match Map[...] patterns
    text = text:gsub('(Map%b[])', function(match)
      if #match > 50 then
        map_count = map_count + 1
        -- Use Map_N instead of Map#N to support '*' search in Vim
        local ref = 'Map_' .. map_count
        table.insert(map_refs, ref .. ': ' .. match)
        return ref
      else
        return match
      end
    end)

    if #map_refs > 0 then
      text = text .. '\n\n' .. table.concat(map_refs, '\n')
    end
  end

  -- 12. Final Polish
  local count = 0
  text, count = text:gsub('Transactions:', '\n\n\n##' .. ' Transactions:\n```haskell')

  if count == 0 then
    -- Detect failed transactions
    text, count = text:gsub('(Script execution failed on commit at[^\n]*)', '\n\n\n## %1\n```haskell')
  end

  if count > 0 then
    text = text .. '\n```'
  end

  text = text:gsub('^%s+', '')

  -- 13. MARKDOWN MAGIC
  text = format_markdown_tables(text)

  return text
end

-- Helper: Update buffer content with header and rendered body
local function update_buffer(buf, content)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  vim.schedule(function()
    local final_lines = {}

    if config.render then
      local plain_text = render_daml_html(content)
      local body_lines = vim.split(plain_text, '\n')

      -- Generate Header
      local t_mark = (active_view == 'table') and '[x]' or '[ ]'
      local x_mark = (active_view == 'transaction') and '[x]' or '[ ]'
      local m_mark = fold_maps and '[x]' or '[ ]'

      local header_lines = {
        'View Config:',
        string.format('%s - <leader>vt - Table view', t_mark),
        string.format('%s - <leader>vx - Tx view', x_mark),
        string.format('%s - <leader>vm - Fold maps', m_mark),
        '', -- spacer
      }

      final_lines = vim.list_extend(header_lines, body_lines)
    else
      -- Raw output as is
      final_lines = vim.split(content, '\n')
    end

    -- Unlock, Write, Lock
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, final_lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = 'markdown'
  end)
end

-- Helper: Refresh all open virtual buffers with current settings
local function refresh_all_views()
  for uri, buf in pairs(_G.DamlVirtualBuffers) do
    if vim.api.nvim_buf_is_valid(buf) then
      local content = raw_content_cache[uri]
      if content then
        update_buffer(buf, content)
      end
    end
  end
end

--- Handler for 'daml/virtualResource/didChange'
function M.on_virtual_resource_change(_, result, ctx)
  if not result or not result.uri then
    return
  end

  local uri = result.uri
  local content = result.contents or result.text or ''
  local buf = _G.DamlVirtualBuffers[uri]

  raw_content_cache[uri] = content

  if buf then
    update_buffer(buf, content)
    vim.notify('Daml: Results updated', vim.log.levels.INFO)
  end
end

--- Handler for 'daml.showResource' command
function M.on_show_resource(command, ctx)
  local args = command.arguments
  if not args or #args < 2 then
    return
  end
  local raw_uri = args[2]

  local buf = vim.api.nvim_create_buf(false, true)
  _G.DamlVirtualBuffers[raw_uri] = buf

  vim.cmd 'botright vsplit'
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)

  local wo = vim.wo[win]
  wo.wrap = false
  wo.virtualedit = 'all'
  wo.number = false
  wo.signcolumn = 'no'
  wo.foldcolumn = '0'
  wo.cursorline = true
  wo.spell = false
  wo.sidescrolloff = 0

  local map_opts = { buffer = buf, silent = true }
  vim.keymap.set({ 'n', 'i' }, '<ScrollWheelRight>', '20zl', map_opts)
  vim.keymap.set({ 'n', 'i' }, '<ScrollWheelLeft>', '20zh', map_opts)
  vim.keymap.set({ 'n', 'i' }, '<S-ScrollWheelDown>', '20zl', map_opts)
  vim.keymap.set({ 'n', 'i' }, '<S-ScrollWheelUp>', '20zh', map_opts)
  vim.keymap.set({ 'n', 'i' }, '<C-ScrollWheelDown>', '20zl', map_opts)
  vim.keymap.set({ 'n', 'i' }, '<C-ScrollWheelUp>', '20zh', map_opts)

  if config.render then
    vim.keymap.set('n', '<leader>vt', function()
      active_view = 'table'
      refresh_all_views()
    end, { buffer = buf, desc = 'Daml: Switch to Table View' })

    vim.keymap.set('n', '<leader>vx', function()
      active_view = 'transaction'
      refresh_all_views()
    end, { buffer = buf, desc = 'Daml: Switch to Transaction View' })

    vim.keymap.set('n', '<leader>vm', function()
      fold_maps = not fold_maps
      refresh_all_views()
    end, { buffer = buf, desc = 'Daml: Toggle Map Folding' })
  end

  vim.diagnostic.enable(false, { bufnr = buf })

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    '⏳ Waiting for Daml Server notification...',
    'URI: ' .. raw_uri,
  })
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = 'markdown'

  vim.keymap.set('n', 'q', function()
    _G.DamlVirtualBuffers[raw_uri] = nil
    raw_content_cache[raw_uri] = nil

    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    local client = vim.lsp.get_client_by_id(ctx.client_id)
    if client then
      client:notify('textDocument/didClose', { textDocument = { uri = raw_uri } })
    end
  end, { buffer = buf })

  local client = vim.lsp.get_client_by_id(ctx.client_id)
  if client then
    vim.notify('Daml: Subscribing...', vim.log.levels.INFO)
    client:notify('textDocument/didOpen', {
      textDocument = { uri = raw_uri, languageId = 'daml', version = 1, text = '' },
    })
  end
end

function M.setup(opts)
  if opts then
    config = vim.tbl_deep_extend('force', config, opts)
  end
  vim.api.nvim_create_user_command('DamlRunScript', function()
    vim.lsp.codelens.run()
  end, {})

  vim.api.nvim_create_autocmd({ 'BufEnter', 'CursorHold', 'InsertLeave' }, {
    group = vim.api.nvim_create_augroup('daml_codelens_refresh', { clear = true }),
    pattern = '*.daml',
    callback = function()
      vim.lsp.codelens.refresh()
    end,
  })
end

return M
