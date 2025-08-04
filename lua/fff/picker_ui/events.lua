-- Event handling for fff.nvim picker UI
-- Handles keymaps, input changes, navigation, and user interactions

local M = {}

local layout = require('fff.layout')

local function normalize_keys(keys)
  if type(keys) == 'string' then
    return { keys }
  elseif type(keys) == 'table' then
    return keys
  else
    return {}
  end
end

function M.setup_keymaps(state, callbacks)
  local keymaps = state.config.keymaps
  local input_opts = { buffer = state.input_buf, noremap = true, silent = true }
  local list_opts = { buffer = state.list_buf, noremap = true, silent = true }

  -- File selection keymaps.
  M.setup_selection_keymaps(keymaps, input_opts, list_opts, callbacks)

  -- Navigation keymaps.
  M.setup_navigation_keymaps(keymaps, input_opts, list_opts, callbacks)

  -- Preview scroll keymaps.
  M.setup_preview_keymaps(keymaps, input_opts, list_opts, callbacks)

  -- Special input handling.
  M.setup_input_handling(state, input_opts, callbacks)

  -- Focus guards and window navigation.
  M.setup_focus_guards(state, input_opts, list_opts, callbacks)
end

function M.setup_selection_keymaps(keymaps, input_opts, list_opts, callbacks)
  -- Close picker.
  for _, key in ipairs(normalize_keys(keymaps.close)) do
    vim.keymap.set('i', key, callbacks.close, input_opts)
    vim.keymap.set('n', key, callbacks.close, list_opts)
  end

  -- Select file.
  for _, key in ipairs(normalize_keys(keymaps.select)) do
    vim.keymap.set('i', key, callbacks.select, input_opts)
    vim.keymap.set('n', key, callbacks.select, list_opts)
  end

  -- Select with split.
  for _, key in ipairs(normalize_keys(keymaps.select_split)) do
    vim.keymap.set('i', key, function() callbacks.select('split') end, input_opts)
    vim.keymap.set('n', key, function() callbacks.select('split') end, list_opts)
  end

  -- Select with vsplit.
  for _, key in ipairs(normalize_keys(keymaps.select_vsplit)) do
    vim.keymap.set('i', key, function() callbacks.select('vsplit') end, input_opts)
    vim.keymap.set('n', key, function() callbacks.select('vsplit') end, list_opts)
  end

  -- Select with tab.
  for _, key in ipairs(normalize_keys(keymaps.select_tab)) do
    vim.keymap.set('i', key, function() callbacks.select('tab') end, input_opts)
    vim.keymap.set('n', key, function() callbacks.select('tab') end, list_opts)
  end
end

function M.setup_navigation_keymaps(keymaps, input_opts, list_opts, callbacks)
  for _, key in ipairs(normalize_keys(keymaps.move_up)) do
    vim.keymap.set('i', key, callbacks.move_up, input_opts)
    vim.keymap.set('n', key, callbacks.move_up, list_opts)
  end

  for _, key in ipairs(normalize_keys(keymaps.move_down)) do
    vim.keymap.set('i', key, callbacks.move_down, input_opts)
    vim.keymap.set('n', key, callbacks.move_down, list_opts)
  end
end

function M.setup_preview_keymaps(keymaps, input_opts, list_opts, callbacks)
  for _, key in ipairs(normalize_keys(keymaps.preview_scroll_up)) do
    vim.keymap.set('i', key, callbacks.scroll_preview_up, input_opts)
    vim.keymap.set('n', key, callbacks.scroll_preview_up, list_opts)
  end

  for _, key in ipairs(normalize_keys(keymaps.preview_scroll_down)) do
    vim.keymap.set('i', key, callbacks.scroll_preview_down, input_opts)
    vim.keymap.set('n', key, callbacks.scroll_preview_down, list_opts)
  end
end

function M.setup_input_handling(state, input_opts, callbacks)
  -- Ctrl-W word deletion in input.
  vim.keymap.set('i', '<C-w>', function()
    local col = vim.fn.col('.') - 1
    local line = vim.fn.getline('.')
    local prompt_len = #state.config.prompt

    if col <= prompt_len then return '' end

    local text_part = line:sub(prompt_len + 1, col)
    local after_cursor = line:sub(col + 1)

    local new_text = text_part:gsub('%S*%s*$', '')
    local new_line = state.config.prompt .. new_text .. after_cursor
    local new_col = prompt_len + #new_text

    vim.fn.setline('.', new_line)
    vim.fn.cursor(vim.fn.line('.'), new_col + 1)

    return ''
  end, input_opts)

  vim.api.nvim_buf_attach(state.input_buf, false, {
    on_lines = function()
      vim.schedule(function() callbacks.on_input_change() end)
    end,
  })
