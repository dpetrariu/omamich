//! Local-file questions: which files belong to sync, what they hash to, and
//! whether now is a good time to upload them.

use std::io::Read;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use sha1::{Digest, Sha1};

use crate::config::WatchFolder;

/// What Immich accepts. Anything else in a watched folder is left alone.
pub const IMAGE_EXTENSIONS: &[&str] = &[
    "jpg", "jpeg", "jpe", "png", "gif", "webp", "avif", "heic", "heif", "hif", "tif", "tiff", "bmp", "jxl", "jp2",
    "svg", "psd", "insp", "dng", "arw", "cr2", "cr3", "crw", "nef", "nrw", "orf", "raf", "rw2", "pef", "srw", "x3f",
    "3fr", "erf", "kdc", "mrw", "rwl", "sr2", "srf", "iiq", "cap", "fff", "k25", "dcr", "raw", "ori",
];
pub const VIDEO_EXTENSIONS: &[&str] = &[
    "mp4", "mov", "m4v", "avi", "mkv", "webm", "3gp", "3gpp", "mts", "m2ts", "mpg", "mpeg", "mp2t", "wmv", "flv",
    "mxf", "vob", "ts", "insv",
];

pub fn extension(path: &Path) -> String {
    path.extension().and_then(|e| e.to_str()).unwrap_or("").to_ascii_lowercase()
}

pub fn is_media(path: &Path) -> bool {
    let ext = extension(path);
    IMAGE_EXTENSIONS.contains(&ext.as_str()) || VIDEO_EXTENSIONS.contains(&ext.as_str())
}

pub fn mime_for(path: &Path) -> &'static str {
    match extension(path).as_str() {
        "jpg" | "jpeg" | "jpe" => "image/jpeg",
        "png" => "image/png",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "avif" => "image/avif",
        "heic" | "hif" => "image/heic",
        "heif" => "image/heif",
        "tif" | "tiff" => "image/tiff",
        "bmp" => "image/bmp",
        "jxl" => "image/jxl",
        "svg" => "image/svg+xml",
        "mp4" | "m4v" | "insv" => "video/mp4",
        "mov" => "video/quicktime",
        "webm" => "video/webm",
        "mkv" => "video/x-matroska",
        "avi" => "video/x-msvideo",
        "3gp" | "3gpp" => "video/3gpp",
        "mts" | "m2ts" | "ts" | "mp2t" => "video/mp2t",
        "mpg" | "mpeg" => "video/mpeg",
        "wmv" => "video/x-ms-wmv",
        "flv" => "video/x-flv",
        _ => "application/octet-stream",
    }
}

/// Why a file is not synced, or None when it should be.
pub fn rejection(folder: &WatchFolder, path: &Path, size: u64) -> Option<&'static str> {
    let root = Path::new(&folder.path);
    let Ok(relative) = path.strip_prefix(root) else {
        return Some("outside the folder");
    };
    if folder.ignore_hidden
        && relative.components().any(|c| c.as_os_str().to_str().map(|s| s.starts_with('.')).unwrap_or(false))
    {
        return Some("hidden");
    }
    if !is_media(path) {
        return Some("not a photo or video");
    }
    if !folder.extensions.is_empty() && !folder.extensions.contains(&extension(path)) {
        return Some("type not selected for this folder");
    }
    if folder.max_file_size_mb > 0 && size > folder.max_file_size_mb * 1024 * 1024 {
        return Some("larger than this folder's limit");
    }
    None
}

/// Temporary files editors and cameras leave while writing.
pub fn is_partial(path: &Path) -> bool {
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
    name.ends_with(".part")
        || name.ends_with(".crdownload")
        || name.ends_with(".tmp")
        || name.ends_with('~')
        || name.starts_with(".~")
        || name.starts_with(".goutputstream")
}

