//! Library requests: browsing, searching and editing what is on the server.
//! Responses are trimmed to what the window shows, so QML never has to dig
//! through Immich's full objects.

use std::collections::HashMap;

use serde_json::{Map, Value, json};

use crate::app::App;
use crate::error::{Error, Result};
use crate::immich::timeline::{self, asset_row};
use crate::immich::{q, require_id, valid_id};

pub fn str_param<'a>(params: &'a Value, key: &str) -> &'a str {
    params.get(key).and_then(|v| v.as_str()).unwrap_or("")
}

pub fn id_param<'a>(params: &'a Value, key: &str) -> Result<&'a str> {
    require_id(str_param(params, key))
}

pub fn ids_param(params: &Value, key: &str) -> Result<Vec<String>> {
    let list = params.get(key).and_then(|v| v.as_array()).ok_or_else(|| Error::invalid("Expected a list of ids"))?;
    if list.is_empty() || list.len() > 5000 {
        return Err(Error::invalid("Choose between 1 and 5000 items"));
    }
    list.iter()
        .map(|v| {
            v.as_str()
                .filter(|s| valid_id(s))
                .map(|s| s.to_string())
                .ok_or_else(|| Error::invalid("Not a valid Immich id"))
        })
        .collect()
}

fn page_param(params: &Value) -> u64 {
    params.get("page").and_then(|v| v.as_u64()).unwrap_or(1).clamp(1, 10_000)
}

fn pick(value: &Value, keys: &[&str]) -> Value {
    let mut out = Map::new();
    for key in keys {
        out.insert((*key).to_string(), value.get(*key).cloned().unwrap_or(Value::Null));
    }
    Value::Object(out)
}

// ---------------------------------------------------------------- timeline

pub async fn timeline_buckets(app: &App, params: &Value) -> Result<Value> {
    let scope = params.get("scope").cloned().unwrap_or(Value::Null);
    let buckets = app.immich.get(&timeline::buckets_path(&scope)?).await?;
    let list: Vec<Value> = buckets
        .as_array()
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .filter_map(|b| {
            let bucket = b.get("timeBucket")?.as_str()?.to_string();
            let count = b.get("count")?.as_u64()?;
            Some(json!({ "timeBucket": bucket, "count": count }))
        })
        .collect();
    Ok(Value::Array(list))
}

pub async fn timeline_bucket(app: &App, params: &Value) -> Result<Value> {
    let scope = params.get("scope").cloned().unwrap_or(Value::Null);
    let bucket = str_param(params, "timeBucket");
    let columns = app.immich.get(&timeline::bucket_path(&scope, bucket)?).await?;
    Ok(Value::Array(timeline::columns_to_rows(&columns)))
}

// ---------------------------------------------------------------- assets

pub async fn asset_get(app: &App, params: &Value) -> Result<Value> {
    let id = id_param(params, "id")?;
    let asset = app.immich.get(&format!("/api/assets/{id}")).await?;
    let exif = asset.get("exifInfo").cloned().unwrap_or(Value::Null);
    let people: Vec<Value> = asset
        .get("people")
        .and_then(|p| p.as_array())
        .cloned()
        .unwrap_or_default()
        .iter()
        .map(|p| json!({
            "id": p.get("id"),
            "name": p.get("name"),
            "isHidden": p.get("isHidden"),
            "version": version_of(p.get("updatedAt")),
        }))
        .collect();
    let tags: Vec<Value> = asset
        .get("tags")
        .and_then(|p| p.as_array())
        .cloned()
        .unwrap_or_default()
        .iter()
        .map(|t| pick(t, &["id", "name", "value", "color"]))
        .collect();
    let mut row = asset_row(&asset).unwrap_or(Value::Null);
    if let Some(obj) = row.as_object_mut() {
        obj.insert("originalFileName".into(), asset.get("originalFileName").cloned().unwrap_or(Value::Null));
        obj.insert("originalMimeType".into(), asset.get("originalMimeType").cloned().unwrap_or(Value::Null));
        obj.insert("originalPath".into(), asset.get("originalPath").cloned().unwrap_or(Value::Null));
        obj.insert("localDateTime".into(), asset.get("localDateTime").cloned().unwrap_or(Value::Null));
        obj.insert("fileCreatedAt".into(), asset.get("fileCreatedAt").cloned().unwrap_or(Value::Null));
        obj.insert("width".into(), asset.get("width").cloned().unwrap_or(Value::Null));
        obj.insert("height".into(), asset.get("height").cloned().unwrap_or(Value::Null));
        obj.insert("isArchived".into(), json!(asset.get("visibility").and_then(|v| v.as_str()) == Some("archive")));
        obj.insert("isOffline".into(), asset.get("isOffline").cloned().unwrap_or(Value::Null));
        obj.insert("isEdited".into(), asset.get("isEdited").cloned().unwrap_or(Value::Null));
        obj.insert("ownerName".into(), asset.pointer("/owner/name").cloned().unwrap_or(Value::Null));
        obj.insert("stackCount".into(), asset.pointer("/stack/assetCount").cloned().unwrap_or(Value::Null));
        obj.insert("people".into(), Value::Array(people));
        obj.insert("tags".into(), Value::Array(tags));
        obj.insert(
            "exif".into(),
            pick(
                &exif,
                &[
                    "make", "model", "lensModel", "fNumber", "focalLength", "iso", "exposureTime",
                    "exifImageWidth", "exifImageHeight", "fileSizeInByte", "dateTimeOriginal", "timeZone",
                    "latitude", "longitude", "city", "state", "country", "description", "rating", "projectionType",
                ],
            ),
        );
    }
    Ok(row)
}

pub async fn asset_albums(app: &App, params: &Value) -> Result<Value> {
    let id = id_param(params, "id")?;
    let albums = app.immich.get(&format!("/api/albums?assetId={id}")).await?;
    Ok(Value::Array(albums.as_array().cloned().unwrap_or_default().iter().map(slim_album).collect()))
}

