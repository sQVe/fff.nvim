use crate::file_key::FileKey;
use crate::git::{format_git_status, GitStatusCache};
use crate::types::{FileItem, ScoringContext, SearchResult};
use git2::Status;
use std::path::{Path, PathBuf};
use std::sync::{Arc, RwLock};
use std::time::{SystemTime, Duration};
use tracing::{debug, warn};

use crate::FRECENCY;

pub fn create_snapshot_from_data(files: Vec<FileItem>, generation: u64) -> Arc<RwLock<FileSnapshot>> {
    Arc::new(RwLock::new(FileSnapshot { files, generation }))
}

/// Safely update search snapshot from sync data with proper lock ordering.
/// This function encapsulates the common pattern of cloning data from sync_data
/// and updating search_snapshot while avoiding deadlocks.
pub fn update_search_snapshot_from_sync(
    sync_data: &Arc<RwLock<FileSync>>,
    search_snapshot: &Arc<RwLock<FileSnapshot>>,
) -> Result<(), &'static str> {
    // Acquire sync_data lock, clone necessary data, release immediately.
    let (files_clone, generation) = {
        let sync_guard = sync_data.read()
            .map_err(|_| "Failed to acquire sync_data read lock")?;
        (sync_guard.files.clone(), sync_guard.scan_generation)
    };

    // Now safely update search snapshot with released sync lock.
    let mut snapshot_guard = search_snapshot.write()
        .map_err(|_| "Failed to acquire search_snapshot write lock")?;
    *snapshot_guard = FileSnapshot { files: files_clone, generation };

    Ok(())
}

/// Safely try to acquire a read lock with timeout.
pub fn try_read_snapshot_with_timeout(
    snapshot_arc: &Arc<RwLock<FileSnapshot>>,
    timeout: Duration,
) -> Result<Arc<FileSnapshot>, &'static str> {
    let start = std::time::Instant::now();
    loop {
        match snapshot_arc.try_read() {
            Ok(guard) => {
                let snapshot_data = FileSnapshot {
                    files: guard.files.clone(),
                    generation: guard.generation,
                };
                return Ok(Arc::new(snapshot_data));
            }
            Err(_) => {
                if start.elapsed() > timeout {
                    return Err("Timeout acquiring read lock on snapshot");
                }
                std::thread::sleep(Duration::from_millis(1));
            }
        }
    }
}

#[derive(Debug, Clone)]
pub struct FileSync {
    pub files: Vec<FileItem>,
    pub last_update: SystemTime,
    pub git_status_cache: Option<GitStatusCache>,
    pub scan_generation: u64,
}

#[derive(Debug)]
pub struct FileSnapshot {
    pub files: Vec<FileItem>,
    pub generation: u64,
}

impl FileSync {
    pub fn new() -> Self {
        Self {
            files: Vec::new(),
            last_update: SystemTime::UNIX_EPOCH,
            git_status_cache: None,
            scan_generation: 0,
        }
    }

    pub fn batch_update_frecency_scores(&mut self) {
        if let Ok(frecency) = FRECENCY.read() {
            if let Some(ref tracker) = *frecency {
                for file in &mut self.files {
                    let file_key = FileKey::from(&*file);
                    file.access_frecency_score = tracker.get_access_score(&file_key);
                    file.modification_frecency_score = tracker
                        .get_modification_score(file.modified, format_git_status(file.git_status));
                    file.total_frecency_score =
                        file.access_frecency_score + file.modification_frecency_score;
                }
            }
        }
    }

    pub fn update_files(
        &mut self,
        files: Vec<FileItem>,
        git_status_cache: Option<GitStatusCache>,
    ) {
        debug_assert!(files.windows(2).all(|w| w[0].relative_path <= w[1].relative_path),
                     "Files should be pre-sorted by relative_path");

        self.files = files;
        self.git_status_cache = git_status_cache;
        self.last_update = SystemTime::now();
        self.scan_generation = self.scan_generation.wrapping_add(1);

        self.batch_update_frecency_scores();
    }

    pub fn prepare_files_for_update(mut files: Vec<FileItem>) -> Vec<FileItem> {
        files.sort_by(|a, b| a.relative_path.cmp(&b.relative_path));
        files
    }

    pub fn create_search_snapshot(&self) -> Box<FileSnapshot> {
        Box::new(FileSnapshot {
            files: self.files.clone(),
            generation: self.scan_generation,
        })
    }

    /// Create a new snapshot Arc outside of any locks for atomic swapping
    pub fn create_search_snapshot_arc(&self) -> Arc<RwLock<FileSnapshot>> {
        Arc::new(RwLock::new(FileSnapshot {
            files: self.files.clone(),
            generation: self.scan_generation,
        }))
    }

    pub fn contains_path(&self, path: &str) -> bool {
        self.files
            .binary_search_by(|file| file.relative_path.as_str().cmp(path))
            .is_ok()
    }

    pub fn find_file_index(&self, path: &str) -> Result<usize, usize> {
        self.files
            .binary_search_by(|file| file.relative_path.as_str().cmp(path))
    }

