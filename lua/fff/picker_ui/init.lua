-- fff.nvim Picker UI - Main interface (properly organized module structure)
-- Consolidated from over-engineered delegation pattern

local M = {}

local fuzzy = require('fff.fuzzy')
local preview = require('fff.file_picker.preview')
local main = require('fff.main')
local layout = require('fff.layout')

local preview_cache = require('fff.picker_ui.preview_cache')
local rendering = require('fff.picker_ui.rendering')
local events = require('fff.picker_ui.events')

-- Core state.
M.state = {
  active = false,
  layout = nil,
  input_win = nil,
  initial_render_complete = false,
  render_scheduled = false,
  input_buf = nil,
  list_win = nil,
  list_buf = nil,
  file_info_win = nil,
  file_info_buf = nil,
  preview_win = nil,
  preview_buf = nil,

  items = {},
  filtered_items = {},
  cursor = 1,
  top = 1,
  query = '',
  item_line_map = {},

  config = nil,
  ns_id = nil,
  last_status_info = nil,
  update_timer = nil,
  update_debounce_ms = 10,
  last_preview_file = nil,
  current_file_cache = nil,
}

function M.create_ui()
  local config = M.state.config

  preview_cache.init_config(main.config)
  layout.setup(main.config)

  if not M.state.ns_id then M.state.ns_id = vim.api.nvim_create_namespace('fff_picker_status') end

  local debug_enabled = main.config and main.config.debug and main.config.debug.show_scores

  local width = math.floor(vim.o.columns * config.width)
  local height = math.floor(vim.o.lines * config.height)
  local col = math.floor((vim.o.columns - width) / 2)
  local row = math.floor((vim.o.lines - height) / 2)

  local preview_width = M.enabled_preview() and math.floor(width * config.preview.width) or 0
  local list_width = width - preview_width - 3 -- Account for separators

  local input_row, list_row, list_height = layout.get_current().calculate_window_positions(row, height)

  local file_info_height = 0
  local preview_height = list_height
  if debug_enabled then
    file_info_height = 10
    preview_height = list_height - file_info_height
  end

  M.create_buffers(debug_enabled)

  M.create_windows(
    col,
    row,
    list_width,
    list_height,
    preview_width,
    input_row,
    list_row,
    file_info_height,
    preview_height,
    debug_enabled
  )

  M.setup_buffers()
  M.setup_windows()
  M.setup_keymaps()

  vim.api.nvim_set_current_win(M.state.input_win)
  preview.set_preview_window(M.state.preview_win)

  M.update_results()
  M.clear_preview()
  M.update_status()

  return true
end

function M.create_buffers(debug_enabled)
  local buf_opts = { false, true }
  M.state.input_buf = vim.api.nvim_create_buf(buf_opts[1], buf_opts[2])
  M.state.list_buf = vim.api.nvim_create_buf(buf_opts[1], buf_opts[2])

  if M.enabled_preview() then M.state.preview_buf = vim.api.nvim_create_buf(buf_opts[1], buf_opts[2]) end

  if debug_enabled then
    M.state.file_info_buf = vim.api.nvim_create_buf(buf_opts[1], buf_opts[2])
  else
    M.state.file_info_buf = nil
  end
end