end

function M.setup_focus_guards(state, input_opts, list_opts, callbacks)
  local function focus_switch()
    local current_win = vim.api.nvim_get_current_win()
    if current_win == state.input_win then
      vim.api.nvim_set_current_win(state.list_win)
    elseif current_win == state.list_win then
      vim.api.nvim_set_current_win(state.input_win)
      vim.cmd('startinsert!')
    else
      vim.api.nvim_set_current_win(state.input_win)
      vim.cmd('startinsert!')
    end
  end

  local window_nav_commands = {
    '<C-w>w',
    '<C-w><C-w>', -- Next window
    '<C-w>h',
    '<C-w><C-h>', -- Left window
    '<C-w>j',
    '<C-w><C-j>', -- Down window
    '<C-w>k',
    '<C-w><C-k>', -- Up window
    '<C-w>l',
    '<C-w><C-l>', -- Right window
    '<C-w>p',
    '<C-w><C-p>', -- Previous window
    '<C-w>t',
    '<C-w><C-t>', -- First window
    '<C-w>b',
    '<C-w><C-b>', -- Last window
  }

  -- Set up window navigation overrides.
  for _, cmd in ipairs(window_nav_commands) do
    vim.keymap.set('i', cmd, focus_switch, input_opts)
    vim.keymap.set('n', cmd, focus_switch, input_opts)
    vim.keymap.set('n', cmd, focus_switch, list_opts)
  end

  -- Prevent command mode and other exits.
  vim.keymap.set('i', ':', callbacks.close, input_opts)
  vim.keymap.set('n', ':', callbacks.close, input_opts)
  vim.keymap.set('n', ':', callbacks.close, list_opts)

  vim.keymap.set('n', 'ZZ', callbacks.close, input_opts)
  vim.keymap.set('n', 'ZQ', callbacks.close, input_opts)
  vim.keymap.set('n', 'ZZ', callbacks.close, list_opts)
  vim.keymap.set('n', 'ZQ', callbacks.close, list_opts)

  -- Alternate buffer switch.
  vim.keymap.set('i', '<C-^>', focus_switch, input_opts)
  vim.keymap.set('n', '<C-^>', focus_switch, input_opts)
  vim.keymap.set('n', '<C-^>', focus_switch, list_opts)
  vim.keymap.set('i', '<C-6>', focus_switch, input_opts)
  vim.keymap.set('n', '<C-6>', focus_switch, input_opts)
  vim.keymap.set('n', '<C-6>', focus_switch, list_opts)

  -- Debug toggle.
  vim.keymap.set('i', '<F2>', callbacks.toggle_debug, input_opts)
  vim.keymap.set('n', '<F2>', callbacks.toggle_debug, input_opts)
  vim.keymap.set('n', '<F2>', callbacks.toggle_debug, list_opts)
end

function M.handle_input_change(state)
  if not state.active then return end

  local lines = vim.api.nvim_buf_get_lines(state.input_buf, 0, -1, false)
  local prompt_len = #state.config.prompt
  local query = ''

  if #lines > 1 then
    -- Handle multi-line paste - join all lines.
    local all_text = table.concat(lines, '')
    if all_text:sub(1, prompt_len) == state.config.prompt then
      query = all_text:sub(prompt_len + 1)
    else
      query = all_text
    end

    query = query:gsub('\r', ''):match('^%s*(.-)%s*$') or ''

    -- Normalize back to single line.
    vim.api.nvim_buf_set_option(state.input_buf, 'modifiable', true)
    vim.api.nvim_buf_set_lines(state.input_buf, 0, -1, false, { state.config.prompt .. query })

    -- Restore cursor position.
    vim.schedule(function()
      if state.active and state.input_win and vim.api.nvim_win_is_valid(state.input_win) then
        vim.api.nvim_win_set_cursor(state.input_win, { 1, prompt_len + #query })
      end
    end)
  else
    local full_line = lines[1] or ''
    if full_line:sub(1, prompt_len) == state.config.prompt then query = full_line:sub(prompt_len + 1) end
  end

  return query
end

function M.move_up(state, total_items)
  if not state.active then return false end

  local new_cursor = layout.get_current().move_selection_up(state.cursor, total_items)
  if new_cursor ~= state.cursor then
    state.cursor = new_cursor
    return true
  end
  return false
end

function M.move_down(state, total_items)
  if not state.active then return false end

  local new_cursor = layout.get_current().move_selection_down(state.cursor, total_items)
  if new_cursor ~= state.cursor then
    state.cursor = new_cursor
    return true
  end
  return false
end

return M
