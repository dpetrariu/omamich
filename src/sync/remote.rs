//! The Immich calls sync makes: duplicate checks, uploads, album membership
//! and downloads.

use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use futures_util::{StreamExt, TryStreamExt};
use serde_json::{Value, json};
use tokio::io::AsyncWriteExt;

use super::files;
use crate::error::{Error, Result};
use crate::immich::{self, Immich, require_id};

#[derive(Debug, Clone, PartialEq)]
pub enum Check {
    /// Immich does not have it yet.
    New,
    /// Immich already has it as this asset.
    Exists(String),
    /// Immich has it, but in the trash: it must come back, or the file here
    /// would be "synced" to something about to be purged.
    Trashed(String),
}

pub async fn restore(immich: &Immich, asset_ids: &[String]) -> Result<()> {
    immich.post("/api/trash/restore/assets", json!({ "ids": asset_ids })).await?;
    Ok(())
}

pub async fn check(immich: &Immich, items: &[(String, String)]) -> Result<Vec<(String, Check)>> {
    let assets: Vec<Value> = items.iter().map(|(id, checksum)| json!({ "id": id, "checksum": checksum })).collect();
    let response = immich.post("/api/assets/bulk-upload-check", json!({ "assets": assets })).await?;
    let mut out = Vec::new();
    for result in response.get("results").and_then(|r| r.as_array()).cloned().unwrap_or_default() {
        let Some(id) = result.get("id").and_then(|v| v.as_str()) else { continue };
        let action = result.get("action").and_then(|v| v.as_str()).unwrap_or("accept");
        let asset = result.get("assetId").and_then(|v| v.as_str()).unwrap_or("");
        let trashed = result.get("isTrashed").and_then(|v| v.as_bool()).unwrap_or(false);
        let verdict = if action == "reject" && !asset.is_empty() {
            if trashed { Check::Trashed(asset.to_string()) } else { Check::Exists(asset.to_string()) }
        } else {
            Check::New
        };
        out.push((id.to_string(), verdict));
    }
    Ok(out)
}

fn iso(meta_time: std::time::SystemTime) -> String {
    let dt: chrono::DateTime<chrono::Utc> = meta_time.into();
    dt.to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}

/// Upload one file. `progress` is advanced as bytes leave.
pub async fn upload(
    immich: &Immich,
    path: &Path,
    sidecar: Option<&Path>,
    progress: Arc<AtomicU64>,
) -> Result<String> {
    let file = files::open_regular(path)?;
    let meta = file.metadata()?;
    let modified = meta.modified().unwrap_or(std::time::SystemTime::now());
    let created = meta.created().ok().filter(|c| *c < modified).unwrap_or(modified);
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("photo").to_string();
    let file = tokio::fs::File::from_std(file);
    let counter = progress.clone();
    let stream = tokio_util::io::ReaderStream::with_capacity(file, 256 * 1024).inspect_ok(move |chunk| {
        counter.fetch_add(chunk.len() as u64, Ordering::Relaxed);
    });
    let part = reqwest::multipart::Part::stream_with_length(reqwest::Body::wrap_stream(stream), meta.len())
        .file_name(name)
        .mime_str(files::mime_for(path))
        .map_err(|e| Error::internal(e.to_string()))?;
    let mut form = reqwest::multipart::Form::new()
        .part("assetData", part)
        .text("fileCreatedAt", iso(created))
        .text("fileModifiedAt", iso(modified))
        .text("isFavorite", "false");
    if let Some(sidecar) = sidecar {
        let read = files::open_regular(sidecar).and_then(|mut f| {
            let mut bytes = Vec::new();
            std::io::Read::read_to_end(&mut f, &mut bytes).map(|_| bytes)
        });
        if let Ok(bytes) = read {
            if let Ok(part) = reqwest::multipart::Part::bytes(bytes)
                .file_name(sidecar.file_name().and_then(|n| n.to_str()).unwrap_or("sidecar.xmp").to_string())
                .mime_str("application/xml")
            {
                form = form.part("sidecarData", part);
            }
        }
    }
    let (base, key) = immich.base().await?;
    let response = immich
        .http()
        .post(format!("{base}/api/assets"))
        .header("x-api-key", key)
        .header("Accept", "application/json")
        .multipart(form)
        .send()
        .await;
    let response = match response {
        Ok(response) => response,
        Err(err) => {
            immich.reset_route().await;
            return Err(immich::network_error(&err));
        }
    };
    let value = immich::read_json(response).await?;
    value
        .get("id")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .ok_or_else(|| Error::new(crate::error::SERVER, "Immich did not say which asset it created"))
}

/// The album with this name, created when it does not exist yet.
pub async fn ensure_album(immich: &Immich, name: &str) -> Result<String> {
    let albums = immich.get("/api/albums").await?;
    if let Some(found) = albums.as_array().and_then(|list| {
        list.iter().find(|a| a.get("albumName").and_then(|n| n.as_str()) == Some(name))
    }) {
        if let Some(id) = found.get("id").and_then(|v| v.as_str()) {
            return Ok(id.to_string());
        }
    }
    let created = immich.post("/api/albums", json!({ "albumName": name })).await?;
    created
        .get("id")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .ok_or_else(|| Error::new(crate::error::SERVER, "Immich did not return the new album"))
}

