//! Timeline buckets: the month index and the photos of one month.

use serde_json::{Value, json};

use super::{q, valid_id};
use crate::error::{Error, Result};

/// Which photos a timeline shows. The UI sends one of these with every call;
/// only recognised keys reach the query string.
pub fn scope_query(scope: &Value) -> Result<String> {
    let mut parts: Vec<String> = Vec::new();
    let obj = scope.as_object().cloned().unwrap_or_default();
    let mut has_owner_scope = false;
    for key in ["albumId", "personId", "tagId"] {
        if let Some(id) = obj.get(key).and_then(|v| v.as_str()).filter(|s| !s.is_empty()) {
            if !valid_id(id) {
                return Err(Error::invalid("Not a valid Immich id"));
            }
            parts.push(format!("{key}={id}"));
            has_owner_scope = true;
        }
    }
    let trashed = obj.get("isTrashed").and_then(|v| v.as_bool()).unwrap_or(false);
    if trashed {
        parts.push("isTrashed=true".into());
    }
    if let Some(fav) = obj.get("isFavorite").and_then(|v| v.as_bool()) {
        parts.push(format!("isFavorite={fav}"));
    }
    let visibility = obj.get("visibility").and_then(|v| v.as_str()).unwrap_or("");
    match visibility {
        "" => {
            // The main timeline and a person's page hide archived photos;
            // an album shows whatever was put in it.
            if !has_owner_scope && !trashed {
                parts.push("visibility=timeline".into());
            } else if obj.contains_key("personId") {
                parts.push("visibility=timeline".into());
            }
        }
        "timeline" | "archive" | "hidden" | "locked" => parts.push(format!("visibility={visibility}")),
        _ => return Err(Error::invalid("Unknown visibility")),
    }
    if obj.get("withPartners").and_then(|v| v.as_bool()) == Some(true) && !has_owner_scope {
        parts.push("withPartners=true".into());
    }
    if obj.get("withStacked").and_then(|v| v.as_bool()) == Some(true) {
        parts.push("withStacked=true".into());
    }
    if obj.get("order").and_then(|v| v.as_str()) == Some("asc") {
        parts.push("order=asc".into());
    }
    Ok(parts.join("&"))
}

pub fn bucket_path(scope: &Value, bucket: &str) -> Result<String> {
    if bucket.is_empty() || bucket.len() > 40 || !bucket.chars().all(|c| c.is_ascii_alphanumeric() || "-:.TZ+".contains(c)) {
        return Err(Error::invalid("Not a valid time bucket"));
    }
    let query = scope_query(scope)?;
    let sep = if query.is_empty() { "" } else { "&" };
    Ok(format!("/api/timeline/bucket?timeBucket={}{sep}{query}", q(bucket)))
}

pub fn buckets_path(scope: &Value) -> Result<String> {
    let query = scope_query(scope)?;
    Ok(if query.is_empty() {
        "/api/timeline/buckets".to_string()
    } else {
        format!("/api/timeline/buckets?{query}")
    })
}

/// Immich answers a month as parallel columns; the UI wants rows.
pub fn columns_to_rows(columns: &Value) -> Vec<Value> {
    let Some(ids) = columns.get("id").and_then(|v| v.as_array()) else {
        return Vec::new();
    };
    let col = |name: &str, i: usize| -> Value {
        columns
            .get(name)
            .and_then(|v| v.as_array())
            .and_then(|a| a.get(i))
            .cloned()
            .unwrap_or(Value::Null)
    };
    ids.iter()
        .enumerate()
        .filter_map(|(i, id)| {
            let id = id.as_str()?;
            let ratio = col("ratio", i).as_f64().filter(|r| r.is_finite() && *r > 0.05).unwrap_or(1.0);
            let duration = col("duration", i);
            Some(json!({
                "id": id,
                "ratio": (ratio * 1000.0).round() / 1000.0,
                "isImage": col("isImage", i).as_bool().unwrap_or(true),
                "isFavorite": col("isFavorite", i).as_bool().unwrap_or(false),
                "isTrashed": col("isTrashed", i).as_bool().unwrap_or(false),
                "visibility": col("visibility", i),
                "duration": duration_text(&duration),
                "livePhotoVideoId": col("livePhotoVideoId", i),
                "fileCreatedAt": col("fileCreatedAt", i),
                "localOffsetHours": col("localOffsetHours", i),
                "ownerId": col("ownerId", i),
                "projectionType": col("projectionType", i),
                "thumbhash": col("thumbhash", i),
                "city": col("city", i),
                "country": col("country", i),
                "stackCount": stack_count(columns, i),
            }))
        })
        .collect()
}

fn stack_count(columns: &Value, i: usize) -> Value {
    columns
        .get("stack")
        .and_then(|v| v.as_array())
        .and_then(|a| a.get(i))
        .and_then(|s| s.as_array())
        .and_then(|pair| pair.get(1))
        .cloned()
        .unwrap_or(Value::Null)
}

/// Immich gives a video's length either as milliseconds or as `H:MM:SS.fff`.
pub fn duration_text(value: &Value) -> Value {
    let seconds = match value {
        Value::Number(n) => n.as_f64().map(|ms| ms / 1000.0),
        Value::String(s) => parse_clock(s),
        _ => None,
    };
    match seconds {
        Some(s) if s > 0.0 => {
            let total = s.round() as u64;
            let (h, m, sec) = (total / 3600, (total / 60) % 60, total % 60);
            Value::String(if h > 0 { format!("{h}:{m:02}:{sec:02}") } else { format!("{m}:{sec:02}") })
        }
        _ => Value::Null,
    }
}

