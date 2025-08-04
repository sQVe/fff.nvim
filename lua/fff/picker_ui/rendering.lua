-- Rendering logic for fff.nvim picker UI
-- Handles list rendering, highlighting, and display formatting

local M = {}

local icons = require('fff.file_picker.icons')
local git_utils = require('fff.git_utils')
local layout = require('fff.layout')

local function shrink_path(path, max_width)
  if #path <= max_width then return path end

  local segments = {}
  for segment in path:gmatch('[^/]+') do
    table.insert(segments, segment)
  end

  if #segments <= 2 then return path end

  local first = segments[1]
  local last = segments[#segments]
  local ellipsis = '../'

  for middle_count = #segments - 2, 1, -1 do
    local middle_parts = {}
    local start_idx = 2
    local end_idx = math.min(start_idx + middle_count - 1, #segments - 1)

    for i = start_idx, end_idx do
      table.insert(middle_parts, segments[i])
    end

    local middle = table.concat(middle_parts, '/')
    if middle_count < #segments - 2 then middle = middle .. ellipsis end

    local result = first .. '/' .. middle .. '/' .. last
    if #result <= max_width then return result end
  end

  return first .. '/' .. ellipsis .. last
end

local function format_file_display(item, max_width)
  local filename = item.name
  local dir_path = item.directory or ''

  if dir_path == '' and item.relative_path then
    local parent_dir = vim.fn.fnamemodify(item.relative_path, ':h')
    if parent_dir ~= '.' and parent_dir ~= '' then dir_path = parent_dir end
  end

  local base_width = #filename + 1
  local path_max_width = max_width - base_width

  if dir_path == '' then return filename, '' end
  local display_path = shrink_path(dir_path, path_max_width)

  return filename, display_path
end

function M.render_list(state, config)
  if not state.active then return end

  local items = state.filtered_items
  local lines = {}

  local main_module = require('fff.main')
  local max_path_width = main_module.config.ui and main_module.config.ui.max_path_width or 80
  local debug_enabled = main_module.config and main_module.config.debug and main_module.config.debug.show_scores
  local win_height = vim.api.nvim_win_get_height(state.list_win)
  local display_count = math.min(#items, win_height)
  local empty_lines_needed = win_height - display_count

  for _ = 1, empty_lines_needed do
    table.insert(lines, '')
  end

  local end_idx = math.min(#items, display_count)
  local items_to_show = {}
  for i = 1, end_idx do
    table.insert(items_to_show, items[i])
  end

  local display_ordered_items = layout.get_current().get_display_items(items_to_show)
  local icon_highlights = {}

  for i, item in ipairs(display_ordered_items) do
    local icon, icon_hl_group = icons.get_icon_display(item.name, item.extension, false)
    local frecency = M.format_frecency_info(item, debug_enabled)
    local current_indicator = item.is_current_file and ' (current)' or ''

    local available_width = math.max(max_path_width - #icon - 1 - #frecency - #current_indicator, 40)
    local filename, dir_path = format_file_display(item, available_width)

    local line
    if dir_path ~= '' then
      line = string.format('%s %s %s%s%s', icon, filename, dir_path, frecency, current_indicator)
    else
      line = string.format('%s %s%s%s', icon, filename, frecency, current_indicator)
    end

    if item.is_current_file then line = string.format('\027[90m%s\027[0m', line) end

    table.insert(lines, line)
    icon_highlights[i] = {
      hl_group = icon_hl_group,
      icon_length = vim.fn.strdisplaywidth(icon),
      git_status = item.git_status,
    }
  end

  local win_width = vim.api.nvim_win_get_width(state.list_win)
  local padded_lines = {}
  for _, line in ipairs(lines) do
    local line_len = vim.fn.strdisplaywidth(line)
    local padding = math.max(0, win_width - line_len + 5) -- +5 extra to ensure full coverage.
    local padded_line = line .. string.rep(' ', padding)
    table.insert(padded_lines, padded_line)
  end

  vim.api.nvim_buf_set_option(state.list_buf, 'modifiable', true)
  vim.api.nvim_buf_set_lines(state.list_buf, 0, -1, false, padded_lines)
  vim.api.nvim_buf_set_option(state.list_buf, 'modifiable', false)

  if #items > 0 then
    M.apply_cursor_highlighting(state, config, empty_lines_needed, display_count, win_height)
    M.apply_line_highlighting(state, config, lines, empty_lines_needed, icon_highlights, debug_enabled)
  end
end

function M.format_frecency_info(item, debug_enabled)
  local frecency = ''
  local total_frecency = (item.total_frecency_score or 0)
  local access_frecency = (item.access_frecency_score or 0)
  local mod_frecency = (item.modification_frecency_score or 0)

  if total_frecency > 0 and debug_enabled then
    local indicator = ''
    if mod_frecency >= 6 then -- High modification frecency.
      indicator = '🔥' -- Fire for recently modified.
    elseif access_frecency >= 4 then -- High access frecency.
      indicator = '⭐' -- Star for frequently accessed.
    elseif total_frecency >= 3 then -- Medium total frecency.
      indicator = '✨' -- Sparkle for moderate activity.
    elseif total_frecency >= 1 then -- Low frecency.
      indicator = '•' -- Dot for minimal activity.
    end
    frecency = string.format(' %s%d', indicator, total_frecency)
  end

  return frecency
end

function M.apply_cursor_highlighting(state, config, empty_lines_needed, display_count, win_height)
  local cursor_line = layout.get_current().get_cursor_position(state.cursor, empty_lines_needed, display_count)

  if cursor_line > 0 and cursor_line <= win_height then
    vim.api.nvim_win_set_cursor(state.list_win, { cursor_line, 0 })

    vim.api.nvim_buf_clear_namespace(state.list_buf, state.ns_id, 0, -1)

    vim.api.nvim_buf_add_highlight(state.list_buf, state.ns_id, config.hl.active_file, cursor_line - 1, 0, -1)

    local current_line = vim.api.nvim_buf_get_lines(state.list_buf, cursor_line - 1, cursor_line, false)[1] or ''
    local line_len = vim.fn.strdisplaywidth(current_line)
    local remaining_width = math.max(0, vim.api.nvim_win_get_width(state.list_win) - line_len)

    if remaining_width > 0 then
      vim.api.nvim_buf_set_extmark(state.list_buf, state.ns_id, cursor_line - 1, -1, {
        virt_text = { { string.rep(' ', remaining_width), config.hl.active_file } },
        virt_text_pos = 'eol',
      })
    end
  end
end

function M.apply_line_highlighting(state, config, lines, empty_lines_needed, icon_highlights, debug_enabled)
  for line_idx, line_content in ipairs(lines) do
    if line_content ~= '' then
      local content_line_idx = line_idx - empty_lines_needed

      -- Icon highlighting.
      local icon_info = icon_highlights[content_line_idx]
      if icon_info and icon_info.hl_group and icon_info.icon_length > 0 then
        vim.api.nvim_buf_add_highlight(
          state.list_buf,
          state.ns_id,
          icon_info.hl_group,
          line_idx - 1,
          0,
          icon_info.icon_length
        )
      end

      -- Frecency indicator highlighting.
      if debug_enabled then
        local star_start, star_end = line_content:find('⭐%d+')
        if star_start then
          vim.api.nvim_buf_add_highlight(
            state.list_buf,
            state.ns_id,
            config.hl.frecency,
            line_idx - 1,
            star_start - 1,
            star_end
          )
        end
      end

      -- Debug info highlighting.
      local debug_start, debug_end = line_content:find('%[%d+|[^%]]*%]')
      if debug_start then
        vim.api.nvim_buf_add_highlight(
          state.list_buf,
          state.ns_id,
          config.hl.debug,
          line_idx - 1,
          debug_start - 1,
          debug_end
        )
      end

      -- Directory path highlighting.
      M.highlight_directory_path(state, line_content, line_idx)

      -- Git status border signs.
      if icon_info and icon_info.git_status then M.apply_git_status_border(state, icon_info.git_status, line_idx) end
    end
  end
end

function M.highlight_directory_path(state, line_content, line_idx)
  local icon_match = line_content:match('^%S+') -- First non-space sequence (icon).
  if icon_match then
    local after_icon = line_content:sub(#icon_match + 1)
    local filename_match = after_icon:match('^%s+(%S+)') -- First word after icon.

    if filename_match then
      local prefix_len = #icon_match + 1 + #filename_match + 1 -- icon + space + filename + space.
      local remaining = line_content:sub(prefix_len + 1)

      local dir_end = remaining:find('⭐')
        or remaining:find('🔥')
        or remaining:find('✨')
        or remaining:find('•')
        or #remaining
      if remaining:find('%s') then dir_end = math.min(dir_end, remaining:find('%s')) end

      if dir_end > 1 then
        vim.api.nvim_buf_add_highlight(
          state.list_buf,
          state.ns_id,
          'Comment',
          line_idx - 1,
          prefix_len,
          prefix_len + dir_end
        )
      end
    end
  end
end

function M.apply_git_status_border(state, git_status, line_idx)
  if git_utils.should_show_border(git_status) then
    local border_char = git_utils.get_border_char(git_status)
    local border_hl = git_utils.get_border_highlight(git_status)

    if border_char ~= '' and border_hl ~= '' then
      vim.api.nvim_buf_set_extmark(state.list_buf, state.ns_id, line_idx - 1, 0, {
        sign_text = border_char,
        sign_hl_group = border_hl,
        priority = 1000,
      })
    end
  end
end

return M
