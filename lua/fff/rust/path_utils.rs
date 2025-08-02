
const MAX_PENALTY_LEVEL_MULTIPLIER: i32 = 10;

pub fn calculate_filename_similarity_bonus(
    current_file_path: &str,
    candidate_file_path: &str,
    max_bonus: i32,
    similarity_threshold: f64,
) -> i32 {
    use std::path::Path;
    use strsim::jaro_winkler;

    let current_path = Path::new(current_file_path);
    let candidate_path = Path::new(candidate_file_path);

    let current_stem = match current_path.file_stem().and_then(|s| s.to_str()) {
        Some(stem) => stem,
        None => return 0,
    };
    let candidate_stem = match candidate_path.file_stem().and_then(|s| s.to_str()) {
        Some(stem) => stem,
        None => return 0,
    };

    if current_file_path == candidate_file_path {
        return 0;
    }

    let similarity = jaro_winkler(current_stem, candidate_stem);

    if similarity >= similarity_threshold {
        (similarity * max_bonus as f64) as i32
    } else {
        0
    }
}

pub fn calculate_filename_similarity_bonus_optimized(
    current_stem: &str,
    candidate_file_path: &str,
    max_bonus: i32,
    similarity_threshold: f64,
) -> i32 {
    use std::path::Path;
    use strsim::jaro_winkler;

    if current_stem.is_empty() {
        return 0;
    }

    let candidate_stem = match Path::new(candidate_file_path).file_stem().and_then(|s| s.to_str()) {
        Some(stem) => stem,
        None => return 0,
    };

    let similarity = jaro_winkler(current_stem, candidate_stem);

    if similarity >= similarity_threshold {
        (similarity * max_bonus as f64) as i32
    } else {
        0
    }
}


pub fn calculate_directory_distance_penalty(current_file: Option<&str>, candidate_path: &str, penalty_per_level: i32) -> i32 {
    use std::path::{Path, Component};

    let Some(current_path_str) = current_file else {
        return 0;
    };

    let current_path = Path::new(current_path_str);
    let candidate_path = Path::new(candidate_path);

    let current_dir = match current_path.parent() {
        Some(p) => p,
        None => return 0,
    };
    let candidate_dir = match candidate_path.parent() {
        Some(p) => p,
        None => return 0,
    };

    if current_dir == candidate_dir {
        return 0;
    }

    let current_components: Vec<_> = current_dir.components()
        .filter(|c| matches!(c, Component::Normal(_)))
        .collect();
    let candidate_components: Vec<_> = candidate_dir.components()
        .filter(|c| matches!(c, Component::Normal(_)))
        .collect();

    let common_len = current_components
        .iter()
        .zip(candidate_components.iter())
        .take_while(|(a, b)| a == b)
        .count();

    let current_depth_from_common = current_components.len() - common_len;
    let candidate_depth_from_common = candidate_components.len() - common_len;
    let total_distance = current_depth_from_common + candidate_depth_from_common;

    if total_distance == 0 {
        return 0;
    }

    let penalty = total_distance as i32 * penalty_per_level;

    if penalty_per_level < 0 {
        penalty.max(penalty_per_level * MAX_PENALTY_LEVEL_MULTIPLIER)
    } else {
        penalty.min(penalty_per_level * MAX_PENALTY_LEVEL_MULTIPLIER)
    }
}