fn parse_clock(text: &str) -> Option<f64> {
    let mut total = 0.0;
    for part in text.split(':') {
        total = total * 60.0 + part.parse::<f64>().ok()?;
    }
    Some(total)
}

/// Normalise any asset response (search hit, album entry, detail) into the
/// row shape the grid uses.
pub fn asset_row(asset: &Value) -> Option<Value> {
    let id = asset.get("id")?.as_str()?;
    let exif = asset.get("exifInfo").cloned().unwrap_or(Value::Null);
    let (w, h) = dimensions(asset, &exif);
    let ratio = match (w, h) {
        (Some(w), Some(h)) if w > 0.0 && h > 0.0 => w / h,
        _ => 1.0,
    };
    let created = asset
        .get("localDateTime")
        .or_else(|| asset.get("fileCreatedAt"))
        .cloned()
        .unwrap_or(Value::Null);
    Some(json!({
        "id": id,
        "ratio": (ratio * 1000.0).round() / 1000.0,
        "isImage": asset.get("type").and_then(|t| t.as_str()) != Some("VIDEO"),
        "isFavorite": asset.get("isFavorite").and_then(|v| v.as_bool()).unwrap_or(false),
        "isTrashed": asset.get("isTrashed").and_then(|v| v.as_bool()).unwrap_or(false),
        "visibility": asset.get("visibility").cloned().unwrap_or(Value::Null),
        "duration": duration_text(asset.get("duration").unwrap_or(&Value::Null)),
        "livePhotoVideoId": asset.get("livePhotoVideoId").cloned().unwrap_or(Value::Null),
        "fileCreatedAt": created,
        "ownerId": asset.get("ownerId").cloned().unwrap_or(Value::Null),
        "thumbhash": asset.get("thumbhash").cloned().unwrap_or(Value::Null),
        "city": exif.get("city").cloned().unwrap_or(Value::Null),
        "country": exif.get("country").cloned().unwrap_or(Value::Null),
        "originalFileName": asset.get("originalFileName").cloned().unwrap_or(Value::Null),
    }))
}

fn dimensions(asset: &Value, exif: &Value) -> (Option<f64>, Option<f64>) {
    let w = asset.get("width").and_then(|v| v.as_f64());
    let h = asset.get("height").and_then(|v| v.as_f64());
    if let (Some(w), Some(h)) = (w, h) {
        return (Some(w), Some(h));
    }
    let mut w = exif.get("exifImageWidth").and_then(|v| v.as_f64());
    let mut h = exif.get("exifImageHeight").and_then(|v| v.as_f64());
    // EXIF sizes are before rotation; orientations 5–8 swap them.
    let orientation = exif
        .get("orientation")
        .and_then(|o| o.as_str().and_then(|s| s.parse::<i64>().ok()).or_else(|| o.as_i64()))
        .unwrap_or(1);
    if (5..=8).contains(&orientation) {
        std::mem::swap(&mut w, &mut h);
    }
    (w, h)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn main_timeline_hides_archive() {
        assert_eq!(scope_query(&json!({})).unwrap(), "visibility=timeline");
        assert_eq!(scope_query(&json!({"visibility": "archive"})).unwrap(), "visibility=archive");
        assert_eq!(scope_query(&json!({"isTrashed": true})).unwrap(), "isTrashed=true");
        let album = scope_query(&json!({"albumId": "95d338b7-e7d1-4a25-89e5-869b16fca112"})).unwrap();
        assert_eq!(album, "albumId=95d338b7-e7d1-4a25-89e5-869b16fca112");
        assert!(scope_query(&json!({"albumId": "x&y=1"})).is_err());
        assert!(scope_query(&json!({"visibility": "everything"})).is_err());
    }

    #[test]
    fn rows_from_columns() {
        let cols = json!({
            "id": ["a", "b"], "ratio": [1.5, null], "isImage": [true, false],
            "duration": [null, 10767], "isFavorite": [false, true]
        });
        let rows = columns_to_rows(&cols);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0]["ratio"], 1.5);
        assert_eq!(rows[1]["ratio"], 1.0);
        assert_eq!(rows[1]["duration"], "0:11");
        assert_eq!(rows[1]["isFavorite"], true);
    }

    #[test]
    fn durations() {
        assert_eq!(duration_text(&json!("0:01:05.500")), json!("1:06"));
        assert_eq!(duration_text(&json!(3_723_000)), json!("1:02:03"));
        assert_eq!(duration_text(&json!("0:00:00.000")), Value::Null);
    }

    #[test]
    fn bucket_validation() {
        assert!(bucket_path(&json!({}), "2026-10-01").is_ok());
        assert!(bucket_path(&json!({}), "2026&x=1").is_err());
    }

    #[test]
    fn rotated_exif_swaps_ratio() {
        let row = asset_row(&json!({"id": "x", "exifInfo": {"exifImageWidth": 4000, "exifImageHeight": 3000, "orientation": "6"}})).unwrap();
        assert_eq!(row["ratio"], 0.75);
    }
}