/// Several assets at once: favourite, archive, rating, date and place.
pub async fn asset_update(app: &App, params: &Value) -> Result<Value> {
    let ids = ids_param(params, "ids")?;
    let mut body = Map::new();
    body.insert("ids".into(), json!(ids));
    let mut single = Map::new();
    if let Some(v) = params.get("isFavorite").and_then(|v| v.as_bool()) {
        body.insert("isFavorite".into(), json!(v));
    }
    if let Some(v) = params.get("visibility").and_then(|v| v.as_str()) {
        if !["timeline", "archive", "hidden", "locked"].contains(&v) {
            return Err(Error::invalid("Unknown visibility"));
        }
        body.insert("visibility".into(), json!(v));
    }
    if let Some(v) = params.get("rating") {
        let rating = v.as_i64().filter(|r| (-1..=5).contains(r)).ok_or_else(|| Error::invalid("Rating is 0 to 5"))?;
        body.insert("rating".into(), json!(rating));
    }
    if let Some(v) = params.get("dateTimeOriginal").and_then(|v| v.as_str()) {
        if chrono::DateTime::parse_from_rfc3339(v).is_err() && chrono::NaiveDateTime::parse_from_str(v, "%Y-%m-%dT%H:%M:%S").is_err() {
            return Err(Error::invalid("Dates look like 2024-05-01T14:30:00+02:00"));
        }
        body.insert("dateTimeOriginal".into(), json!(v));
    }
    if let (Some(lat), Some(lon)) = (params.get("latitude").and_then(|v| v.as_f64()), params.get("longitude").and_then(|v| v.as_f64())) {
        if !(-90.0..=90.0).contains(&lat) || !(-180.0..=180.0).contains(&lon) {
            return Err(Error::invalid("That place is not on Earth"));
        }
        body.insert("latitude".into(), json!(lat));
        body.insert("longitude".into(), json!(lon));
    }
    if let Some(v) = params.get("description").and_then(|v| v.as_str()) {
        if ids.len() != 1 {
            return Err(Error::invalid("A description belongs to one photo"));
        }
        single.insert("description".into(), json!(v.chars().take(4000).collect::<String>()));
    }
    if body.len() > 1 {
        app.immich.put("/api/assets", Value::Object(body)).await?;
    }
    if !single.is_empty() {
        app.immich.put(&format!("/api/assets/{}", ids[0]), Value::Object(single)).await?;
    }
    Ok(json!(true))
}

pub async fn asset_trash(app: &App, params: &Value, force: bool) -> Result<Value> {
    let ids = ids_param(params, "ids")?;
    app.immich.delete("/api/assets", Some(json!({ "ids": ids, "force": force }))).await?;
    Ok(json!(ids.len()))
}

/// Take photos out of the trash, then check which really came out. Immich
/// answers success but keeps an external-library photo whose file is missing
/// ("offline") in the trash; the window must not claim it was restored.
pub async fn asset_restore(app: &App, params: &Value) -> Result<Value> {
    use futures_util::StreamExt;
    let ids = ids_param(params, "ids")?;
    let response = app.immich.post("/api/trash/restore/assets", json!({ "ids": ids })).await?;
    let reported = response.get("count").and_then(|v| v.as_u64());
    if ids.len() > 200 {
        // Too many to look at one by one; go by Immich's count.
        let all = reported.map(|c| c as usize >= ids.len()).unwrap_or(true);
        return Ok(json!({ "restored": if all { ids.clone() } else { vec![] }, "notRestored": [], "offline": [], "count": reported }));
    }
    let checks: Vec<(String, Option<Value>)> = futures_util::stream::iter(ids.into_iter().map(|id| async move {
        let asset = app.immich.get(&format!("/api/assets/{id}")).await.ok();
        (id, asset)
    }))
    .buffer_unordered(8)
    .collect()
    .await;
    let mut restored = Vec::new();
    let mut not_restored = Vec::new();
    let mut offline = Vec::new();
    for (id, asset) in checks {
        let still_trashed = asset.as_ref().and_then(|a| a.get("isTrashed")).and_then(|v| v.as_bool()).unwrap_or(false);
        if still_trashed {
            if asset.as_ref().and_then(|a| a.get("isOffline")).and_then(|v| v.as_bool()) == Some(true) {
                offline.push(id.clone());
            }
            not_restored.push(id);
        } else {
            restored.push(id);
        }
    }
    Ok(json!({ "restored": restored, "notRestored": not_restored, "offline": offline, "count": reported }))
}

pub async fn trash_restore_all(app: &App) -> Result<Value> {
    let response = app.immich.post("/api/trash/restore", json!({})).await?;
    // What is still there afterwards is what Immich would not restore.
    let left = app
        .immich
        .get("/api/assets/statistics?isTrashed=true")
        .await
        .ok()
        .and_then(|s| s.get("total").and_then(|v| v.as_u64()))
        .unwrap_or(0);
    Ok(json!({ "count": response.get("count"), "left": left }))
}

pub async fn trash_empty(app: &App) -> Result<Value> {
    Ok(app.immich.post("/api/trash/empty", json!({})).await?)
}

pub fn downloads_dir() -> std::path::PathBuf {
    let home = crate::paths::home();
    let config = home.join(".config/user-dirs.dirs");
    if let Ok(text) = std::fs::read_to_string(config) {
        for line in text.lines() {
            if let Some(value) = line.strip_prefix("XDG_DOWNLOAD_DIR=") {
                let value = value.trim().trim_matches('"').replace("$HOME", &home.to_string_lossy());
                let path = std::path::PathBuf::from(value);
                if path.is_absolute() {
                    return path;
                }
            }
        }
    }
    home.join("Downloads")
}

