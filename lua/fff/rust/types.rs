use mlua::prelude::*;
use std::path::PathBuf;

use crate::git::format_git_status;

#[derive(Debug, Clone)]
pub struct FileItem {
    pub path: PathBuf,
    pub relative_path: String,
    pub file_name: String,
    pub extension: String,
    pub directory: String,
    pub size: u64,
    pub modified: u64,
    pub access_frecency_score: i64,
    pub modification_frecency_score: i64,
    pub total_frecency_score: i64,
    pub git_status: Option<git2::Status>,
    pub is_current_file: bool,
}

#[derive(Debug, Clone)]
pub struct Score {
    pub total: i32,
    pub base_score: i32,
    pub filename_bonus: i32,
    pub special_filename_bonus: i32,
    pub frecency_boost: i32,
    pub distance_penalty: i32,
    pub match_type: &'static str,
}

#[derive(Debug, Clone)]
pub struct ScoringContext<'a> {
    pub query: &'a str,
    pub current_file: Option<&'a String>,
    pub max_typos: u16,
    pub max_threads: usize,
}

#[derive(Debug, Clone, Default)]
pub struct SearchResult {
    pub items: Vec<FileItem>,
    pub scores: Vec<Score>,
    pub total_matched: usize,
    pub total_files: usize,
}

impl IntoLua for FileItem {
    #[inline]
    fn into_lua(self, lua: &Lua) -> LuaResult<LuaValue> {
        let table = lua.create_table()?;
        table.set("path", self.path.to_string_lossy().to_string())?;
        table.set("relative_path", self.relative_path)?;
        table.set("name", self.file_name)?;
        table.set("extension", self.extension)?;
        table.set("directory", self.directory)?;
        table.set("size", self.size)?;
        table.set("modified", self.modified)?;
        table.set("access_frecency_score", self.access_frecency_score)?;
        table.set(
            "modification_frecency_score",
            self.modification_frecency_score,
        )?;
        table.set("total_frecency_score", self.total_frecency_score)?;
        table.set("git_status", format_git_status(self.git_status))?;
        table.set("is_current_file", self.is_current_file)?;
        Ok(LuaValue::Table(table))
    }
}

impl IntoLua for Score {
    #[inline]
    fn into_lua(self, lua: &Lua) -> LuaResult<LuaValue> {
        let table = lua.create_table()?;
        table.set("total", self.total)?;
        table.set("base_score", self.base_score)?;
        table.set("filename_bonus", self.filename_bonus)?;
        table.set("special_filename_bonus", self.special_filename_bonus)?;
        table.set("frecency_boost", self.frecency_boost)?;
        table.set("distance_penalty", self.distance_penalty)?;
        table.set("match_type", self.match_type)?;
        Ok(LuaValue::Table(table))
    }
}

impl IntoLua for SearchResult {
    #[inline]
    fn into_lua(self, lua: &Lua) -> LuaResult<LuaValue> {
        let table = lua.create_table()?;
        table.set("items", self.items)?;
        table.set("scores", self.scores)?;
        table.set("total_matched", self.total_matched)?;
        table.set("total_files", self.total_files)?;
        Ok(LuaValue::Table(table))
    }
}
