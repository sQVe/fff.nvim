use crate::types::FileItem;
use git2::{Repository, StatusOptions};
use notify::{EventKind, RecursiveMode};
use notify_debouncer_full::{new_debouncer, DebounceEventResult, DebouncedEvent};
use std::path::{Path, PathBuf};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Condvar, Mutex, RwLock,
};
use std::thread;
use std::time::Duration;
use tracing::{debug, error, info};

use super::core::{FileSnapshot, FileSync, update_search_snapshot_from_sync};
use super::scanner::{scan_filesystem, should_add_new_file};

pub fn spawn_background_watcher(
    base_path: PathBuf,
    git_workdir: Option<PathBuf>,
    sync_data: Arc<RwLock<FileSync>>,
    search_snapshot: Arc<RwLock<FileSnapshot>>,
    _shutdown: Arc<AtomicBool>,
    scan_signal: Arc<AtomicBool>,
    shutdown_condvar: Arc<(Mutex<bool>, Condvar)>,
) -> thread::JoinHandle<()> {
    thread::spawn(move || {
        scan_signal.store(true, Ordering::Relaxed);
        info!("SCAN_INIT: Starting background watcher thread");
        let scan_start_time = std::time::Instant::now();

        match scan_filesystem(&base_path, git_workdir.as_ref()) {
            Ok((files, git_cache)) => {
                let scan_duration = scan_start_time.elapsed();
                info!(
                    "SCAN_COMPLETE: Initial parallel filesystem scan completed: found {} files in {:?}",
                    files.len(), scan_duration
                );

                let sorted_files = FileSync::prepare_files_for_update(files);

                if let Ok(mut data) = sync_data.write() {
                    data.update_files(sorted_files, git_cache);
                    debug!("SCAN_COMPLETE: Initial file cache updated successfully");
                }

                if let Err(e) = update_search_snapshot_from_sync(&sync_data, &search_snapshot) {
                    error!("Failed to update search snapshot: {}", e);
                }
            }
            Err(e) => {
                error!("SCAN_ERROR: Failed to scan filesystem: {:?}", e);
            }
        }

        scan_signal.store(false, Ordering::Relaxed);
        info!(
            "SCAN_COMPLETE: is_scanning = FALSE (initial scan completed in {:?})",
            scan_start_time.elapsed()
        );

        let mut debouncer = match new_debouncer(Duration::from_millis(500), None, {
            let sync_data = Arc::clone(&sync_data);
            let search_snapshot = Arc::clone(&search_snapshot);
            let base_path = base_path.clone();
            let git_workdir = git_workdir.clone();

            move |result: DebounceEventResult| match result {
                Ok(events) => {
                    handle_debounced_events(
                        events,
                        &sync_data,
                        &search_snapshot,
                        &base_path,
                        &git_workdir,
                    );
                }
                Err(errors) => {
                    error!("File watcher errors: {:?}", errors);
                }
            }
        }) {
            Ok(debouncer) => debouncer,
            Err(e) => {
                error!("Failed to create debouncer: {:?}", e);
                return;
            }
        };

        if let Err(e) = debouncer.watch(&base_path, RecursiveMode::Recursive) {
            error!("Failed to start watching: {:?}", e);
            return;
        }

        let (shutdown_mutex, condvar) = &*shutdown_condvar;
        let mut shutdown_flag = match shutdown_mutex.lock() {
            Ok(flag) => flag,
            Err(poisoned) => {
                error!("Shutdown mutex poisoned, recovering: {:?}", poisoned);
                poisoned.into_inner()
            }
        };
        while !*shutdown_flag {
            shutdown_flag = match condvar.wait(shutdown_flag) {
                Ok(flag) => flag,
                Err(poisoned) => {
                    error!("Condvar wait poisoned, recovering: {:?}", poisoned);
                    poisoned.into_inner()
                }
            };
        }
    })
}

pub fn handle_debounced_events(
    events: Vec<DebouncedEvent>,
    sync_data: &Arc<RwLock<FileSync>>,
    search_snapshot: &Arc<RwLock<FileSnapshot>>,
    base_path: &Path,
    git_workdir: &Option<PathBuf>,
) {
    let mut affected_paths = Vec::with_capacity(events.len());
    for event in events {
        let relevant_paths: Vec<_> = event
            .paths
            .iter()
            .filter_map(|path| {
                let relative_path = pathdiff::diff_paths(path, base_path)?;

                let Ok(sync_read) = sync_data.read() else {
                    return None;
                };

                let relative_str = relative_path.to_string_lossy();

                if sync_read.contains_path(&relative_str) {
                    return Some(path.clone());
                }

                match event.event.kind {
                    EventKind::Create(_) => {
                        if should_add_new_file(path, git_workdir.as_ref()) {
                            Some(path.clone())
                        } else {
                            None
                        }
                    }
                    _ => None,
                }
            })
            .collect();

        if relevant_paths.is_empty() {
            continue;
        }

        debug!(?event, "File watcher event");
        match event.event.kind {
            EventKind::Create(_) => {
                handle_create_events(
                    &relevant_paths,
                    sync_data,
                    search_snapshot,
                    base_path,
                    git_workdir.as_ref(),
                );
                affected_paths.extend(relevant_paths);
            }
            EventKind::Modify(_) => {
                affected_paths.extend(relevant_paths);
            }
            EventKind::Remove(_) => {
                remove_paths_from_index(relevant_paths, sync_data, search_snapshot, base_path);
            }
            _ => {
                affected_paths.extend(relevant_paths);
            }
        }
    }

    if !affected_paths.is_empty() {
        update_git_status_for_paths(
            sync_data,
            search_snapshot,
            git_workdir,
            base_path,
            &affected_paths,
        );
    }
}