/// Save originals into the Downloads folder (or `directory`).
pub async fn asset_download(app: &App, params: &Value) -> Result<Value> {
    let ids = ids_param(params, "ids")?;
    let dir = match str_param(params, "directory") {
        "" => downloads_dir(),
        d => crate::paths::expand_home(d),
    };
    tokio::fs::create_dir_all(&dir).await?;
    let mut saved = Vec::new();
    for id in ids {
        let asset = app.immich.get(&format!("/api/assets/{id}")).await?;
        let name = crate::sync::files::safe_file_name(asset.get("originalFileName").and_then(|v| v.as_str()).unwrap_or("photo"));
        let target = crate::sync::files::unique_path(&dir, &name);
        crate::sync::remote::download(&app.immich, &id, &target, None).await?;
        saved.push(target.to_string_lossy().into_owned());
    }
    Ok(json!({ "paths": saved, "directory": dir.to_string_lossy() }))
}

// ---------------------------------------------------------------- albums

pub fn slim_album(album: &Value) -> Value {
    let shared = album.get("shared").and_then(|v| v.as_bool()).unwrap_or(false)
        || album.get("albumUsers").and_then(|v| v.as_array()).map(|a| !a.is_empty()).unwrap_or(false);
    json!({
        "id": album.get("id"),
        "albumName": album.get("albumName"),
        "description": album.get("description"),
        "assetCount": album.get("assetCount"),
        "albumThumbnailAssetId": album.get("albumThumbnailAssetId"),
        "startDate": album.get("startDate"),
        "endDate": album.get("endDate"),
        "updatedAt": album.get("updatedAt"),
        "createdAt": album.get("createdAt"),
        "shared": shared,
        "ownerId": album.get("ownerId"),
        "ownerName": album.pointer("/owner/name"),
        "order": album.get("order"),
        "isActivityEnabled": album.get("isActivityEnabled"),
        "users": album.get("albumUsers").and_then(|v| v.as_array()).cloned().unwrap_or_default().iter().map(|u| json!({
            "id": u.pointer("/user/id"),
            "name": u.pointer("/user/name"),
            "email": u.pointer("/user/email"),
            "role": u.get("role"),
        })).collect::<Vec<_>>(),
    })
}

pub async fn albums_list(app: &App, params: &Value) -> Result<Value> {
    let path = match params.get("shared").and_then(|v| v.as_bool()) {
        Some(true) => "/api/albums?shared=true",
        Some(false) => "/api/albums?shared=false",
        None => "/api/albums",
    };
    let mut albums: Vec<Value> = app.immich.get(path).await?.as_array().cloned().unwrap_or_default().iter().map(slim_album).collect();
    if params.get("shared").is_none() {
        // Albums others shared with me come from a separate listing.
        if let Ok(shared) = app.immich.get("/api/albums?shared=true").await {
            for album in shared.as_array().cloned().unwrap_or_default() {
                let slim = slim_album(&album);
                if !albums.iter().any(|a| a["id"] == slim["id"]) {
                    albums.push(slim);
                }
            }
        }
    }
    albums.sort_by(|a, b| {
        let key = |v: &Value| v.get("endDate").or(v.get("updatedAt")).and_then(|d| d.as_str()).unwrap_or("").to_string();
        key(b).cmp(&key(a))
    });
    Ok(Value::Array(albums))
}

pub async fn album_get(app: &App, params: &Value) -> Result<Value> {
    let id = id_param(params, "id")?;
    let album = app.immich.get(&format!("/api/albums/{id}?withoutAssets=true")).await?;
    Ok(slim_album(&album))
}

fn album_name(params: &Value) -> Result<String> {
    let name = str_param(params, "albumName").trim().to_string();
    if name.is_empty() || name.chars().count() > 200 {
        return Err(Error::invalid("Album names are 1 to 200 characters"));
    }
    Ok(name)
}

pub async fn album_create(app: &App, params: &Value) -> Result<Value> {
    let mut body = json!({ "albumName": album_name(params)? });
    if let Some(desc) = params.get("description").and_then(|v| v.as_str()) {
        body["description"] = json!(desc);
    }
    if params.get("assetIds").map(|v| !v.is_null()).unwrap_or(false) {
        body["assetIds"] = json!(ids_param(params, "assetIds")?);
    }
    let album = app.immich.post("/api/albums", body).await?;
    Ok(slim_album(&album))
}

pub async fn album_update(app: &App, params: &Value) -> Result<Value> {
    let id = id_param(params, "id")?;
    let mut body = Map::new();
    if params.get("albumName").is_some() {
        body.insert("albumName".into(), json!(album_name(params)?));
    }
    if let Some(desc) = params.get("description").and_then(|v| v.as_str()) {
        body.insert("description".into(), json!(desc.chars().take(4000).collect::<String>()));
    }
    if let Some(cover) = params.get("albumThumbnailAssetId").and_then(|v| v.as_str()) {
        body.insert("albumThumbnailAssetId".into(), json!(require_id(cover)?));
    }
    if let Some(order) = params.get("order").and_then(|v| v.as_str()) {
        if order != "asc" && order != "desc" {
            return Err(Error::invalid("Order is asc or desc"));
        }
        body.insert("order".into(), json!(order));
    }
    let album = app.immich.patch(&format!("/api/albums/{id}"), Value::Object(body)).await?;
    Ok(slim_album(&album))
}

pub async fn album_delete(app: &App, params: &Value) -> Result<Value> {
    let id = id_param(params, "id")?;
    app.immich.delete(&format!("/api/albums/{id}"), None).await?;
    Ok(json!(true))
}

pub async fn album_assets(app: &App, params: &Value, add: bool) -> Result<Value> {
    let id = id_param(params, "id")?;
    let ids = ids_param(params, "ids")?;
    let path = format!("/api/albums/{id}/assets");
    let result = if add {
        app.immich.put(&path, json!({ "ids": ids })).await?
    } else {
        app.immich.delete(&path, Some(json!({ "ids": ids }))).await?
    };
    let changed = result
        .as_array()
        .map(|r| r.iter().filter(|x| x.get("success").and_then(|s| s.as_bool()) == Some(true)).count())
        .unwrap_or(ids.len());
    Ok(json!({ "changed": changed, "requested": ids.len() }))
}

