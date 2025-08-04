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

use super::core::{FileSnapshot, FileSync};
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
                if let Ok(mut data) = sync_data.write() {
                    data.update_files(files, git_cache);
                    debug!("SCAN_COMPLETE: Initial file cache updated successfully");

                    // Create safe snapshot for search operations.
                    let new_snapshot = data.create_search_snapshot();
                    if let Ok(mut snapshot_guard) = search_snapshot.write() {
                        *snapshot_guard = *new_snapshot;
                    }
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
        let mut shutdown_flag = shutdown_mutex.lock().unwrap();
        while !*shutdown_flag {
            shutdown_flag = condvar.wait(shutdown_flag).unwrap();
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

        let new_snapshot = sync_write.create_search_snapshot();
        if let Ok(mut snapshot_guard) = search_snapshot.write() {
            *snapshot_guard = *new_snapshot;
        }
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

        let new_snapshot = sync_write.create_search_snapshot();
        if let Ok(mut snapshot_guard) = search_snapshot.write() {
            *snapshot_guard = *new_snapshot;
        }
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
        for status_entry in statuses.iter() {
            let Some(file_path) = status_entry.path() else {
                continue;
            };

            if let Ok(index) = sync_write.find_file_index(file_path) {
                sync_write.files[index].git_status = Some(status_entry.status());
                // Individual frecency update for git status changes.
                sync_write.files[index].update_frecency_scores();
            }
        }

        let new_snapshot = sync_write.create_search_snapshot();
        if let Ok(mut snapshot_guard) = search_snapshot.write() {
            *snapshot_guard = *new_snapshot;
        }
    }
}
