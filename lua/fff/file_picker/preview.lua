--- Advanced file preview module inspired by Snacks.nvim and Telescope
--- Provides sophisticated file content rendering with syntax highlighting

local M = {}

-- Lazy loading prevents startup performance degradation.
local image = nil
local icons = nil

local file_reader = require('fff.file_picker.preview.file_reader')
local formatters = require('fff.file_picker.preview.formatters')
local info = require('fff.file_picker.preview.info')

local function get_image()
  if not image then image = require('fff.file_picker.image') end
  return image
end

local function get_icons()
  if not icons then icons = require('fff.file_picker.icons') end
  return icons
end

local function safe_set_buffer_lines(bufnr, start, end_line, strict_indexing, lines)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return false end

  local was_modifiable = vim.api.nvim_buf_get_option(bufnr, 'modifiable')
  vim.api.nvim_buf_set_option(bufnr, 'modifiable', true)

  local ok, err = pcall(vim.api.nvim_buf_set_lines, bufnr, start, end_line, strict_indexing, lines)

  vim.api.nvim_buf_set_option(bufnr, 'modifiable', was_modifiable)

  if not ok then
    vim.notify('Error setting buffer lines: ' .. err, vim.log.levels.WARN)
    return false
  end

  return true
end

M.config = {
  max_lines = 1000,
  max_file_size = 10 * 1024 * 1024, -- 10MB
  line_numbers = false,
  wrap_lines = false,
  show_file_info = false,
  binary_file_threshold = 1024, -- bytes to check for binary content

  -- File type specific configurations
  previews = {
    ['*.md'] = { wrap_lines = true },
    ['*.txt'] = { wrap_lines = true },
    ['*.log'] = { tail_lines = 100 },
    ['*.json'] = { format = true },
  },
}

M.state = {
  bufnr = nil,
  winid = nil,
  current_file = nil,
  scroll_offset = 0,
  content_height = 0,
}

--- Setup preview configuration
--- @param config table Configuration options
function M.setup(config)
  M.config = vim.tbl_deep_extend('force', M.config, config or {})

  -- Setup submodules with configuration.
  file_reader.setup({
    binary_file_threshold = M.config.binary_file_threshold,
    max_lines = M.config.max_lines,
    max_file_size = M.config.max_file_size,
  })

  formatters.setup({
    line_numbers = M.config.line_numbers,
    wrap_lines = M.config.wrap_lines,
  })
end

-- Note: Removed delegation functions - using submodules directly for cleaner code