pub async fn album_share(app: &App, params: &Value) -> Result<Value> {
    let id = id_param(params, "id")?;
    let user = id_param(params, "userId")?;
    let role = match str_param(params, "role") {
        "viewer" => "viewer",
        _ => "editor",
    };
    let album = app
        .immich
        .put(&format!("/api/albums/{id}/users"), json!({ "albumUsers": [{ "userId": user, "role": role }] }))
        .await?;
    Ok(slim_album(&album))
}

pub async fn album_set_role(app: &App, params: &Value) -> Result<Value> {
    let id = id_param(params, "id")?;
    let user = id_param(params, "userId")?;
    let role = match str_param(params, "role") {
        "viewer" => "viewer",
        "editor" => "editor",
        _ => return Err(Error::invalid("A role is viewer or editor")),
    };
    app.immich.put(&format!("/api/albums/{id}/user/{user}"), json!({ "role": role })).await?;
    album_get(app, params).await
}

pub async fn album_unshare(app: &App, params: &Value) -> Result<Value> {
    let id = id_param(params, "id")?;
    let user = str_param(params, "userId");
    let user = if user == "me" { "me" } else { require_id(user)? };
    app.immich.delete(&format!("/api/albums/{id}/user/{user}"), None).await?;
    Ok(json!(true))
}

pub async fn users_list(app: &App) -> Result<Value> {
    let users = app.immich.get("/api/users").await?;
    Ok(Value::Array(
        users.as_array().cloned().unwrap_or_default().iter().map(|u| pick(u, &["id", "name", "email", "avatarColor"])).collect(),
    ))
}

// ---------------------------------------------------------------- people

fn version_of(value: Option<&Value>) -> String {
    value.and_then(|v| v.as_str()).map(|s| s.chars().filter(|c| c.is_ascii_digit()).collect()).unwrap_or_default()
}

fn slim_person(p: &Value) -> Value {
    json!({
        "id": p.get("id"),
        "name": p.get("name"),
        "isHidden": p.get("isHidden"),
        "isFavorite": p.get("isFavorite"),
        "birthDate": p.get("birthDate"),
        "version": version_of(p.get("updatedAt")),
    })
}

pub async fn people_list(app: &App, params: &Value) -> Result<Value> {
    let with_hidden = params.get("withHidden").and_then(|v| v.as_bool()).unwrap_or(false);
    let path = |page: u64| format!("/api/people?withHidden={with_hidden}&page={page}&size=500");
    let first = app.immich.get(&path(1)).await?;
    let total = first.get("total").and_then(|v| v.as_u64()).unwrap_or(0);
    let hidden = first.get("hidden").and_then(|v| v.as_u64()).unwrap_or(0);
    let mut pages = vec![first.clone()];
    if first.get("hasNextPage").and_then(|v| v.as_bool()) == Some(true) {
        // The total says how many pages there are; fetch the rest together.
        let count = total.div_ceil(500).clamp(2, 40);
        let rest = futures_util::future::join_all((2..=count).map(|page| {
            let url = path(page);
            async move { app.immich.get(&url).await }
        }))
        .await;
        for page in rest {
            pages.push(page?);
        }
    }
    let mut people = Vec::new();
    for page in pages {
        for p in page.get("people").and_then(|v| v.as_array()).cloned().unwrap_or_default() {
            people.push(slim_person(&p));
        }
    }
    Ok(json!({ "people": people, "total": total, "hidden": hidden }))
}

pub async fn person_get(app: &App, params: &Value) -> Result<Value> {
    let id = id_param(params, "id")?;
    let person = app.immich.get(&format!("/api/people/{id}")).await?;
    let mut slim = slim_person(&person);
    if let Ok(stats) = app.immich.get(&format!("/api/people/{id}/statistics")).await {
        slim["assets"] = stats.get("assets").cloned().unwrap_or(Value::Null);
    }
    Ok(slim)
}

pub async fn person_update(app: &App, params: &Value) -> Result<Value> {
    let id = id_param(params, "id")?;
    let mut body = Map::new();
    if let Some(name) = params.get("name").and_then(|v| v.as_str()) {
        body.insert("name".into(), json!(name.trim().chars().take(200).collect::<String>()));
    }
    for key in ["isHidden", "isFavorite"] {
        if let Some(v) = params.get(key).and_then(|v| v.as_bool()) {
            body.insert(key.into(), json!(v));
        }
    }
    if let Some(birth) = params.get("birthDate") {
        match birth.as_str() {
            Some("") | None => {
                body.insert("birthDate".into(), Value::Null);
            }
            Some(text) => {
                chrono::NaiveDate::parse_from_str(text, "%Y-%m-%d").map_err(|_| Error::invalid("Birthdays look like 1984-04-09"))?;
                body.insert("birthDate".into(), json!(text));
            }
        }
    }
    // The key photo: Immich crops the person's face from this photo for
    // their thumbnail. It must be a photo they are in.
    let key_photo = str_param(params, "featureFaceAssetId");
    if !key_photo.is_empty() {
        body.insert("featureFaceAssetId".into(), json!(require_id(key_photo)?));
    }
    let person = app.immich.put(&format!("/api/people/{id}"), Value::Object(body)).await.map_err(|e| {
        if e.message.to_lowercase().contains("feature face") {
            Error::invalid("That photo does not show this person's face")
        } else {
            e
        }
    })?;
    Ok(slim_person(&person))
}

// ---------------------------------------------------------------- faces

/// The faces Immich found in a photo: where each one is (in the size of the
/// image Immich measured it on) and who it is, if anyone.
pub async fn asset_faces(app: &App, params: &Value) -> Result<Value> {
    let id = id_param(params, "id")?;
    let faces = app.immich.get(&format!("/api/faces?id={id}")).await?;
    Ok(Value::Array(faces.as_array().map(|list| list.iter().filter_map(slim_face).collect()).unwrap_or_default()))
}

