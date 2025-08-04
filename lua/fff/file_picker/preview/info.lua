-- File information and debug data creation for preview functionality
-- Handles file info display, debug cards, and score information

local M = {}

function M.create_file_info_content(file, info, file_index)
  local lines = {}

  local main = require('fff.main')
  local config = main.config
  local debug_mode = config and config.debug and config.debug.show_scores

  if debug_mode then
    local score = nil

    table.insert(
      lines,
      string.format('Size: %-8s │ Total Score: %d', info.size_formatted or 'N/A', score and score.total or 0)
    )
    table.insert(
      lines,
      string.format('Type: %-8s │ Match Type: %s', info.filetype or 'text', score and score.match_type or 'unknown')
    )
    table.insert(
      lines,
      string.format(
        'Git:  %-8s │ Frecency Mod: %d, Acc: %d',
        file.git_status or 'clear',
        file.modification_frecency_score or 0,
        file.access_frecency_score or 0
      )
    )

    -- Add detailed score breakdown
    if score then
      table.insert(
        lines,
        string.format(
          'Score Breakdown: base=%d, name_bonus=%d, special_bonus=%d',
          score.base_score,
          score.filename_bonus,
          score.special_filename_bonus
        )
      )
      table.insert(
        lines,
        string.format('Score Modifiers: frec_boost=%d, dist_penalty=%d', score.frecency_boost, score.distance_penalty)
      )
    else
      table.insert(lines, 'Score Breakdown: N/A (no score data available)')
    end
    table.insert(lines, '')

    -- Time information section
    table.insert(lines, 'TIMINGS')
    table.insert(lines, string.rep('─', 50))
    table.insert(lines, string.format('Modified: %s', info.modified_formatted or 'N/A'))
    table.insert(lines, string.format('Last Access: %s', info.accessed_formatted or 'N/A'))
  else
    -- Simple file info for non-debug mode
    table.insert(lines, string.format('File: %s', info.name or 'Unknown'))
    table.insert(lines, string.format('Size: %s', info.size_formatted or 'N/A'))
    table.insert(lines, string.format('Type: %s', info.filetype or 'text'))
    table.insert(lines, string.format('Modified: %s', info.modified_formatted or 'N/A'))
    if file.git_status and file.git_status ~= 'clear' then
      table.insert(lines, string.format('Git Status: %s', file.git_status))
    end
  end

  return lines
end

-- Create debug card (legacy function for backward compatibility)
function M.create_debug_card(file, info)
  -- Debug info is now handled in create_file_info_content, return empty for preview
  return {}
end

-- Create simple file info header
function M.create_file_info_header(info, show_file_info)
  if not show_file_info or not info then return {} end

  local header = {}
  table.insert(header, string.format('File: %s', info.name))
  table.insert(header, string.format('Size: %s', info.size_formatted))
  table.insert(header, string.format('Modified: %s', info.modified_formatted))
  table.insert(header, string.format('Type: %s', info.filetype))

  if info.extension ~= '' then table.insert(header, string.format('Extension: .%s', info.extension)) end

  table.insert(header, string.rep('─', 50))
  table.insert(header, '')

  return header
end

-- Create file info panel content for debug mode
function M.create_file_info_panel_content()
  return {
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
  }
end

-- Create basic file statistics summary
function M.create_file_stats(file, info)
  local stats = {}

  if info then
    stats.size = info.size_formatted or 'Unknown'
    stats.type = info.filetype or 'text'
    stats.modified = info.modified_formatted or 'Unknown'
    stats.extension = info.extension or ''
  end

  if file then
    stats.git_status = file.git_status or 'clear'
    stats.frecency_total = file.total_frecency_score or 0
    stats.frecency_access = file.access_frecency_score or 0
    stats.frecency_mod = file.modification_frecency_score or 0
  end

  return stats
end

-- Create score information summary
function M.create_score_summary(score)
  if not score then
    return {
      total = 0,
      base = 0,
      filename_bonus = 0,
      frecency_boost = 0,
      distance_penalty = 0,
      match_type = 'unknown',
    }
  end

  return {
    total = score.total,
    base = score.base_score,
    filename_bonus = score.filename_bonus,
    special_bonus = score.special_filename_bonus,
    frecency_boost = score.frecency_boost,
    distance_penalty = score.distance_penalty,
    match_type = score.match_type,
  }
end

function M.format_git_status(git_status)
  if not git_status or git_status == 'clear' then return 'Clean' end
  return git_status
end

function M.format_frecency_display(access_score, mod_score, total_score)
  return {
    access = access_score or 0,
    modification = mod_score or 0,
    total = total_score or 0,
    formatted = string.format('Acc: %d, Mod: %d, Total: %d', access_score or 0, mod_score or 0, total_score or 0),
  }
end

function M.create_score_breakdown_text(score)
  if not score then return 'Score Breakdown: N/A (no score data available)' end

  local breakdown = string.format(
    'Score Breakdown: base=%d, name_bonus=%d, special_bonus=%d',
    score.base_score,
    score.filename_bonus,
    score.special_filename_bonus
  )

  local modifiers =
    string.format('Score Modifiers: frec_boost=%d, dist_penalty=%d', score.frecency_boost, score.distance_penalty)

  return { breakdown, modifiers }
end

function M.is_debug_mode_enabled()
  local main = require('fff.main')
  local config = main.config

  return config and config.debug and config.debug.show_scores
end

return M
