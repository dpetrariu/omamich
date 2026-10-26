//! The Immich REST client. Every request goes through `send`, which picks the
//! reachable address, attaches the key and turns failures into sentences.

pub mod timeline;

use std::time::Duration;

use reqwest::{Method, StatusCode};
use serde_json::Value;
use tokio::sync::RwLock;

use crate::error::{self, Error, Result};

const PING_TIMEOUT: Duration = Duration::from_secs(4);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(60);

#[derive(Debug, Clone, Default)]
struct Conn {
    lan: Option<String>,
    wan: Option<String>,
    key: Option<String>,
    active: Option<String>,
    route: &'static str,
}

pub struct Immich {
    http: reqwest::Client,
    conn: RwLock<Conn>,
}

/// Which address answered.
#[derive(Debug, Clone, serde::Serialize)]
pub struct Route {
    pub url: String,
    pub route: &'static str,
}

impl Immich {
    pub fn new() -> Self {
        let http = reqwest::Client::builder()
            .user_agent(concat!("omamich/", env!("CARGO_PKG_VERSION")))
            .connect_timeout(Duration::from_secs(8))
            // Immich (Node) closes an idle connection after 5 s; reusing one
            // it has just closed fails a request with "error sending request".
            .pool_idle_timeout(Duration::from_secs(4))
            .build()
            .expect("http client");
        Self { http, conn: RwLock::new(Conn::default()) }
    }

    pub fn http(&self) -> &reqwest::Client {
        &self.http
    }

    pub async fn configure(&self, lan: Option<String>, wan: Option<String>, key: Option<String>) {
        let mut conn = self.conn.write().await;
        let changed = conn.lan != lan || conn.wan != wan || conn.key != key;
        conn.lan = lan.filter(|s| !s.is_empty());
        conn.wan = wan.filter(|s| !s.is_empty());
        conn.key = key.filter(|s| !s.is_empty());
        if changed {
            conn.active = None;
        }
    }

    pub async fn set_urls(&self, lan: Option<String>, wan: Option<String>) {
        let mut conn = self.conn.write().await;
        conn.lan = lan.filter(|s| !s.is_empty());
        conn.wan = wan.filter(|s| !s.is_empty());
        conn.active = None;
    }

    pub async fn set_key(&self, key: Option<String>) {
        let mut conn = self.conn.write().await;
        conn.key = key.filter(|s| !s.is_empty());
        conn.active = None;
    }

    pub async fn has_key(&self) -> bool {
        self.conn.read().await.key.is_some()
    }

    pub async fn is_configured(&self) -> bool {
        let conn = self.conn.read().await;
        conn.key.is_some() && (conn.lan.is_some() || conn.wan.is_some())
    }

    pub async fn route(&self) -> Option<Route> {
        let conn = self.conn.read().await;
        conn.active.clone().map(|url| Route { url, route: conn.route })
    }

    /// Forget the address that answered last, so the next request looks again.
    pub async fn reset_route(&self) {
        self.conn.write().await.active = None;
    }

    async fn ping(&self, base: &str) -> bool {
        let url = format!("{base}/api/server/ping");
        match self.http.get(&url).timeout(PING_TIMEOUT).send().await {
            Ok(resp) if resp.status().is_success() => resp
                .json::<Value>()
                .await
                .map(|v| v.get("res").and_then(|r| r.as_str()) == Some("pong"))
                .unwrap_or(false),
            _ => false,
        }
    }

    /// The base address and key to use now. Home first, then away.
    pub async fn base(&self) -> Result<(String, String)> {
        {
            let conn = self.conn.read().await;
            let Some(key) = conn.key.clone() else {
                return Err(Error::not_configured());
            };
            if let Some(active) = conn.active.clone() {
                return Ok((active, key));
            }
            if conn.lan.is_none() && conn.wan.is_none() {
                return Err(Error::not_configured());
            }
        }
        let (lan, wan, key) = {
            let conn = self.conn.read().await;
            (conn.lan.clone(), conn.wan.clone(), conn.key.clone().unwrap_or_default())
        };
        let candidates = [(lan, "lan"), (wan, "wan")];
        for (candidate, route) in candidates {
            if let Some(url) = candidate {
                if self.ping(&url).await {
                    let mut conn = self.conn.write().await;
                    conn.active = Some(url.clone());
                    conn.route = route;
                    return Ok((url, key));
                }
            }
        }
        Err(Error::new(error::NETWORK, "Could not reach the Immich server"))
    }