fn slim_face(f: &Value) -> Option<Value> {
    let num = |k: &str| f.get(k).and_then(|v| v.as_f64());
    let (w, h) = (num("imageWidth")?, num("imageHeight")?);
    if w <= 0.0 || h <= 0.0 {
        return None;
    }
    let person = f.get("person").filter(|p| p.is_object()).map(|p| json!({
        "id": p.get("id"),
        "name": p.get("name"),
        "isHidden": p.get("isHidden"),
        "version": version_of(p.get("updatedAt")),
    }));
    Some(json!({
        "id": f.get("id")?.as_str()?,
        // Fractions of the picture, so the window needs no image sizes. A box
        // may reach past an edge; the window clips it.
        "x1": num("boundingBoxX1")? / w,
        "y1": num("boundingBoxY1")? / h,
        "x2": num("boundingBoxX2")? / w,
        "y2": num("boundingBoxY2")? / h,
        "person": person.unwrap_or(Value::Null),
    }))
}

/// Give one face to another person: `personId`, or a new person called
/// `name`.
pub async fn face_reassign(app: &App, params: &Value) -> Result<Value> {
    let face = id_param(params, "faceId")?;
    let person_id = match str_param(params, "personId") {
        "" => {
            let name: String = str_param(params, "name").trim().chars().take(200).collect();
            if name.is_empty() {
                return Err(Error::invalid("Pick a person or type a name"));
            }
            let person = app.immich.post("/api/people", json!({ "name": name })).await?;
            person.get("id").and_then(|v| v.as_str()).map(str::to_string).ok_or_else(|| Error::new(crate::error::SERVER, "Immich did not create the person"))?
        }
        id => require_id(id)?.to_string(),
    };
    // Immich's path names the person and the body the face.
    let person = app.immich.put(&format!("/api/faces/{person_id}"), json!({ "id": face })).await?;
    Ok(slim_person(&person))
}

/// Take a face away from its person (someone you do not know, or a wrong
/// match): Immich stops tracking it, and the photo stays. Immich's soft
/// delete, as its own web app uses; it cannot be undone through the API.
pub async fn face_remove(app: &App, params: &Value) -> Result<Value> {
    let face = id_param(params, "faceId")?;
    app.immich.delete(&format!("/api/faces/{face}"), Some(json!({ "force": false }))).await?;
    Ok(json!(true))
}

pub async fn person_merge(app: &App, params: &Value) -> Result<Value> {
    let id = id_param(params, "id")?;
    let ids = ids_param(params, "ids")?;
    app.immich.post(&format!("/api/people/{id}/merge"), json!({ "ids": ids })).await?;
    Ok(json!(true))
}

// ---------------------------------------------------------------- explore & places

pub async fn explore(app: &App) -> Result<Value> {
    let data = app.immich.get("/api/search/explore").await?;
    let sections: Vec<Value> = data
        .as_array()
        .cloned()
        .unwrap_or_default()
        .iter()
        .map(|section| json!({
            "fieldName": section.get("fieldName"),
            "items": section.get("items").and_then(|i| i.as_array()).cloned().unwrap_or_default().iter().map(|item| json!({
                "value": item.get("value"),
                "assetId": item.pointer("/data/id"),
            })).collect::<Vec<_>>(),
        }))
        .collect();
    Ok(Value::Array(sections))
}

/// Every place with photos, from the map markers, largest first.
pub async fn places(app: &App) -> Result<Value> {
    let markers = app.immich.get("/api/map/markers").await?;
    let mut places: HashMap<(String, String), (u64, String, f64, f64)> = HashMap::new();
    for marker in markers.as_array().cloned().unwrap_or_default() {
        let city = marker.get("city").and_then(|v| v.as_str()).unwrap_or("").to_string();
        let country = marker.get("country").and_then(|v| v.as_str()).unwrap_or("").to_string();
        if city.is_empty() && country.is_empty() {
            continue;
        }
        let entry = places.entry((city, country)).or_insert_with(|| {
            (
                0,
                marker.get("id").and_then(|v| v.as_str()).unwrap_or("").to_string(),
                marker.get("lat").and_then(|v| v.as_f64()).unwrap_or(0.0),
                marker.get("lon").and_then(|v| v.as_f64()).unwrap_or(0.0),
            )
        });
        entry.0 += 1;
    }
    let mut list: Vec<Value> = places
        .into_iter()
        .map(|((city, country), (count, asset, lat, lon))| json!({
            "city": city, "country": country, "count": count, "assetId": asset, "lat": lat, "lon": lon,
        }))
        .collect();
    list.sort_by(|a, b| b["count"].as_u64().cmp(&a["count"].as_u64()));
    Ok(Value::Array(list))
}

// ---------------------------------------------------------------- search

fn search_result(result: &Value) -> Value {
    let items: Vec<Value> = result
        .pointer("/assets/items")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default()
        .iter()
        .filter_map(asset_row)
        .collect();
    json!({
        "items": items,
        "nextPage": result.pointer("/assets/nextPage").cloned().unwrap_or(Value::Null),
        "total": result.pointer("/assets/total").cloned().unwrap_or(Value::Null),
    })
}

