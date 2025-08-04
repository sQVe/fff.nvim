use crate::error::Error;
use crate::git::GitStatusCache;
use crate::types::FileItem;
use git2::Repository;
use ignore::{WalkBuilder, WalkState};
use rayon::prelude::*;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::thread;
use tracing::{debug, info};

pub fn scan_filesystem(
    base_path: &Path,
    git_workdir: Option<&PathBuf>,
) -> Result<(Vec<FileItem>, Option<GitStatusCache>), Error> {
    let scan_start = std::time::Instant::now();
    let git_workdir = git_workdir.map(|p| p.as_path());
    info!("SCAN_START: Starting parallel filesystem scan and git status");

    // run separate thread for git status because it effectively does another separate file
    // traversal which could be pretty slow on large repos (in general 300-500ms)
    thread::scope(|s| {
        let git_handle = s.spawn(|| {
            let git_start = std::time::Instant::now();
            debug!("GIT_SCAN: Starting git status scan thread");
            let result = GitStatusCache::read_git_status(git_workdir);
            debug!(
                "GIT_SCAN: Git status scan completed in {:?}",
                git_start.elapsed()
            );
            result
        });

        let walker = WalkBuilder::new(base_path)
            .hidden(false)
            .git_ignore(true)
            .git_exclude(true)
            .git_global(true)
            .ignore(true)
            .follow_links(false)
            .sort_by_file_name(std::cmp::Ord::cmp)
            .build_parallel();

        let walker_start = std::time::Instant::now();
        info!("SCAN_WALK: Starting file walker");

        let files = Arc::new(Mutex::new(Vec::with_capacity(1024))); // Pre-allocate for typical repos.
        walker.run(|| {
            let files = Arc::clone(&files);
            let base_path = base_path.to_path_buf();

            Box::new(move |result| {
                if let Ok(entry) = result {
                    if let Some(file_type) = entry.file_type() {
                        if file_type.is_file() {
                            let path = entry.path();

                            if is_git_file(path) {
                                return WalkState::Continue;
                            }

                            let file_item = FileItem::new(
                                path.to_path_buf(),
                                &base_path,
                                None,
                            );

                            if let Ok(mut files_vec) = files.lock() {
                                files_vec.push(file_item);
                            }
                        }
                    }
                }
                WalkState::Continue
            })
        });

        let mut files = Arc::try_unwrap(files).unwrap().into_inner().unwrap();
        let walker_time = walker_start.elapsed();
        info!(
            "SCAN_WALK: File walking completed in {:?} with {} files",
            walker_time,
            files.len()
        );

        let git_cache = git_handle
            .join()
            .map_err(|_| Error::InvalidPath("Git status thread panicked".to_string()))?;

        let git_apply_start = std::time::Instant::now();
        if let Some(git_cache) = &git_cache {
            debug!(
                "GIT_APPLY: Starting git status application for {} files",
                files.len()
            );
            files.par_iter_mut().for_each(|file| {
                file.git_status = git_cache.lookup_status(&file.path);
            });
            debug!(
                "GIT_APPLY: Git status application completed in {:?}",
                git_apply_start.elapsed()
            );
        }
        // Note: Frecency scores will be batch-updated in FileSync::update_files.

        let total_time = scan_start.elapsed();
        info!(
            "SCAN_TIMING: Total scan time {:?} for {} files (walk: {:?}, git: {:?})",
            total_time,
            files.len(),
            walker_time,
            git_apply_start.elapsed()
        );

        Ok((files, git_cache))
    })
}

pub fn should_add_new_file(path: &Path, git_workdir: Option<&PathBuf>) -> bool {
    if is_git_file(path) {
        return false;
    }

    if !path.is_file() {
        return false;
    }

    if let Some(git_workdir) = git_workdir {
        if let Ok(repo) = Repository::open(git_workdir) {
            if repo.is_path_ignored(path).unwrap_or(false) {
                return false;
            }
        }
    }

    true
}

#[inline]
pub fn is_git_file(path: &Path) -> bool {
    path.to_str().is_some_and(|path| path.contains("/.git/"))
}
