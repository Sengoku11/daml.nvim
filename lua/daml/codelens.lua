---@class Sengoku11.Daml.CodeLens
local M = {}

local config = { render = true }

-- Global registry to map Virtual URIs -> Neovim Buffer IDs
_G.DamlVirtualBuffers = _G.DamlVirtualBuffers or {}

-- View State Management
local active_view = 'table' -- 'table', 'transaction' or 'html'
local fold_maps = true -- Toggle for folding long Map[...] structures
local show_archived = false -- Toggle for showing archived contracts (rows)
local compact_tables = true -- Toggle for compact tables (trim decimals & types)
local is_fullscreen = false -- Toggle for fullscreen mode tracking
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
  if active_view == 'html' then
    return html
  end

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

  -- 1.5. Filter Archived Contracts (if enabled and applicable)
  if not show_archived then
    -- Remove rows with class="archived".
    text = text:gsub('<tr[^>]*class="archived"[^>]*>.-</tr>', '')

    -- Remove empty tables (containers) that have no data rows left.
    -- Matches structure: <div ...><h1>...</h1><table>...</table></div>
    text = text:gsub('(<div[^>]*>%s*<h1[^>]*>.-</h1>%s*<table>(.-)</table>%s*</div>)', function(block, content)
      -- If the table content has no <td> cells (only <th> headers), it's considered empty.
      if not content:find '<td' then
        return ''
      end
      return block
    end)
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

  -- 10.5. COMPACT TABLES LOGIC
  if compact_tables then
    local lines = vim.split(text, '\n')
    local new_lines = {}

    for _, line in ipairs(lines) do
      -- Apply compaction only to lines that look like table rows (contain a pipe |).
      -- This reliably excludes Headers (# Title) and other non-table text.
      if line:find('|', 1, true) then
        -- 1. Trim Decimals
        line = line:gsub('(%d+%.%d+)', function(match)
          local trimmed = match:gsub('0+$', '')
          if trimmed:sub(-1) == '.' then
            return trimmed .. '0'
          end
          return trimmed
        end)

        -- 2. Trim Types (Table View Only)
        if active_view == 'table' then
          -- Robust Context-Agnostic Regex:
          -- Finds structure: Path + Separator + Type
          -- Path: Starts with word char, contains alphanum/dots/underscores/hyphens
          -- Separator: Colon
          -- Type: Starts with Uppercase, contains alphanum/underscores
          line = line:gsub('([%w_][%.%w_%-]*):([A-Z][%w_]*)', '%2')
        end
      end
      table.insert(new_lines, line)
    end
    text = table.concat(new_lines, '\n')
  end

  -- 11. MAP FOLDING (Only in Table View)
  if active_view == 'table' and fold_maps then
    local map_refs = {}
    local map_count = 0

    -- Match Map[...] patterns
    text = text:gsub('(Map%b[])', function(match)
      if #match > 50 then
        map_count = map_count + 1
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
      local h_mark = (active_view == 'html') and '[x]' or '[ ]'
      local m_mark = fold_maps and '[x]' or '[ ]'
      local a_mark = show_archived and '[x]' or '[ ]'
      local c_mark = compact_tables and '[x]' or '[ ]'

      -- Fullscreen Logic
      local f_mark = is_fullscreen and '[x]' or '[ ]'
      local f_desc = is_fullscreen and 'Close Fullscreen' or 'Enter Fullscreen'

      local header_lines = {
        'Controls: <q> close, <CR> toggle option',
        '',
        'View Config:',
        string.format('- %s <leader>vt - Table view', t_mark),
        string.format('- %s <leader>vx - Tx view', x_mark),
        string.format('- %s <leader>vh - Show HTML', h_mark),
        string.format('- %s <leader>vm - Fold maps', m_mark),
        string.format('- %s <leader>va - Show archived', a_mark),
        string.format('- %s <leader>vc - Compact tables', c_mark),
        string.format('- %s <leader>vf - %s', f_mark, f_desc),
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
function M.on_virtual_resource_change(_, result, _)
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

  local existing_buf = _G.DamlVirtualBuffers[raw_uri]
  if existing_buf and vim.api.nvim_buf_is_valid(existing_buf) then
    local winnr = vim.fn.bufwinnr(existing_buf)
    if winnr ~= -1 then
      -- Window exists in current tab, jump to it
      vim.cmd(winnr .. 'wincmd w')
    else
      -- Buffer exists but hidden or in another tab: Open new split with existing buffer
      vim.cmd 'botright vsplit'
      local win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, existing_buf)

      -- We must reapply window options (wrapping, numbers, etc)
      local wo = vim.wo[win]
      wo.wrap = false
      wo.virtualedit = 'all'
      wo.number = false
      wo.signcolumn = 'no'
      wo.foldcolumn = '0'
      wo.cursorline = true
      wo.spell = false
      wo.sidescrolloff = 0
    end
    -- STOP HERE. Don't re-init, don't send didOpen again.
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  _G.DamlVirtualBuffers[raw_uri] = buf

  vim.cmd 'botright vsplit'
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)

  -- Ensure buffer is wiped when window closes to trigger auto-cleanup
  vim.bo[buf].bufhidden = 'wipe'

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

    vim.keymap.set('n', '<leader>vh', function()
      active_view = 'html'
      refresh_all_views()
    end, { buffer = buf, desc = 'Daml: Switch to HTML View' })

    vim.keymap.set('n', '<leader>vm', function()
      fold_maps = not fold_maps
      refresh_all_views()
    end, { buffer = buf, desc = 'Daml: Toggle Map Folding' })

    vim.keymap.set('n', '<leader>va', function()
      show_archived = not show_archived
      refresh_all_views()
    end, { buffer = buf, desc = 'Daml: Toggle Archived Contracts' })

    vim.keymap.set('n', '<leader>vc', function()
      compact_tables = not compact_tables
      refresh_all_views()
    end, { buffer = buf, desc = 'Daml: Toggle Compact Tables' })

    vim.keymap.set('n', '<leader>vf', function()
      if vim.t.daml_zoomed then
        vim.cmd 'tabclose'
        is_fullscreen = false
      else
        vim.cmd 'tab split'
        vim.t.daml_zoomed = true
        is_fullscreen = true
      end
      refresh_all_views()
    end, { buffer = buf, desc = 'Daml: Toggle Fullscreen' })

    vim.keymap.set('n', '<CR>', function()
      local line = vim.api.nvim_get_current_line()
      if line:find('<leader>vt', 1, true) then
        active_view = 'table'
        refresh_all_views()
      elseif line:find('<leader>vx', 1, true) then
        active_view = 'transaction'
        refresh_all_views()
      elseif line:find('<leader>vh', 1, true) then
        active_view = 'html'
        refresh_all_views()
      elseif line:find('<leader>vm', 1, true) then
        fold_maps = not fold_maps
        refresh_all_views()
      elseif line:find('<leader>va', 1, true) then
        show_archived = not show_archived
        refresh_all_views()
      elseif line:find('<leader>vc', 1, true) then
        compact_tables = not compact_tables
        refresh_all_views()
      elseif line:find('<leader>vf', 1, true) then
        if vim.t.daml_zoomed then
          vim.cmd 'tabclose'
          is_fullscreen = false
        else
          vim.cmd 'tab split'
          vim.t.daml_zoomed = true
          is_fullscreen = true
        end
        refresh_all_views()
      end
    end, { buffer = buf, desc = 'Daml: Toggle View Setting' })
  end

  vim.diagnostic.enable(false, { bufnr = buf })

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    '⏳ Waiting for Daml Server notification...',
    'URI: ' .. raw_uri,
  })
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = 'markdown'

  -- Robust cleanup handler that fires on buffer death (via q, :bd, snacks.bufdelete, etc.)
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    callback = function()
      -- Check if this specific buffer is still the registered one to avoid race conditions
      if _G.DamlVirtualBuffers[raw_uri] == buf then
        _G.DamlVirtualBuffers[raw_uri] = nil
        raw_content_cache[raw_uri] = nil

        local client = vim.lsp.get_client_by_id(ctx.client_id)
        if client then
          client:notify('textDocument/didClose', { textDocument = { uri = raw_uri } })
        end
      end
    end,
  })

  vim.keymap.set('n', 'q', function()
    if vim.t.daml_zoomed then
      -- If in fullscreen tab, just close the tab (exit fullscreen)
      vim.cmd 'tabclose'
      is_fullscreen = false
      refresh_all_views()
    else
      -- Force wipeout to trigger the BufWipeout autocommand defined above
      vim.cmd('bwipeout ' .. buf)
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