    pub async fn get(&self, path: &str) -> Result<Value> {
        self.send(Method::GET, path, None).await
    }

    pub async fn post(&self, path: &str, body: Value) -> Result<Value> {
        self.send(Method::POST, path, Some(body)).await
    }

    pub async fn put(&self, path: &str, body: Value) -> Result<Value> {
        self.send(Method::PUT, path, Some(body)).await
    }

    pub async fn patch(&self, path: &str, body: Value) -> Result<Value> {
        self.send(Method::PATCH, path, Some(body)).await
    }

    pub async fn delete(&self, path: &str, body: Option<Value>) -> Result<Value> {
        self.send(Method::DELETE, path, body).await
    }

    pub async fn send(&self, method: Method, path: &str, body: Option<Value>) -> Result<Value> {
        let (base, key) = self.base().await?;
        let mut request = self
            .http
            .request(method, format!("{base}{path}"))
            .header("x-api-key", key)
            .header("Accept", "application/json")
            .timeout(REQUEST_TIMEOUT);
        if let Some(body) = body {
            request = request.json(&body);
        }
        let response = match request.send().await {
            Ok(response) => response,
            Err(err) => {
                self.reset_route().await;
                return Err(network_error(&err));
            }
        };
        read_json(response).await
    }

    /// A raw response for media, keeping the server's headers. `extra` carries
    /// Range and conditional headers through unchanged.
    pub async fn raw(&self, path: &str, extra: &[(&str, String)]) -> Result<reqwest::Response> {
        let (base, key) = self.base().await?;
        let mut request = self.http.get(format!("{base}{path}")).header("x-api-key", key);
        for (name, value) in extra {
            request = request.header(*name, value);
        }
        match request.send().await {
            Ok(response) if response.status().is_success() || response.status() == StatusCode::NOT_MODIFIED => {
                Ok(response)
            }
            Ok(response) => Err(status_error(response.status(), &response.text().await.unwrap_or_default())),
            Err(err) => {
                self.reset_route().await;
                Err(network_error(&err))
            }
        }
    }

    /// Check an address and key without touching the saved configuration.
    pub async fn probe(&self, url: &str, key: &str) -> Result<Value> {
        if !self.ping(url).await {
            return Err(Error::new(
                error::NETWORK,
                "No Immich server answered at that address",
            ));
        }
        let me = self
            .http
            .get(format!("{url}/api/users/me"))
            .header("x-api-key", key)
            .timeout(Duration::from_secs(15))
            .send()
            .await
            .map_err(|e| network_error(&e))?;
        let me = read_json(me).await?;
        let version = self
            .http
            .get(format!("{url}/api/server/version"))
            .timeout(Duration::from_secs(15))
            .send()
            .await
            .map_err(|e| network_error(&e))?;
        let version = read_json(version).await.unwrap_or(Value::Null);
        Ok(serde_json::json!({ "user": slim_user(&me), "version": version_text(&version) }))
    }
}

pub fn slim_user(me: &Value) -> Value {
    serde_json::json!({
        "id": me.get("id").cloned().unwrap_or(Value::Null),
        "name": me.get("name").cloned().unwrap_or(Value::Null),
        "email": me.get("email").cloned().unwrap_or(Value::Null),
        "isAdmin": me.get("isAdmin").cloned().unwrap_or(Value::Bool(false)),
        "avatarColor": me.get("avatarColor").cloned().unwrap_or(Value::Null),
        "quotaUsageInBytes": me.get("quotaUsageInBytes").cloned().unwrap_or(Value::Null),
        "quotaSizeInBytes": me.get("quotaSizeInBytes").cloned().unwrap_or(Value::Null),
    })
}

