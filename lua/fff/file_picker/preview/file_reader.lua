-- File reading and I/O operations for preview functionality
-- Handles file content reading, binary detection, and file system operations

local M = {}

M.config = {
  binary_file_threshold = 1024, -- bytes to check for binary content
  max_lines = 1000,
  max_file_size = 10 * 1024 * 1024, -- 10MB
}

function M.setup(config) M.config = vim.tbl_deep_extend('force', M.config, config or {}) end

function M.is_binary_file(file_path)
  local ext = string.lower(vim.fn.fnamemodify(file_path, ':e'))
  local binary_extensions = {
    'jpg',
    'jpeg',
    'png',
    'gif',
    'bmp',
    'pdf',
    'zip',
    'rar',
    '7z',
    'tar',
    'gz',
    'exe',
    'dll',
    'so',
    'mp3',
    'mp4',
    'avi',
  }

  for _, binary_ext in ipairs(binary_extensions) do
    if ext == binary_ext then return true end
  end

  return false
end

function M.get_file_info(file_path)
  local stat = vim.loop.fs_stat(file_path)
  if not stat then return nil end

  local info = {
    name = vim.fn.fnamemodify(file_path, ':t'),
    path = file_path,
    size = stat.size,
    modified = stat.mtime.sec,
    accessed = stat.atime.sec,
    type = stat.type,
    permissions = stat.mode,
  }

  info.extension = vim.fn.fnamemodify(file_path, ':e'):lower()
  info.filetype = vim.filetype.match({ filename = file_path, buf = 0 }) or 'text'

  -- Format file size.
  if info.size < 1024 then
    info.size_formatted = info.size .. 'B'
  elseif info.size < 1024 * 1024 then
    info.size_formatted = string.format('%.1fKB', info.size / 1024)
  elseif info.size < 1024 * 1024 * 1024 then
    info.size_formatted = string.format('%.1fMB', info.size / 1024 / 1024)
  else
    info.size_formatted = string.format('%.1fGB', info.size / 1024 / 1024 / 1024)
  end

  -- Format timestamps.
  info.modified_formatted = os.date('%Y-%m-%d %H:%M:%S', info.modified)
  info.accessed_formatted = os.date('%Y-%m-%d %H:%M:%S', info.accessed)

  return info
end

function M.read_file_content(file_path, max_lines)
  max_lines = max_lines or M.config.max_lines
  local ok, lines = pcall(vim.fn.readfile, file_path, '', max_lines)
  if not ok or not lines then return nil end
  return lines
end

function M.read_file_tail(file_path, tail_lines)
  local ok, lines = pcall(vim.fn.readfile, file_path)
  if not ok or not lines then return nil end

  local total_lines = #lines
  if total_lines <= tail_lines then return lines end

  local tail_start = total_lines - tail_lines + 1
  local result = {}
  for i = tail_start, total_lines do
    table.insert(result, lines[i])
  end

  return result
end

function M.is_file_too_large(file_path)
  local stat = vim.loop.fs_stat(file_path)
  if not stat then return true end

  return stat.size > M.config.max_file_size
end

function M.get_size_info(file_path)
  local stat = vim.loop.fs_stat(file_path)
  if not stat then return 'Unknown size' end

  local size_mb = stat.size / (1024 * 1024)
  local max_size_mb = M.config.max_file_size / (1024 * 1024)

  return {
    size_mb = size_mb,
    max_size_mb = max_size_mb,
    formatted_size = string.format('%.1fMB', size_mb),
    formatted_max = string.format('%.1fMB', max_size_mb),
  }
end

return M