pub fn handle_create_events(
    paths: &[PathBuf],
    sync_data: &Arc<RwLock<FileSync>>,
    search_snapshot: &Arc<RwLock<FileSnapshot>>,
    base_path: &Path,
    git_workdir: Option<&PathBuf>,
) {
    let repo = git_workdir.as_ref().and_then(|p| Repository::open(p).ok());
    if let Ok(mut sync_write) = sync_data.write() {
        for path in paths {
            if repo
                .as_ref()
                .is_some_and(|repo| repo.is_path_ignored(path).unwrap_or(false))
            {
                debug!("Ignoring file {} due to gitignore rules", path.display());
                continue;
            }

            let file_item = FileItem::new(path.clone(), base_path, None);
            sync_write.insert_file_sorted(file_item);
            // Note: frecency will be updated in batch when snapshot is created.
        }
    }

    if let Err(e) = update_search_snapshot_from_sync(&sync_data, &search_snapshot) {
        error!("Failed to update search snapshot: {}", e);
    }
}

pub fn remove_paths_from_index(
    paths: Vec<PathBuf>,
    sync_data: &Arc<RwLock<FileSync>>,
    search_snapshot: &Arc<RwLock<FileSnapshot>>,
    base_path: &Path,
) {
    if let Ok(mut sync_write) = sync_data.write() {
        for path in paths {
            if let Some(relative_path) = pathdiff::diff_paths(path, base_path) {
                let relative_str = relative_path.to_string_lossy();
                sync_write.remove_file_by_path(&relative_str);
            }
        }
    }

    if let Err(e) = update_search_snapshot_from_sync(&sync_data, &search_snapshot) {
        error!("Failed to update search snapshot: {}", e);
    }
}

pub fn update_git_status_for_paths(
    sync_data: &Arc<RwLock<FileSync>>,
    search_snapshot: &Arc<RwLock<FileSnapshot>>,
    git_workdir: &Option<PathBuf>,
    base_path: &Path,
    affected_paths: &[PathBuf],
) {
    let Some(git_workdir) = git_workdir else {
        return;
    };

    let Ok(repo) = Repository::open(git_workdir) else {
        return;
    };

    let mut status_options = StatusOptions::new();
    status_options.include_untracked(true);
    status_options.include_ignored(false);

    for path in affected_paths {
        if let Some(relative_path) = pathdiff::diff_paths(path, base_path) {
            let path_str = relative_path.to_string_lossy();
            status_options.pathspec(&*path_str);
        }
    }

    let Ok(statuses) = repo.statuses(Some(&mut status_options)) else {
        error!(
            "Failed to get git statuses for affected paths: {:?}",
            affected_paths
        );
        return;
    };

    if let Ok(mut sync_write) = sync_data.write() {
        let mut updated_indices = Vec::new();

        // First pass: update git status and collect indices.
        for status_entry in statuses.iter() {
            let Some(file_path) = status_entry.path() else {
                continue;
            };

            if let Ok(index) = sync_write.find_file_index(file_path) {
                sync_write.files[index].git_status = Some(status_entry.status());
                updated_indices.push(index);
            }
        }

        // Second pass: batch frecency update for all modified files.
        if !updated_indices.is_empty() {
            if let Ok(frecency) = crate::FRECENCY.read() {
                if let Some(ref tracker) = *frecency {
                    for &index in &updated_indices {
                        let file = &mut sync_write.files[index];
                        let file_key = crate::file_key::FileKey::from(&*file);
                        file.access_frecency_score = tracker.get_access_score(&file_key);
                        file.modification_frecency_score = tracker.get_modification_score(
                            file.modified,
                            crate::git::format_git_status(file.git_status),
                        );
                        file.total_frecency_score =
                            file.access_frecency_score + file.modification_frecency_score;
                    }
                }
            }
        }
    }

    if let Err(e) = update_search_snapshot_from_sync(&sync_data, &search_snapshot) {
        error!("Failed to update search snapshot: {}", e);
    }
}
