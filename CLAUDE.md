# Omamich — working agreements

Omamich is an Immich client built as an Omarchy shell plugin, following the structure and interface principles of [Omamail](https://github.com/huacnlee/omamail) and the feature set of [Mimick](https://github.com/nicx17/mimick). Read `README.md` for what it does and `docs/ARCHITECTURE.md` for how the pieces fit before changing anything.

## Shape of the code

- `src/` — Rust backend, `omamich serve`, JSON-RPC 2.0 over stdin/stdout (one JSON object per line). `methods.rs` is the only method table; `library.rs` library calls; `local.rs` files on this computer; `media.rs` the token-guarded 127.0.0.1 media proxy; `sync/` folder sync; `immich/` the HTTP client.
- `ui/` — QML loaded by the Omarchy shell (Quickshell). `Service.qml` lives as long as the shell and owns the backend and shared state; `App.qml` is the window and owns navigation, key context and every photo action; `views/` draw and report; `components/` are reusable; `lib/*.js` and `keys/Keymap.js` hold testable logic.
- `tests/` — `mock_immich.py` (in-memory Immich, `--seed` for a synthetic library), `sync_e2e.py`, `library_e2e.py`, `ui_e2e.py` (the real window off-screen), `ui_logic.js`, plus `tests/ui/shell.qml`, a stand-in shell for the UI test.

## Rules that protect people's photos

- **Never send a write to a real Immich server while developing or testing.** A configured key may have full permissions (the maintainer's does). Read-only `GET`s and searches against a real server are fine for checking API shapes; every change is tested against `tests/mock_immich.py`.
- **Never type synthetic keys into a window connected to a real library** (`wtype` and similar). Their keymap is not applied reliably; a test once sent `1` (rate) instead of `l`. Drive the window with `omarchy-shell shell call omamich navigate <id>`, which refuses anything that changes the library, or use the off-screen harness.
- **Do not screenshot or drive the person's desktop while they are using it.** Prefer `tests/ui_e2e.py`, which renders off-screen.
- Sync deletion mirroring stays off by default and must keep its guards: skip unreadable folders and walks with errors; treat only `try_exists() == Ok(false)` as gone; refuse mass deletions (`mass_deletion`); key album snapshots by folder *and* album; forget records when a folder's path changes; wait (without holding a worker) until the folder's scans and uploads settle; restore an Immich asset found in the trash rather than linking to it. Every one of these has a regression test in `sync_e2e.py`.
- Test processes get their own `OMAMICH_HOME` (config, data, cache, and no keyring) and `XDG_DATA_HOME` (desktop trash). Never run `omamich serve` against the real config in a test.
- Keys that change the library never auto-repeat (`changes: true` in `Keymap.js`); the confirm dialog focuses Cancel.

## Development loop

```bash
make test                       # everything: Rust, sync/library/UI end-to-end, UI logic
make install                    # rebuild bin/omamich (the plugin runs this binary)
./install.sh                    # first time (and to update): build, link into Omarchy, enable, restart the shell
omarchy restart shell           # the shell caches QML; restart after UI edits
OMAMICH_UI_SHOTS=/tmp/shots python3 tests/ui_e2e.py target/debug/omamich   # keep screenshots
```

Rust comes from mise: prefix cargo with `mise exec rust@latest cmake@latest --` (or pass `CARGO=` to make).

- **Look at the screenshots** the UI test leaves in `$OMAMICH_UI_SHOTS`; passing assertions do not prove a view looks right (a favourite heart on every local file passed until someone looked).
- After a UI run, list the remaining warnings in the harness log (`/tmp/omamich-ui-*/qs.log`) and fix anything mentioning `omamich` — `ui_e2e.py` fails on TypeError, ReferenceError, "Unable to assign", "Cannot assign" and binding loops, but read the rest too.
- `qmllint -I /usr/lib/qt6/qml <file>` catches syntax errors before a slow UI run; unresolved `qs.*` imports are expected noise.
- `pkill -f <pattern>` matches the shell command running it; use a bracket (`pkill -f "[q]s -p ..."`) or `pkill -x`.
- Real-shell logs: `qs log -i "$(ls -t /run/user/$UID/quickshell/by-id/ | head -1)"`. Hyprland here takes Lua dispatchers: `hyprctl dispatch "hl.dsp.window.float({ action = 'on', window = 'address:0x…' })"`.

## QML pitfalls met here

- A child binding `theme: theme` binds to itself; App's Theme has id `appTheme`.
- A `signal xChanged` clashes with property `x`'s change signal and stops the file loading; two functions with one name do too. The UI test catches both because the window never comes up.
- Name clashes with `QtQuick.Controls`: import it as `QQC`; our popup is `PopupMenu`, our modal is `Sheet`.
- A binding that can yield `undefined` for a bool leaves the property at its default (`visible` stays `true`): compare with `=== true`.
- Inside `onFooChanged`, other bindings that depend on `foo` may not have updated yet; compute from `foo` directly.
- Callbacks from `service.call` can arrive after a view is destroyed: every one starts with `if (!root) return`. Deferred work uses a child `Timer` (dies with the view), not `Qt.callLater(fn)`.
- Arrays passed through `var` signal arguments become sequences (`Array.isArray` is false); `var` properties keep real arrays.
- Quickshell windows take their size only at creation; off-screen tests use `app.narrowOverride` instead of resizing.

## Design principles (from Omamail)

- All colours and sizes come from the Omarchy theme through `components/Theme.qml`; secondary text mixes foreground toward background. Never convey state by colour alone.
- One key table (`keys/Keymap.js`) drives shortcuts, the status-bar hints and the `?` sheet. Text-entry contexts bind no bare letters.
- Actions that open another surface end in `...`. Labels say their real scope. Destructive actions use the urgent colour and confirm; reversible ones offer Undo.
- Untrusted text (server data, file names) renders as `Text.PlainText`. Ids are validated as UUIDs before reaching a URL; the API key never reaches QML.

## How a feature is added

1. Backend method in `src/` with input validation, registered in `methods.rs`; unit tests for pure logic.
2. Mock support in `tests/mock_immich.py` that mirrors Immich's real behaviour (check the real API shape with a read-only call first).
3. A backend end-to-end check (`library_e2e.py` or `sync_e2e.py`), including refusals of bad input.
4. The UI, then a scenario in `ui_e2e.py` that drives it through `testHooks` and asserts on the mock's `/_state`.
5. `make test`, read the screenshots and the harness log, update `README.md`, commit with a message that says what changed and why.

For a wider change, get a fresh-eyes review from a separate agent focused on data loss, security and QML runtime errors; the first review here found two ways sync could have emptied a library.