/// Filters a person can combine with any search.
fn apply_filters(body: &mut Map<String, Value>, filters: &Value) -> Result<()> {
    let Some(filters) = filters.as_object() else { return Ok(()) };
    for (key, value) in filters {
        match key.as_str() {
            "city" | "state" | "country" | "make" | "model" | "lensModel" => {
                if let Some(text) = value.as_str().filter(|s| !s.is_empty()) {
                    body.insert(key.clone(), json!(text));
                }
            }
            "takenAfter" | "takenBefore" => {
                if let Some(text) = value.as_str().filter(|s| !s.is_empty()) {
                    body.insert(key.clone(), json!(text));
                }
            }
            "type" => match value.as_str() {
                Some("IMAGE") | Some("VIDEO") => {
                    body.insert("type".into(), value.clone());
                }
                _ => {}
            },
            "isFavorite" | "isNotInAlbum" | "isMotion" => {
                if value.as_bool() == Some(true) {
                    body.insert(key.clone(), json!(true));
                }
            }
            "personIds" | "albumIds" | "tagIds" => {
                let ids: Vec<String> = value
                    .as_array()
                    .cloned()
                    .unwrap_or_default()
                    .iter()
                    .filter_map(|v| v.as_str().filter(|s| valid_id(s)).map(|s| s.to_string()))
                    .collect();
                if !ids.is_empty() {
                    body.insert(key.clone(), json!(ids));
                }
            }
            "rating" => {
                if let Some(r) = value.as_i64().filter(|r| (1..=5).contains(r)) {
                    body.insert("rating".into(), json!(r));
                }
            }
            "visibility" => {
                if let Some(v) = value.as_str().filter(|v| ["timeline", "archive"].contains(v)) {
                    body.insert("visibility".into(), json!(v));
                }
            }
            _ => {}
        }
    }
    Ok(())
}

/// One search entry point. `mode` picks how the words are matched:
/// smart (CLIP), filename, description, ocr, or filters only.
pub async fn search(app: &App, params: &Value) -> Result<Value> {
    let mode = str_param(params, "mode");
    let query = str_param(params, "query").trim().chars().take(500).collect::<String>();
    let page = page_param(params);
    let size = params.get("size").and_then(|v| v.as_u64()).unwrap_or(150).clamp(1, 500);
    let mut body = Map::new();
    body.insert("page".into(), json!(page));
    body.insert("size".into(), json!(size));
    body.insert("withExif".into(), json!(true));
    apply_filters(&mut body, params.get("filters").unwrap_or(&Value::Null))?;
    let path = match mode {
        "smart" | "" => {
            if query.is_empty() {
                "/api/search/metadata"
            } else {
                body.insert("query".into(), json!(query));
                body.remove("withExif");
                "/api/search/smart"
            }
        }
        "filename" => {
            body.insert("originalFileName".into(), json!(query));
            "/api/search/metadata"
        }
        "description" => {
            body.insert("description".into(), json!(query));
            "/api/search/metadata"
        }
        "ocr" => {
            body.insert("ocr".into(), json!(query));
            "/api/search/metadata"
        }
        "metadata" => "/api/search/metadata",
        _ => return Err(Error::invalid("Unknown search mode")),
    };
    if path == "/api/search/metadata" && !body.contains_key("visibility") {
        body.insert("visibility".into(), json!("timeline"));
    }
    let result = app.immich.post(path, Value::Object(body)).await?;
    Ok(search_result(&result))
}

pub async fn search_suggestions(app: &App, params: &Value) -> Result<Value> {
    let kind = match str_param(params, "type") {
        t @ ("country" | "state" | "city" | "camera-make" | "camera-model" | "camera-lens-model") => t,
        _ => return Err(Error::invalid("Unknown suggestion type")),
    };
    let mut path = format!("/api/search/suggestions?type={kind}");
    for key in ["country", "state", "make", "model"] {
        let value = str_param(params, key);
        if !value.is_empty() {
            path.push_str(&format!("&{key}={}", q(value)));
        }
    }
    let list = app.immich.get(&path).await?;
    Ok(Value::Array(list.as_array().cloned().unwrap_or_default().into_iter().filter(|v| v.is_string()).collect()))
}

pub async fn place_assets(app: &App, params: &Value) -> Result<Value> {
    let mut filters = Map::new();
    for key in ["city", "country"] {
        let value = str_param(params, key);
        if !value.is_empty() {
            filters.insert(key.into(), json!(value));
        }
    }
    if filters.is_empty() {
        return Err(Error::invalid("Choose a place"));
    }
    let request = json!({ "mode": "metadata", "page": page_param(params), "size": 250, "filters": Value::Object(filters) });
    search(app, &request).await
}

// ---------------------------------------------------------------- tags

pub async fn tags_list(app: &App) -> Result<Value> {
    let tags = app.immich.get("/api/tags").await?;
    let mut list: Vec<Value> = tags
        .as_array()
        .cloned()
        .unwrap_or_default()
        .iter()
        .map(|t| pick(t, &["id", "name", "value", "color", "parentId", "updatedAt"]))
        .collect();
    list.sort_by(|a, b| {
        a["value"].as_str().unwrap_or("").to_lowercase().cmp(&b["value"].as_str().unwrap_or("").to_lowercase())
    });
    Ok(Value::Array(list))
}

fn tag_color(params: &Value) -> Result<Option<String>> {
    match params.get("color").and_then(|v| v.as_str()) {
        None | Some("") => Ok(None),
        Some(c) if c.len() == 7 && c.starts_with('#') && c[1..].chars().all(|x| x.is_ascii_hexdigit()) => Ok(Some(c.to_string())),
        _ => Err(Error::invalid("Colours look like #4a90d9")),
    }
}

/// Create a tag. A name like `Trips/2024` is a nested tag; Immich creates
/// any missing parents. Answers with the deepest tag.
pub async fn tag_create(app: &App, params: &Value) -> Result<Value> {
    let name = str_param(params, "name").trim().trim_matches('/').to_string();
    if name.is_empty() || name.len() > 200 || name.contains("//") {
        return Err(Error::invalid("Tag names are 1 to 200 characters; use / between levels"));
    }
    let created = app.immich.put("/api/tags", json!({ "tags": [name] })).await?;
    let mut tag = created
        .as_array()
        .and_then(|list| list.iter().find(|t| t.get("value").and_then(|v| v.as_str()) == Some(name.as_str())).or(list.last()).cloned())
        .ok_or_else(|| Error::new(crate::error::SERVER, "Immich did not return the new tag"))?;
    if let Some(color) = tag_color(params)? {
        if let Some(id) = tag.get("id").and_then(|v| v.as_str()) {
            tag = app.immich.put(&format!("/api/tags/{}", require_id(id)?), json!({ "color": color })).await?;
        }
    }
    Ok(pick(&tag, &["id", "name", "value", "color", "parentId"]))
}

