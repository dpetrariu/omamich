# Omamich architecture

Omamich follows Omamail's split: QML owns presentation and interaction, a Rust process owns the network, credentials, files and sync. They talk over newline-delimited JSON-RPC 2.0 on stdin/stdout.

## Shell entry points (`manifest.json`)

- `ui/Service.qml` — constructed by the shell at startup and kept for its life. Starts `bin/omamich serve`, holds settings, server overview, statistics, sync status and the shared lists (albums, people, places, tags), builds media URLs, and sends desktop notifications. Folder sync therefore runs whether or not the window is open.
- `ui/BarWidget.qml` — the bar icon. Reads the service, pushes the widget's settings into it, and toggles the window.
- `ui/App.qml` — the window. Owns where you are (section, page stack, open photo), the key context, and what every photo action does. Views draw and report; App decides.

## Backend (`src/`)

| Module | Owns |
| --- | --- |
| `rpc.rs` | Frame reading, concurrent dispatch, one writer for stdout, notifications (`sync.changed`, `server.changed`). |
| `methods.rs` | The method table. Unknown methods are refused. Settings, auth, sync control. |
| `library.rs` | Library requests, trimmed to what the window shows. Every id is validated as a UUID before it reaches a URL. |
| `immich/` | The HTTP client: home address first, away address as fallback, readable errors (401 → key rejected, 403 → which permission is missing). `timeline.rs` turns Immich's columnar month buckets into rows. |
| `media.rs` | A 127.0.0.1 HTTP server that QML `Image` and `MediaPlayer` load from. Paths start with a random per-process token; the API key never reaches QML. Thumbnails, previews and faces are cached on disk under a size cap (LRU pruning); video and originals stream with Range pass-through. |
| `secrets.rs` | The API key in the Secret Service keyring (oo7), a 0600 file only when no keyring answers. Reads Mimick's key for one-click migration. |
| `config.rs`, `paths.rs` | `~/.config/omamich/config.json` (0600, written atomically), XDG directories. |
| `sync/` | Folder sync: `index.rs` (SQLite: path, size, mtime, SHA-1, asset id, state), `files.rs` (rules, hashing, sidecars, desktop trash, metered/battery checks, quiet hours), `remote.rs` (bulk duplicate check, streamed multipart upload with progress, albums, downloads), `mod.rs` (watcher with debounce, scans, queue, workers, retries with backoff, album download, deletion mirroring, status). |

### Sync safety rules

- Nothing is deleted unless the folder's mirror option is on, and both are off by default.
- A local deletion waits ten seconds, then trashes the Immich asset only if the file is still gone and no other uploading folder holds the same photo (so a move is not a delete). Copies a download folder made from the album do not count as "elsewhere".
- An album removal only counts when the previous pass saw the photo in the album; the first pass after start never deletes. Local files go to the desktop trash, never `unlink`.
- Album lookup and creation is serialised, so concurrent uploads never create the same album twice.

## Window (`ui/`)

- `components/Timeline.qml` — a ListView of rows (month header, day header, justified photo row, or one tall placeholder per unloaded month). Placeholders load their month when created, then are swapped for real rows in place. The keyboard cursor and the selection are kept separately from hover. Also serves paged results (search, places, folders) through a `pager` function.
- `lib/Layout.js` — the justified-row arithmetic, pure and tested.
- `keys/Keymap.js` + `components/KeyRouter.qml` — one table of every binding, by context (`grid`, `tiles`, `viewer`, `search`, `page`, `dialog`). Text-entry contexts bind no bare letters. The shortcut sheet and status-bar hints are drawn from the same table.
- `components/Theme.qml` — every colour and size comes from the active Omarchy theme (`qs.Commons`), created once in App and passed down.
- Views in `views/` expose `kind` (`grid` or `tiles`), `grid` (their Timeline, if any), `typing`/`isForm` (so App can park the keyboard), `statusText` and `reload()`.

## Tests

- `cargo test` — config, paths, ids, timeline conversion, media routing, sync rules, index.
- `tests/sync_e2e.py` — real backend against `tests/mock_immich.py`: uploads into an album, watcher, duplicates, album download, deletion mirroring including the "moved, not deleted" case, hand-picked upload.
- `tests/library_e2e.py` — every library write the window can make, plus input validation.
- `tests/ui_logic.js` — layout, formatting, keymap conflicts, thumbhash and wire parsing.
