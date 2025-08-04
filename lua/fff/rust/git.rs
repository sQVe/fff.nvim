use git2::{Repository, Status, StatusOptions};
use std::path::{Path, PathBuf};
use tracing::error;

#[derive(Debug, Clone)]
pub struct GitStatusCache {
    paths: Vec<PathBuf>,
    statuses: Vec<Status>,
}

impl GitStatusCache {
    fn from_git_entries(mut entries: Vec<(PathBuf, Status)>) -> Self {
        entries.sort_by(|a, b| a.0.cmp(&b.0));

        let (paths, statuses) = entries.into_iter().unzip();
        Self { paths, statuses }
    }

    pub fn lookup_status(&self, full_path: &Path) -> Option<Status> {
        match self
            .paths
            .binary_search_by(|probe| probe.as_path().cmp(full_path))
        {
            Ok(idx) => self.statuses.get(idx).copied(),
            Err(_) => None,
        }
    }

    pub fn read_git_status(git_workdir: Option<&Path>) -> Option<Self> {
        let mut entries = Vec::with_capacity(256);
        let git_workdir = git_workdir.as_ref()?;
        let repository = Repository::open(git_workdir).ok()?;

        let statuses = repository
            .statuses(Some(&mut StatusOptions::new().include_untracked(true)))
            .map_err(|e| {
                error!("Failed to get git statuses: {}", e);
                e
            })
            .ok()?;

        for entry in &statuses {
            if let Some(entry_path) = entry.path() {
                let full_path = git_workdir.join(entry_path);
                entries.push((full_path, entry.status()));
            }
        }

        Some(Self::from_git_entries(entries))
    }
}

#[inline]
pub fn is_modified_status(status: Status) -> bool {
    status.intersects(
        Status::WT_MODIFIED
            | Status::INDEX_MODIFIED
            | Status::WT_NEW
            | Status::INDEX_NEW
            | Status::WT_RENAMED,
    )
}

pub fn format_git_status(status: Option<Status>) -> &'static str {
    match status {
        None => "clear",
        Some(status) => {
            if status.contains(Status::WT_NEW) {
                "untracked"
            } else if status.contains(Status::WT_MODIFIED) {
                "modified"
            } else if status.contains(Status::WT_DELETED) {
                "deleted"
            } else if status.contains(Status::WT_RENAMED) {
                "renamed"
            } else if status.contains(Status::INDEX_NEW) {
                "staged_new"
            } else if status.contains(Status::INDEX_MODIFIED) {
                "staged_modified"
            } else if status.contains(Status::INDEX_DELETED) {
                "staged_deleted"
            } else if status.contains(Status::IGNORED) {
                "ignored"
            } else if status.contains(Status::CURRENT) || status.is_empty() {
                "clean"
            } else {
                "unknown"
            }
        }
    }
}