pub fn calculate_directory_distance_penalty_optimized(
    current_directory_parts: &[String],
    candidate_path: &str,
    penalty_per_level: i32,
) -> i32 {
    use std::path::{Path, Component};

    let candidate_path = Path::new(candidate_path);
    let candidate_dir = match candidate_path.parent() {
        Some(p) => p,
        None => return 0,
    };

    let candidate_parts: Vec<String> = candidate_dir.components()
        .filter_map(|c| match c {
            Component::Normal(os_str) => os_str.to_str().map(|s| s.to_string()),
            _ => None,
        })
        .collect();

    let common_len = current_directory_parts
        .iter()
        .zip(candidate_parts.iter())
        .take_while(|(a, b)| a == b)
        .count();

    let current_depth_from_common = current_directory_parts.len() - common_len;
    let candidate_depth_from_common = candidate_parts.len() - common_len;
    let total_distance = current_depth_from_common + candidate_depth_from_common;

    if total_distance == 0 {
        return 0; // Same path
    }

    let penalty = total_distance as i32 * penalty_per_level;

    if penalty_per_level < 0 {
        penalty.max(penalty_per_level * MAX_PENALTY_LEVEL_MULTIPLIER)
    } else {
        penalty.min(penalty_per_level * MAX_PENALTY_LEVEL_MULTIPLIER)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_calculate_filename_similarity_bonus() {
        // Test with Jaro-Winkler similarity (different from Levenshtein scores)

        // Perfect similarity (same stem, different extensions)
        assert_eq!(calculate_filename_similarity_bonus("vector.h", "vector.cpp", 50, 0.6), 50); // 1.0 similarity
        assert_eq!(calculate_filename_similarity_bonus("api.rs", "api.md", 50, 0.6), 50); // 1.0 similarity
        assert_eq!(calculate_filename_similarity_bonus("main.js", "main.ts", 50, 0.6), 50); // 1.0 similarity

        // High similarity cases (Jaro-Winkler prefers prefix matches)
        let utils_similarity = calculate_filename_similarity_bonus("utils.rs", "utils_test.rs", 50, 0.6);
        assert!(utils_similarity > 0, "utils.rs and utils_test.rs should have high Jaro-Winkler similarity");

        let button_similarity = calculate_filename_similarity_bonus("Button.tsx", "Button.test.tsx", 50, 0.6);
        assert!(button_similarity > 0, "Button.tsx and Button.test.tsx should have high Jaro-Winkler similarity");

        // Low similarity (below threshold)
        assert_eq!(calculate_filename_similarity_bonus("Button.tsx", "Modal.tsx", 50, 0.6), 0);
        assert_eq!(calculate_filename_similarity_bonus("user.rs", "main.rs", 50, 0.6), 0);

        // Same file = no bonus
        assert_eq!(calculate_filename_similarity_bonus("Button.tsx", "Button.tsx", 50, 0.6), 0);
        assert_eq!(calculate_filename_similarity_bonus("main.rs", "main.rs", 50, 0.6), 0);

        // Invalid files = no bonus
        assert_eq!(calculate_filename_similarity_bonus("", "Button.tsx", 50, 0.6), 0);
        assert_eq!(calculate_filename_similarity_bonus("Button.tsx", "", 50, 0.6), 0);

        // Test that threshold works correctly
        let low_threshold_bonus = calculate_filename_similarity_bonus("data.py", "data_backup.py", 30, 0.3);
        let high_threshold_bonus = calculate_filename_similarity_bonus("data.py", "data_backup.py", 30, 0.9);
        assert!(low_threshold_bonus > 0, "Low threshold should allow more matches");
        assert_eq!(high_threshold_bonus, 0, "High threshold should reject moderate similarity");
    }


    #[test]
    fn test_calculate_directory_distance_penalty() {
        const PENALTY_PER_LEVEL: i32 = -2;

        // No current file = no penalty
        assert_eq!(calculate_directory_distance_penalty(None, "/path/to/file.txt", PENALTY_PER_LEVEL), 0);

        // Same directory = no penalty
        assert_eq!(
            calculate_directory_distance_penalty(
                Some("/path/to/current/file.txt"),
                "/path/to/current/other.txt",
                PENALTY_PER_LEVEL
            ),
            0
        );

        // 1 level up = 1 * penalty
        assert_eq!(
            calculate_directory_distance_penalty(
                Some("/path/to/current/file.txt"),
                "/path/to/file.txt",
                PENALTY_PER_LEVEL
            ),
            1 * PENALTY_PER_LEVEL
        );

        // 2 levels apart = 2 * penalty
        assert_eq!(
            calculate_directory_distance_penalty(
                Some("/path/to/current/file.txt"),
                "/path/to/other/file.txt",
                PENALTY_PER_LEVEL
            ),
            2 * PENALTY_PER_LEVEL
        );

        // 3 levels apart = 3 * penalty
        assert_eq!(
            calculate_directory_distance_penalty(
                Some("/path/to/current/file.txt"),
                "/path/to/another/dir/file.txt",
                PENALTY_PER_LEVEL
            ),
            3 * PENALTY_PER_LEVEL
        );

        // Completely different paths = 8 levels apart = 8 * penalty
        assert_eq!(
            calculate_directory_distance_penalty(Some("/a/b/c/d/file.txt"), "/x/y/z/w/file.txt", PENALTY_PER_LEVEL),
            8 * PENALTY_PER_LEVEL
        );

        // Files in root directory = same directory = no penalty
        assert_eq!(
            calculate_directory_distance_penalty(Some("/file1.txt"), "/file2.txt", PENALTY_PER_LEVEL),
            0
        );

        // Test with different penalty values to ensure logic is independent of -2
        const DIFFERENT_PENALTY: i32 = -5;
        assert_eq!(
            calculate_directory_distance_penalty(
                Some("/path/to/current/file.txt"),
                "/path/to/file.txt",
                DIFFERENT_PENALTY
            ),
            1 * DIFFERENT_PENALTY
        );
    }
}
