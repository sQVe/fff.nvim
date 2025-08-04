use crate::error::Error;
use crate::git::GitStatusCache;
use crate::types::{FileItem, SearchResult};
use git2::Repository;
use std::path::{Path, PathBuf};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Condvar, Mutex, RwLock,
};
use std::thread;
use tracing::{debug, info};

use crate::file_picker::{
    fuzzy_search_with_snapshot, scan_filesystem, spawn_background_watcher, FileSnapshot, FileSync,
    ScanProgress,
};

pub struct FilePicker {
    base_path: PathBuf,
    git_workdir: Option<PathBuf>,
    sync_data: Arc<RwLock<FileSync>>,
    search_snapshot: Arc<RwLock<FileSnapshot>>,
    shutdown_signal: Arc<AtomicBool>,
    is_scanning: Arc<AtomicBool>,
    shutdown_condvar: Arc<(Mutex<bool>, Condvar)>,
    _background_handle: Option<thread::JoinHandle<()>>,
}

impl std::fmt::Debug for FilePicker {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("FilePicker")
            .field("base_path", &self.base_path)
            .field("git_workdir", &self.git_workdir)
            .finish_non_exhaustive()
    }
}

impl FilePicker {
    pub fn new(base_path: String) -> Result<Self, Error> {
        info!("Initializing FilePicker with base_path: {}", base_path);
        let path = PathBuf::from(&base_path);
        if !path.exists() {
            return Err(Error::InvalidPath(path.to_string_lossy().into_owned()));
        }

        let git_workdir = Repository::discover(&path)
            .ok()
            .and_then(|repo| repo.workdir().map(Path::to_path_buf));

        if let Some(ref git_dir) = git_workdir {
            debug!("Git repository found at: {}", git_dir.display());
        } else {
            debug!("No git repository found for path: {}", base_path);
        }

        let sync_data = Arc::new(RwLock::new(FileSync::new()));
        let shutdown = Arc::new(AtomicBool::new(false));
        let scan_signal = Arc::new(AtomicBool::new(false));
        let shutdown_condvar = Arc::new((Mutex::new(false), Condvar::new()));

        let initial_snapshot = FileSnapshot {
            files: Vec::new(),
            generation: 0,
        };
        let search_snapshot = Arc::new(RwLock::new(initial_snapshot));

        let background_handle = spawn_background_watcher(
            path.clone(),
            git_workdir.clone(),
            Arc::clone(&sync_data),
            Arc::clone(&search_snapshot),
            Arc::clone(&shutdown),
            Arc::clone(&scan_signal),
            Arc::clone(&shutdown_condvar),
        );

        Ok(Self {
            base_path: path,
            git_workdir,
            sync_data,
            search_snapshot,
            shutdown_signal: shutdown,
            is_scanning: scan_signal,
            shutdown_condvar,
            _background_handle: Some(background_handle),
        })
    }

                    let new_snapshot = data.create_search_snapshot();
                    if let Ok(mut snapshot_guard) = search_snapshot.write() {
                        *snapshot_guard = *new_snapshot;
                    }
                }
            } else {
                tracing::warn!("Filesystem scan failed");
            }

            scan_signal.store(false, Ordering::Relaxed);
            info!("is_scanning = FALSE (manual rescan completed)");
        });

        Ok(())
    }

    #[inline]
    pub fn is_scan_active(&self) -> bool {
        self.is_scanning.load(Ordering::Relaxed)
    }

    pub fn stop_background_monitor(&self) {
        self.shutdown_signal.store(true, Ordering::Relaxed);
    }
}

impl Drop for FilePicker {
    fn drop(&mut self) {
        self.shutdown_signal.store(true, Ordering::Relaxed);

        let (shutdown_mutex, condvar) = &*self.shutdown_condvar;
        if let Ok(mut shutdown_flag) = shutdown_mutex.lock() {
            *shutdown_flag = true;
            condvar.notify_all();
        }
    }
}