function M.create_windows(
  col,
  row,
  list_width,
  list_height,
  preview_width,
  input_row,
  list_row,
  file_info_height,
  preview_height,
  debug_enabled
)
  -- Main file list window.
  M.state.list_win = vim.api.nvim_open_win(M.state.list_buf, false, {
    relative = 'editor',
    width = list_width,
    height = list_height,
    col = col + 1,
    row = list_row,
    border = 'single',
    style = 'minimal',
    title = ' Files ',
    title_pos = 'left',
  })

  -- File info window.
  if debug_enabled then
    M.state.file_info_win = vim.api.nvim_open_win(M.state.file_info_buf, false, {
      relative = 'editor',
      width = preview_width,
      height = file_info_height,
      col = col + list_width + 3,
      row = row + 1,
      border = 'single',
      style = 'minimal',
      title = ' File Info ',
      title_pos = 'left',
    })
  else
    M.state.file_info_win = nil
  end

  -- Preview window.
  if M.enabled_preview() then
    local preview_row = debug_enabled and (row + file_info_height + 3) or (row + 1)
    local preview_height_adj = debug_enabled and preview_height or (list_height + 2)

    M.state.preview_win = vim.api.nvim_open_win(M.state.preview_buf, false, {
      relative = 'editor',
      width = preview_width,
      height = preview_height_adj,
      col = col + list_width + 3,
      row = preview_row,
      border = 'single',
      style = 'minimal',
      title = ' Preview ',
      title_pos = 'left',
    })
  end

  -- Input window.
  M.state.input_win = vim.api.nvim_open_win(M.state.input_buf, false, {
    relative = 'editor',
    width = list_width,
    height = 1,
    col = col + 1,
    row = input_row,
    border = 'single',
    style = 'minimal',
  })
end