pub async fn tag_update(app: &App, params: &Value) -> Result<Value> {
    let id = id_param(params, "id")?;
    let mut body = Map::new();
    if let Some(color) = tag_color(params)? {
        body.insert("color".into(), json!(color));
    }
    let tag = app.immich.put(&format!("/api/tags/{id}"), Value::Object(body)).await?;
    Ok(pick(&tag, &["id", "name", "value", "color", "parentId"]))
}

pub async fn tag_delete(app: &App, params: &Value) -> Result<Value> {
    let id = id_param(params, "id")?;
    app.immich.delete(&format!("/api/tags/{id}"), None).await?;
    Ok(json!(true))
}

pub async fn tag_assets(app: &App, params: &Value, add: bool) -> Result<Value> {
    let id = id_param(params, "id")?;
    let ids = ids_param(params, "ids")?;
    let path = format!("/api/tags/{id}/assets");
    if add {
        app.immich.put(&path, json!({ "ids": ids })).await?;
    } else {
        app.immich.delete(&path, Some(json!({ "ids": ids }))).await?;
    }
    Ok(json!(ids.len()))
}

/// One photo and the photo count per tag, to draw tags as tiles and rows.
/// Eight questions at a time, so a long tag list does not flood the server.
pub async fn tag_covers(app: &App, params: &Value) -> Result<Value> {
    use futures_util::StreamExt;
    let list = params.get("ids").and_then(|v| v.as_array()).ok_or_else(|| Error::invalid("Expected a list of ids"))?;
    let ids: Vec<String> = list
        .iter()
        .filter_map(|v| v.as_str().filter(|s| valid_id(s)).map(|s| s.to_string()))
        .take(500)
        .collect();
    let found: Vec<Option<(String, Value, Value)>> = futures_util::stream::iter(ids.into_iter().map(|id| async move {
        let result = app
            .immich
            .post("/api/search/metadata", json!({ "tagIds": [id], "size": 1, "page": 1, "withExif": false }))
            .await
            .ok()?;
        let asset = result.pointer("/assets/items/0/id").cloned().unwrap_or(Value::Null);
        let total = result.pointer("/assets/total").cloned().unwrap_or(Value::Null);
        Some((id, asset, total))
    }))
    .buffer_unordered(8)
    .collect()
    .await;
    let mut out = Map::new();
    for (id, asset, total) in found.into_iter().flatten() {
        out.insert(id, json!({ "assetId": asset, "count": total }));
    }
    Ok(Value::Object(out))
}

// ---------------------------------------------------------------- folders

pub async fn folder_paths(app: &App) -> Result<Value> {
    let paths = app.immich.get("/api/view/folder/unique-paths").await?;
    let mut list: Vec<String> = paths.as_array().cloned().unwrap_or_default().into_iter().filter_map(|v| v.as_str().map(|s| s.to_string())).collect();
    list.sort();
    Ok(json!(list))
}

pub async fn folder_assets(app: &App, params: &Value) -> Result<Value> {
    let path = str_param(params, "path");
    if path.is_empty() || path.len() > 4096 {
        return Err(Error::invalid("Choose a folder"));
    }
    let assets = app.immich.get(&format!("/api/view/folder?path={}", q(path))).await?;
    let mut rows: Vec<Value> = assets.as_array().cloned().unwrap_or_default().iter().filter_map(asset_row).collect();
    rows.sort_by(|a, b| b["fileCreatedAt"].as_str().unwrap_or("").cmp(a["fileCreatedAt"].as_str().unwrap_or("")));
    Ok(Value::Array(rows))
}

// ---------------------------------------------------------------- sharing

async fn public_base(app: &App) -> String {
    let settings = app.settings();
    if settings.external_enabled && !settings.external_url.is_empty() {
        return settings.external_url;
    }
    if let Ok((base, _)) = app.immich.base().await {
        return base;
    }
    settings.server_url
}

fn slim_link(link: &Value, base: &str) -> Value {
    let key = link.get("key").and_then(|v| v.as_str()).unwrap_or("");
    let slug = link.get("slug").and_then(|v| v.as_str()).filter(|s| !s.is_empty());
    let url = match slug {
        Some(slug) => format!("{base}/s/{slug}"),
        None => format!("{base}/share/{key}"),
    };
    json!({
        "id": link.get("id"),
        "url": url,
        "type": link.get("type"),
        "description": link.get("description"),
        "expiresAt": link.get("expiresAt"),
        "createdAt": link.get("createdAt"),
        "allowDownload": link.get("allowDownload"),
        "allowUpload": link.get("allowUpload"),
        "showMetadata": link.get("showMetadata"),
        "hasPassword": link.get("password").map(|p| !p.is_null() && p.as_str() != Some("")).unwrap_or(false),
        "albumName": link.pointer("/album/albumName"),
        "albumId": link.pointer("/album/id"),
        "assetCount": link.get("assets").and_then(|a| a.as_array()).map(|a| a.len()),
        "coverAssetId": link
            .pointer("/album/albumThumbnailAssetId")
            .cloned()
            .or_else(|| link.pointer("/assets/0/id").cloned()),
    })
}

pub async fn shared_links_list(app: &App) -> Result<Value> {
    let base = public_base(app).await;
    let links = app.immich.get("/api/shared-links").await?;
    Ok(Value::Array(links.as_array().cloned().unwrap_or_default().iter().map(|l| slim_link(l, &base)).collect()))
}

