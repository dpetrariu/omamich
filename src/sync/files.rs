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

/// Open a file of a watched folder to read, walking down from `root` one
/// directory at a time and refusing a symlink at every step, not only the
/// last. A path that merely starts with the folder is not enough: someone
/// writing to a shared folder can swap a parent directory for a link to a
/// private one after the file was queued, and the same name would then be
/// read from outside the folder. `root` itself is followed, because the
/// owner chose it. Opening without blocking means a FIFO cannot stall sync.
pub fn open_beneath(root: &Path, path: &Path) -> std::io::Result<std::fs::File> {
    use std::ffi::CString;
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::os::unix::ffi::OsStrExt;
    use std::path::Component;

    let outside = || std::io::Error::other("outside the folder");
    let relative = path.strip_prefix(root).map_err(|_| outside())?;
    let mut parts: Vec<&std::ffi::OsStr> = Vec::new();
    for component in relative.components() {
        match component {
            Component::Normal(part) => parts.push(part),
            _ => return Err(outside()),
        }
    }
    let Some((name, dirs)) = parts.split_last() else {
        return Err(outside());
    };
    let open_at = |dir: Option<&OwnedFd>, name: &std::ffi::OsStr, flags: libc::c_int| -> std::io::Result<OwnedFd> {
        let name = CString::new(name.as_bytes()).map_err(|_| outside())?;
        let at = dir.map(|d| d.as_raw_fd()).unwrap_or(libc::AT_FDCWD);
        // SAFETY: a valid NUL-terminated name and a directory fd we own.
        let fd = unsafe { libc::openat(at, name.as_ptr(), flags | libc::O_CLOEXEC) };
        if fd < 0 {
            return Err(std::io::Error::last_os_error());
        }
        // SAFETY: openat just returned this fd and nothing else holds it.
        Ok(unsafe { OwnedFd::from_raw_fd(fd) })
    };
    let mut dir = open_at(None, root.as_os_str(), libc::O_RDONLY | libc::O_DIRECTORY)?;
    for part in dirs {
        dir = open_at(Some(&dir), part, libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW)?;
    }
    let file = std::fs::File::from(open_at(Some(&dir), name, libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK)?);
    if !file.metadata()?.is_file() {
        return Err(std::io::Error::other("not a regular file"));
    }
    Ok(file)
}

/// Open a file to upload or hash: beneath its watched folder when it has
/// one. A file the person picked was resolved to its real path when it was
/// queued, so it is walked from `/` with no link allowed anywhere: a parent
/// swapped for a link while it waited cannot redirect it either.
pub fn open_source(root: Option<&Path>, path: &Path) -> std::io::Result<std::fs::File> {
    open_beneath(root.unwrap_or(Path::new("/")), path)
}

/// Size and times of a file to upload, read from the file `open_source`
/// reaches, never from whatever a swapped parent now points to.
pub fn source_metadata(root: Option<&Path>, path: &Path) -> std::io::Result<std::fs::Metadata> {
    open_source(root, path)?.metadata()
}

/// Whether `path` itself is a regular file (a symlink is not).
pub fn is_regular(path: &Path) -> bool {
    std::fs::symlink_metadata(path).map(|m| m.is_file()).unwrap_or(false)
}

