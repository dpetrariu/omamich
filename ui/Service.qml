import QtQuick
import Quickshell
import Quickshell.Io
import "backend"
import "lib/Format.js" as Format

// Lives as long as the shell does. Owns the backend process, the settings,
// folder-sync status and the library lists every view shares, so the window
// opens onto data it already has and sync runs while the window is shut.
Item {
  id: root

  visible: false
  width: 0
  height: 0

  // Injected by the shell. Settings arrive later from the bar widget.
  property var shell: null
  property var manifest: null
  property var pluginRegistry: null
  property var barWidgetRegistry: null

  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl("..")).replace(/^file:\/\//, "")).replace(/\/$/, "")
  readonly property string executable: Quickshell.env("OMAMICH_BIN") || (pluginDir + "/bin/omamich")
  readonly property string version: manifest && manifest.version ? String(manifest.version) : "0.1.0"

  // ---------------------------------------------------------------- backend

  // The backend binary must match this plugin's version. A plugin installed
  // with `omarchy plugin add` or updated with `omarchy plugin update` has no
  // matching binary yet, so the release built for this version is downloaded
  // and checked. A development checkout (one with a target/ folder) builds its
  // own and is never overwritten.
  readonly property bool developmentBinary: Quickshell.env("OMAMICH_BIN") !== ""
  property string backendState: "checking"   // checking | downloading | ready | failed | outdated
  property string backendMessage: ""
  property string binaryVersion: ""
  property bool devCheckout: false
  readonly property bool binaryChecked: backendState !== "checking"
  readonly property bool binaryPresent: backendState === "ready"

  function checkBinary() {
    backendState = "checking"
    binaryVersion = ""
    versionProbe.running = true
  }

  function fetchBinary() {
    backendState = "downloading"
    backendMessage = ""
    fetcher.running = true
  }

  Process {
    id: checkoutProbe
    command: ["test", "-d", root.pluginDir + "/target"]
    onExited: function(code) {
      root.devCheckout = code === 0
      root.checkBinary()
    }
  }

  Process {
    id: versionProbe
    command: [root.executable, "version"]
    stdout: SplitParser {
      onRead: data => {
        var m = /^omamich (\S+) /.exec(String(data))
        if (m) root.binaryVersion = m[1]
      }
    }
    onExited: function(code) {
      if (root.developmentBinary) {
        root.backendState = code === 0 ? "ready" : "failed"
        root.backendMessage = code === 0 ? "" : "OMAMICH_BIN does not run: " + root.executable
        return
      }
      if (code === 0 && root.binaryVersion === root.version) {
        root.backendState = "ready"
        return
      }
      if (root.devCheckout) {
        // A developer's own build: say so, never replace it.
        root.backendState = code === 0 ? "outdated" : "failed"
        root.backendMessage = code === 0
          ? "This checkout's backend is " + root.binaryVersion + " but the plugin is " + root.version + "; run make install"
          : "Build the backend once: make install"
        return
      }
      root.fetchBinary()
    }
  }

  Process {
    id: fetcher
    command: [root.pluginDir + "/scripts/fetch-backend.sh", root.version]
    stderr: SplitParser {
      onRead: data => root.backendMessage = String(data)
    }
    onExited: function(code) {
      if (code === 0) {
        root.checkBinary()
        return
      }
      root.backendState = "failed"
      if (!root.backendMessage) root.backendMessage = "Downloading the backend failed (" + code + ")"
    }
  }

  readonly property alias backend: rustBackend
  Backend {
    id: rustBackend
    executable: root.backendState === "ready" || root.backendState === "outdated" ? root.executable : ""
    onNotification: function(method, params) {
      if (method === "sync.changed") root.applySyncStatus(params)
      else if (method === "server.changed") root.refreshServer()
    }
  }
  readonly property bool ready: rustBackend.ready
  readonly property string mediaBase: rustBackend.info ? String(rustBackend.info.mediaBase) : ""

  function call(method, params, callback) {
    rustBackend.call(method, params || {}, callback)
  }

  onReadyChanged: if (ready) {
    loadSettings()
    refreshServer()
    refreshSync()
  }

  // ---------------------------------------------------------------- settings

  property var settings: ({})
  property bool hasKey: false
  property string keyStorage: ""
  property bool settingsLoaded: false
  readonly property bool configured: hasKey && !!settings && (!!settings.serverUrl || !!settings.externalUrl)
  readonly property var uiPrefs: settings && settings.ui ? settings.ui : ({})

  function applySettingsResponse(result) {
    if (!result) return
    settings = result.settings || ({})
    hasKey = result.hasKey === true
    keyStorage = String(result.keyStorage || "")
    settingsLoaded = true
  }

  function loadSettings() {
    call("settings.get", {}, function(result, error) {
      if (!error) root.applySettingsResponse(result)
    })
  }

  function updateSettings(patch, callback) {
    call("settings.update", { patch: patch }, function(result, error) {
      if (!error) root.applySettingsResponse(result)
      if (typeof callback === "function") callback(result, error)
    })
  }

  // Window preferences are saved a moment after the last change.
  property var pendingPrefs: ({})
  function setPref(key, value) {
    var next = Object.assign({}, pendingPrefs)
    next[key] = value
    pendingPrefs = next
    var merged = Object.assign({}, settings)
    merged.ui = Object.assign({}, uiPrefs)
    merged.ui[key] = value
    settings = merged
    prefTimer.restart()
  }
  function pref(key, fallback) {
    var value = uiPrefs[key]
    return value === undefined || value === null ? fallback : value
  }
  Timer {
    id: prefTimer
    interval: 600
    onTriggered: {
      var patch = root.pendingPrefs
      root.pendingPrefs = ({})
      root.call("settings.update", { patch: { ui: patch } }, function() {})
    }
  }

  // Bar widget settings travel through here, since the shell hands them to
  // the widget and not to the service.
  property var barSettings: ({})
  readonly property bool showBarIcon: barSettings.showBarIcon !== false
  readonly property string notifySync: String(barSettings.notifySync || "Errors only")
  function applySettings(values) {
    barSettings = values || ({})
  }

  // ---------------------------------------------------------------- server

  property var overview: null
  property var statistics: null
  property string serverError: ""
  property bool serverLoading: false
  readonly property var user: overview ? overview.user : null
  readonly property var features: overview && overview.features ? overview.features : ({})
  readonly property string serverVersion: overview ? String(overview.version || "") : ""
  readonly property string route: overview && overview.route ? String(overview.route.route || "") : ""
  readonly property bool online: overview !== null && serverError === ""

  function refreshServer() {
    loadSettings()
    if (!configuredGuess()) {
      overview = null
      return
    }
    serverLoading = true
    call("server.overview", {}, function(result, error) {
      root.serverLoading = false
      if (error) {
        root.serverError = error.message
        return
      }
      root.serverError = ""
      root.overview = result
      root.libraryRevision++
      root.refreshStatistics()
    })
  }

  // Settings may not have arrived yet; the backend knows whether it has a key.
  function configuredGuess() {
    return rustBackend.info ? rustBackend.info.hasKey !== false || hasKey : hasKey
  }

  function refreshStatistics() {
    call("server.statistics", {}, function(result, error) {
      if (!error) root.statistics = result
    })
  }

  // Bumped whenever the library changed underneath the views, so they reload.
  property int libraryRevision: 0
  function libraryChanged() {
    libraryRevision++
    refreshStatistics()
    albumsStale = true
  }

  // ---------------------------------------------------------------- shared lists

  property var albums: []
  property bool albumsLoading: false
  property bool albumsStale: true
  property string albumsError: ""
  function loadAlbums(force) {
    if (albumsLoading || (!force && !albumsStale)) return
    albumsLoading = true
    call("albums.list", {}, function(result, error) {
      root.albumsLoading = false
      root.albumsError = error ? error.message : ""
      if (!error) {
        root.albums = result
        root.albumsStale = false
      }
    })
  }

  property var people: []
  property int peopleTotal: 0
  property bool peopleLoading: false
  property bool peopleLoaded: false
  property string peopleError: ""
  function loadPeople(force) {
    if (peopleLoading || (peopleLoaded && !force)) return
    peopleLoading = true
    call("people.list", { withHidden: true }, function(result, error) {
      root.peopleLoading = false
      root.peopleError = error ? error.message : ""
      if (!error) {
        root.people = result.people
        root.peopleTotal = result.total
        root.peopleLoaded = true
      }
    })
  }
  function patchPerson(person) {
    var next = people.slice()
    for (var i = 0; i < next.length; i++) if (next[i].id === person.id) next[i] = person
    people = next
  }

  property var places: []
  property bool placesLoading: false
  property bool placesLoaded: false
  property string placesError: ""
  function loadPlaces(force) {
    if (placesLoading || (placesLoaded && !force)) return
    placesLoading = true
    call("places.list", {}, function(result, error) {
      root.placesLoading = false
      root.placesError = error ? error.message : ""
      if (!error) {
        root.places = result
        root.placesLoaded = true
      }
    })
  }

  property var tags: []
  property bool tagsLoading: false
  function loadTags() {
    if (tagsLoading) return
    tagsLoading = true
    call("tags.list", {}, function(result, error) {
      root.tagsLoading = false
      if (!error) root.tags = result
    })
  }

  // ---------------------------------------------------------------- media

  function thumbUrl(id, size, version) {
    if (!mediaBase || !id) return ""
    return mediaBase + "/thumb/" + id + "?size=" + (size || "thumbnail") + "&v=" + Format.versionOf(version)
  }
  function personUrl(id, version) {
    return mediaBase && id ? mediaBase + "/person/" + id + "?v=" + Format.versionOf(version) : ""
  }
  function avatarUrl(id) {
    return mediaBase && id ? mediaBase + "/avatar/" + id : ""
  }
  function videoUrl(id) {
    return mediaBase && id ? mediaBase + "/video/" + id : ""
  }
  function originalUrl(id) {
    return mediaBase && id ? mediaBase + "/original/" + id : ""
  }

  // ---------------------------------------------------------------- sync

  property var syncStatus: null
  readonly property string syncPhase: syncStatus ? String(syncStatus.phase) : "disabled"
  readonly property bool syncBusy: ["uploading", "downloading", "scanning", "queued"].indexOf(syncPhase) >= 0
  readonly property bool syncAttention: !!syncStatus && (syncStatus.failed > 0 || syncStatus.offline === true)
  readonly property string syncSummary: Format.syncSummary(syncStatus)
  property int lastNotifiedUploads: -1
  property int lastNotifiedFailures: -1

  function applySyncStatus(status) {
    var previous = syncStatus
    syncStatus = status
    maybeNotify(previous, status)
  }

  function refreshSync() {
    call("sync.status", {}, function(result, error) {
      if (!error) root.applySyncStatus(result)
    })
  }

  // A batch finished, or something failed: say so on the desktop, once.
  function maybeNotify(previous, status) {
    if (!status || notifySync === "Off") return
    var failed = Number(status.failedSession || 0)
    if (lastNotifiedFailures < 0) lastNotifiedFailures = failed
    if (failed > lastNotifiedFailures) {
      lastNotifiedFailures = failed
      notify("Omamich could not upload a file", String(status.lastError || "See Sync for details"))
    }
    var uploads = Number(status.uploaded || 0) + Number(status.downloaded || 0)
    if (lastNotifiedUploads < 0) lastNotifiedUploads = uploads
    var settled = previous && previous.phase !== "idle" && status.phase === "idle"
    if (notifySync === "Every batch" && settled && uploads > lastNotifiedUploads) {
      var count = uploads - lastNotifiedUploads
      lastNotifiedUploads = uploads
      notify("Omamich synced " + count + (count === 1 ? " photo" : " photos"), "Your folders are up to date")
    }
    if (settled && uploads > lastNotifiedUploads) lastNotifiedUploads = uploads
    if (settled) libraryChanged()
  }

  function notify(title, body) {
    Quickshell.execDetached(["notify-send", "--app-name=Omamich", "--icon=image-multiple", "--", title, body])
  }

  // ---------------------------------------------------------------- window

  property bool windowOpen: false
  function openWindow(payload) {
    if (shell && typeof shell.summon === "function") shell.summon("omamich", JSON.stringify(payload || {}))
  }

  // After the shell has handed over the manifest, which carries the version.
  Component.onCompleted: Qt.callLater(function() { checkoutProbe.running = true })
  Component.onDestruction: rustBackend.shutdown()
}
