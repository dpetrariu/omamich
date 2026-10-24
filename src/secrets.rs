use std::time::Duration;

use crate::error::{Error, KEYRING, Result};
use crate::paths::{self, Paths};

const SERVICE: &str = "omamich";
const ACCOUNT: &str = "api_key";
const LABEL: &str = "Omamich Immich API key";
const TIMEOUT: Duration = Duration::from_secs(8);

/// Where the key ended up when it was saved.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Storage {
    Keyring,
    File,
}

impl Storage {
    pub fn as_str(self) -> &'static str {
        match self {
            Storage::Keyring => "keyring",
            Storage::File => "file",
        }
    }
}

async fn keyring() -> Result<oo7::Keyring> {
    match tokio::time::timeout(TIMEOUT, oo7::Keyring::new()).await {
        Ok(Ok(keyring)) => Ok(keyring),
        Ok(Err(err)) => Err(Error::new(KEYRING, format!("The keyring is unavailable: {err}"))),
        Err(_) => Err(Error::new(KEYRING, "The keyring did not answer")),
    }
}

async fn lookup(service: &str) -> Result<Option<String>> {
    let keyring = keyring().await?;
    let _ = tokio::time::timeout(TIMEOUT, keyring.unlock()).await;
    let attributes = vec![("service", service), ("account", ACCOUNT)];
    let items = tokio::time::timeout(TIMEOUT, keyring.search_items(&attributes))
        .await
        .map_err(|_| Error::new(KEYRING, "The keyring did not answer"))?
        .map_err(|err| Error::new(KEYRING, format!("Keyring search failed: {err}")))?;
    for item in items {
        if let Ok(secret) = item.secret().await {
            let key = clean_key(&String::from_utf8_lossy(&secret));
            if !key.is_empty() {
                return Ok(Some(key));
            }
        }
    }
    Ok(None)
}

/// A key pasted with a stray space or newline is still the key.
pub fn clean_key(raw: &str) -> String {
    raw.chars().filter(|c| !c.is_whitespace()).collect()
}

pub fn valid_key_shape(key: &str) -> bool {
    !key.is_empty()
        && key.len() <= 256
        && key.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '=' | '+' | '/' | '.'))
}

/// A test or second profile (OMAMICH_HOME) never touches the real keyring.
fn sandboxed() -> bool {
    std::env::var_os("OMAMICH_HOME").is_some()
}

pub async fn load(paths: &Paths) -> Option<String> {
    let found = if sandboxed() { Ok(None) } else { lookup(SERVICE).await };
    match found {
        Ok(Some(key)) => return Some(key),
        Ok(None) => {}
        Err(err) => eprintln!("omamich: {err}"),
    }
    std::fs::read_to_string(paths.key_fallback_file())
        .ok()
        .map(|text| clean_key(&text))
        .filter(|key| !key.is_empty())
}

pub async fn store(paths: &Paths, key: &str) -> Result<Storage> {
    if sandboxed() {
        paths::write_private(&paths.key_fallback_file(), key.as_bytes())?;
        return Ok(Storage::File);
    }
    let saved = async {
        let keyring = keyring().await?;
        let attributes = vec![("service", SERVICE), ("account", ACCOUNT)];
        tokio::time::timeout(TIMEOUT, keyring.create_item(LABEL, &attributes, key.as_bytes(), true))
            .await
            .map_err(|_| Error::new(KEYRING, "The keyring did not answer"))?
            .map_err(|err| Error::new(KEYRING, format!("Saving to the keyring failed: {err}")))
    }
    .await;
    match saved {
        Ok(()) => {
            let _ = std::fs::remove_file(paths.key_fallback_file());
            Ok(Storage::Keyring)
        }
        Err(err) => {
            eprintln!("omamich: {err}; keeping the key in a private file instead");
            paths::write_private(&paths.key_fallback_file(), key.as_bytes())?;
            Ok(Storage::File)
        }
    }
}

pub async fn delete(paths: &Paths) {
    if sandboxed() {
        let _ = std::fs::remove_file(paths.key_fallback_file());
        return;
    }
    if let Ok(keyring) = keyring().await {
        let attributes = vec![("service", SERVICE), ("account", ACCOUNT)];
        let _ = tokio::time::timeout(TIMEOUT, keyring.delete(&attributes)).await;
    }
    let _ = std::fs::remove_file(paths.key_fallback_file());
}

/// The key and server Mimick already uses, so moving over is one click.
pub async fn mimick_settings() -> Result<(String, String, Option<String>)> {
    let config = paths::home().join(".config/mimick/config.json");
    let text = std::fs::read_to_string(&config)
        .map_err(|_| Error::invalid("Mimick is not set up on this computer"))?;
    let value: serde_json::Value = serde_json::from_str(&text)?;
    let pick = |url: &str, enabled: &str| -> String {
        let on = value.get(enabled).and_then(|v| v.as_bool()).unwrap_or(true);
        if !on {
            return String::new();
        }
        value.get(url).and_then(|v| v.as_str()).unwrap_or("").to_string()
    };
    let internal = pick("internal_url", "internal_url_enabled");
    let external = pick("external_url", "external_url_enabled");
    let mut key = lookup("mimick").await.unwrap_or(None);
    if key.is_none() {
        // Mimick's own fallback file keeps the key base64-encoded beside its config.
        for name in [".api_key.key"] {
            if let Ok(raw) = std::fs::read_to_string(paths::home().join(".config/mimick").join(name)) {
                let decoded = decode_base64(raw.trim()).unwrap_or_else(|| raw.trim().to_string());
                let cleaned = clean_key(&decoded);
                if !cleaned.is_empty() {
                    key = Some(cleaned);
                    break;
                }
            }
        }
    }
    Ok((internal, external, key))
}

fn decode_base64(text: &str) -> Option<String> {
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
    String::from_utf8(out).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cleans_pasted_keys() {
        assert_eq!(clean_key(" abc\n def "), "abcdef");
        assert!(valid_key_shape("Abc123_-xyz"));
        assert!(!valid_key_shape("bad key"));
        assert!(!valid_key_shape(""));
    }

    #[test]
    fn decodes_base64() {
        assert_eq!(decode_base64("aGVsbG8=").as_deref(), Some("hello"));
        assert_eq!(decode_base64("!!"), None);
    }
}