pub fn version_text(version: &Value) -> String {
    match (
        version.get("major").and_then(|v| v.as_u64()),
        version.get("minor").and_then(|v| v.as_u64()),
        version.get("patch").and_then(|v| v.as_u64()),
    ) {
        (Some(a), Some(b), Some(c)) => format!("{a}.{b}.{c}"),
        _ => String::new(),
    }
}

pub async fn read_json(response: reqwest::Response) -> Result<Value> {
    let status = response.status();
    let text = response.text().await.map_err(|e| network_error(&e))?;
    if !status.is_success() {
        return Err(status_error(status, &text));
    }
    if text.trim().is_empty() {
        return Ok(Value::Null);
    }
    serde_json::from_str(&text).map_err(|_| Error::new(error::SERVER, "Immich sent a response Omamich could not read"))
}

fn server_message(body: &str) -> Option<String> {
    let value: Value = serde_json::from_str(body).ok()?;
    match value.get("message")? {
        Value::String(s) => Some(s.clone()),
        Value::Array(items) => Some(
            items.iter().filter_map(|v| v.as_str()).collect::<Vec<_>>().join("; "),
        ),
        _ => None,
    }
}

pub fn status_error(status: StatusCode, body: &str) -> Error {
    let detail = server_message(body);
    match status {
        StatusCode::UNAUTHORIZED => Error::new(
            error::UNAUTHORIZED,
            "Immich rejected the API key. Create a new one in Immich and paste it in Settings",
        ),
        StatusCode::FORBIDDEN => Error::new(
            error::FORBIDDEN,
            match detail {
                Some(d) if d.to_lowercase().contains("permission") => {
                    format!("The API key is not allowed to do this ({d})")
                }
                Some(d) => d,
                None => "The API key is not allowed to do this".to_string(),
            },
        ),
        StatusCode::NOT_FOUND => Error::new(error::NOT_FOUND, detail.unwrap_or_else(|| "Not found on the server".into())),
        StatusCode::PAYLOAD_TOO_LARGE => Error::new(error::SERVER, "Immich rejected the file as too large"),
        s if s.is_client_error() => Error::new(
            error::INVALID_PARAMS,
            detail.unwrap_or_else(|| format!("Immich refused the request ({})", s.as_u16())),
        ),
        s => Error::new(
            error::SERVER,
            format!("Immich had a problem ({}){}", s.as_u16(), detail.map(|d| format!(": {d}")).unwrap_or_default()),
        ),
    }
}

pub fn network_error(err: &reqwest::Error) -> Error {
    if err.is_timeout() {
        Error::new(error::NETWORK, "The Immich server took too long to answer")
    } else if err.is_connect() {
        Error::new(error::NETWORK, "Could not reach the Immich server")
    } else {
        Error::new(error::NETWORK, format!("Network problem: {err}"))
    }
}

/// Percent-encode one query value.
pub fn q(value: &str) -> String {
    percent_encoding::utf8_percent_encode(value, percent_encoding::NON_ALPHANUMERIC).to_string()
}

/// Immich ids are UUIDs; anything else never reaches a URL path.
pub fn valid_id(id: &str) -> bool {
    id.len() == 36
        && id.chars().enumerate().all(|(i, c)| match i {
            8 | 13 | 18 | 23 => c == '-',
            _ => c.is_ascii_hexdigit(),
        })
}

pub fn require_id(id: &str) -> Result<&str> {
    if valid_id(id) { Ok(id) } else { Err(Error::invalid("Not a valid Immich id")) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_ids() {
        assert!(valid_id("95d338b7-e7d1-4a25-89e5-869b16fca112"));
        assert!(!valid_id("../../etc/passwd"));
        assert!(!valid_id("95d338b7e7d14a2589e5869b16fca1120000"));
    }

    #[test]
    fn explains_statuses() {
        let e = status_error(StatusCode::FORBIDDEN, r#"{"message":"Missing required permission: asset.update"}"#);
        assert_eq!(e.code, error::FORBIDDEN);
        assert!(e.message.contains("asset.update"));
        assert_eq!(status_error(StatusCode::UNAUTHORIZED, "").code, error::UNAUTHORIZED);
    }
}
