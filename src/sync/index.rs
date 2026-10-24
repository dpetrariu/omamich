//! What sync knows about each local file, kept in SQLite so a restart does not
//! re-hash a library.

use std::path::Path;
use std::sync::Mutex;

use rusqlite::{Connection, OptionalExtension, params};

use crate::error::Result;

#[derive(Debug, Clone, PartialEq)]
pub struct FileRecord {
    pub path: String,
    pub folder_id: String,
    pub size: i64,
    pub mtime: i64,
    pub checksum: String,
    pub asset_id: String,
    pub state: String,
    pub error: String,
    pub attempts: i64,
}

pub struct Index {
    conn: Mutex<Connection>,
}

#[derive(Debug, Default, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FolderCounts {
    pub files: i64,
    pub done: i64,
    pub failed: i64,
    pub pending: i64,
}

impl Index {
    pub fn open(path: &Path) -> Result<Self> {
        let conn = Connection::open(path)?;
        Self::init(conn)
    }

    #[cfg(test)]
    pub fn memory() -> Result<Self> {
        Self::init(Connection::open_in_memory()?)
    }

    fn init(conn: Connection) -> Result<Self> {
        conn.execute_batch(
            "PRAGMA journal_mode=WAL;
             PRAGMA synchronous=NORMAL;
             CREATE TABLE IF NOT EXISTS files (
                path TEXT PRIMARY KEY,
                folder_id TEXT NOT NULL,
                size INTEGER NOT NULL DEFAULT 0,
                mtime INTEGER NOT NULL DEFAULT 0,
                checksum TEXT NOT NULL DEFAULT '',
                asset_id TEXT NOT NULL DEFAULT '',
                state TEXT NOT NULL DEFAULT 'pending',
                error TEXT NOT NULL DEFAULT '',
                attempts INTEGER NOT NULL DEFAULT 0,
                updated_at INTEGER NOT NULL DEFAULT 0
             );
             CREATE INDEX IF NOT EXISTS files_folder ON files(folder_id);
             CREATE INDEX IF NOT EXISTS files_checksum ON files(checksum);
             CREATE INDEX IF NOT EXISTS files_asset ON files(asset_id);",
        )?;
        Ok(Self { conn: Mutex::new(conn) })
    }

    fn row(row: &rusqlite::Row<'_>) -> rusqlite::Result<FileRecord> {
        Ok(FileRecord {
            path: row.get(0)?,
            folder_id: row.get(1)?,
            size: row.get(2)?,
            mtime: row.get(3)?,
            checksum: row.get(4)?,
            asset_id: row.get(5)?,
            state: row.get(6)?,
            error: row.get(7)?,
            attempts: row.get(8)?,
        })
    }

    const COLUMNS: &'static str = "path, folder_id, size, mtime, checksum, asset_id, state, error, attempts";

    pub fn get(&self, path: &str) -> Result<Option<FileRecord>> {
        let conn = self.conn.lock().unwrap();
        Ok(conn
            .query_row(&format!("SELECT {} FROM files WHERE path = ?1", Self::COLUMNS), [path], Self::row)
            .optional()?)
    }

    pub fn put(&self, record: &FileRecord) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO files (path, folder_id, size, mtime, checksum, asset_id, state, error, attempts, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, strftime('%s','now'))
             ON CONFLICT(path) DO UPDATE SET folder_id=excluded.folder_id, size=excluded.size,
               mtime=excluded.mtime, checksum=excluded.checksum, asset_id=excluded.asset_id,
               state=excluded.state, error=excluded.error, attempts=excluded.attempts,
               updated_at=excluded.updated_at",
            params![
                record.path,
                record.folder_id,
                record.size,
                record.mtime,
                record.checksum,
                record.asset_id,
                record.state,
                record.error,
                record.attempts
            ],
        )?;
        Ok(())
    }

    pub fn remove(&self, path: &str) -> Result<()> {
        self.conn.lock().unwrap().execute("DELETE FROM files WHERE path = ?1", [path])?;
        Ok(())
    }

    pub fn under_folder(&self, folder_id: &str) -> Result<Vec<FileRecord>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(&format!("SELECT {} FROM files WHERE folder_id = ?1", Self::COLUMNS))?;
        let rows = stmt.query_map([folder_id], Self::row)?.collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows)
    }

    pub fn by_checksum(&self, checksum: &str) -> Result<Vec<FileRecord>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(&format!("SELECT {} FROM files WHERE checksum = ?1", Self::COLUMNS))?;
        let rows = stmt.query_map([checksum], Self::row)?.collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows)
    }

    pub fn failed(&self) -> Result<Vec<FileRecord>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare(&format!(
            "SELECT {} FROM files WHERE state = 'failed' ORDER BY updated_at DESC LIMIT 500",
            Self::COLUMNS
        ))?;
        let rows = stmt.query_map([], Self::row)?.collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows)
    }

    pub fn counts(&self, folder_id: &str) -> Result<FolderCounts> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare("SELECT state, COUNT(*) FROM files WHERE folder_id = ?1 GROUP BY state")?;
        let mut counts = FolderCounts::default();
        let rows = stmt.query_map([folder_id], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)))?;
        for row in rows {
            let (state, n) = row?;
            counts.files += n;
            match state.as_str() {
                "done" => counts.done += n,
                "failed" => counts.failed += n,
                "skipped" => {}
                _ => counts.pending += n,
            }
        }
        Ok(counts)
    }

    pub fn total_failed(&self) -> Result<i64> {
        let conn = self.conn.lock().unwrap();
        Ok(conn.query_row("SELECT COUNT(*) FROM files WHERE state = 'failed'", [], |r| r.get(0))?)
    }

    /// A folder was removed from sync; forget its files so adding it back
    /// starts clean.
    pub fn forget_folder(&self, folder_id: &str) -> Result<()> {
        self.conn.lock().unwrap().execute("DELETE FROM files WHERE folder_id = ?1", [folder_id])?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record(path: &str, state: &str) -> FileRecord {
        FileRecord {
            path: path.into(),
            folder_id: "f".into(),
            size: 1,
            mtime: 2,
            checksum: "abc".into(),
            asset_id: String::new(),
            state: state.into(),
            error: String::new(),
            attempts: 0,
        }
    }

    #[test]
    fn upserts_and_counts() {
        let index = Index::memory().unwrap();
        index.put(&record("/a", "done")).unwrap();
        index.put(&record("/b", "failed")).unwrap();
        index.put(&record("/b", "done")).unwrap();
        index.put(&record("/c", "pending")).unwrap();
        let counts = index.counts("f").unwrap();
        assert_eq!((counts.files, counts.done, counts.failed, counts.pending), (3, 2, 0, 1));
        assert_eq!(index.by_checksum("abc").unwrap().len(), 3);
        index.remove("/a").unwrap();
        assert!(index.get("/a").unwrap().is_none());
        index.forget_folder("f").unwrap();
        assert_eq!(index.counts("f").unwrap().files, 0);
    }
}
