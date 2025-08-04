-- Preview cache management for fff.nvim
-- Simple file content caching with size limit

local M = {}

M.state = {
  cache = {}, -- Simple cache: { [path] = { lines, filetype, timestamp, mtime } }
  cache_keys = {}, -- Array tracking insertion order for eviction
  pending_file = nil,
  max_cache_size = 20,
}

function M.init_config(config)
  if not config or not config.preview then return end
  M.state.max_cache_size = config.preview.cache_size or 20
end

local function is_cache_valid(file_path, cache_entry)
  if not cache_entry or not cache_entry.mtime then return false end

  local stat = vim.loop.fs_stat(file_path)
  if not stat then return false end

  return stat.mtime.sec == cache_entry.mtime
end

function M.add_to_cache(file_path, cache_entry)
  -- Remove existing entry if present.
  for i, cached_path in ipairs(M.state.cache_keys) do
    if cached_path == file_path then
      table.remove(M.state.cache_keys, i)
      break
    end
  end

  -- Evict oldest entry if cache is full.
  if #M.state.cache_keys >= M.state.max_cache_size then
    local oldest_key = table.remove(M.state.cache_keys, 1)
    M.state.cache[oldest_key] = nil
  end

  table.insert(M.state.cache_keys, file_path)
  M.state.cache[file_path] = cache_entry
end

function M.get_cached_entry(file_path)
  local cached_entry = M.state.cache[file_path]
  if cached_entry and is_cache_valid(file_path, cached_entry) then
    return cached_entry
  elseif cached_entry then
    M.state.cache[file_path] = nil
    for i, cached_path in ipairs(M.state.cache_keys) do
      if cached_path == file_path then
        table.remove(M.state.cache_keys, i)
        break
      end
    end
  end
  return nil
end

function M.create_cache_entry(item, config)
  local file_path = item.path
  local stat = vim.loop.fs_stat(file_path)
  if not stat then
    return {
      lines = { 'File not accessible' },
      filetype = 'text',
      timestamp = vim.loop.hrtime(),
      mtime = 0,
    }
  end

  local max_size = config and config.preview and config.preview.max_size or (2 * 1024 * 1024)
  if stat.size > max_size then
    return {
      lines = { 'File too large for preview' },
      filetype = 'text',
      timestamp = vim.loop.hrtime(),
      mtime = stat.mtime.sec,
    }
  end

  local ext = string.lower(vim.fn.fnamemodify(file_path, ':e'))
  if M.is_binary_extension(ext) then
    return {
      lines = { '⚠ Binary File', '', 'File: ' .. vim.fn.fnamemodify(file_path, ':t') },
      filetype = 'text',
      timestamp = vim.loop.hrtime(),
      mtime = stat.mtime.sec,
    }
  end

  local max_lines = config and config.preview and config.preview.max_lines or 800
  local ok, lines = pcall(vim.fn.readfile, file_path, '', max_lines)
  if not ok or not lines then
    return {
      lines = { 'Failed to read file' },
      filetype = 'text',
      timestamp = vim.loop.hrtime(),
      mtime = stat.mtime.sec,
    }
  end

  return {
    lines = lines,
    filetype = M.detect_filetype(ext),
    timestamp = vim.loop.hrtime(),
    mtime = stat.mtime.sec,
  }
end

function M.is_binary_extension(ext)
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

function M.detect_filetype(ext)
  local filetypes = {
    js = 'javascript',
    jsx = 'javascriptreact',
    ts = 'typescript',
    tsx = 'typescriptreact',
    lua = 'lua',
    py = 'python',
    rs = 'rust',
    go = 'go',
    json = 'json',
    md = 'markdown',
    html = 'html',
    css = 'css',
    java = 'java',
    c = 'c',
    cpp = 'cpp',
    h = 'c',
    php = 'php',
    rb = 'ruby',
    sh = 'bash',
    vim = 'vim',
    yaml = 'yaml',
    yml = 'yaml',
  }

  return filetypes[ext] or 'text'
end

function M.clear_cache()
  M.state.cache = {}
  M.state.cache_keys = {}
  M.state.pending_file = nil
end

function M.cancel_pending() M.state.pending_file = nil end

return M