--- Preview a regular file
--- @param file_path string Path to the file
--- @param bufnr number Buffer number for preview
--- @param file table Optional file information from search results for debug info
--- @return boolean Success status
function M.preview_file(file_path, bufnr, file)
  local file_info = file_reader.get_file_info(file_path)
  if not file_info then return false end

  -- Check file size
  if file_reader.is_file_too_large(file_path) then
    local size_info = file_reader.get_size_info(file_path)
    local lines = formatters.create_size_error_message(size_info)
    safe_set_buffer_lines(bufnr, 0, -1, false, lines)
    return true
  end

  -- Get file-specific configuration
  local file_config = M.get_file_config(file_path)

  -- Create debug card (only shown when debug mode is enabled)
  local debug_card = info.create_debug_card(file or {}, file_info)

  -- Create header
  local header = info.create_file_info_header(file_info, M.config.show_file_info)

  -- Read content
  local content
  if file_config.tail_lines then
    content = file_reader.read_file_tail(file_path, file_config.tail_lines)
    if content then
      local tail_indicator = formatters.create_tail_indicator(file_config.tail_lines)
      table.insert(header, tail_indicator)
      table.insert(header, '')
    end
  else
    content = file_reader.read_file_content(file_path, M.config.max_lines)
  end

  if not content then
    local error_lines = formatters.create_read_error_message()
    local lines = vim.list_extend(debug_card, vim.list_extend(header, error_lines))
    safe_set_buffer_lines(bufnr, 0, -1, false, lines)
    return false
  end

  -- Format content using formatters module
  content = formatters.format_content(content, file_info, file_config)

  -- Combine debug card, header and content
  local all_lines = vim.list_extend(debug_card, vim.list_extend(header, content))

  -- Set buffer content safely
  safe_set_buffer_lines(bufnr, 0, -1, false, all_lines)

  -- Set filetype for syntax highlighting
  vim.api.nvim_buf_set_option(bufnr, 'filetype', file_info.filetype)

  -- Set buffer options (make non-modifiable after content is set)
  vim.api.nvim_buf_set_option(bufnr, 'modifiable', false)
  vim.api.nvim_buf_set_option(bufnr, 'readonly', true)
  vim.api.nvim_buf_set_option(bufnr, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(bufnr, 'wrap', file_config.wrap_lines or M.config.wrap_lines)

  -- Store content info for scrolling
  M.state.content_height = #all_lines
  M.state.scroll_offset = 0

  return true
end

--- Preview a binary file
--- @param file_path string Path to the file
--- @param bufnr number Buffer number for preview
--- @param file_info table File information
--- @param file table Optional file information from search results for debug info
--- @return boolean Success status
function M.preview_binary_file(file_path, bufnr, file_info, file)
  -- Create debug card (only shown when debug mode is enabled)
  local debug_card = info.create_debug_card(file or {}, file_info)

  local header = info.create_file_info_header(file_info, M.config.show_file_info)
  local binary_message = formatters.create_binary_message()

  local lines = vim.list_extend(debug_card, vim.list_extend(header, binary_message))

  safe_set_buffer_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(bufnr, 'filetype', 'text')
  vim.api.nvim_buf_set_option(bufnr, 'modifiable', false)
  vim.api.nvim_buf_set_option(bufnr, 'readonly', true)

  return true
end

--- Get file-specific configuration
--- @param file_path string Path to the file
--- @return table Configuration for the file
function M.get_file_config(file_path)
  local filename = vim.fn.fnamemodify(file_path, ':t')
  local extension = '*.' .. vim.fn.fnamemodify(file_path, ':e'):lower()

  -- Check for exact filename match first
  if M.config.previews[filename] then return M.config.previews[filename] end

  -- Check for extension match
  if M.config.previews[extension] then return M.config.previews[extension] end

  -- Return default configuration
  return {}
end

--- Main preview function
--- @param file_path string Path to the file or directory
--- @param bufnr number Buffer number for preview
--- @param file table Optional file information from search results for debug info
--- @return boolean Success status
function M.preview(file_path, bufnr, file)
  if not file_path or file_path == '' then
    M.clear_buffer_completely(bufnr)
    local no_file_lines = formatters.create_no_file_message()
    safe_set_buffer_lines(bufnr, 0, -1, false, no_file_lines)
    return false
  end

  M.state.current_file = file_path
  M.state.bufnr = bufnr

  local stat = vim.loop.fs_stat(file_path)
  if not stat then
    M.clear_buffer_completely(bufnr)
    local not_found_lines = formatters.create_not_found_message(file_path)
    safe_set_buffer_lines(bufnr, 0, -1, false, not_found_lines)
    return false
  end

  -- Clear buffer completely before switching content types
  M.clear_buffer_completely(bufnr)

  -- Handle different file types
  if stat.type == 'directory' then
    local directory_lines = formatters.create_directory_message(file_path)
    safe_set_buffer_lines(bufnr, 0, -1, false, directory_lines)
    return false
  elseif get_image().is_image(file_path) then
    -- Delegate to image preview
    local win_width = 80
    local win_height = 24

    -- Try to get actual window dimensions if available
    if M.state.winid and vim.api.nvim_win_is_valid(M.state.winid) then
      win_width = vim.api.nvim_win_get_width(M.state.winid) - 2
      win_height = vim.api.nvim_win_get_height(M.state.winid) - 2
    end

    get_image().display_image(file_path, bufnr, win_width, win_height)
    return true
  elseif file_reader.is_binary_file(file_path) then
    -- Handle binary files before attempting to read as text
    local file_info = file_reader.get_file_info(file_path)
    return M.preview_binary_file(file_path, bufnr, file_info, file)
  else
    return M.preview_file(file_path, bufnr, file)
  end
end

--- Scroll preview content
--- @param lines number Number of lines to scroll (positive = down, negative = up)
function M.scroll(lines)
  if not M.state.bufnr or not vim.api.nvim_buf_is_valid(M.state.bufnr) then return end

  if not M.state.winid or not vim.api.nvim_win_is_valid(M.state.winid) then return end

  -- Get current cursor position
  local cursor = vim.api.nvim_win_get_cursor(M.state.winid)
  local current_line = cursor[1]
  local win_height = vim.api.nvim_win_get_height(M.state.winid)

  -- Calculate new position
  local new_line = math.max(1, math.min(M.state.content_height, current_line + lines))

  -- Set new cursor position
  vim.api.nvim_win_set_cursor(M.state.winid, { new_line, 0 })

  -- Update scroll offset
  M.state.scroll_offset = new_line
end

--- Set preview window
--- @param winid number Window ID for the preview
function M.set_preview_window(winid) M.state.winid = winid end

--- Create preview header with file information (delegate to formatters)
--- @param file table File information from search results
--- @return table Lines for the preview header
function M.create_preview_header(file) return formatters.create_preview_header(file) end

--- Update file info buffer
--- @param file table File information from search results
--- @param bufnr number Buffer number for file info
--- @return boolean Success status
function M.update_file_info_buffer(file, bufnr, file_index)
  if not file then
    local no_file_lines = formatters.create_no_file_message()
    safe_set_buffer_lines(bufnr, 0, -1, false, no_file_lines)
    return false
  end

  local file_info = file_reader.get_file_info(file.path)
  if not file_info then
    safe_set_buffer_lines(bufnr, 0, -1, false, { 'File info unavailable' })
    return false
  end

  local file_info_lines = info.create_file_info_content(file, file_info, file_index)
  safe_set_buffer_lines(bufnr, 0, -1, false, file_info_lines)

  -- Set buffer options
  vim.api.nvim_buf_set_option(bufnr, 'modifiable', false)
  vim.api.nvim_buf_set_option(bufnr, 'readonly', true)
  vim.api.nvim_buf_set_option(bufnr, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(bufnr, 'wrap', false)

  return true
end

--- Clear buffer completely including any image attachments
--- @param bufnr number Buffer number to clear
function M.clear_buffer_completely(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end

  -- Clear any image attachments first
  get_image().clear_buffer_images(bufnr)

  -- Clear text content
  safe_set_buffer_lines(bufnr, 0, -1, false, {})

  -- Reset filetype to prevent syntax highlighting issues
  vim.api.nvim_buf_set_option(bufnr, 'filetype', '')
end

--- Clear preview
function M.clear()
  if M.state.bufnr and vim.api.nvim_buf_is_valid(M.state.bufnr) then
    M.clear_buffer_completely(M.state.bufnr)

    local no_preview_lines = formatters.create_no_preview_message()
    safe_set_buffer_lines(M.state.bufnr, 0, -1, false, no_preview_lines)
  end

  M.state.current_file = nil
  M.state.scroll_offset = 0
  M.state.content_height = 0
end

return M
