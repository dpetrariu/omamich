//! The RPC surface. Each method name maps to one handler; anything else is
//! refused, so the UI cannot reach the network except through these.

use std::path::PathBuf;

use serde_json::{Value, json};

use crate::app::App;
use crate::config::{WatchFolder, normalize_url};
use crate::error::{Error, METHOD_NOT_FOUND, Result};
use crate::library::{self as lib, str_param};
use crate::secrets;

/// Bumped whenever a method, parameter or response changes shape.
pub const API_VERSION: u64 = 1;

pub async fn dispatch(app: &App, method: &str, params: &Value) -> Result<Value> {
    match method {
        "system.info" => system_info(app).await,

        "settings.get" => settings_get(app).await,
        "settings.update" => settings_update(app, params).await,
        "auth.setKey" => auth_set_key(app, params).await,
        "auth.clearKey" => auth_clear_key(app).await,
        "auth.test" => auth_test(app, params).await,
        "auth.mimick" => auth_mimick(app, params).await,

        "server.overview" => lib::server_overview(app).await,
        "server.statistics" => lib::statistics(app).await,
        "users.list" => lib::users_list(app).await,

        "timeline.buckets" => lib::timeline_buckets(app, params).await,
        "timeline.bucket" => lib::timeline_bucket(app, params).await,

        "asset.get" => lib::asset_get(app, params).await,
        "asset.albums" => lib::asset_albums(app, params).await,
        "asset.update" => lib::asset_update(app, params).await,
        "asset.trash" => lib::asset_trash(app, params, false).await,
        "asset.deleteForever" => lib::asset_trash(app, params, true).await,
        "asset.restore" => lib::asset_restore(app, params).await,
        "asset.download" => lib::asset_download(app, params).await,
        "trash.restoreAll" => lib::trash_restore_all(app).await,
        "trash.empty" => lib::trash_empty(app).await,

        "albums.list" => lib::albums_list(app, params).await,
        "album.get" => lib::album_get(app, params).await,
        "album.create" => lib::album_create(app, params).await,
        "album.update" => lib::album_update(app, params).await,
        "album.delete" => lib::album_delete(app, params).await,
        "album.addAssets" => lib::album_assets(app, params, true).await,
        "album.removeAssets" => lib::album_assets(app, params, false).await,
        "album.share" => lib::album_share(app, params).await,
        "album.unshare" => lib::album_unshare(app, params).await,
        "album.setRole" => lib::album_set_role(app, params).await,

        "people.list" => lib::people_list(app, params).await,
        "person.get" => lib::person_get(app, params).await,
        "person.update" => lib::person_update(app, params).await,
        "person.merge" => lib::person_merge(app, params).await,

        "explore" => lib::explore(app).await,
        "places.list" => lib::places(app).await,
        "place.assets" => lib::place_assets(app, params).await,
        "search" => lib::search(app, params).await,
        "search.suggestions" => lib::search_suggestions(app, params).await,

        "tags.list" => lib::tags_list(app).await,
        "tag.create" => lib::tag_create(app, params).await,
        "tag.update" => lib::tag_update(app, params).await,
        "tag.delete" => lib::tag_delete(app, params).await,
        "tag.assign" => lib::tag_assets(app, params, true).await,
        "tag.unassign" => lib::tag_assets(app, params, false).await,

        "folders.paths" => lib::folder_paths(app).await,
        "folder.assets" => lib::folder_assets(app, params).await,

        "sharedLinks.list" => lib::shared_links_list(app).await,
        "sharedLink.create" => lib::shared_link_create(app, params).await,
        "sharedLink.update" => lib::shared_link_update(app, params).await,
        "sharedLink.delete" => lib::shared_link_delete(app, params).await,
        "partners.list" => lib::partners(app).await,
        "partner.add" => lib::partner_add(app, params).await,
        "partner.remove" => lib::partner_remove(app, params).await,
        "partner.timeline" => lib::partner_timeline(app, params).await,

        "cache.info" => cache_info(app).await,
        "cache.clear" => cache_clear(app).await,

        "sync.status" => Ok(app.sync.status()),
        "sync.failed" => Ok(app.sync.failed_files()),
        "sync.pause" => {
            app.sync.set_paused(params.get("paused").and_then(|v| v.as_bool()).unwrap_or(true));
            Ok(app.sync.status())
        }
        "sync.rescan" => {
            app.sync.rescan();
            Ok(app.sync.status())
        }
        "sync.retryFailed" => Ok(json!(app.sync.retry_failed())),
        "sync.clearQueue" => {
            app.sync.clear_queue();
            Ok(app.sync.status())
        }
        "sync.uploadFiles" => sync_upload_files(app, params).await,
        "sync.folderSave" => sync_folder_save(app, params).await,
        "sync.folderRemove" => sync_folder_remove(app, params).await,

        _ => Err(Error::new(METHOD_NOT_FOUND, format!("Unknown method: {method}"))),
    }
}