pub async fn add_to_album(immich: &Immich, album_id: &str, asset_ids: &[String]) -> Result<()> {
    require_id(album_id)?;
    if asset_ids.is_empty() {
        return Ok(());
    }
    immich.put(&format!("/api/albums/{album_id}/assets"), json!({ "ids": asset_ids })).await?;
    Ok(())
}

pub async fn album_exists(immich: &Immich, album_id: &str) -> Result<bool> {
    require_id(album_id)?;
    match immich.get(&format!("/api/albums/{album_id}?withoutAssets=true")).await {
        Ok(_) => Ok(true),
        Err(e) if e.code == crate::error::NOT_FOUND || e.code == crate::error::INVALID_PARAMS => Ok(false),
        Err(e) => Err(e),
    }
}

#[derive(Debug, Clone)]
pub struct RemoteAsset {
    pub id: String,
    pub file_name: String,
    pub checksum_hex: String,
}

pub async fn album_assets(immich: &Immich, album_id: &str) -> Result<Vec<RemoteAsset>> {
    require_id(album_id)?;
    let album = immich.get(&format!("/api/albums/{album_id}")).await?;
    let mut out = Vec::new();
    for asset in album.get("assets").and_then(|a| a.as_array()).cloned().unwrap_or_default() {
        if asset.get("isTrashed").and_then(|v| v.as_bool()) == Some(true) {
            continue;
        }
        let (Some(id), Some(name), Some(checksum)) = (
            asset.get("id").and_then(|v| v.as_str()),
            asset.get("originalFileName").and_then(|v| v.as_str()),
            asset.get("checksum").and_then(|v| v.as_str()),
        ) else {
            continue;
        };
        out.push(RemoteAsset {
            id: id.to_string(),
            file_name: files::safe_file_name(name),
            checksum_hex: files::base64_to_hex(checksum).unwrap_or_default(),
        });
    }
    // Some servers only list assets through the search endpoint for large albums.
    if out.is_empty() && album.get("assetCount").and_then(|v| v.as_u64()).unwrap_or(0) > 0 {
        let mut page = 1;
        loop {
            let result = immich
                .post("/api/search/metadata", json!({ "albumIds": [album_id], "page": page, "size": 500 }))
                .await?;
            let items = result.pointer("/assets/items").and_then(|v| v.as_array()).cloned().unwrap_or_default();
            for asset in &items {
                if let (Some(id), Some(name), Some(checksum)) = (
                    asset.get("id").and_then(|v| v.as_str()),
                    asset.get("originalFileName").and_then(|v| v.as_str()),
                    asset.get("checksum").and_then(|v| v.as_str()),
                ) {
                    out.push(RemoteAsset {
                        id: id.to_string(),
                        file_name: files::safe_file_name(name),
                        checksum_hex: files::base64_to_hex(checksum).unwrap_or_default(),
                    });
                }
            }
            if result.pointer("/assets/nextPage").map(|v| v.is_null()).unwrap_or(true) || page > 200 {
                break;
            }
            page += 1;
        }
    }
    Ok(out)
}

/// Save an asset's original into `target`, writing to a temporary file first
/// so a dropped connection never leaves half a photo.
pub async fn download(immich: &Immich, asset_id: &str, target: &Path, progress: Option<Arc<AtomicU64>>) -> Result<u64> {
    require_id(asset_id)?;
    let response = immich.raw(&format!("/api/assets/{asset_id}/original"), &[]).await?;
    let tmp = target.with_file_name(format!(
        ".{}.omamich-part",
        target.file_name().and_then(|n| n.to_str()).unwrap_or("download")
    ));
    // Made afresh, never through a link someone planted under that name:
    // a leftover is removed (a link goes, not what it points to), and if
    // one appears again before the file is made, the download fails.
    let _ = std::fs::remove_file(&tmp);
    let mut file = {
        use std::os::unix::fs::OpenOptionsExt;
        tokio::fs::File::from_std(std::fs::OpenOptions::new().write(true).create_new(true).custom_flags(libc::O_NOFOLLOW).open(&tmp)?)
    };
    let mut written = 0u64;
    let mut body = response.bytes_stream();
    let result: Result<()> = async {
        while let Some(chunk) = body.next().await {
            let chunk = chunk.map_err(|e| immich::network_error(&e))?;
            file.write_all(&chunk).await?;
            written += chunk.len() as u64;
            if let Some(p) = &progress {
                p.fetch_add(chunk.len() as u64, Ordering::Relaxed);
            }
        }
        file.flush().await?;
        file.sync_all().await?;
        Ok(())
    }
    .await;
    if let Err(err) = result {
        let _ = tokio::fs::remove_file(&tmp).await;
        return Err(err);
    }
    tokio::fs::rename(&tmp, target).await?;
    Ok(written)
}

pub async fn trash(immich: &Immich, asset_ids: &[String]) -> Result<()> {
    immich.delete("/api/assets", Some(json!({ "ids": asset_ids, "force": false }))).await?;
    Ok(())
}