fn link_options(params: &Value, body: &mut Map<String, Value>) -> Result<()> {
    for key in ["allowDownload", "allowUpload", "showMetadata"] {
        if let Some(v) = params.get(key).and_then(|v| v.as_bool()) {
            body.insert(key.into(), json!(v));
        }
    }
    if let Some(desc) = params.get("description").and_then(|v| v.as_str()) {
        body.insert("description".into(), json!(desc.chars().take(1000).collect::<String>()));
    }
    if let Some(password) = params.get("password").and_then(|v| v.as_str()) {
        body.insert("password".into(), if password.is_empty() { Value::Null } else { json!(password) });
    }
    match params.get("expiresInDays").and_then(|v| v.as_i64()) {
        Some(days) if days > 0 => {
            let at = chrono::Utc::now() + chrono::Duration::days(days.min(3650));
            body.insert("expiresAt".into(), json!(at.to_rfc3339()));
        }
        Some(_) => {
            body.insert("expiresAt".into(), Value::Null);
        }
        None => {}
    }
    Ok(())
}

pub async fn shared_link_create(app: &App, params: &Value) -> Result<Value> {
    let mut body = Map::new();
    if let Some(album) = params.get("albumId").and_then(|v| v.as_str()).filter(|s| !s.is_empty()) {
        body.insert("type".into(), json!("ALBUM"));
        body.insert("albumId".into(), json!(require_id(album)?));
    } else {
        body.insert("type".into(), json!("INDIVIDUAL"));
        body.insert("assetIds".into(), json!(ids_param(params, "assetIds")?));
    }
    link_options(params, &mut body)?;
    let link = app.immich.post("/api/shared-links", Value::Object(body)).await?;
    Ok(slim_link(&link, &public_base(app).await))
}

pub async fn shared_link_update(app: &App, params: &Value) -> Result<Value> {
    let id = id_param(params, "id")?;
    let mut body = Map::new();
    link_options(params, &mut body)?;
    let link = app.immich.patch(&format!("/api/shared-links/{id}"), Value::Object(body)).await?;
    Ok(slim_link(&link, &public_base(app).await))
}

pub async fn shared_link_delete(app: &App, params: &Value) -> Result<Value> {
    let id = id_param(params, "id")?;
    app.immich.delete(&format!("/api/shared-links/{id}"), None).await?;
    Ok(json!(true))
}

pub async fn partners(app: &App) -> Result<Value> {
    let by = app.immich.get("/api/partners?direction=shared-by").await.unwrap_or(Value::Array(vec![]));
    let with = app.immich.get("/api/partners?direction=shared-with").await.unwrap_or(Value::Array(vec![]));
    let slim = |v: &Value| -> Vec<Value> {
        v.as_array().cloned().unwrap_or_default().iter().map(|p| pick(p, &["id", "name", "email", "inTimeline"])).collect()
    };
    Ok(json!({ "sharedBy": slim(&by), "sharedWith": slim(&with) }))
}

pub async fn partner_add(app: &App, params: &Value) -> Result<Value> {
    let id = id_param(params, "userId")?;
    app.immich.post("/api/partners", json!({ "sharedWithId": id })).await?;
    Ok(json!(true))
}

pub async fn partner_remove(app: &App, params: &Value) -> Result<Value> {
    let id = id_param(params, "userId")?;
    app.immich.delete(&format!("/api/partners/{id}"), None).await?;
    Ok(json!(true))
}

pub async fn partner_timeline(app: &App, params: &Value) -> Result<Value> {
    let id = id_param(params, "userId")?;
    let show = params.get("inTimeline").and_then(|v| v.as_bool()).unwrap_or(true);
    app.immich.put(&format!("/api/partners/{id}"), json!({ "inTimeline": show })).await?;
    Ok(json!(true))
}

// ---------------------------------------------------------------- server

pub async fn statistics(app: &App) -> Result<Value> {
    let (all, favorites, archived, trashed) = tokio::join!(
        app.immich.get("/api/assets/statistics"),
        app.immich.get("/api/assets/statistics?isFavorite=true"),
        app.immich.get("/api/assets/statistics?visibility=archive"),
        app.immich.get("/api/assets/statistics?isTrashed=true"),
    );
    let total = |r: &Result<Value>| r.as_ref().ok().and_then(|v| v.get("total").cloned()).unwrap_or(Value::Null);
    let all = all?;
    Ok(json!({
        "images": all.get("images"),
        "videos": all.get("videos"),
        "total": all.get("total"),
        "favorites": total(&favorites),
        "archived": total(&archived),
        "trashed": total(&trashed),
    }))
}

pub async fn server_overview(app: &App) -> Result<Value> {
    let (me, version, features, about, storage, preferences) = tokio::join!(
        app.immich.get("/api/users/me"),
        app.immich.get("/api/server/version"),
        app.immich.get("/api/server/features"),
        app.immich.get("/api/server/about"),
        app.immich.get("/api/server/storage"),
        app.immich.get("/api/users/me/preferences"),
    );
    // Which pages the person turned off in their Immich account.
    let enabled = |key: &str| -> Value {
        preferences
            .as_ref()
            .ok()
            .and_then(|p| p.get(key))
            .and_then(|v| v.get("enabled"))
            .cloned()
            .unwrap_or(Value::Bool(true))
    };
    let preferences = json!({
        "folders": enabled("folders"),
        "tags": enabled("tags"),
        "people": enabled("people"),
        "sharedLinks": enabled("sharedLinks"),
        "ratings": enabled("ratings"),
    });
    let me = me?;
    let route = app.immich.route().await;
    Ok(json!({
        "user": crate::immich::slim_user(&me),
        "version": version.map(|v| crate::immich::version_text(&v)).unwrap_or_default(),
        "features": features.unwrap_or(Value::Null),
        "about": about.map(|a| pick(&a, &["version", "build", "repository", "licensed"])).unwrap_or(Value::Null),
        "storage": storage.map(|s| pick(&s, &["diskSize", "diskUse", "diskAvailable", "diskUsagePercentage"])).unwrap_or(Value::Null),
        "preferences": preferences,
        "route": route,
    }))
}
