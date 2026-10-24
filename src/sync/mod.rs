//! Folder sync: watch folders, upload what is new, keep albums and folders in
//! step. One engine runs for the life of the backend; settings changes reload
//! it in place.

pub mod files;
pub mod index;
pub mod remote;

use std::collections::{HashMap, HashSet, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};

use notify::{EventKind, RecursiveMode, Watcher};
use serde_json::{Value, json};
use tokio::sync::{Notify, mpsc};

use crate::config::{SyncSettings, WatchFolder};
use crate::error::{self, Error, Result};
use crate::immich::Immich;
use crate::rpc::Notifier;
use index::{FileRecord, Index};
use remote::Check;

const MAX_WORKERS: usize = 8;
const MAX_ATTEMPTS: u32 = 5;
const SETTLE: Duration = Duration::from_secs(2);
const CHECK_BATCH: usize = 100;
const EVENT_LIMIT: usize = 200;

#[derive(Debug, Clone)]
enum Job {
    Upload {
        path: PathBuf,
        /// None for files the person chose to upload by hand.
        folder_id: Option<String>,
        album_id: Option<String>,
        checksum: Option<(String, i64, i64)>,
        attempt: u32,
    },
    Delete {
        path: String,
        folder_id: String,
    },
}

impl Job {
    fn key(&self) -> String {
        match self {
            Job::Upload { path, .. } => format!("u:{}", path.display()),
            Job::Delete { path, .. } => format!("d:{path}"),
        }
    }

    fn manual(&self) -> bool {
        matches!(self, Job::Upload { folder_id: None, .. })
    }
}

struct Active {
    name: String,
    direction: &'static str,
    total: u64,
    done: Arc<AtomicU64>,
}

#[derive(Default)]
struct State {
    queue: VecDeque<Job>,
    queued: HashSet<String>,
    active: HashMap<u64, Active>,
    next_active: u64,
    manual_pause: bool,
    pause_reason: String,
    offline: bool,
    scanning: usize,
    scan_note: String,
    downloading: bool,
    uploaded: u64,
    duplicates: u64,
    downloaded: u64,
    failed_session: u64,
    last_error: String,
    last_sync_at: i64,
    events: VecDeque<Value>,
    /// Album contents seen by the previous download pass, per folder. Only an
    /// asset seen there and missing now counts as removed from the album.
    album_snapshots: HashMap<String, HashSet<String>>,
}

pub struct Engine {
    immich: Arc<Immich>,
    index: Arc<Index>,
    notifier: Notifier,
    settings: RwLock<SyncSettings>,
    state: Mutex<State>,
    wake: Notify,
    dirty: AtomicBool,
    watcher: Mutex<Option<notify::RecommendedWatcher>>,
    fs_tx: mpsc::UnboundedSender<notify::Event>,
    albums: Mutex<HashMap<String, String>>,
    /// Held while an album is looked up or created, so two workers never
    /// create the same album twice.
    album_lock: tokio::sync::Mutex<()>,
    started: AtomicBool,
}

fn now() -> i64 {
    chrono::Utc::now().timestamp()
}

fn file_name(path: &Path) -> String {
    path.file_name().and_then(|n| n.to_str()).unwrap_or("").to_string()
}

impl Engine {
    pub fn start(immich: Arc<Immich>, index: Arc<Index>, notifier: Notifier, settings: SyncSettings) -> Arc<Engine> {
        let (fs_tx, fs_rx) = mpsc::unbounded_channel();
        let engine = Arc::new(Engine {
            immich,
            index,
            notifier,
            settings: RwLock::new(settings),
            state: Mutex::new(State::default()),
            wake: Notify::new(),
            dirty: AtomicBool::new(true),
            watcher: Mutex::new(None),
            fs_tx,
            albums: Mutex::new(HashMap::new()),
            album_lock: tokio::sync::Mutex::new(()),
            started: AtomicBool::new(false),
        });
        for slot in 0..MAX_WORKERS {
            let e = engine.clone();
            tokio::spawn(async move { e.worker(slot).await });
        }
        tokio::spawn(engine.clone().debounce(fs_rx));
        tokio::spawn(engine.clone().environment());
        tokio::spawn(engine.clone().publisher());
        tokio::spawn(engine.clone().periodic());
        engine
    }

    fn settings(&self) -> SyncSettings {
        self.settings.read().unwrap().clone()
    }

    fn folder(&self, id: &str) -> Option<WatchFolder> {
        self.settings.read().unwrap().folders.iter().find(|f| f.id == id).cloned()
    }

