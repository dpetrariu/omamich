//! Files on this computer: the upload staging list, the synced folders seen
//! from the library, and copies of originals for dragging out of the window.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use crate::app::App;
use crate::error::{Error, Result};
use crate::immich::require_id;
use crate::library::str_param;
use crate::sync::files;
use crate::sync::remote::{self, Check};

const LIST_LIMIT: usize = 5000;

fn file_entry(path: &Path, meta: &std::fs::Metadata) -> Value {
    let ext = files::extension(path);
    json!({
        "path": path.to_string_lossy(),
        "name": path.file_name().and_then(|n| n.to_str()).unwrap_or(""),
        "size": meta.len(),
        "mtime": files::mtime_secs(meta),
        "isImage": !files::VIDEO_EXTENSIONS.contains(&ext.as_str()),
    })
}

fn param_paths(params: &Value) -> Result<Vec<PathBuf>> {
    let list = params.get("paths").and_then(|v| v.as_array()).ok_or_else(|| Error::invalid("Choose files"))?;
    Ok(list
        .iter()
        .filter_map(|v| v.as_str())
        .map(|s| {
            let s = s.strip_prefix("file://").unwrap_or(s);
            crate::paths::expand_home(&percent_encoding::percent_decode_str(s).decode_utf8_lossy())
        })
        .filter(|p| p.is_absolute())
        .collect())
}

/// The photos and videos among these paths, folders opened, for the
/// staging window.
pub async fn list(params: &Value) -> Result<Value> {
    let paths = param_paths(params)?;
    let (items, truncated) = tokio::task::spawn_blocking(move || {
        let mut out = Vec::new();
        let mut truncated = false;
        for path in paths {
            let walker = walkdir::WalkDir::new(&path).follow_links(false).into_iter().filter_entry(|e| {
                e.depth() == 0 || !e.file_name().to_str().map(|n| n.starts_with('.')).unwrap_or(false)
            });
            for entry in walker.filter_map(|e| e.ok()) {
                if !entry.file_type().is_file() || !files::is_media(entry.path()) {
                    continue;
                }
                let Ok(meta) = entry.metadata() else { continue };
                if out.len() >= LIST_LIMIT {
                    truncated = true;
                    break;
                }
                out.push(file_entry(entry.path(), &meta));
            }
        }
        (out, truncated)
    })
    .await
    .map_err(|e| Error::internal(e.to_string()))?;
    Ok(json!({ "items": items, "truncated": truncated }))
}

/// Which of these files Immich already has. Hashes them, so the UI asks in
/// small batches.
pub async fn check(app: &App, params: &Value) -> Result<Value> {
    let paths = param_paths(params)?;
    if paths.len() > 200 {
        return Err(Error::invalid("Check at most 200 files at a time"));
    }
    let hashed = futures_util::future::join_all(paths.into_iter().map(|path| async move {
        let p = path.clone();
        // Picked by hand: a link is taken to mean the file it points to.
        let sum = tokio::task::spawn_blocking(move || files::sha1_hex(None, &std::fs::canonicalize(&p)?)).await.ok()?.ok()?;
        Some((path, sum))
    }))
    .await;
    let hashed: Vec<(PathBuf, String)> = hashed.into_iter().flatten().collect();
    let request: Vec<(String, String)> = hashed.iter().enumerate().map(|(i, (_, s))| (i.to_string(), s.clone())).collect();
    let verdicts: HashMap<String, Check> = remote::check(&app.immich, &request).await?.into_iter().collect();
    let out: Vec<Value> = hashed
        .iter()
        .enumerate()
        .map(|(i, (path, _))| {
            let state = match verdicts.get(&i.to_string()) {
                Some(Check::Exists(_)) => "inImmich",
                Some(Check::Trashed(_)) => "inTrash",
                _ => "new",
            };
            json!({ "path": path.to_string_lossy(), "state": state })
        })
        .collect();
    Ok(Value::Array(out))
}

