# Omamich

Your [Immich](https://immich.app) photo library in a native Omarchy window, plus Mimick-style folder sync. Omamich follows the active Omarchy theme, is keyboard-first, and lives in the shell like [Omamail](https://github.com/huacnlee/omamail): a service that keeps running, a bar icon, and a window you summon.

## What it does

- **Timeline** of the whole library, month by month, in justified rows with day headers. Months load as they come near the screen; a scrubber on the right jumps through the years. Libraries of 100,000+ photos scroll the same as small ones.
- **Viewer** with zoom and pan (full size loads when you zoom in), video playback, live photos, slideshow, rating, and a details panel: date, file, camera and lens, place with a map link, people, albums, tags, description.
- **People** (rename, birthday, favourite, hide, merge, key photo: right-click one of their photos). In a photo's details, point at a face to see its frame on the photo (Shift+F frames them all) and click it to change who it is: only that face moves, to someone else or a new person, with Undo, **Places**, **Explore** (people, places, your most used tags, search ideas), **Albums** (create, rename, describe, sort, cover, share with people as viewer or editor, public links, delete), **Partners** (share your library, show a partner's photos in your timeline), **Favourites**, **Tags** (a tree with photo counts; `Trips/2024` nests under `Trips`), **Folders** (the server's import folders), **Archive** and **Trash** (restore, empty). Pages turned off in your Immich account settings are hidden.
- **Search**: smart (CLIP), file name, description and text-in-photo (OCR), filtered by person, place, camera, dates, photos or videos, favourites and not-in-album, and sorted by relevance, date, name or type. Prefixes work in the search field: `file:IMG_2041`, `ocr:receipt`, `desc:holiday`. Enter in an empty field filters the whole library.
- **Actions** on a photo or a selection: favourite, archive, trash, delete permanently, add to album, tag, shared link, edit the date taken, download the original, or drag photos out of the window into a file manager. Undo for archive and trash.
- **Folder sync** like Mimick: watch folders, upload new photos and videos, skip what Immich already has (SHA-1 check), put each folder into an album or each subfolder into its own album, download an album into a folder, or both ways. Optional deletion mirroring in either direction (local deletes go to the Immich trash, album removals go to the desktop trash), with guards against unmounted drives and mass deletions. Pauses on metered connections, on battery and during quiet hours. Failed files can be retried or dismissed one by one; a diagnostics bundle leaves out everything private.
- **Uploading by hand** goes through a staging page: preview the files, see which Immich already has, pick the library, an album or a new album. Start it from the upload button, by dropping files on the window, or with "Open with → Upload to Immich" in the file manager.
- **On this computer**: the synced folders as files, each marked in Immich, waiting, only here, failed or skipped; sortable by sync state, viewable offline.
- **Back and Forward** through the pages you visited (Alt+Left/Right, mouse buttons), and a phone-width layout with tabs at the bottom.
- **Bar icon** with a dot while sync works and the urgent colour when it needs attention; desktop notifications for sync failures (or every batch).

## Install

You need [Omarchy](https://omarchy.org) 4 or later (Omamich is a plugin for its Quickshell-based shell) and an [Immich](https://immich.app) server. Omamich is built from source on your computer, so it runs on x86_64 and ARM alike; the installer fetches what it needs to build (a C compiler, and Rust through mise).

```bash
curl -fsSL https://raw.githubusercontent.com/dpetrariu/omamich/main/install.sh | bash
```

It downloads Omamich into `~/.local/share/omamich-plugin`, fetches the prebuilt backend for your machine (x86_64 or ARM; checked against the release checksums), adds the plugin to Omarchy with its bar icon and an "Upload to Immich" entry for your file manager, and restarts the shell. If no prebuilt backend fits, it builds one instead, installing a C compiler and Rust if needed (pacman may ask for your password). `--build` always builds from source.

Already have Omarchy's plugin manager in mind? `omarchy plugin add https://github.com/dpetrariu/omamich.git --enable` works too: the first time the window opens, Omamich downloads its backend by itself. The installer additionally sets up the file-manager entry.

Prefer to look first? Clone it and run the same script from the checkout, which then installs from that folder:

```bash
git clone https://github.com/dpetrariu/omamich.git
cd omamich
./install.sh
```

### First start

Click the photos icon in the bar. Enter your Immich address (for example `http://192.168.1.10:2283` or `https://photos.example.com`) and an API key: in Immich, click your profile picture → **Account Settings** → **API Keys** → **New API Key**. If [Mimick](https://github.com/nicx17/mimick) is set up on the computer, **Use Mimick's** takes over its server and key in one click. The key is stored in your keyring.

To open Omamich from the keyboard, add a binding to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + SHIFT + I", "Omamich", "omarchy shell shell toggle omamich '{}'")
```

Folder sync starts switched off; turn it on and add folders under **Folder sync**.

### Update

Run the installer again (the `curl` line, or `./install.sh` in your checkout). It pulls the latest code, fetches the matching backend and restarts the shell. If you installed with `omarchy plugin add`, `omarchy plugin update omamich` works as well; the new backend is downloaded the next time the window opens.

### Uninstall

```bash
~/.local/share/omamich-plugin/scripts/uninstall.sh          # keeps your settings
~/.local/share/omamich-plugin/scripts/uninstall.sh --purge  # also removes settings, cache and the saved key
```

Use the path of your checkout if you installed from one. Nothing in your Immich library is touched either way.

### API key permissions

`all` makes every feature work. For a read-only viewer, `user.read`, `asset.read`, `asset.view`, `asset.download`, `album.read`, `person.read`, `tag.read`, `userPreference.read`, `server.about` and `asset.statistics` are enough. Folder sync additionally needs `asset.upload`, `asset.update`, `album.create` and `albumAsset.create`. An action the key may not do says so instead of failing silently.

## Keys

Press `?` in the window for the full sheet. The essentials: `h j k l` move, `enter` view, `esc` back, `space` select, `f` favourite, `a` archive, `d` trash, `Shift+A` add to album, `t` tag, `s` share, `Shift+D` download, `i` details, `/` search, `Alt+1…0` sidebar sections, `Ctrl+,` settings, `Ctrl+Y` folder sync.

Scripts and keybindings can move around (never change anything) over IPC: `omarchy-shell shell call omamich navigate next`, `… navigate go:people`, `… navigate search:sunset`.

## Development

Work from a checkout installed with `./install.sh`; the plugin is a link to it, so edits are live after `omarchy restart shell`.

```bash
make test        # Rust unit tests; sync, library and off-screen UI end-to-end tests against a mock Immich; UI logic tests
make install     # rebuild bin/omamich
omarchy restart shell   # the shell caches QML; restart it after UI edits
qs log -i "$(ls -t /run/user/$UID/quickshell/by-id/ | head -1)" -f | grep omamich
```

A checkout with a `target/` folder is treated as a development copy: the plugin uses the backend you build and never downloads one over it. `./install.sh` from a checkout builds from source.

Releases: `scripts/release.sh 0.2.0` bumps the version in `Cargo.toml` and `manifest.json`, tags and pushes; the Release workflow tests, builds the x86_64 and ARM backends and publishes them with `SHA256SUMS`. CI runs the unit, sync, library and UI-logic tests on every push.

`OMAMICH_HOME=/tmp/x omamich serve` runs a backend with its own config, data and cache, and never touches the keyring. The end-to-end tests use this with `tests/mock_immich.py`, so they never touch a real library.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how the pieces fit.

## Credits and licence

Omamich's features follow [Mimick](https://github.com/nicx17/mimick) (GPL-3.0), and its structure and interface principles follow [Omamail](https://github.com/huacnlee/omamail) (MIT). Omamich is licensed under the GNU General Public License v3.0 or later. Not affiliated with Immich.
