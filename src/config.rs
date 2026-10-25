use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::error::{Error, Result};
use crate::paths::{self, Paths};

/// Everything Omamich remembers between runs, except the API key, which lives
/// in the keyring. Unknown or missing fields fall back to their defaults so an
/// older file always loads.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    /// The address used at home, tried first.
    pub server_url: String,
    pub server_enabled: bool,
    /// The address used away from home, tried when the first does not answer.
    pub external_url: String,
    pub external_enabled: bool,
    pub cache_cap_mb: u64,
    pub sync: SyncSettings,
    /// Window preferences owned by the UI (sidebar width, info panel, …).
    pub ui: Value,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            server_url: String::new(),
            server_enabled: true,
            external_url: String::new(),
            external_enabled: false,
            cache_cap_mb: 2000,
            sync: SyncSettings::default(),
            ui: Value::Object(Default::default()),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct SyncSettings {
    /// Watching and uploading run only while this is on.
    pub enabled: bool,
    pub concurrency: u32,
    pub pause_on_metered: bool,
    pub pause_on_battery: bool,
    /// "HH:MM" local time; both set means uploads wait inside that window.
    pub quiet_start: String,
    pub quiet_end: String,
    /// Look for files that changed while Omamich was not running.
    pub startup_scan: bool,
    /// Send `photo.jpg.xmp` / `photo.xmp` alongside the photo.
    pub upload_sidecars: bool,
    pub folders: Vec<WatchFolder>,
}

impl Default for SyncSettings {
    fn default() -> Self {
        Self {
            enabled: false,
            concurrency: 3,
            pause_on_metered: true,
            pause_on_battery: false,
            quiet_start: String::new(),
            quiet_end: String::new(),
            startup_scan: true,
            upload_sidecars: true,
            folders: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "lowercase")]
pub enum SyncMethod {
    /// Local → Immich only.
    #[default]
    Upload,
    /// Immich album → local folder only.
    Download,
    /// Both directions.
    Full,
}

impl SyncMethod {
    pub fn uploads(self) -> bool {
        matches!(self, SyncMethod::Upload | SyncMethod::Full)
    }