    fn folder_for(&self, path: &Path) -> Option<WatchFolder> {
        self.settings
            .read()
            .unwrap()
            .folders
            .iter()
            .filter(|f| f.enabled && path.starts_with(&f.path))
            .max_by_key(|f| f.path.len())
            .cloned()
    }

    fn touch(&self) {
        self.dirty.store(true, Ordering::Relaxed);
    }

    fn event(&self, kind: &str, path: &str, message: &str) {
        let mut state = self.state.lock().unwrap();
        state.events.push_front(json!({
            "at": now(),
            "kind": kind,
            "name": file_name(Path::new(path)),
            "path": path,
            "message": message,
        }));
        state.events.truncate(EVENT_LIMIT);
        drop(state);
        self.touch();
    }

    /// Settings changed: rebuild watches and look at anything new.
    pub fn reload(self: &Arc<Self>, next: SyncSettings) {
        let previous = std::mem::replace(&mut *self.settings.write().unwrap(), next.clone());
        let known: HashSet<_> = next.folders.iter().map(|f| f.id.clone()).collect();
        for folder in &previous.folders {
            if !known.contains(&folder.id) {
                let _ = self.index.forget_folder(&folder.id);
                self.albums.lock().unwrap().remove(&folder.id);
            }
        }
        // A folder whose album changed must look its album up again.
        for folder in &next.folders {
            if let Some(old) = previous.folders.iter().find(|f| f.id == folder.id) {
                if old.album_name != folder.album_name || old.album_id != folder.album_id {
                    self.albums.lock().unwrap().remove(&folder.id);
                }
            }
        }
        {
            let mut state = self.state.lock().unwrap();
            let live: HashSet<_> = next.folders.iter().filter(|f| f.enabled).map(|f| f.id.clone()).collect();
            let enabled = next.enabled;
            state.queue.retain(|job| match job {
                Job::Upload { folder_id: None, .. } => true,
                Job::Upload { folder_id: Some(id), .. } | Job::Delete { folder_id: id, .. } => {
                    enabled && live.contains(id)
                }
            });
            let keys: HashSet<_> = state.queue.iter().map(|j| j.key()).collect();
            state.queued = keys;
        }
        self.rewatch();
        if next.enabled {
            let first = !self.started.swap(true, Ordering::SeqCst);
            let added: Vec<WatchFolder> = next
                .folders
                .iter()
                .filter(|f| f.enabled)
                .filter(|f| {
                    first
                        || !previous.enabled
                        || !previous.folders.iter().any(|p| p.id == f.id && p.enabled && p.path == f.path)
                })
                .cloned()
                .collect();
            if !first || next.startup_scan {
                for folder in added {
                    self.spawn_scan(folder);
                }
            }
            let engine = self.clone();
            tokio::spawn(async move { engine.download_all().await });
        }
        self.touch();
        self.wake.notify_waiters();
    }