async fn system_info(app: &App) -> Result<Value> {
    Ok(json!({
        "name": "omamich",
        "version": env!("CARGO_PKG_VERSION"),
        "apiVersion": API_VERSION,
        "mediaBase": app.media.base_url(),
        "configured": app.immich.is_configured().await,
        "hasKey": app.immich.has_key().await,
    }))
}

async fn settings_get(app: &App) -> Result<Value> {
    Ok(json!({
        "settings": app.settings().to_json(),
        "hasKey": app.immich.has_key().await,
        "keyStorage": *app.key_storage.read().unwrap(),
    }))
}

async fn settings_update(app: &App, params: &Value) -> Result<Value> {
    let patch = params.get("patch").cloned().unwrap_or(Value::Null);
    let (before, after) = {
        let mut settings = app.settings.write().unwrap();
        let before = settings.clone();
        settings.apply_patch(&patch)?;
        (before, settings.clone())
    };
    after.save(&app.paths)?;
    if before.server_url != after.server_url
        || before.external_url != after.external_url
        || before.server_enabled != after.server_enabled
        || before.external_enabled != after.external_enabled
    {
        app.reconnect().await;
    }
    if before.sync != after.sync {
        app.sync.reload(after.sync.clone());
    }
    settings_get(app).await
}

async fn auth_set_key(app: &App, params: &Value) -> Result<Value> {
    let key = secrets::clean_key(str_param(params, "key"));
    if !secrets::valid_key_shape(&key) {
        return Err(Error::invalid("That does not look like an Immich API key"));
    }
    let storage = secrets::store(&app.paths, &key).await?;
    *app.key_storage.write().unwrap() = storage.as_str();
    app.immich.set_key(Some(key)).await;
    app.notifier.notify("server.changed", json!({}));
    Ok(json!({ "storage": storage.as_str() }))
}

async fn auth_clear_key(app: &App) -> Result<Value> {
    secrets::delete(&app.paths).await;
    *app.key_storage.write().unwrap() = "";
    app.immich.set_key(None).await;
    app.notifier.notify("server.changed", json!({}));
    Ok(json!(true))
}

/// Try an address and key — the typed ones, or the saved ones — and say
/// whether they work, without saving anything.
async fn auth_test(app: &App, params: &Value) -> Result<Value> {
    let settings = app.settings();
    let typed_key = secrets::clean_key(str_param(params, "key"));
    let key = if typed_key.is_empty() {
        app.immich.base().await.map(|(_, k)| k).ok().or(secrets::load(&app.paths).await)
    } else {
        Some(typed_key)
    };
    let Some(key) = key else {
        return Err(Error::invalid("Paste an API key first"));
    };
    let mut results = serde_json::Map::new();
    for (field, saved, label) in [
        ("serverUrl", &settings.server_url, "lan"),
        ("externalUrl", &settings.external_url, "wan"),
    ] {
        let url = match params.get(field).and_then(|v| v.as_str()) {
            Some(typed) => normalize_url(typed)?,
            None => saved.clone(),
        };
        if url.is_empty() {
            continue;
        }
        let outcome = match app.immich.probe(&url, &key).await {
            Ok(info) => json!({ "ok": true, "url": url, "user": info["user"], "version": info["version"] }),
            Err(err) => json!({ "ok": false, "url": url, "error": err.message }),
        };
        results.insert(label.to_string(), outcome);
    }
    if results.is_empty() {
        return Err(Error::invalid("Enter the server address first"));
    }
    Ok(Value::Object(results))
}