/// SHA-1, the hash Immich uses to recognise a file it already has. `root`
/// is the watched folder the file belongs to, if any (see `open_source`).
pub fn sha1_hex(root: Option<&Path>, path: &Path) -> std::io::Result<String> {
    let mut file = open_source(root, path)?;
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
    if is_regular(&first) {
        return Some(first);
    }
    let second = path.with_extension("xmp");
    is_regular(&second).then_some(second)
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
    // The trash is the user's alone (the spec asks for 0700): the names in it,
    // and the paths in its .trashinfo files, say what was there.
    {
        use std::os::unix::fs::DirBuilderExt;
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&files)?;
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&info)?;
    }
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("photo").to_string();
    let target = unique_path(&files, &name);
    let target_name = target.file_name().and_then(|n| n.to_str()).unwrap_or(&name).to_string();
    let absolute = std::fs::canonicalize(path)?;
    const PATH_SET: &percent_encoding::AsciiSet =
        &percent_encoding::NON_ALPHANUMERIC.remove(b'/').remove(b'-').remove(b'_').remove(b'.').remove(b'~');
    let encoded = percent_encoding::utf8_percent_encode(&absolute.to_string_lossy(), PATH_SET).to_string();
    let stamp = chrono::Local::now().format("%Y-%m-%dT%H:%M:%S");
    {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(info.join(format!("{target_name}.trashinfo")))?;
        f.write_all(format!("[Trash Info]\nPath={encoded}\nDeletionDate={stamp}\n").as_bytes())?;
    }
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
    fn symlinks_are_never_read_as_photos() {
        let dir = tempfile::tempdir().unwrap();
        let secret = dir.path().join("id_ed25519");
        std::fs::write(&secret, b"private key").unwrap();
        let link = dir.path().join("leak.jpg");
        std::os::unix::fs::symlink(&secret, &link).unwrap();
        assert!(open_source(None, &link).is_err() && sha1_hex(None, &link).is_err());
        assert!(!is_regular(&link) && is_regular(&secret));
        std::os::unix::fs::symlink(&secret, dir.path().join("photo.jpg.xmp")).unwrap();
        assert_eq!(sidecar_for(&dir.path().join("photo.jpg")), None);
    }

    #[test]
    fn a_parent_swapped_for_a_symlink_is_not_followed() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("watched");
        let private = dir.path().join("private");
        std::fs::create_dir_all(root.join("drop")).unwrap();
        std::fs::create_dir_all(&private).unwrap();
        std::fs::write(root.join("drop/x.jpg"), b"shared").unwrap();
        std::fs::write(private.join("x.jpg"), b"private").unwrap();
        let path = root.join("drop/x.jpg");
        assert!(open_beneath(&root, &path).is_ok());

        // The path still starts with the folder, but drop/ now leads outside.
        std::fs::rename(root.join("drop"), dir.path().join("moved")).unwrap();
        std::os::unix::fs::symlink(&private, root.join("drop")).unwrap();
        assert!(std::fs::File::open(&path).is_ok(), "a plain open follows the parent link");
        assert!(open_beneath(&root, &path).is_err());
        assert!(sha1_hex(Some(&root), &path).is_err());
        assert!(open_source(Some(&root), &path).is_err());
        assert!(source_metadata(Some(&root), &path).is_err());

        // A hand-picked file is queued by its real path and opened from `/`
        // with no link allowed, so the same swap cannot redirect it either.
        let real = std::fs::canonicalize(dir.path().join("moved/x.jpg")).unwrap();
        assert!(open_source(None, &real).is_ok());
        assert!(open_source(None, &path).is_err());
    }

    #[test]
    fn open_beneath_stays_inside_the_folder() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("watched");
        std::fs::create_dir_all(root.join("a/b")).unwrap();
        std::fs::write(root.join("a/b/photo.jpg"), b"ok").unwrap();
        std::fs::write(dir.path().join("outside.jpg"), b"no").unwrap();
        assert!(open_beneath(&root, &root.join("a/b/photo.jpg")).is_ok());
        assert!(open_beneath(&root, &root.join("a/../../outside.jpg")).is_err());
        assert!(open_beneath(&root, &dir.path().join("outside.jpg")).is_err());
        assert!(open_beneath(&root, &root).is_err());
        assert!(open_beneath(&root, &root.join("a")).is_err(), "a directory is not a photo");

        // The folder the person chose may itself be reached through a link.
        let alias = dir.path().join("alias");
        std::os::unix::fs::symlink(&root, &alias).unwrap();
        assert!(open_beneath(&alias, &alias.join("a/b/photo.jpg")).is_ok());

        // A FIFO named like a photo is refused instead of blocking the open.
        let fifo = root.join("a/pipe.jpg");
        let name = std::ffi::CString::new(fifo.to_str().unwrap()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
        assert!(open_beneath(&root, &fifo).is_err());
    }

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
    fn the_trash_is_private() {
        use std::os::unix::fs::PermissionsExt;
        let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
        let dir = tempfile::tempdir().unwrap();
        unsafe { std::env::set_var("XDG_DATA_HOME", dir.path().join("data")) };
        let photo = dir.path().join("a.jpg");
        std::fs::write(&photo, b"x").unwrap();
        let moved = move_to_trash(&photo).unwrap();
        let trash = dir.path().join("data/Trash");
        assert!(moved.exists() && !photo.exists());
        assert_eq!((mode(&trash), mode(&trash.join("files")), mode(&trash.join("info"))), (0o700, 0o700, 0o700));
        assert_eq!(mode(&trash.join("info/a.jpg.trashinfo")), 0o600);
    }

    #[test]
    fn checksums() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("a.jpg");
        std::fs::write(&file, b"hello").unwrap();
        assert_eq!(sha1_hex(None, &file).unwrap(), "aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d");
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