pub fn mtime_secs(meta: &std::fs::Metadata) -> i64 {
    meta.modified()
        .ok()
        .and_then(|m| m.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// SHA-1, the hash Immich uses to recognise a file it already has.
pub fn sha1_hex(path: &Path) -> std::io::Result<String> {
    let mut file = std::fs::File::open(path)?;
    let mut hasher = Sha1::new();
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = file.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(hex::encode(hasher.finalize()))
}

/// Immich reports checksums as base64; the index keeps hex.
pub fn base64_to_hex(text: &str) -> Option<String> {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut buffer = 0u32;
    let mut bits = 0;
    let mut out = Vec::new();
    for byte in text.bytes() {
        if byte == b'=' {
            break;
        }
        let value = TABLE.iter().position(|&c| c == byte)? as u32;
        buffer = (buffer << 6) | value;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((buffer >> bits) as u8);
            buffer &= (1 << bits) - 1;
        }
    }
    Some(hex::encode(out))
}

/// The XMP sidecar next to a photo, under either naming convention.
pub fn sidecar_for(path: &Path) -> Option<PathBuf> {
    let mut with_ext = path.as_os_str().to_owned();
    with_ext.push(".xmp");
    let first = PathBuf::from(with_ext);
    if first.is_file() {
        return Some(first);
    }
    let second = path.with_extension("xmp");
    second.is_file().then_some(second)
}

/// A file name Immich gave us, made safe to write into a folder.
pub fn safe_file_name(name: &str) -> String {
    let base = name.rsplit(['/', '\\']).next().unwrap_or("");
    let cleaned: String = base
        .chars()
        .map(|c| if c.is_control() || c == '/' || c == '\\' { '_' } else { c })
        .collect();
    let cleaned = cleaned.trim().trim_start_matches('.').to_string();
    if cleaned.is_empty() { "photo".to_string() } else { cleaned.chars().take(200).collect() }
}

/// A folder Omamich has to make, open only to the user: it fills with
/// photos (or a diagnostics bundle naming them). One that is already there,
/// chosen and perhaps shared on purpose, is left as it is.
pub fn make_private_dir(dir: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::DirBuilderExt;
    if dir.try_exists()? {
        return Ok(());
    }
    if let Some(parent) = dir.parent() {
        std::fs::create_dir_all(parent)?;
    }
    match std::fs::DirBuilder::new().mode(0o700).create(dir) {
        Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => Ok(()),
        other => other,
    }
}

/// `name.jpg`, then `name (1).jpg`, … — the first that does not exist yet.
pub fn unique_path(dir: &Path, name: &str) -> PathBuf {
    let candidate = dir.join(name);
    if !candidate.exists() {
        return candidate;
    }
    let path = Path::new(name);
    let stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or("photo");
    let ext = path.extension().and_then(|s| s.to_str());
    for n in 1..10_000 {
        let next = match ext {
            Some(ext) => format!("{stem} ({n}).{ext}"),
            None => format!("{stem} ({n})"),
        };
        let candidate = dir.join(next);
        if !candidate.exists() {
            return candidate;
        }
    }
    dir.join(format!("{stem}-{}", crate::config::new_id()))
}

/// Move a file to the desktop trash rather than deleting it, so a mirrored
/// deletion can always be undone from the file manager.
pub fn move_to_trash(path: &Path) -> std::io::Result<PathBuf> {
    let base = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| crate::paths::home().join(".local/share"))
        .join("Trash");
    let files = base.join("files");
    let info = base.join("info");
    std::fs::create_dir_all(&files)?;
    std::fs::create_dir_all(&info)?;
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("photo").to_string();
    let target = unique_path(&files, &name);
    let target_name = target.file_name().and_then(|n| n.to_str()).unwrap_or(&name).to_string();
    let absolute = std::fs::canonicalize(path)?;
    const PATH_SET: &percent_encoding::AsciiSet =
        &percent_encoding::NON_ALPHANUMERIC.remove(b'/').remove(b'-').remove(b'_').remove(b'.').remove(b'~');
    let encoded = percent_encoding::utf8_percent_encode(&absolute.to_string_lossy(), PATH_SET).to_string();
    let stamp = chrono::Local::now().format("%Y-%m-%dT%H:%M:%S");
    std::fs::write(
        info.join(format!("{target_name}.trashinfo")),
        format!("[Trash Info]\nPath={encoded}\nDeletionDate={stamp}\n"),
    )?;
    if std::fs::rename(path, &target).is_err() {
        std::fs::copy(path, &target)?;
        std::fs::remove_file(path)?;
    }
    Ok(target)
}

/// NetworkManager's view of the active connection.
pub fn is_metered() -> bool {
    let Ok(output) = std::process::Command::new("nmcli")
        .args(["-t", "-f", "GENERAL.METERED", "dev", "show"])
        .stderr(std::process::Stdio::null())
        .output()
    else {
        return false;
    };
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .any(|l| l.trim_start_matches("GENERAL.METERED:").starts_with("yes"))
}

