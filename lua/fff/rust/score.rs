use crate::{
    git::is_modified_status,
    path_utils::calculate_distance_penalty,
    types::{FileItem, Score, ScoringContext},
};
use rayon::prelude::*;

const EXACT_FILENAME_BONUS_DIVISOR: i32 = 5;
const EXACT_FILENAME_BONUS_MULTIPLIER: i32 = 2;
const FUZZY_FILENAME_BONUS_DIVISOR: i32 = 5;
const SPECIAL_ENTRY_BONUS_PERCENT: i32 = 18;

#[inline]
pub fn match_and_score_files(files: &[FileItem], context: &ScoringContext) -> Vec<(usize, Score)> {
    if context.query.len() < 2 {
        return score_all_by_frecency(files, context);
    }

    if files.is_empty() {
        return Vec::new();
    }

    let options = neo_frizbee::Options {
        prefilter: true,
        max_typos: Some(context.max_typos),
        sort: false,
    };

    // Unified matching: search paths first, then check filenames for matched files.
    let mut haystack = Vec::with_capacity(files.len());
    haystack.extend(files.iter().map(|f| f.relative_path.as_str()));
    let path_matches =
        neo_frizbee::match_list_parallel(context.query, &haystack, options, context.max_threads);

    let mut results = Vec::with_capacity(path_matches.len());

    for neo_frizbee_match in path_matches {
        let file_idx = neo_frizbee_match.index_in_haystack as usize;
        let file = &files[file_idx];

        let base_score = neo_frizbee_match.score as i32;
        let frecency_boost = base_score.saturating_mul(file.total_frecency_score as i32) / 100;
        let distance_penalty = calculate_distance_penalty(
            context.current_file.map(|s| s.as_str()),
            &file.relative_path,
        );

        let (filename_bonus, match_type, has_special_bonus) =
            calculate_filename_bonus(context.query, &file.file_name, base_score);

        let total = base_score
            .saturating_add(frecency_boost)
            .saturating_add(distance_penalty)
            .saturating_add(filename_bonus);

        let score = Score {
            total,
            base_score,
            filename_bonus,
            special_filename_bonus: if has_special_bonus { filename_bonus } else { 0 },
            frecency_boost,
            distance_penalty,
            match_type,
        };

        results.push((file_idx, score));
    }

    results.par_sort_unstable_by(|a, b| b.1.total.cmp(&a.1.total));

    results
}

#[inline]
fn calculate_filename_bonus(
    query: &str,
    filename: &str,
    base_score: i32,
) -> (i32, &'static str, bool) {
    if filename.eq_ignore_ascii_case(query) {
        return (
            base_score / EXACT_FILENAME_BONUS_DIVISOR * EXACT_FILENAME_BONUS_MULTIPLIER,
            "exact_filename",
            false,
        );
    }

    if filename.to_lowercase().contains(&query.to_lowercase()) {
        return (
            base_score / FUZZY_FILENAME_BONUS_DIVISOR,
            "fuzzy_filename",
            false,
        );
    }

    if is_special_entry_point_file(filename) {
        return (
            base_score * SPECIAL_ENTRY_BONUS_PERCENT / 100,
            "fuzzy_path",
            true,
        );
    }

    (0, "fuzzy_path", false)
}


#[inline]
fn is_special_entry_point_file(filename: &str) -> bool {
    matches!(
        filename,
        "mod.rs"
            | "lib.rs"
            | "main.rs"
            | "index.js"
            | "index.jsx"
            | "index.ts"
            | "index.tsx"
            | "index.mjs"
            | "index.cjs"
            | "index.vue"
            | "__init__.py"
            | "__main__.py"
            | "main.go"
            | "main.c"
            | "index.php"
            | "main.rb"
            | "index.rb"
    )
}

fn score_all_by_frecency(files: &[FileItem], context: &ScoringContext) -> Vec<(usize, Score)> {
    files
        .par_iter()
        .enumerate()
        .map(|(idx, file)| {
            let total_frecency_score = file.access_frecency_score as i32
                + (file.modification_frecency_score as i32).saturating_mul(4);

            let distance_penalty = calculate_distance_penalty(
                context.current_file.map(|x| x.as_str()),
                &file.relative_path,
            );

            let total = total_frecency_score
                .saturating_add(distance_penalty)
                .saturating_add(calculate_file_bonus(file, context));

            let score = Score {
                total,
                base_score: 0,
                filename_bonus: 0,
                special_filename_bonus: 0,
                frecency_boost: total_frecency_score,
                distance_penalty,
                match_type: "frecency",
            };

            (idx, score)
        })
        .collect()
}

#[inline]
fn calculate_file_bonus(file: &FileItem, context: &ScoringContext) -> i32 {
    let mut bonus = 0i32;

    if let Some(current) = context.current_file {
        if file.relative_path == *current {
            bonus -= match file.git_status {
                Some(status) if is_modified_status(status) => 150,
                _ => 300,
            };
        }
    }

    bonus
}