    fn rewatch(&self) {
        let settings = self.settings();
        let mut guard = self.watcher.lock().unwrap();
        *guard = None;
        if !settings.enabled {
            return;
        }
        let tx = self.fs_tx.clone();
        let watcher = notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
            if let Ok(event) = res {
                let _ = tx.send(event);
            }
        });
        let Ok(mut watcher) = watcher else {
            self.set_error("Could not watch folders for changes");
            return;
        };
        for folder in settings.folders.iter().filter(|f| f.enabled) {
            if let Err(err) = watcher.watch(Path::new(&folder.path), RecursiveMode::Recursive) {
                self.event("failed", &folder.path, &format!("Cannot watch this folder: {err}"));
            }
        }
        *guard = Some(watcher);
    }

    fn set_error(&self, message: &str) {
        self.state.lock().unwrap().last_error = message.to_string();
        self.touch();
    }

    fn push(&self, job: Job) -> bool {
        let mut state = self.state.lock().unwrap();
        let key = job.key();
        if !state.queued.insert(key) {
            return false;
        }
        state.queue.push_back(job);
        drop(state);
        self.touch();
        self.wake.notify_waiters();
        true
    }

    /// The person asked for these files to be uploaded, into `album_id` if given.
    pub fn upload_files(&self, paths: Vec<PathBuf>, album_id: Option<String>) -> usize {
        let mut count = 0;
        let mut stack = paths;
        while let Some(path) = stack.pop() {
            if path.is_dir() {
                for entry in walkdir::WalkDir::new(&path).into_iter().filter_map(|e| e.ok()) {
                    if entry.file_type().is_file() && files::is_media(entry.path()) {
                        stack.push(entry.into_path());
                    }
                }
                continue;
            }
            if path.is_file() && files::is_media(&path) {
                let job = Job::Upload { path, folder_id: None, album_id: album_id.clone(), checksum: None, attempt: 0 };
                if self.push(job) {
                    count += 1;
                }
            }
        }
        count
    }

    pub fn set_paused(&self, paused: bool) {
        self.state.lock().unwrap().manual_pause = paused;
        self.touch();
        self.wake.notify_waiters();
    }

    pub fn rescan(self: &Arc<Self>) {
        let settings = self.settings();
        if !settings.enabled {
            return;
        }
        for folder in settings.folders.into_iter().filter(|f| f.enabled) {
            self.spawn_scan(folder);
        }
        let engine = self.clone();
        tokio::spawn(async move { engine.download_all().await });
    }

    pub fn retry_failed(&self) -> usize {
        let failed = self.index.failed().unwrap_or_default();
        let mut count = 0;
        for record in failed {
            let folder_id = if record.folder_id.is_empty() { None } else { Some(record.folder_id.clone()) };
            let job = Job::Upload { path: PathBuf::from(&record.path), folder_id, album_id: None, checksum: None, attempt: 0 };
            let mut reset = record.clone();
            reset.state = "pending".into();
            reset.error.clear();
            reset.attempts = 0;
            let _ = self.index.put(&reset);
            if self.push(job) {
                count += 1;
            }
        }
        count
    }

    pub fn clear_queue(&self) {
        let mut state = self.state.lock().unwrap();
        state.queue.clear();
        state.queued.clear();
        drop(state);
        self.touch();
    }

    fn spawn_scan(self: &Arc<Self>, folder: WatchFolder) {
        let engine = self.clone();
        tokio::spawn(async move {
            {
                let mut state = engine.state.lock().unwrap();
                state.scanning += 1;
            }
            engine.touch();
            if let Err(err) = engine.scan(&folder, Path::new(&folder.path)).await {
                engine.event("failed", &folder.path, &err.message);
            }
            {
                let mut state = engine.state.lock().unwrap();
                state.scanning = state.scanning.saturating_sub(1);
                if state.scanning == 0 {
                    state.scan_note.clear();
                }
            }
            engine.touch();
        });
    }

    /// Compare a folder (or a subfolder of it) against the index, hash what
    /// changed, ask Immich which of those it already has, and queue the rest.
    async fn scan(self: &Arc<Self>, folder: &WatchFolder, root: &Path) -> Result<()> {
        if !folder.method.uploads() && !folder.mirror_local_deletes {
            return Ok(());
        }
        let walk_root = root.to_path_buf();
        let folder_copy = folder.clone();
        let found: Vec<(PathBuf, u64, i64)> = tokio::task::spawn_blocking(move || {
            walkdir::WalkDir::new(&walk_root)
                .follow_links(false)
                .into_iter()
                .filter_entry(|e| {
                    !(folder_copy.ignore_hidden
                        && e.depth() > 0
                        && e.file_name().to_str().map(|s| s.starts_with('.')).unwrap_or(false))
                })
                .filter_map(|e| e.ok())
                .filter(|e| e.file_type().is_file())
                .filter_map(|e| {
                    let meta = e.metadata().ok()?;
                    let path = e.into_path();
                    if files::is_partial(&path) || files::rejection(&folder_copy, &path, meta.len()).is_some() {
                        return None;
                    }
                    Some((path, meta.len(), files::mtime_secs(&meta)))
                })
                .collect()
        })
        .await
        .map_err(|e| Error::internal(e.to_string()))?;

        let records = self.index.under_folder(&folder.id)?;
        let present: HashSet<String> = found.iter().map(|(p, _, _)| p.to_string_lossy().into_owned()).collect();
        // Files the index knows that are gone now.
        if root == Path::new(&folder.path) {
            for record in records.iter().filter(|r| !present.contains(&r.path)) {
                if Path::new(&record.path).exists() {
                    continue;
                }
                if folder.mirror_local_deletes && record.state == "done" && !record.asset_id.is_empty() {
                    self.push(Job::Delete { path: record.path.clone(), folder_id: folder.id.clone() });
                } else {
                    let _ = self.index.remove(&record.path);
                }
            }
        }
        if !folder.method.uploads() {
            return Ok(());
        }
        let known: HashMap<&str, &FileRecord> = records.iter().map(|r| (r.path.as_str(), r)).collect();
        let changed: Vec<(PathBuf, u64, i64)> = found
            .into_iter()
            .filter(|(path, size, mtime)| match known.get(path.to_string_lossy().as_ref()) {
                Some(r) => !(r.state == "done" && r.size == *size as i64 && r.mtime == *mtime),
                None => true,
            })
            .collect();
        let total = changed.len();
        for (offset, chunk) in changed.chunks(CHECK_BATCH).enumerate() {
            if !self.settings().enabled {
                return Ok(());
            }
            {
                let mut state = self.state.lock().unwrap();
                state.scan_note = format!("Checking {} of {} new files", (offset * CHECK_BATCH + chunk.len()).min(total), total);
            }
            self.touch();
            let mut hashed = Vec::new();
            let hashes = futures_util::future::join_all(chunk.iter().map(|(path, size, mtime)| {
                let path = path.clone();
                let (size, mtime) = (*size, *mtime);
                async move {
                    let p = path.clone();
                    let sum = tokio::task::spawn_blocking(move || files::sha1_hex(&p)).await.ok()?.ok()?;
                    Some((path, size, mtime, sum))
                }
            }))
            .await;
            for item in hashes.into_iter().flatten() {
                hashed.push(item);
            }
            let request: Vec<(String, String)> = hashed
                .iter()
                .enumerate()
                .map(|(i, (_, _, _, sum))| (i.to_string(), sum.clone()))
                .collect();
            let verdicts = match remote::check(&self.immich, &request).await {
                Ok(v) => v,
                Err(err) => {
                    // Could not ask: queue them all and let the workers ask one by one.
                    self.note_failure(&err);
                    request.iter().map(|(id, _)| (id.clone(), Check::New)).collect()
                }
            };
            let verdicts: HashMap<String, Check> = verdicts.into_iter().collect();
            let mut existing_for_album = Vec::new();
            for (i, (path, size, mtime, sum)) in hashed.into_iter().enumerate() {
                let path_text = path.to_string_lossy().into_owned();
                match verdicts.get(&i.to_string()) {
                    Some(Check::Exists(asset)) => {
                        let _ = self.index.put(&FileRecord {
                            path: path_text,
                            folder_id: folder.id.clone(),
                            size: size as i64,
                            mtime,
                            checksum: sum,
                            asset_id: asset.clone(),
                            state: "done".into(),
                            error: String::new(),
                            attempts: 0,
                        });
                        existing_for_album.push(asset.clone());
                        self.state.lock().unwrap().duplicates += 1;
                    }
                    _ => {
                        let _ = self.index.put(&FileRecord {
                            path: path_text,
                            folder_id: folder.id.clone(),
                            size: size as i64,
                            mtime,
                            checksum: sum.clone(),
                            asset_id: String::new(),
                            state: "pending".into(),
                            error: String::new(),
                            attempts: 0,
                        });
                        self.push(Job::Upload {
                            path,
                            folder_id: Some(folder.id.clone()),
                            album_id: None,
                            checksum: Some((sum, size as i64, mtime)),
                            attempt: 0,
                        });
                    }
                }
            }
            // Photos Immich already had still belong in this folder's album.
            if !existing_for_album.is_empty() && !folder.album_name.is_empty() {
                if let Ok(album) = self.album_for(folder).await {
                    let _ = remote::add_to_album(&self.immich, &album, &existing_for_album).await;
                }
            }
            self.touch();
        }
        Ok(())
    }

    async fn album_for(&self, folder: &WatchFolder) -> Result<String> {
        if let Some(id) = self.albums.lock().unwrap().get(&folder.id).cloned() {
            return Ok(id);
        }
        let _guard = self.album_lock.lock().await;
        if let Some(id) = self.albums.lock().unwrap().get(&folder.id).cloned() {
            return Ok(id);
        }
        let id = if !folder.album_id.is_empty() && remote::album_exists(&self.immich, &folder.album_id).await? {
            folder.album_id.clone()
        } else {
            remote::ensure_album(&self.immich, &folder.album_name).await?
        };
        self.albums.lock().unwrap().insert(folder.id.clone(), id.clone());
        Ok(id)
    }

    fn note_failure(&self, err: &Error) {
        let mut state = self.state.lock().unwrap();
        state.last_error = err.message.clone();
        if err.code == error::NETWORK {
            state.offline = true;
        }
        drop(state);
        self.touch();
    }

    fn runnable(&self, slot: usize, job: &Job) -> bool {
        let settings = self.settings.read().unwrap();
        let state = self.state.lock().unwrap();
        if state.manual_pause {
            return false;
        }
        if job.manual() {
            return slot < settings.concurrency.max(1) as usize;
        }
        settings.enabled && state.pause_reason.is_empty() && slot < settings.concurrency.max(1) as usize
    }

    fn take(&self, slot: usize) -> Option<Job> {
        let candidates: Vec<Job> = {
            let state = self.state.lock().unwrap();
            state.queue.iter().take(64).cloned().collect()
        };
        let chosen = candidates.into_iter().position(|job| self.runnable(slot, &job))?;
        let mut state = self.state.lock().unwrap();
        if chosen >= state.queue.len() {
            return None;
        }
        let job = state.queue.remove(chosen)?;
        state.queued.remove(&job.key());
        Some(job)
    }

    async fn worker(self: Arc<Self>, slot: usize) {
        loop {
            let Some(job) = self.take(slot) else {
                let _ = tokio::time::timeout(Duration::from_secs(5), self.wake.notified()).await;
                continue;
            };
            self.touch();
            match job {
                Job::Upload { path, folder_id, album_id, checksum, attempt } => {
                    self.process_upload(path, folder_id, album_id, checksum, attempt).await
                }
                Job::Delete { path, folder_id } => self.process_delete(path, folder_id).await,
            }
            self.touch();
        }
    }

    fn begin(&self, name: String, direction: &'static str, total: u64) -> (u64, Arc<AtomicU64>) {
        let done = Arc::new(AtomicU64::new(0));
        let mut state = self.state.lock().unwrap();
        state.next_active += 1;
        let id = state.next_active;
        state.active.insert(id, Active { name, direction, total, done: done.clone() });
        (id, done)
    }

    fn end(&self, id: u64) {
        self.state.lock().unwrap().active.remove(&id);
        self.touch();
    }

    async fn process_upload(
        self: &Arc<Self>,
        path: PathBuf,
        folder_id: Option<String>,
        album_id: Option<String>,
        checksum: Option<(String, i64, i64)>,
        attempt: u32,
    ) {
        let path_text = path.to_string_lossy().into_owned();
        let folder = match &folder_id {
            Some(id) => match self.folder(id) {
                Some(folder) if folder.enabled => Some(folder),
                _ => return,
            },
            None => None,
        };
        // Wait for a file that is still being written to settle.
        let mut meta = match tokio::fs::metadata(&path).await {
            Ok(m) if m.is_file() => m,
            _ => return,
        };
        for _ in 0..30 {
            let fresh = meta.modified().ok().and_then(|m| m.elapsed().ok()).map(|age| age < SETTLE).unwrap_or(false);
            if !fresh {
                break;
            }
            tokio::time::sleep(SETTLE).await;
            match tokio::fs::metadata(&path).await {
                Ok(next) => meta = next,
                Err(_) => return,
            }
        }
        let size = meta.len() as i64;
        let mtime = files::mtime_secs(&meta);
        if let Some(folder) = &folder {
            if let Some(reason) = files::rejection(folder, &path, meta.len()) {
                let _ = reason;
                return;
            }
        }
        let existing = self.index.get(&path_text).ok().flatten();
        if folder.is_some() {
            if let Some(record) = &existing {
                if record.state == "done" && record.size == size && record.mtime == mtime {
                    return;
                }
            }
        }
        let record_folder = folder.as_ref().map(|f| f.id.clone()).unwrap_or_default();
        let (active_id, progress) = self.begin(file_name(&path), "upload", meta.len());

        let result: Result<(String, bool)> = async {
            let sum = match checksum {
                Some((sum, s, m)) if s == size && m == mtime => sum,
                _ => {
                    let p = path.clone();
                    tokio::task::spawn_blocking(move || files::sha1_hex(&p))
                        .await
                        .map_err(|e| Error::internal(e.to_string()))??
                }
            };
            let verdict = remote::check(&self.immich, &[("0".to_string(), sum.clone())]).await?;
            let (asset, created) = match verdict.into_iter().next().map(|v| v.1) {
                Some(Check::Exists(asset)) => (asset, false),
                _ => {
                    let sidecar = if self.settings().upload_sidecars { files::sidecar_for(&path) } else { None };
                    (remote::upload(&self.immich, &path, sidecar.as_deref(), progress.clone()).await?, true)
                }
            };
            let target_album = match (&folder, &album_id) {
                (_, Some(id)) => Some(id.clone()),
                (Some(f), None) if !f.album_name.is_empty() => Some(self.album_for(f).await?),
                _ => None,
            };
            if let Some(album) = target_album {
                remote::add_to_album(&self.immich, &album, std::slice::from_ref(&asset)).await?;
            }
            let _ = self.index.put(&FileRecord {
                path: path_text.clone(),
                folder_id: record_folder.clone(),
                size,
                mtime,
                checksum: sum,
                asset_id: asset.clone(),
                state: "done".into(),
                error: String::new(),
                attempts: 0,
            });
            Ok((asset, created))
        }
        .await;
        self.end(active_id);

        match result {
            Ok((_, created)) => {
                {
                    let mut state = self.state.lock().unwrap();
                    if created {
                        state.uploaded += 1;
                    } else {
                        state.duplicates += 1;
                    }
                    state.offline = false;
                    state.last_error.clear();
                    state.last_sync_at = now();
                }
                self.event(
                    if created { "uploaded" } else { "duplicate" },
                    &path_text,
                    if created { "Uploaded" } else { "Already in Immich" },
                );
            }
            Err(err) => {
                let retry = err.code == error::NETWORK || err.code == error::SERVER;
                self.note_failure(&err);
                if retry && attempt + 1 < MAX_ATTEMPTS {
                    let engine = self.clone();
                    let delay = Duration::from_secs(15 * 2u64.pow(attempt));
                    let job = Job::Upload { path, folder_id, album_id, checksum: None, attempt: attempt + 1 };
                    tokio::spawn(async move {
                        tokio::time::sleep(delay).await;
                        engine.push(job);
                    });
                    return;
                }
                let _ = self.index.put(&FileRecord {
                    path: path_text.clone(),
                    folder_id: record_folder,
                    size,
                    mtime,
                    checksum: existing.map(|r| r.checksum).unwrap_or_default(),
                    asset_id: String::new(),
                    state: "failed".into(),
                    error: err.message.clone(),
                    attempts: attempt as i64 + 1,
                });
                self.state.lock().unwrap().failed_session += 1;
                self.event("failed", &path_text, &err.message);
            }
        }
    }

    async fn process_delete(self: &Arc<Self>, path: String, folder_id: String) {
        // Give a move or an editor's save-by-replace time to finish.
        tokio::time::sleep(Duration::from_secs(10)).await;
        if Path::new(&path).exists() {
            return;
        }
        let Some(folder) = self.folder(&folder_id) else { return };
        let Ok(Some(record)) = self.index.get(&path) else { return };
        let _ = self.index.remove(&path);
        if !folder.mirror_local_deletes || record.asset_id.is_empty() {
            return;
        }
        // The same photo still lives in a folder that uploads: it moved there.
        // A copy that a download folder made from the album does not count.
        let uploading: HashSet<String> = self
            .settings()
            .folders
            .iter()
            .filter(|f| f.method.uploads())
            .map(|f| f.id.clone())
            .collect();
        let elsewhere = self
            .index
            .by_checksum(&record.checksum)
            .unwrap_or_default()
            .into_iter()
            .any(|r| r.path != path && uploading.contains(&r.folder_id) && Path::new(&r.path).exists());
        if elsewhere {
            return;
        }
        match remote::trash(&self.immich, std::slice::from_ref(&record.asset_id)).await {
            Ok(()) => self.event("trashed", &path, "Deleted here, moved to the Immich trash"),
            Err(err) => self.event("failed", &path, &format!("Could not mirror the deletion: {}", err.message)),
        }
    }

    async fn download_all(self: &Arc<Self>) {
        let settings = self.settings();
        if !settings.enabled {
            return;
        }
        let folders: Vec<WatchFolder> = settings
            .folders
            .into_iter()
            .filter(|f| f.enabled && f.method.downloads() && !f.album_name.is_empty())
            .collect();
        if folders.is_empty() {
            return;
        }
        {
            let mut state = self.state.lock().unwrap();
            if state.downloading || state.manual_pause || !state.pause_reason.is_empty() {
                return;
            }
            state.downloading = true;
        }
        self.touch();
        for folder in folders {
            if let Err(err) = self.download_folder(&folder).await {
                self.note_failure(&err);
                self.event("failed", &folder.path, &format!("Album download: {}", err.message));
            }
        }
        self.state.lock().unwrap().downloading = false;
        self.touch();
    }

    async fn download_folder(self: &Arc<Self>, folder: &WatchFolder) -> Result<()> {
        let album = self.album_for(folder).await?;
        let assets = remote::album_assets(&self.immich, &album).await?;
        let records = self.index.under_folder(&folder.id)?;
        let local_sums: HashSet<&str> = records.iter().map(|r| r.checksum.as_str()).filter(|s| !s.is_empty()).collect();
        let local_assets: HashSet<&str> = records.iter().map(|r| r.asset_id.as_str()).filter(|s| !s.is_empty()).collect();
        let dir = PathBuf::from(&folder.path);
        tokio::fs::create_dir_all(&dir).await?;
        for asset in &assets {
            if local_sums.contains(asset.checksum_hex.as_str()) || local_assets.contains(asset.id.as_str()) {
                continue;
            }
            if self.state.lock().unwrap().manual_pause {
                break;
            }
            let target = files::unique_path(&dir, &asset.file_name);
            let (active_id, progress) = self.begin(asset.file_name.clone(), "download", 0);
            let result = remote::download(&self.immich, &asset.id, &target, Some(progress)).await;
            self.end(active_id);
            match result {
                Ok(_) => {
                    let meta = std::fs::metadata(&target)?;
                    self.index.put(&FileRecord {
                        path: target.to_string_lossy().into_owned(),
                        folder_id: folder.id.clone(),
                        size: meta.len() as i64,
                        mtime: files::mtime_secs(&meta),
                        checksum: asset.checksum_hex.clone(),
                        asset_id: asset.id.clone(),
                        state: "done".into(),
                        error: String::new(),
                        attempts: 0,
                    })?;
                    {
                        let mut state = self.state.lock().unwrap();
                        state.downloaded += 1;
                        state.last_sync_at = now();
                    }
                    self.event("downloaded", &target.to_string_lossy(), "Downloaded from the album");
                }
                Err(err) => self.event("failed", &asset.file_name, &format!("Download failed: {}", err.message)),
            }
        }
        let current: HashSet<String> = assets.iter().map(|a| a.id.clone()).collect();
        let previous = self.state.lock().unwrap().album_snapshots.insert(folder.id.clone(), current.clone());
        if folder.mirror_remote_deletes {
            if let Some(previous) = previous {
                for record in records.iter().filter(|r| {
                    !r.asset_id.is_empty() && previous.contains(&r.asset_id) && !current.contains(&r.asset_id)
                }) {
                    let path = Path::new(&record.path);
                    if path.exists() {
                        match files::move_to_trash(path) {
                            Ok(_) => self.event("trashed", &record.path, "Removed from the album, moved to the trash here"),
                            Err(err) => self.event("failed", &record.path, &format!("Could not move to the trash: {err}")),
                        }
                    }
                    let _ = self.index.remove(&record.path);
                }
            }
        }
        Ok(())
    }

    async fn debounce(self: Arc<Self>, mut rx: mpsc::UnboundedReceiver<notify::Event>) {
        let mut pending: HashMap<PathBuf, (bool, Instant)> = HashMap::new();
        let mut tick = tokio::time::interval(Duration::from_millis(700));
        loop {
            tokio::select! {
                event = rx.recv() => {
                    let Some(event) = event else { return };
                    let removed = matches!(event.kind, EventKind::Remove(_))
                        || matches!(event.kind, EventKind::Modify(notify::event::ModifyKind::Name(notify::event::RenameMode::From)));
                    let both = matches!(event.kind, EventKind::Modify(notify::event::ModifyKind::Name(notify::event::RenameMode::Both)));
                    if matches!(event.kind, EventKind::Access(_)) {
                        continue;
                    }
                    for (i, path) in event.paths.into_iter().enumerate() {
                        let gone = if both { i == 0 } else { removed };
                        pending.insert(path, (gone, Instant::now()));
                    }
                }
                _ = tick.tick() => {
                    let ready: Vec<(PathBuf, bool)> = pending
                        .iter()
                        .filter(|(_, (_, at))| at.elapsed() >= SETTLE)
                        .map(|(p, (gone, _))| (p.clone(), *gone))
                        .collect();
                    for (path, gone) in ready {
                        pending.remove(&path);
                        self.on_change(path, gone);
                    }
                }
            }
        }
    }

    fn on_change(self: &Arc<Self>, path: PathBuf, gone: bool) {
        let Some(folder) = self.folder_for(&path) else { return };
        if !self.settings().enabled {
            return;
        }
        if gone || !path.exists() {
            let text = path.to_string_lossy().into_owned();
            match self.index.get(&text) {
                Ok(Some(record)) if folder.mirror_local_deletes && record.state == "done" && !record.asset_id.is_empty() => {
                    self.push(Job::Delete { path: text, folder_id: folder.id.clone() });
                }
                Ok(Some(_)) => {
                    let _ = self.index.remove(&text);
                }
                _ => {
                    // A whole directory went away: its files are in the index under it.
                    if let Ok(records) = self.index.under_folder(&folder.id) {
                        let prefix = format!("{text}/");
                        for record in records.into_iter().filter(|r| r.path.starts_with(&prefix)) {
                            if folder.mirror_local_deletes && record.state == "done" && !record.asset_id.is_empty() {
                                self.push(Job::Delete { path: record.path, folder_id: folder.id.clone() });
                            } else {
                                let _ = self.index.remove(&record.path);
                            }
                        }
                    }
                }
            }
            return;
        }
        if !folder.method.uploads() {
            return;
        }
        if path.is_dir() {
            let engine = self.clone();
            tokio::spawn(async move {
                let _ = engine.scan(&folder, &path).await;
            });
            return;
        }
        if files::is_partial(&path) {
            return;
        }
        let size = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
        if files::rejection(&folder, &path, size).is_some() {
            return;
        }
        self.push(Job::Upload { path, folder_id: Some(folder.id.clone()), album_id: None, checksum: None, attempt: 0 });
    }

    /// Decide every half minute whether the environment allows uploading.
    async fn environment(self: Arc<Self>) {
        loop {
            let settings = self.settings();
            let reason = tokio::task::spawn_blocking(move || {
                use chrono::Timelike;
                let now = chrono::Local::now();
                let minutes = now.hour() * 60 + now.minute();
                if files::in_quiet_hours(&settings.quiet_start, &settings.quiet_end, minutes) {
                    return format!("Quiet hours until {}", settings.quiet_end);
                }
                if settings.pause_on_battery && files::on_battery() {
                    return "On battery power".to_string();
                }
                if settings.pause_on_metered && files::is_metered() {
                    return "On a metered connection".to_string();
                }
                String::new()
            })
            .await
            .unwrap_or_default();
            let changed = {
                let mut state = self.state.lock().unwrap();
                let changed = state.pause_reason != reason;
                state.pause_reason = reason;
                changed
            };
            if changed {
                self.touch();
                self.wake.notify_waiters();
            }
            tokio::time::sleep(Duration::from_secs(30)).await;
        }
    }

    async fn periodic(self: Arc<Self>) {
        loop {
            tokio::time::sleep(Duration::from_secs(300)).await;
            if self.settings().enabled {
                self.download_all().await;
                let offline = self.state.lock().unwrap().offline;
                if offline {
                    self.retry_network_failures();
                }
            }
        }
    }

    fn retry_network_failures(&self) {
        // The server came back: files that failed only because it was away get another go.
        for record in self.index.failed().unwrap_or_default() {
            if record.error.contains("reach") || record.error.contains("too long") || record.error.contains("Network") {
                let folder_id = (!record.folder_id.is_empty()).then(|| record.folder_id.clone());
                self.push(Job::Upload { path: PathBuf::from(&record.path), folder_id, album_id: None, checksum: None, attempt: 0 });
            }
        }
    }

    async fn publisher(self: Arc<Self>) {
        loop {
            tokio::time::sleep(Duration::from_millis(400)).await;
            let busy = !self.state.lock().unwrap().active.is_empty();
            if self.dirty.swap(false, Ordering::Relaxed) || busy {
                self.notifier.notify("sync.changed", self.status());
            }
        }
    }

    pub fn status(&self) -> Value {
        let settings = self.settings();
        let state = self.state.lock().unwrap();
        let active: Vec<Value> = state
            .active
            .values()
            .map(|a| json!({ "name": a.name, "direction": a.direction, "total": a.total, "done": a.done.load(Ordering::Relaxed) }))
            .collect();
        let phase = if !settings.enabled && state.queue.is_empty() && state.active.is_empty() {
            "disabled"
        } else if state.manual_pause {
            "paused"
        } else if !state.pause_reason.is_empty() && state.active.is_empty() {
            "waiting"
        } else if state.active.iter().any(|(_, a)| a.direction == "upload") {
            "uploading"
        } else if state.downloading || !state.active.is_empty() {
            "downloading"
        } else if state.scanning > 0 {
            "scanning"
        } else if state.offline {
            "offline"
        } else if !state.queue.is_empty() {
            "queued"
        } else {
            "idle"
        };
        let folders: Vec<Value> = settings
            .folders
            .iter()
            .map(|f| {
                let counts = self.index.counts(&f.id).unwrap_or_default();
                json!({ "id": f.id, "exists": Path::new(&f.path).is_dir(), "counts": counts })
            })
            .collect();
        json!({
            "enabled": settings.enabled,
            "phase": phase,
            "paused": state.manual_pause,
            "pauseReason": state.pause_reason,
            "offline": state.offline,
            "scanning": state.scanning > 0,
            "scanNote": state.scan_note,
            "queue": state.queue.len(),
            "active": active,
            "uploaded": state.uploaded,
            "duplicates": state.duplicates,
            "downloaded": state.downloaded,
            "failedSession": state.failed_session,
            "failed": self.index.total_failed().unwrap_or(0),
            "lastError": state.last_error,
            "lastSyncAt": state.last_sync_at,
            "folders": folders,
            "events": state.events.iter().take(60).cloned().collect::<Vec<_>>(),
        })
    }

    pub fn failed_files(&self) -> Value {
        let failed = self.index.failed().unwrap_or_default();
        Value::Array(
            failed
                .into_iter()
                .map(|r| json!({ "path": r.path, "name": file_name(Path::new(&r.path)), "error": r.error, "attempts": r.attempts }))
                .collect(),
        )
    }
}