    pub fn insert_file_sorted(&mut self, file: FileItem) {
        match self
            .files
            .binary_search_by(|f| f.relative_path.cmp(&file.relative_path))
        {
            Ok(_) => {
                tracing::warn!(
                    "Trying to insert a file that already exists: {}",
                    file.relative_path
                );
            }
            Err(pos) => {
                self.files.insert(pos, file);
                self.scan_generation = self.scan_generation.wrapping_add(1);
            }
        }
    }

    pub fn remove_file_by_path(&mut self, path: &str) -> bool {
        match self.find_file_index(path) {
            Ok(index) => {
                self.files.remove(index);
                self.scan_generation = self.scan_generation.wrapping_add(1);
                true
            }
            Err(_) => false,
        }
    }
}

impl FileItem {
    #[inline]
    pub fn new(path: PathBuf, base_path: &Path, git_status: Option<Status>) -> Self {
        let relative_path = pathdiff::diff_paths(&path, base_path)
            .unwrap_or_else(|| path.clone())
            .to_string_lossy()
            .into_owned();

        let name = path
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned();

        let extension = path
            .extension()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned();

        let directory = match Path::new(&relative_path).parent() {
            Some(parent) if parent != Path::new(".") && !parent.as_os_str().is_empty() => {
                parent.to_string_lossy().into_owned()
            }
            _ => String::new(),
        };

        let (size, modified) = match std::fs::metadata(&path) {
            Ok(metadata) => {
                let size = metadata.len();
                let modified = metadata
                    .modified()
                    .ok()
                    .and_then(|t| t.duration_since(SystemTime::UNIX_EPOCH).ok())
                    .map_or(0, |d| d.as_secs());

                (size, modified)
            }
            Err(_) => (0, 0),
        };

        Self {
            path,
            relative_path,
            file_name: name,
            extension,
            directory,
            size,
            modified,
            access_frecency_score: 0,
            modification_frecency_score: 0,
            total_frecency_score: 0,
            git_status,
            is_current_file: false,
        }
    }

    pub fn update_frecency_scores(&mut self) {
        if let Ok(frecency) = FRECENCY.read() {
            if let Some(ref tracker) = *frecency {
                let file_key = FileKey::from(&*self);
                self.access_frecency_score = tracker.get_access_score(&file_key);
                self.modification_frecency_score = tracker
                    .get_modification_score(self.modified, format_git_status(self.git_status));
                self.total_frecency_score =
                    self.access_frecency_score + self.modification_frecency_score;
            }
        }
    }
}

impl From<&FileItem> for FileKey {
    fn from(file: &FileItem) -> Self {
        FileKey {
            path: file.relative_path.clone(),
        }
    }
}

#[allow(unused)]
#[derive(Debug, Clone)]
pub struct ScanProgress {
    pub total_files: usize,
    pub scanned_files: usize,
    pub is_scanning: bool,
}

pub fn fuzzy_search_with_snapshot(
    snapshot_arc: &Arc<RwLock<FileSnapshot>>,
    query: &str,
    max_results: usize,
    max_threads: usize,
    current_file: Option<&String>,
) -> SearchResult {
    use crate::score::match_and_score_files;
    use rayon::prelude::*;

    let max_threads = max_threads.max(1); // Ensure at least 1 to avoid division by zero.

    debug!(
        "Starting fuzzy search: query='{}', max_results={}",
        query, max_results
    );

    let time = std::time::Instant::now();

    let timeout = Duration::from_millis(100);
    let snapshot = match try_read_snapshot_with_timeout(snapshot_arc, timeout) {
        Ok(snapshot_arc) => snapshot_arc,
        Err(e) => {
            warn!("Failed to acquire snapshot read lock: {}", e);
            return SearchResult::default();
        }
    };

    let total_files = snapshot.files.len();

    debug!(
        "Using {} files from generation {}",
        total_files, snapshot.generation
    );

    // small queries with a large number of results can match absolutely everything
    let max_typos = (query.len() as u16 / 4).clamp(2, 6);
    let context = ScoringContext {
        query,
        max_typos,
        max_threads,
        current_file,
    };

    let scored_indices = match_and_score_files(&snapshot.files, &context);
    let total_matched = scored_indices.len();

    let mut scored_results: Vec<(usize, crate::types::Score)> = scored_indices;

    scored_results.par_sort_unstable_by(|a, b| {
        b.1.total.cmp(&a.1.total).then_with(|| {
            snapshot.files[b.0]
                .modified
                .cmp(&snapshot.files[a.0].modified)
        })
    });

    scored_results.truncate(max_results);

    let (items, scores): (Vec<FileItem>, Vec<crate::types::Score>) = scored_results
        .into_iter()
        .map(|(idx, score)| (snapshot.files[idx].clone(), score))
        .unzip();

    debug!(
        "Search completed: {} results, {} total matched in {:?}",
        items.len(),
        total_matched,
        time.elapsed()
    );
    SearchResult {
        items,
        scores,
        total_matched,
        total_files,
    }
}