pub fn on_battery() -> bool {
    let Ok(entries) = std::fs::read_dir("/sys/class/power_supply") else {
        return false;
    };
    let mut has_battery = false;
    for entry in entries.flatten() {
        let dir = entry.path();
        let kind = std::fs::read_to_string(dir.join("type")).unwrap_or_default();
        match kind.trim() {
            "Mains" | "USB" => {
                if std::fs::read_to_string(dir.join("online")).unwrap_or_default().trim() == "1" {
                    return false;
                }
            }
            "Battery" => {
                let status = std::fs::read_to_string(dir.join("status")).unwrap_or_default();
                if status.trim() == "Discharging" {
                    has_battery = true;
                }
            }
            _ => {}
        }
    }
    has_battery
}

/// Inside "HH:MM"–"HH:MM", wrapping past midnight.
pub fn in_quiet_hours(start: &str, end: &str, now_minutes: u32) -> bool {
    let parse = |s: &str| -> Option<u32> {
        let (h, m) = s.split_once(':')?;
        Some(h.parse::<u32>().ok()? * 60 + m.parse::<u32>().ok()?)
    };
    let (Some(s), Some(e)) = (parse(start), parse(end)) else {
        return false;
    };
    if s == e {
        return false;
    }
    if s < e { now_minutes >= s && now_minutes < e } else { now_minutes >= s || now_minutes < e }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn folders_omamich_makes_are_private_and_chosen_ones_are_left_alone() {
        use std::os::unix::fs::PermissionsExt;
        let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
        let dir = tempfile::tempdir().unwrap();
        let made = dir.path().join("Pictures/Immich");
        make_private_dir(&made).unwrap();
        assert_eq!(mode(&made), 0o700);
        let chosen = dir.path().join("Shared");
        std::fs::create_dir(&chosen).unwrap();
        std::fs::set_permissions(&chosen, std::fs::Permissions::from_mode(0o755)).unwrap();
        make_private_dir(&chosen).unwrap();
        assert_eq!(mode(&chosen), 0o755);
    }

    fn folder() -> WatchFolder {
        WatchFolder { path: "/p".into(), ..Default::default() }
    }

    #[test]
    fn rules() {
        let f = folder();
        assert_eq!(rejection(&f, Path::new("/p/a.jpg"), 1), None);
        assert_eq!(rejection(&f, Path::new("/p/.thumbs/a.jpg"), 1), Some("hidden"));
        assert_eq!(rejection(&f, Path::new("/p/a.txt"), 1), Some("not a photo or video"));
        assert_eq!(rejection(&f, Path::new("/q/a.jpg"), 1), Some("outside the folder"));
        let limited = WatchFolder { max_file_size_mb: 1, extensions: vec!["png".into()], ..f.clone() };
        assert_eq!(rejection(&limited, Path::new("/p/a.jpg"), 1), Some("type not selected for this folder"));
        assert_eq!(rejection(&limited, Path::new("/p/a.png"), 2 * 1024 * 1024), Some("larger than this folder's limit"));
    }

    #[test]
    fn quiet_hours_wrap_midnight() {
        assert!(in_quiet_hours("22:00", "07:00", 23 * 60));
        assert!(in_quiet_hours("22:00", "07:00", 60));
        assert!(!in_quiet_hours("22:00", "07:00", 12 * 60));
        assert!(in_quiet_hours("09:00", "17:00", 10 * 60));
        assert!(!in_quiet_hours("", "", 10));
    }

    #[test]
    fn checksums() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("a.jpg");
        std::fs::write(&file, b"hello").unwrap();
        assert_eq!(sha1_hex(&file).unwrap(), "aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d");
        assert_eq!(base64_to_hex("qvTGHdzF6KLavt4PO0gs2a6pQ00=").unwrap(), "aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d");
    }

    #[test]
    fn names_are_safe_and_unique() {
        assert_eq!(safe_file_name("../../etc/passwd"), "passwd");
        assert_eq!(safe_file_name(".hidden.jpg"), "hidden.jpg");
        assert_eq!(safe_file_name(""), "photo");
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("a.jpg"), b"").unwrap();
        assert_eq!(unique_path(dir.path(), "a.jpg"), dir.path().join("a (1).jpg"));
    }

    #[test]
    fn sidecars() {
        let dir = tempfile::tempdir().unwrap();
        let photo = dir.path().join("a.jpg");
        std::fs::write(&photo, b"").unwrap();
        assert!(sidecar_for(&photo).is_none());
        std::fs::write(dir.path().join("a.xmp"), b"").unwrap();
        assert_eq!(sidecar_for(&photo).unwrap(), dir.path().join("a.xmp"));
    }
}