/// Read what Mimick uses; with `apply`, take it over.
async fn auth_mimick(app: &App, params: &Value) -> Result<Value> {
    let (internal, external, key) = secrets::mimick_settings().await?;
    let apply = params.get("apply").and_then(|v| v.as_bool()).unwrap_or(false);
    if apply {
        let patch = json!({
            "serverUrl": internal,
            "serverEnabled": !internal.is_empty(),
            "externalUrl": external,
            "externalEnabled": !external.is_empty(),
        });
        settings_update(app, &json!({ "patch": patch })).await?;
        if let Some(key) = &key {
            auth_set_key(app, &json!({ "key": key })).await?;
        }
    }
    Ok(json!({
        "serverUrl": internal,
        "externalUrl": external,
        "keyFound": key.is_some(),
        "applied": apply,
    }))
}

async fn cache_info(app: &App) -> Result<Value> {
    let media = app.media.clone();
    let bytes = tokio::task::spawn_blocking(move || media.cache_size()).await.unwrap_or(0);
    Ok(json!({ "bytes": bytes, "capMb": app.settings().cache_cap_mb }))
}

async fn cache_clear(app: &App) -> Result<Value> {
    let media = app.media.clone();
    let freed = tokio::task::spawn_blocking(move || media.clear()).await.unwrap_or(0);
    Ok(json!({ "freed": freed }))
}

async fn sync_upload_files(app: &App, params: &Value) -> Result<Value> {
    let paths: Vec<PathBuf> = params
        .get("paths")
        .and_then(|v| v.as_array())
        .ok_or_else(|| Error::invalid("Choose files to upload"))?
        .iter()
        .filter_map(|v| v.as_str())
        .map(|s| {
            let s = s.strip_prefix("file://").unwrap_or(s);
            let decoded = percent_encoding::percent_decode_str(s).decode_utf8_lossy().into_owned();
            crate::paths::expand_home(&decoded)
        })
        .filter(|p| p.is_absolute())
        .collect();
    let album = match str_param(params, "albumId") {
        "" => None,
        id => Some(crate::immich::require_id(id)?.to_string()),
    };
    let queued = app.sync.upload_files(paths, album);
    Ok(json!({ "queued": queued }))
}

async fn sync_folder_save(app: &App, params: &Value) -> Result<Value> {
    let folder: WatchFolder = serde_json::from_value(params.get("folder").cloned().unwrap_or(Value::Null))
        .map_err(|e| Error::invalid(format!("Folder settings: {e}")))?;
    let folder = folder.normalized();
    let path = PathBuf::from(&folder.path);
    if !path.is_absolute() {
        return Err(Error::invalid("Choose a folder by its full path"));
    }
    if !path.is_dir() && !folder.method.downloads() {
        return Err(Error::invalid("That folder does not exist"));
    }
    if path == crate::paths::home() || path == PathBuf::from("/") {
        return Err(Error::invalid("Pick a photo folder rather than your whole home folder"));
    }
    let next_sync = {
        let mut settings = app.settings.write().unwrap();
        let folders = &mut settings.sync.folders;
        if folders.iter().any(|f| f.path == folder.path && f.id != folder.id) {
            return Err(Error::invalid("That folder is already synced"));
        }
        if folders.iter().any(|f| f.id != folder.id && (path.starts_with(&f.path) || PathBuf::from(&f.path).starts_with(&path))) {
            return Err(Error::invalid("That folder overlaps one that is already synced"));
        }
        let mut folder = folder;
        if folder.id.is_empty() {
            folder.id = crate::config::new_id();
        }
        match folders.iter_mut().find(|f| f.id == folder.id) {
            Some(existing) => *existing = folder,
            None => folders.push(folder),
        }
        *settings = settings.clone().normalized();
        settings.save(&app.paths)?;
        settings.sync.clone()
    };
    if !path.exists() {
        std::fs::create_dir_all(&path)?;
    }
    app.sync.reload(next_sync);
    settings_get(app).await
}

async fn sync_folder_remove(app: &App, params: &Value) -> Result<Value> {
    let id = str_param(params, "id").to_string();
    let next_sync = {
        let mut settings = app.settings.write().unwrap();
        let before = settings.sync.folders.len();
        settings.sync.folders.retain(|f| f.id != id);
        if settings.sync.folders.len() == before {
            return Err(Error::invalid("That folder is not synced"));
        }
        settings.save(&app.paths)?;
        settings.sync.clone()
    };
    app.sync.reload(next_sync);
    settings_get(app).await
}