/// A watched folder's files as the library sees them: each with its sync
/// state, newest first, a page at a time.
pub async fn folder_files(app: &App, params: &Value) -> Result<Value> {
    let id = str_param(params, "folderId").to_string();
    let folder = app
        .settings()
        .sync
        .folders
        .into_iter()
        .find(|f| f.id == id)
        .ok_or_else(|| Error::invalid("That folder is not synced"))?;
    let page = params.get("page").and_then(|v| v.as_u64()).unwrap_or(1).max(1) as usize;
    let size = 300usize;
    let records: HashMap<String, (String, String, String)> = app
        .sync
        .index()
        .under_folder(&folder.id)?
        .into_iter()
        .map(|r| (r.path.clone(), (r.state, r.asset_id, r.error)))
        .collect();
    let root = PathBuf::from(&folder.path);
    let folder_copy = folder.clone();
    let mut found: Vec<(PathBuf, std::fs::Metadata)> = tokio::task::spawn_blocking(move || {
        walkdir::WalkDir::new(&root)
            .follow_links(false)
            .into_iter()
            .filter_entry(|e| {
                !(folder_copy.ignore_hidden && e.depth() > 0 && e.file_name().to_str().map(|n| n.starts_with('.')).unwrap_or(false))
            })
            .filter_map(|e| e.ok())
            .filter(|e| e.file_type().is_file() && files::is_media(e.path()))
            .filter_map(|e| {
                let meta = e.metadata().ok()?;
                Some((e.into_path(), meta))
            })
            .collect()
    })
    .await
    .map_err(|e| Error::internal(e.to_string()))?;
    found.sort_by_key(|(_, m)| std::cmp::Reverse(files::mtime_secs(m)));
    let total = found.len();
    let items: Vec<Value> = found
        .iter()
        .skip((page - 1) * size)
        .take(size)
        .map(|(path, meta)| {
            let mut entry = file_entry(path, meta);
            let key = path.to_string_lossy().into_owned();
            let rejection = files::rejection(&folder, path, meta.len());
            let (state, asset, error) = match (records.get(&key), rejection) {
                (_, Some(reason)) => ("skipped".to_string(), String::new(), reason.to_string()),
                (Some((state, asset, error)), None) => (state.clone(), asset.clone(), error.clone()),
                (None, None) => ("localOnly".to_string(), String::new(), String::new()),
            };
            let obj = entry.as_object_mut().expect("object");
            obj.insert("syncState".into(), json!(state));
            obj.insert("assetId".into(), json!(asset));
            obj.insert("syncError".into(), json!(error));
            entry
        })
        .collect();
    Ok(json!({ "items": items, "total": total, "nextPage": if page * size < total { json!(page + 1) } else { Value::Null } }))
}

/// Download originals into the export cache so they can be dragged out of
/// the window as files. Reuses copies already there.
pub async fn export_prepare(app: &App, params: &Value) -> Result<Value> {
    let ids = crate::library::ids_param(params, "ids")?;
    if ids.len() > 200 {
        return Err(Error::invalid("Drag at most 200 photos at a time"));
    }
    let base = app.paths.cache_dir.join("export");
    let mut out = Vec::new();
    for id in ids {
        require_id(&id)?;
        let dir = base.join(&id);
        if let Some(existing) = std::fs::read_dir(&dir)
            .ok()
            .and_then(|mut entries| entries.find_map(|e| e.ok().map(|e| e.path())))
            .filter(|p| p.is_file() && !p.file_name().and_then(|n| n.to_str()).unwrap_or("").starts_with('.'))
        {
            out.push(existing.to_string_lossy().into_owned());
            continue;
        }
        let asset = app.immich.get(&format!("/api/assets/{id}")).await?;
        let name = files::safe_file_name(asset.get("originalFileName").and_then(|v| v.as_str()).unwrap_or("photo"));
        tokio::fs::create_dir_all(&dir).await?;
        let target = dir.join(name);
        remote::download(&app.immich, &id, &target, None).await?;
        out.push(target.to_string_lossy().into_owned());
    }
    Ok(json!({ "paths": out }))
}

