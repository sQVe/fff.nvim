local M = {}

M.DEFAULT_SAME_DIR_PREFERENCE = 0.7
M.DEFAULT_SCORING_CONFIG = {
  same_dir_preference = M.DEFAULT_SAME_DIR_PREFERENCE,
}

--- @param config table Configuration table to validate
--- @param default_value number Default value to use if invalid
--- @return boolean True if value was valid, false if it was corrected
function M.validate_same_dir_preference(config, default_value)
  default_value = default_value or M.DEFAULT_SAME_DIR_PREFERENCE

  if not config.scoring or not config.scoring.same_dir_preference then return true end

  local preference = config.scoring.same_dir_preference
  if preference < 0.0 or preference > 1.0 then
    vim.notify(
      string.format(
        "Invalid 'scoring.same_dir_preference' (%g). Must be between 0.0 and 1.0. Using default (%.1f).",
        preference,
        default_value
      ),
      vim.log.levels.WARN
    )
    config.scoring.same_dir_preference = default_value
    return false
  end

  return true
end

--- @param preference number User preference value between 0.0 and 1.0
--- @return table Internal scoring parameters
function M.map_preference_to_scoring(preference)
  return {
    directory_distance_penalty = -8, -- Balanced penalty for different directories
    filename_similarity_bonus_max = math.floor(50 * preference), -- Moderate sibling bonus (35 with default 0.7)
    filename_similarity_threshold = 0.5, -- Good relevance/performance balance
    max_search_directory_levels = math.floor(1 + 3 * preference),
  }
end

return M