function M.setup_buffers()
  vim.api.nvim_buf_set_option(M.state.input_buf, 'buftype', 'prompt')
  vim.api.nvim_buf_set_option(M.state.input_buf, 'filetype', 'fff_input')
  vim.fn.prompt_setprompt(M.state.input_buf, M.state.config.prompt)

  vim.api.nvim_buf_set_option(M.state.list_buf, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(M.state.list_buf, 'filetype', 'fff_list')
  vim.api.nvim_buf_set_option(M.state.list_buf, 'modifiable', false)

  if M.state.file_info_buf then
    vim.api.nvim_buf_set_option(M.state.file_info_buf, 'buftype', 'nofile')
    vim.api.nvim_buf_set_option(M.state.file_info_buf, 'filetype', 'fff_file_info')
    vim.api.nvim_buf_set_option(M.state.file_info_buf, 'modifiable', false)
  end

  if M.enabled_preview() then
    vim.api.nvim_buf_set_option(M.state.preview_buf, 'buftype', 'nofile')
    vim.api.nvim_buf_set_option(M.state.preview_buf, 'filetype', 'fff_preview')
    vim.api.nvim_buf_set_option(M.state.preview_buf, 'modifiable', false)
  end
end

function M.setup_windows()
  local windows = {
    { M.state.input_win, false },
    { M.state.list_win, true },
    { M.state.preview_win, false },
  }

  for _, win_info in ipairs(windows) do
    local win, enable_signcolumn = win_info[1], win_info[2]
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_option(win, 'wrap', false)
      vim.api.nvim_win_set_option(win, 'cursorline', false)
      vim.api.nvim_win_set_option(win, 'number', false)
      vim.api.nvim_win_set_option(win, 'relativenumber', false)
      vim.api.nvim_win_set_option(win, 'signcolumn', enable_signcolumn and 'yes:1' or 'no')
      vim.api.nvim_win_set_option(win, 'foldcolumn', '0')
    end
  end
end

function M.setup_keymaps()
  local callbacks = {
    close = M.close,
    select = M.select,
    move_up = M.move_up,
    move_down = M.move_down,
    scroll_preview_up = M.scroll_preview_up,
    scroll_preview_down = M.scroll_preview_down,
    toggle_debug = M.toggle_debug,
    on_input_change = M.on_input_change,
  }

  events.setup_keymaps(M.state, callbacks)
end

function M.on_input_change()
  local query = events.handle_input_change(M.state)

  -- Guard against spurious empty query events during initial render.
  if not M.state.initial_render_complete and query == '' then return end

  if query then
    if type(query) == 'string' and #query <= 1000 then -- Reasonable query length limit
      M.state.query = query
      M.update_results()
    end
  end
end

-- Navigation functions (consolidated with debouncing).
function M.move_up()
  if events.move_up(M.state, #M.state.filtered_items) then M.debounced_update() end
end

function M.move_down()
  if events.move_down(M.state, #M.state.filtered_items) then M.debounced_update() end
end

function M.update_results()
  if not M.state.active then return end

  -- Render deduplication.
  if not M.state.render_scheduled then
    M.state.render_scheduled = true
    vim.schedule(function()
      M.render_complete_ui()
      M.state.render_scheduled = false
    end)
  end
end

function M.render_complete_ui()
  if not M.state.active then return end

  -- Cache current file if not already cached.
  if not M.state.current_file_cache then
    local current_buf = vim.api.nvim_get_current_buf()

    if current_buf and vim.api.nvim_buf_is_valid(current_buf) then
      local current_file = vim.api.nvim_buf_get_name(current_buf)

      M.state.current_file_cache = (current_file ~= '' and vim.fn.filereadable(current_file) == 1) and current_file
        or nil
    end
  end

  local max_threads = M.state.config.max_threads or 4
  local ok, search_result =
    pcall(fuzzy.fuzzy_search_files, M.state.query, M.state.config.max_results, max_threads, M.state.current_file_cache)

  local results = {}
  if ok and search_result and search_result.items then
    -- If scores are available and lengths match, merge them into the items
    if search_result.scores and #search_result.scores == #search_result.items then
      for i, item in ipairs(search_result.items) do
        item.score = search_result.scores[i]
        table.insert(results, item)
      end
    else
      -- Fallback if scores are missing or mismatched, to prevent errors
      results = search_result.items
    end
  elseif not ok then
    vim.notify('Search failed: ' .. tostring(search_result), vim.log.levels.ERROR)
  end

  M.state.items = results
  M.state.filtered_items = results

  -- Preserve cursor position across updates.
  if #results == 0 then
    M.state.cursor = 1
  elseif M.state.cursor > #results then
    M.state.cursor = math.min(M.state.cursor, #results)
  end

  M.state.top = 1
  M.debounced_update()
end

function M.debounced_update()
  if M.state.update_timer then
    vim.fn.timer_stop(M.state.update_timer)
    M.state.update_timer = nil
  end

  M.state.update_timer = vim.fn.timer_start(M.state.update_debounce_ms, function()
    if M.state.active then
      M.render_list()
      M.update_preview()
      M.update_status()

      -- Mark initial render as complete.
      if not M.state.initial_render_complete then M.state.initial_render_complete = true end
    end
    M.state.update_timer = nil
  end)
end

function M.render_list() rendering.render_list(M.state, M.state.config) end

function M.enabled_preview()
  local preview_config = M.state and M.state.config and M.state.config.preview
  if not preview_config then return true end
  return preview_config.enabled
end

function M.update_preview()
  if not M.enabled_preview() or not M.state.active then return end

  local item = preview_cache.state.pending_file
  if not item then
    -- Use current cursor position if no pending file.
    local items = M.state.filtered_items

    if #items == 0 or M.state.cursor > #items then
      M.clear_preview()
      M.state.last_preview_file = nil
      return
    end
    item = items[M.state.cursor]
  end

  if not item then
    M.clear_preview()
    M.state.last_preview_file = nil
    return
  end

  if M.state.last_preview_file == item.path then return end

  M.execute_preview_update(item)
  preview_cache.state.pending_file = nil -- Clear pending file after processing.
end

function M.update_preview_with_cache(item)
  preview_cache.state.pending_file = item
  M.debounced_update()
end

function M.execute_preview_update(item)
  if not M.enabled_preview() or not M.state.active or not item then return end

  M.state.last_preview_file = item.path
  M.update_preview_title(item)

  local cached_entry = preview_cache.get_cached_entry(item.path)
  if cached_entry then
    M.apply_cached_preview(item, cached_entry)
    return
  end

  M.show_loading_preview(item)
  vim.schedule(function() M.load_preview_async(item) end)
end

function M.update_preview_title(item)
  if not M.state.preview_win or not vim.api.nvim_win_is_valid(M.state.preview_win) then return end

  local relative_path = item.relative_path or item.path
  local win_width = vim.api.nvim_win_get_width(M.state.preview_win)
  local max_title_width = win_width - 4

  local title
  if #relative_path <= max_title_width then
    title = string.format(' %s ', relative_path)
  else
    local filename = vim.fn.fnamemodify(relative_path, ':t')
    local dirname = vim.fn.fnamemodify(relative_path, ':h')
    local available_dir_width = max_title_width - #filename - 6

    if available_dir_width > 10 then
      local truncated_dir = '...' .. dirname:sub(-available_dir_width + 3)
      title = string.format(' %s/%s ', truncated_dir, filename)
    else
      if #filename > max_title_width - 4 then filename = filename:sub(1, max_title_width - 7) .. '...' end
      title = string.format(' %s ', filename)
    end
  end

  vim.api.nvim_win_set_config(M.state.preview_win, {
    title = title,
    title_pos = 'left',
  })
end

function M.show_loading_preview(item)
  if M.state.preview_buf and vim.api.nvim_buf_is_valid(M.state.preview_buf) then
    vim.api.nvim_buf_set_option(M.state.preview_buf, 'modifiable', true)
    vim.api.nvim_buf_set_lines(M.state.preview_buf, 0, -1, false, {
      '⏳ Loading preview...',
      '',
      'File: ' .. (item.relative_path or item.path),
    })
    vim.api.nvim_buf_set_option(M.state.preview_buf, 'modifiable', false)
  end
end

function M.load_preview_async(item)
  if M.state.last_preview_file ~= item.path then return end

  local cache_entry = preview_cache.create_cache_entry(item, main.config)
  if cache_entry then
    preview_cache.add_to_cache(item.path, cache_entry)
    M.apply_cached_preview(item, cache_entry)
  else
    M.show_preview_error(item)
  end
end

function M.apply_cached_preview(item, cache_entry)
  if not M.state.preview_buf or not vim.api.nvim_buf_is_valid(M.state.preview_buf) then return end

  vim.api.nvim_buf_set_option(M.state.preview_buf, 'modifiable', true)
  vim.api.nvim_buf_set_lines(M.state.preview_buf, 0, -1, false, cache_entry.lines)
  vim.api.nvim_buf_set_option(M.state.preview_buf, 'filetype', cache_entry.filetype)
  vim.api.nvim_buf_set_option(M.state.preview_buf, 'modifiable', false)

  if M.state.file_info_buf then preview.update_file_info_buffer(item, M.state.file_info_buf, M.state.cursor) end

  preview.set_preview_window(M.state.preview_win)
end

function M.show_preview_error(item)
  if M.state.preview_buf and vim.api.nvim_buf_is_valid(M.state.preview_buf) then
    vim.api.nvim_buf_set_option(M.state.preview_buf, 'modifiable', true)
    vim.api.nvim_buf_set_lines(M.state.preview_buf, 0, -1, false, {
      '❌ Failed to load preview',
      '',
      'File: ' .. item.path,
      'File may be inaccessible or locked.',
    })
    vim.api.nvim_buf_set_option(M.state.preview_buf, 'modifiable', false)
  end

  vim.notify('FFF: Failed to load preview for ' .. item.path, vim.log.levels.DEBUG)
end

function M.clear_preview()
  if not M.state.active or not M.enabled_preview() then return end

  if M.state.preview_win and vim.api.nvim_win_is_valid(M.state.preview_win) then
    vim.api.nvim_win_set_config(M.state.preview_win, {
      title = ' Preview ',
      title_pos = 'left',
    })
  end

  if M.state.file_info_buf then
    vim.api.nvim_buf_set_option(M.state.file_info_buf, 'modifiable', true)
    vim.api.nvim_buf_set_lines(M.state.file_info_buf, 0, -1, false, {
      'File Info Panel',
      '',
      'Select a file to view:',
      '• Comprehensive scoring details',
      '• File size and type information',
      '• Git status integration',
      '• Modification & access timings',
      '• Frecency scoring breakdown',
      '',
      'Navigate: ↑↓ or Ctrl+p/n',
    })
    vim.api.nvim_buf_set_option(M.state.file_info_buf, 'modifiable', false)
  end

  if M.state.preview_buf and vim.api.nvim_buf_is_valid(M.state.preview_buf) then
    vim.api.nvim_buf_set_option(M.state.preview_buf, 'modifiable', true)
    vim.api.nvim_buf_set_lines(M.state.preview_buf, 0, -1, false, { 'No preview available' })
    vim.api.nvim_buf_set_option(M.state.preview_buf, 'modifiable', false)
  end
end

function M.scroll_preview_up()
  if not M.state.active or not M.state.preview_win then return end

  local win_height = vim.api.nvim_win_get_height(M.state.preview_win)
  local scroll_lines = math.floor(win_height / 2)
  preview.scroll(-scroll_lines)
end

function M.scroll_preview_down()
  if not M.state.active or not M.state.preview_win then return end

  local win_height = vim.api.nvim_win_get_height(M.state.preview_win)
  local scroll_lines = math.floor(win_height / 2)
  preview.scroll(scroll_lines)
end

function M.update_status()
  if not M.state.active or not M.state.ns_id then return end

  local ok, progress = pcall(fuzzy.get_scan_progress)
  if not ok then progress = { total_files = 0, scanned_files = 0, is_scanning = false } end
  -- Calculate search metadata from the last search result.
  local search_metadata = { total_matched = #M.state.items, total_files = progress.total_files }

  local status_info
  if progress.is_scanning then
    status_info = 'Scanning...'
  else
    status_info = string.format('%d/%d', search_metadata.total_matched, search_metadata.total_files)
  end

  if status_info == M.state.last_status_info then return end
  M.state.last_status_info = status_info

  vim.api.nvim_buf_clear_namespace(M.state.input_buf, M.state.ns_id, 0, -1)

  local win_width = vim.api.nvim_win_get_width(M.state.input_win)
  local available_width = win_width - 2 -- Account for borders.
  local status_len = #status_info
  local col_position = available_width - status_len

  vim.api.nvim_buf_set_extmark(M.state.input_buf, M.state.ns_id, 0, 0, {
    virt_text = { { status_info, 'LineNr' } },
    virt_text_win_col = col_position,
  })
end

-- File selection and actions with input validation
function M.select(action)
  if not M.state.active then return end

  local items = M.state.filtered_items
  if #items == 0 or M.state.cursor > #items then return end

  local item = items[M.state.cursor]
  if not item then return end

  action = action or 'edit'

  local valid_actions = { 'edit', 'split', 'vsplit', 'tab' }
  if not vim.tbl_contains(valid_actions, action) then
    vim.notify('FFF: Invalid action: ' .. action, vim.log.levels.ERROR)
    return
  end

  if not item.path or item.path == '' then
    vim.notify('FFF: Invalid file path', vim.log.levels.ERROR)
    return
  end

  local relative_path = vim.fn.fnamemodify(item.path, ':.')
  pcall(fuzzy.access_file, relative_path)

  vim.cmd('stopinsert')
  M.close()

  local file_path = vim.fn.fnameescape(item.path)
  if action == 'edit' then
    vim.cmd('edit ' .. file_path)
  elseif action == 'split' then
    vim.cmd('split ' .. file_path)
  elseif action == 'vsplit' then
    vim.cmd('vsplit ' .. file_path)
  elseif action == 'tab' then
    vim.cmd('tabedit ' .. file_path)
  end
end

function M.toggle_debug()
  local main_config = require('fff.main')
  local old_debug_state = main_config.config.debug.show_scores
  main_config.config.debug.show_scores = not main_config.config.debug.show_scores
  local status = main_config.config.debug.show_scores and 'enabled' or 'disabled'

  vim.notify('FFF debug scores ' .. status, vim.log.levels.INFO)

  if old_debug_state ~= main_config.config.debug.show_scores then
    local current_query = M.state.query
    local current_items = M.state.items
    local current_cursor = M.state.cursor

    M.close()
    M.open()

    M.state.query = current_query
    M.state.items = current_items
    M.state.cursor = current_cursor
    M.render_list()
    M.update_preview()
    M.update_status()

    vim.schedule(function()
      if M.state.active and M.state.input_win then
        vim.api.nvim_set_current_win(M.state.input_win)
        vim.cmd('startinsert!')
      end
    end)
  else
    M.update_results()
  end
end

function M.open(opts)
  if M.state.active then return end

  if not main.is_initialized() then
    local config = {
      base_path = opts and opts.cwd or vim.fn.getcwd(),
      max_results = 100,
      frecency = {
        enabled = true,
        db_path = vim.fn.stdpath('cache') .. '/fff_nvim',
      },
    }

    if not main.setup(config) then
      vim.notify('Failed to initialize FFF through main module', vim.log.levels.ERROR)
      return
    end
  else
    -- If main is initialized but with different base path, reinitialize file picker.
    local base_path = opts and opts.cwd or vim.fn.getcwd()

    if base_path ~= vim.fn.getcwd() then
      local ok, result = pcall(fuzzy.init_file_picker, base_path)
      if not ok then
        vim.notify('Failed to reinitialize file picker for path: ' .. result, vim.log.levels.ERROR)
        return
      end
    end
  end

  M.state.config = main.config

  if not M.create_ui() then
    vim.notify('Failed to create picker UI', vim.log.levels.ERROR)
    return
  end

  M.state.active = true
  vim.cmd('startinsert!')

  local ok, progress = pcall(fuzzy.get_scan_progress)
  if ok and progress and not progress.is_scanning then pcall(fuzzy.scan_files) end

  vim.defer_fn(function() M.monitor_scan_progress() end, 0)
end

function M.monitor_scan_progress()
  if not M.state.active then return end

  local ok, progress = pcall(fuzzy.get_scan_progress)
  if not ok then return end

  if progress.is_scanning then
    M.update_status()
    vim.defer_fn(function() M.monitor_scan_progress() end, 10)
  else
    M.update_results()
  end
end

function M.close()
  if not M.state.active then return end

  vim.cmd('stopinsert')
  M.state.active = false

  local windows = {
    M.state.input_win,
    M.state.list_win,
    M.state.preview_win,
    M.state.file_info_win,
  }

  for _, win in ipairs(windows) do
    if win and vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end

  local buffers = {
    M.state.input_buf,
    M.state.list_buf,
    M.state.file_info_buf,
    M.state.preview_buf,
  }

  for _, buf in ipairs(buffers) do
    if buf and vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
  end

  M.reset_state()

  preview_cache.clear_cache()
end

function M.reset_state()
  M.state.input_win = nil
  M.state.list_win = nil
  M.state.file_info_win = nil
  M.state.preview_win = nil
  M.state.input_buf = nil
  M.state.list_buf = nil
  M.state.file_info_buf = nil
  M.state.preview_buf = nil
  M.state.items = {}
  M.state.filtered_items = {}
  M.state.cursor = 1
  M.state.top = 1
  M.state.query = ''
  M.state.ns_id = nil
  M.state.last_preview_file = nil
  M.state.current_file_cache = nil
  M.state.initial_render_complete = false
  M.state.render_scheduled = false

  if M.state.update_timer then
    vim.fn.timer_stop(M.state.update_timer)
    M.state.update_timer = nil
  end

  preview_cache.clear_cache()
end

return M

