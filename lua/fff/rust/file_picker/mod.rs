// File picker modules - organized for clarity and maintainability

pub mod core;
pub mod scanner;
pub mod watcher;

pub use core::{fuzzy_search_with_snapshot, FileSnapshot, FileSync, ScanProgress};
pub use scanner::scan_filesystem;
pub use watcher::spawn_background_watcher;