/// Exported copies are only needed while they are being dragged; keep the
/// cache from growing past a day's worth.
pub fn prune_exports(cache_dir: &Path) {
    let base = cache_dir.join("export");
    let Ok(entries) = std::fs::read_dir(&base) else { return };
    for entry in entries.flatten() {
        let old = entry
            .metadata()
            .ok()
            .and_then(|m| m.modified().ok())
            .and_then(|m| m.elapsed().ok())
            .map(|age| age.as_secs() > 86_400)
            .unwrap_or(false);
        if old {
            let _ = std::fs::remove_dir_all(entry.path());
        }
    }
}

/// A support bundle with nothing private in it: versions, counts, settings
/// with addresses reduced to their scheme, and failures by file name only.
pub async fn diagnostics(app: &App, params: &Value) -> Result<Value> {
    let settings = app.settings();
    let redact = |url: &str| -> String {
        match url::Url::parse(url) {
            Ok(u) => format!("{}://<redacted>{}", u.scheme(), u.port().map(|p| format!(":{p}")).unwrap_or_default()),
            Err(_) if url.is_empty() => String::new(),
            Err(_) => "<redacted>".into(),
        }
    };
    let mut config = settings.to_json();
    config["serverUrl"] = json!(redact(&settings.server_url));
    config["externalUrl"] = json!(redact(&settings.external_url));
    if let Some(folders) = config.pointer_mut("/sync/folders").and_then(|v| v.as_array_mut()) {
        for (i, folder) in folders.iter_mut().enumerate() {
            folder["path"] = json!(format!("<folder {}>", i + 1));
            if folder.get("albumName").and_then(|v| v.as_str()).map(|s| !s.is_empty()).unwrap_or(false) {
                folder["albumName"] = json!("<album>");
            }
            folder["albumId"] = json!("");
        }
    }
    config["ui"] = json!({});
    let mut status = app.sync.status();
    if let Some(events) = status.get_mut("events").and_then(|v| v.as_array_mut()) {
        for event in events {
            event["path"] = json!("");
        }
    }
    let failed: Vec<Value> = app
        .sync
        .failed_files()
        .as_array()
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .map(|f| json!({ "name": f["name"], "error": f["error"], "attempts": f["attempts"] }))
        .collect();
    let route = app.immich.route().await.map(|r| r.route).unwrap_or("none");
    let version = app.immich.get("/api/server/version").await.map(|v| crate::immich::version_text(&v)).unwrap_or_default();
    let summary = format!(
        "Omamich {} (api {})\nImmich {}\nConnected via: {}\nKey stored in: {}\nWatched folders: {}\nSync enabled: {}\nFailed files: {}\nGenerated: {}\n",
        env!("CARGO_PKG_VERSION"),
        crate::methods::API_VERSION,
        if version.is_empty() { "unreachable".to_string() } else { version },
        route,
        *app.key_storage.read().unwrap(),
        settings.sync.folders.len(),
        settings.sync.enabled,
        failed.len(),
        chrono::Local::now().format("%Y-%m-%d %H:%M:%S"),
    );
    let base = match str_param(params, "directory") {
        "" => crate::library::downloads_dir(),
        d => crate::paths::expand_home(d),
    };
    let dir = files::unique_path(&base, &format!("omamich-diagnostics-{}", chrono::Local::now().format("%Y%m%d-%H%M%S")));
    std::fs::create_dir_all(&base)?;
    files::make_private_dir(&dir)?;
    let write = |name: &str, text: String| std::fs::write(dir.join(name), text);
    write("summary.txt", summary)?;
    write("config.redacted.json", serde_json::to_string_pretty(&config)?)?;
    write("status.redacted.json", serde_json::to_string_pretty(&status)?)?;
    write("failed.redacted.json", serde_json::to_string_pretty(&failed)?)?;
    write(
        "privacy-note.txt",
        "This bundle leaves out the API key, server addresses, folder paths, album names and file paths.\n\
         Failed files are listed by name only. Read the files before sharing them.\n"
            .to_string(),
    )?;
    Ok(json!({ "directory": dir.to_string_lossy() }))
}
