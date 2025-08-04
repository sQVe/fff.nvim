-- Content formatting utilities for preview functionality
-- Handles JSON formatting, line numbers, and other content transformations

local M = {}

M.config = {
  line_numbers = false,
  wrap_lines = false,
}

function M.setup(config) M.config = vim.tbl_deep_extend('force', M.config, config or {}) end

function M.format_json(content)
  local ok, result = pcall(vim.fn.json_decode, content)
  if not ok then return content end

  local formatted_ok, formatted = pcall(vim.fn.json_encode, result)
  if not formatted_ok then return content end

  local pretty_json =
    formatted:gsub('([{[]),', '%1,\n  '):gsub('([}]]),', '%1,\n'):gsub(':",', '": '):gsub('([^{[]){', '%1{\n  ')

  return pretty_json
end

function M.add_line_numbers(lines, start_line)
  if not M.config.line_numbers then return lines end

  start_line = start_line or 1
  local numbered_lines = {}
  local max_line_num = start_line + #lines - 1
  local line_num_width = string.len(tostring(max_line_num))

  for i, line in ipairs(lines) do
    local line_num = start_line + i - 1
    local formatted_num = string.format('%' .. line_num_width .. 'd', line_num)
    table.insert(numbered_lines, formatted_num .. ' │ ' .. line)
  end

  return numbered_lines
end

function M.format_content(content, file_info, file_config)
  if not content or not file_info then return content end

  local formatted_content = content

  if file_config.format and file_info.filetype == 'json' then
    local full_content = table.concat(formatted_content, '\n')
    local formatted_json = M.format_json(full_content)
    formatted_content = vim.split(formatted_json, '\n')
  end

  local start_line = file_config.tail_lines and math.max(1, file_info.size - file_config.tail_lines + 1) or 1
  formatted_content = M.add_line_numbers(formatted_content, start_line)

  return formatted_content
end

function M.format_file_size(size_bytes)
  if size_bytes < 1024 then
    return size_bytes .. 'B'
  elseif size_bytes < 1024 * 1024 then
    return string.format('%.1fKB', size_bytes / 1024)
  elseif size_bytes < 1024 * 1024 * 1024 then
    return string.format('%.1fMB', size_bytes / 1024 / 1024)
  else
    return string.format('%.1fGB', size_bytes / 1024 / 1024 / 1024)
  end
end

function M.format_timestamp(timestamp) return os.date('%Y-%m-%d %H:%M:%S', timestamp) end

function M.create_header(file_info, show_file_info)
  if not show_file_info or not file_info then return {} end

  local header = {}
  table.insert(header, string.format('File: %s', file_info.name))
  table.insert(header, string.format('Size: %s', file_info.size_formatted))
  table.insert(header, string.format('Modified: %s', file_info.modified_formatted))
  table.insert(header, string.format('Type: %s', file_info.filetype))

  if file_info.extension ~= '' then table.insert(header, string.format('Extension: .%s', file_info.extension)) end

  table.insert(header, string.rep('─', 50))
  table.insert(header, '')

  return header
end

function M.create_preview_header(file)
  if not file then return {} end

  local header = {}
  local filename = file.name or vim.fn.fnamemodify(file.path or '', ':t')
  local dir = file.directory or vim.fn.fnamemodify(file.path or '', ':h')
  if dir == '.' then dir = '' end

  table.insert(header, string.format('📄 %s', filename))
  if dir ~= '' then table.insert(header, string.format('📁 %s', dir)) end
  table.insert(header, string.rep('─', 50))
  table.insert(header, '')

  return header
end

function M.create_tail_indicator(tail_lines) return string.format('Showing last %d lines:', tail_lines) end

function M.create_size_error_message(size_info)
  return {
    'File too large for preview',
    string.format('Size: %s (max: %s)', size_info.formatted_size, size_info.formatted_max),
    '',
    'Use a text editor to view this file.',
  }
end

function M.create_read_error_message()
  return {
    'Failed to read file content',
    'File may be locked or inaccessible.',
  }
end

function M.create_binary_message()
  return {
    '⚠ Binary File Detected',
    '',
    'This file contains binary data and cannot be displayed as text.',
    '',
    'Binary file detected - content not displayed for performance.',
    '',
    'Use a hex editor or appropriate application to view this file.',
  }
end

function M.create_directory_message(file_path)
  return {
    'Directory Preview Not Available',
    '',
    'This is a file search tool.',
    'Directories are not meant to be previewed.',
    '',
    'Path: ' .. file_path,
  }
end

function M.create_no_preview_message() return { 'No preview available' } end

function M.create_no_file_message() return { 'No file selected' } end

function M.create_not_found_message(file_path)
  return {
    'File not found or inaccessible:',
    file_path,
  }
end

return M
