use std::sync::{Arc, RwLock};

use crate::config::Settings;
use crate::immich::Immich;
use crate::media::Media;
use crate::paths::Paths;
use crate::rpc::Notifier;
use crate::sync::Engine;
use crate::sync::index::Index;

/// Everything a request handler can reach.
pub struct App {
    pub paths: Paths,
    pub settings: RwLock<Settings>,
    pub immich: Arc<Immich>,
    pub media: Arc<Media>,
    pub notifier: Notifier,
    pub sync: Arc<Engine>,
    pub key_storage: RwLock<&'static str>,
}

impl App {
    pub async fn start(paths: Paths, notifier: Notifier) -> std::io::Result<Arc<App>> {
        paths.ensure()?;
        let settings = Settings::load(&paths);
        let immich = Arc::new(Immich::new());
        let key = crate::secrets::load(&paths).await;
        let key_storage = if key.is_some() { "keyring" } else { "" };
        immich
            .configure(
                settings.server_enabled.then(|| settings.server_url.clone()),
                settings.external_enabled.then(|| settings.external_url.clone()),
                key,
            )
            .await;
        let media = Media::start(immich.clone(), paths.media_cache()).await?;
        let index = Arc::new(
            Index::open(&paths.sync_db()).map_err(|e| std::io::Error::other(e.message))?,
        );
        let sync = Engine::start(immich.clone(), index, notifier.clone(), settings.sync.clone());
        let app = Arc::new(App {
            paths,
            settings: RwLock::new(settings.clone()),
            immich,
            media,
            notifier,
            sync,
            key_storage: RwLock::new(key_storage),
        });
        app.sync.reload(settings.sync);
        // Keep the thumbnail cache under its cap.
        let pruner = app.clone();
        tokio::spawn(async move {
            loop {
                let cap = pruner.settings.read().unwrap().cache_cap_mb * 1024 * 1024;
                let media = pruner.media.clone();
                let _ = tokio::task::spawn_blocking(move || media.prune(cap)).await;
                tokio::time::sleep(std::time::Duration::from_secs(900)).await;
            }
        });
        Ok(app)
    }

    pub fn settings(&self) -> Settings {
        self.settings.read().unwrap().clone()
    }

    /// Point the client at the saved addresses again.
    pub async fn reconnect(&self) {
        let settings = self.settings();
        self.immich
            .set_urls(
                settings.server_enabled.then(|| settings.server_url.clone()),
                settings.external_enabled.then(|| settings.external_url.clone()),
            )
            .await;
        self.notifier.notify("server.changed", serde_json::json!({}));
    }
}