    pub fn downloads(self) -> bool {
        matches!(self, SyncMethod::Download | SyncMethod::Full)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct WatchFolder {
    pub id: String,
    pub path: String,
    pub enabled: bool,
    /// Album that receives this folder's uploads; empty means the library only.
    pub album_name: String,
    pub album_id: String,
    pub method: SyncMethod,
    pub ignore_hidden: bool,
    /// 0 means no limit.
    pub max_file_size_mb: u64,
    /// Lower-case extensions without a dot; empty means every supported type.
    pub extensions: Vec<String>,
    /// Deleting a local file moves its Immich copy to the trash.
    pub mirror_local_deletes: bool,
    /// Removing a photo from the album moves the local file to the desktop trash.
    pub mirror_remote_deletes: bool,
    /// Each subfolder becomes its own album, named after it; files directly
    /// in the folder go to `album_name`, or an album named after the folder.
    pub album_per_subfolder: bool,
}

impl Default for WatchFolder {
    fn default() -> Self {
        Self {
            id: String::new(),
            path: String::new(),
            enabled: true,
            album_name: String::new(),
            album_id: String::new(),
            method: SyncMethod::Upload,
            ignore_hidden: true,
            max_file_size_mb: 0,
            extensions: Vec::new(),
            mirror_local_deletes: false,
            mirror_remote_deletes: false,
            album_per_subfolder: false,
        }
    }
}

impl WatchFolder {
    /// A folder without an album has nothing to download from and nothing to
    /// reconcile deletions against, so it can only upload.
    pub fn normalized(mut self) -> Self {
        self.path = paths::expand_home(&self.path).to_string_lossy().into_owned();
        while self.path.len() > 1 && self.path.ends_with('/') {
            self.path.pop();
        }
        self.album_name = self.album_name.trim().to_string();
        self.extensions = self
            .extensions
            .iter()
            .map(|e| e.trim().trim_start_matches('.').to_ascii_lowercase())
            .filter(|e| !e.is_empty())
            .collect();
        if self.album_per_subfolder {
            // Albums follow the subfolders, so there is no one album to
            // download from or mirror removals of.
            self.album_id.clear();
            self.method = SyncMethod::Upload;
            self.mirror_remote_deletes = false;
        } else if self.album_name.is_empty() {
            self.album_id.clear();
            self.method = SyncMethod::Upload;
            self.mirror_remote_deletes = false;
            self.mirror_local_deletes = false;
        }
        if !self.method.downloads() {
            self.mirror_remote_deletes = false;
        }
        if !self.method.uploads() {
            self.mirror_local_deletes = false;
        }
        self
    }
}

pub fn normalize_url(raw: &str) -> Result<String> {
    let mut value = raw.trim().to_string();
    if value.is_empty() {
        return Ok(value);
    }
    if !value.contains("://") {
        value = format!("http://{value}");
    }
    let parsed = url::Url::parse(&value).map_err(|_| Error::invalid("That is not a valid server address"))?;
    if parsed.scheme() != "http" && parsed.scheme() != "https" {
        return Err(Error::invalid("The server address must start with http:// or https://"));
    }
    if parsed.host_str().is_none() {
        return Err(Error::invalid("The server address has no host"));
    }
    let mut text = parsed.to_string();
    while text.ends_with('/') {
        text.pop();
    }
    // People paste the API root as often as the web address.
    if let Some(stripped) = text.strip_suffix("/api") {
        text = stripped.to_string();
    }
    Ok(text)
}

fn valid_clock(value: &str) -> bool {
    if value.is_empty() {
        return true;
    }
    let mut parts = value.split(':');
    let (Some(h), Some(m), None) = (parts.next(), parts.next(), parts.next()) else {
        return false;
    };
    if h.is_empty() || h.len() > 2 || m.len() != 2 {
        return false;
    }
    matches!((h.parse::<u32>(), m.parse::<u32>()), (Ok(h), Ok(m)) if h < 24 && m < 60)
}

impl Settings {
    pub fn load(paths: &Paths) -> Self {
        match std::fs::read(paths.config_file()) {
            Ok(bytes) => serde_json::from_slice::<Settings>(&bytes)
                .map(Settings::normalized)
                .unwrap_or_else(|err| {
                    eprintln!("omamich: config unreadable, using defaults: {err}");
                    Settings::default()
                }),
            Err(_) => Settings::default(),
        }
    }

    pub fn save(&self, paths: &Paths) -> Result<()> {
        let bytes = serde_json::to_vec_pretty(self)?;
        paths::write_private(&paths.config_file(), &bytes)?;
        Ok(())
    }

    pub fn normalized(mut self) -> Self {
        self.sync.concurrency = self.sync.concurrency.clamp(1, 8);
        self.cache_cap_mb = self.cache_cap_mb.clamp(200, 100_000);
        if !self.ui.is_object() {
            self.ui = Value::Object(Default::default());
        }
        let mut seen = std::collections::HashSet::new();
        self.sync.folders = std::mem::take(&mut self.sync.folders)
            .into_iter()
            .map(WatchFolder::normalized)
            .filter(|f| !f.path.is_empty() && seen.insert(f.path.clone()))
            .map(|mut f| {
                if f.id.is_empty() {
                    f.id = new_id();
                }
                f
            })
            .collect();
        if !valid_clock(&self.sync.quiet_start) || !valid_clock(&self.sync.quiet_end) {
            self.sync.quiet_start.clear();
            self.sync.quiet_end.clear();
        }
        self
    }

    /// Apply a partial update from the UI. Only known keys are honoured, and
    /// each is validated before anything is changed.
    pub fn apply_patch(&mut self, patch: &Value) -> Result<()> {
        let Some(patch) = patch.as_object() else {
            return Err(Error::invalid("Expected an object of settings"));
        };
        let mut next = self.clone();
        for (key, value) in patch {
            match key.as_str() {
                "serverUrl" => next.server_url = normalize_url(str_of(value)?)?,
                "externalUrl" => next.external_url = normalize_url(str_of(value)?)?,
                "serverEnabled" => next.server_enabled = bool_of(value)?,
                "externalEnabled" => next.external_enabled = bool_of(value)?,
                "cacheCapMb" => next.cache_cap_mb = u64_of(value)?,
                "ui" => {
                    let Some(obj) = value.as_object() else {
                        return Err(Error::invalid("ui must be an object"));
                    };
                    let target = next.ui.as_object_mut().expect("normalized ui");
                    for (k, v) in obj {
                        if v.is_null() {
                            target.remove(k);
                        } else {
                            target.insert(k.clone(), v.clone());
                        }
                    }
                }
                "sync" => {
                    let Some(obj) = value.as_object() else {
                        return Err(Error::invalid("sync must be an object"));
                    };
                    for (k, v) in obj {
                        match k.as_str() {
                            "enabled" => next.sync.enabled = bool_of(v)?,
                            "concurrency" => next.sync.concurrency = u64_of(v)? as u32,
                            "pauseOnMetered" => next.sync.pause_on_metered = bool_of(v)?,
                            "pauseOnBattery" => next.sync.pause_on_battery = bool_of(v)?,
                            "startupScan" => next.sync.startup_scan = bool_of(v)?,
                            "uploadSidecars" => next.sync.upload_sidecars = bool_of(v)?,
                            "quietStart" | "quietEnd" => {
                                let text = str_of(v)?.trim().to_string();
                                if !valid_clock(&text) {
                                    return Err(Error::invalid("Quiet hours use 24-hour HH:MM"));
                                }
                                if k == "quietStart" {
                                    next.sync.quiet_start = text;
                                } else {
                                    next.sync.quiet_end = text;
                                }
                            }
                            _ => return Err(Error::invalid(format!("Unknown sync setting: {k}"))),
                        }
                    }
                }
                _ => return Err(Error::invalid(format!("Unknown setting: {key}"))),
            }
        }
        if next.server_url.is_empty() && next.external_url.is_empty() {
            next.server_enabled = true;
        }
        *self = next.normalized();
        Ok(())
    }

    /// What the UI may see: everything here, since the key is never stored in it.
    pub fn to_json(&self) -> Value {
        serde_json::to_value(self).unwrap_or(Value::Null)
    }
}

pub fn new_id() -> String {
    let mut bytes = [0u8; 8];
    let _ = getrandom::fill(&mut bytes);
    hex::encode(bytes)
}

fn str_of(value: &Value) -> Result<&str> {
    value.as_str().ok_or_else(|| Error::invalid("Expected text"))
}

fn bool_of(value: &Value) -> Result<bool> {
    value.as_bool().ok_or_else(|| Error::invalid("Expected true or false"))
}

fn u64_of(value: &Value) -> Result<u64> {
    value
        .as_u64()
        .or_else(|| value.as_f64().filter(|f| *f >= 0.0).map(|f| f as u64))
        .ok_or_else(|| Error::invalid("Expected a whole number"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn normalizes_server_addresses() {
        assert_eq!(normalize_url("192.168.1.10:2283").unwrap(), "http://192.168.1.10:2283");
        assert_eq!(normalize_url("https://photos.example.com/api/").unwrap(), "https://photos.example.com");
        assert!(normalize_url("ftp://x").is_err());
        assert_eq!(normalize_url("  ").unwrap(), "");
    }

    #[test]
    fn folders_without_albums_only_upload() {
        let folder = WatchFolder {
            path: "/tmp/a/".into(),
            method: SyncMethod::Full,
            mirror_local_deletes: true,
            mirror_remote_deletes: true,
            extensions: vec![".JPG".into(), " ".into()],
            ..Default::default()
        }
        .normalized();
        assert_eq!(folder.path, "/tmp/a");
        assert_eq!(folder.method, SyncMethod::Upload);
        assert!(!folder.mirror_local_deletes && !folder.mirror_remote_deletes);
        assert_eq!(folder.extensions, vec!["jpg".to_string()]);
    }

    #[test]
    fn album_per_subfolder_only_uploads() {
        let folder = WatchFolder {
            path: "/p".into(),
            album_per_subfolder: true,
            method: SyncMethod::Full,
            mirror_local_deletes: true,
            mirror_remote_deletes: true,
            ..Default::default()
        }
        .normalized();
        assert_eq!(folder.method, SyncMethod::Upload);
        assert!(folder.mirror_local_deletes);
        assert!(!folder.mirror_remote_deletes);
    }

    #[test]
    fn patch_rejects_unknown_keys_and_keeps_state() {
        let mut settings = Settings::default();
        assert!(settings.apply_patch(&json!({"serverUrl": "nas:2283", "bogus": 1})).is_err());
        assert_eq!(settings.server_url, "");
        settings.apply_patch(&json!({"serverUrl": "nas:2283", "sync": {"quietStart": "22:00"}})).unwrap();
        assert_eq!(settings.server_url, "http://nas:2283");
        assert_eq!(settings.sync.quiet_start, "22:00");
        assert!(settings.apply_patch(&json!({"sync": {"quietEnd": "25:00"}})).is_err());
    }

    #[test]
    fn ui_patch_merges_and_removes() {
        let mut settings = Settings::default();
        settings.apply_patch(&json!({"ui": {"a": 1, "b": 2}})).unwrap();
        settings.apply_patch(&json!({"ui": {"a": null}})).unwrap();
        assert_eq!(settings.ui, json!({"b": 2}));
    }
}
