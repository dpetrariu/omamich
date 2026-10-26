import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Window
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui

import "components"
import "views"
import "keys/Keymap.js" as Keymap
import "lib/Format.js" as Format

// The window. It owns where you are (section, pages, the open photo), which
// key context is live, and what the photo actions do; views draw what they
// are given and report what was asked for.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property var service: null
  property bool opened: false
  property bool closingFromHost: false

  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : "omamich"
  readonly property bool ready: !!service && service.ready
  readonly property bool configured: !!service && service.configured

  Theme { id: appTheme }

  // ---------------------------------------------------------------- host contract

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(String(payloadJson || "{}")) || ({}) } catch (e) {}
    closingFromHost = false
    opened = true
    if (service) service.windowOpen = true
    if (payload.section) go(String(payload.section))
    // From the file manager: "Upload to Immich" opens the staging page.
    if (payload.upload && service) {
      var paths = []
      for (var i = 0; i < payload.upload.length && i < 5000; i++) paths.push(String(payload.upload[i]))
      stage(paths, "")
    }
    Qt.callLater(focusContent)
  }

  function close() {
    closingFromHost = true
    opened = false
    if (service) service.windowOpen = false
    closingFromHost = false
  }

  // `omarchy-shell shell call omamich navigate <id>` — keyboard actions that
  // only move around, for scripts and keybindings. Anything that changes the
  // library is refused here; those stay behind a person's keypress.
  readonly property var navigationIds: ["left", "right", "up", "down", "pageDown", "pageUp", "first", "last",
    "open", "previous", "next", "back", "info", "help", "sidebar", "search", "refresh", "zoomIn", "zoomOut",
    "zoomReset", "fullscreen", "settings", "sync", "select", "selectAll", "historyBack", "historyForward"]
  function navigate(id) {
    var name = String(id || "")
    if (name.indexOf("go:") === 0) {
      go(name.slice(3))
      return "ok"
    }
    if (name.indexOf("search:") === 0) {
      searchBar.text = name.slice(7)
      runSearch(name.slice(7))
      return "ok"
    }
    if (navigationIds.indexOf(name) < 0) return "refused"
    runShortcut(name, "")
    return "ok"
  }

  // `omarchy-shell shell call omamich screenshot /path.png` saves what the
  // window shows, for bug reports and the UI tests.
  function screenshot(path) {
    var target = String(path || "")
    if (target.indexOf("/") !== 0 || !/\.png$/.test(target)) return "refused"
    frame.grabToImage(function(result) { result.saveToFile(target) })
    return "ok"
  }

  // Handles for the off-screen UI tests, which drive dialogs directly.
  readonly property var testHooks: ({ menu: menu, prompt: promptDialog, confirm: confirmDialog, picker: pickerDialog,
    share: shareDialog, albumPeople: albumPeople, viewer: viewer, info: infoPanel, toast: toast,
    content: contentLoader, window: window })

  function requestClose() {
    if (shell && typeof shell.hide === "function") shell.hide(pluginId)
    else close()
  }

  onOpenedChanged: Qt.callLater(function() { window.visible = root.opened })

  // ---------------------------------------------------------------- navigation

  // Pages the person turned off in Immich, or features the server lacks,
  // are left out rather than shown failing.
  readonly property var preferences: service && service.overview && service.overview.preferences ? service.overview.preferences : ({})
  function sectionAvailable(id) {
    var f = features()
    switch (id) {
    case "people": return f.facialRecognition !== false && preferences.people !== false
    case "places": return f.reverseGeocoding !== false || f.map !== false
    case "tags": return preferences.tags !== false
    case "folders": return preferences.folders !== false
    case "trash": return f.trash !== false
    case "computer": return !!service && !!service.settings && !!service.settings.sync && (service.settings.sync.folders || []).length > 0
    }
    return true
  }
  readonly property var sections: allSections.filter(function(s) { return root.sectionAvailable(s.id) })
  readonly property var allSections: [
    { id: "photos", label: "Photos", icon: "photos", group: "library", count: service && service.statistics ? Format.thousands(service.statistics.total) : "" },
    { id: "explore", label: "Explore", icon: "explore", group: "library" },
    { id: "people", label: "People", icon: "people", group: "library", count: service && service.peopleLoaded ? Format.thousands(service.peopleTotal) : "" },
    { id: "places", label: "Places", icon: "places", group: "library" },
    { id: "albums", label: "Albums", icon: "albums", group: "library", count: service && service.albums.length ? String(service.albums.length) : "" },
    { id: "favorites", label: "Favourites", icon: "favorite", group: "collections", count: service && service.statistics && service.statistics.favorites ? Format.thousands(service.statistics.favorites) : "" },
    { id: "sharing", label: "Sharing", icon: "shared", group: "collections" },
    { id: "tags", label: "Tags", icon: "tags", group: "collections" },
    { id: "folders", label: "Folders", icon: "folders", group: "collections" },
    { id: "archive", label: "Archive", icon: "archive", group: "utility", count: service && service.statistics && service.statistics.archived ? Format.thousands(service.statistics.archived) : "" },
    { id: "trash", label: "Trash", icon: "trash", group: "utility", count: service && service.statistics && service.statistics.trashed ? Format.thousands(service.statistics.trashed) : "" },
    { id: "computer", label: "On this computer", icon: "computer", group: "utility" },
    { id: "sync", label: "Folder sync", icon: "cloudSync", group: "utility" }
  ]

  property string section: "photos"
  // Pages opened inside a section: an album, a person, a place, a search.
  property var stack: []
  readonly property var page: stack.length > 0 ? stack[stack.length - 1] : null
  property bool settingsOpen: false
  property var viewerAsset: null
  property bool infoOpen: service ? service.pref("infoOpen", false) === true : false
  property bool sidebarCollapsed: service ? service.pref("sidebarCollapsed", false) === true : false
  property bool helpOpen: false
  property real zoom: service ? Number(service.pref("gridZoom", 1)) || 1 : 1
  property bool fullscreen: false
  // A phone-width window: tabs at the bottom instead of the sidebar.
  readonly property bool narrow: narrowOverride || window.width < appTheme.space(640)
  // Off-screen tests cannot resize the window, so they ask for the layout.
  property bool narrowOverride: false

  readonly property bool needsSetup: ready && service.settingsLoaded && !configured

  function go(id) {
    if (id === "settings") {
      settingsOpen = true
      remember()
      return
    }
    settingsOpen = false
    viewerAsset = null
    stack = []
    searchBar.clear()
    section = id
    remember()
    Qt.callLater(focusContent)
  }

  function push(entry) {
    viewerAsset = null
    var next = stack.slice()
    next.push(entry)
    stack = next
    remember()
    Qt.callLater(focusContent)
  }

  function pop() {
    var next = stack.slice()
    next.pop()
    stack = next
    remember()
    Qt.callLater(focusContent)
  }

  // Back and Forward through the places visited, like a browser. Escape
  // still leaves the innermost thing first; these walk the history.
  property var history: [{ section: "photos", stack: [], settingsOpen: false }]
  property int historyIndex: 0
  property bool restoring: false
  readonly property bool canGoBackInHistory: historyIndex > 0
  readonly property bool canGoForward: historyIndex < history.length - 1

  function snapshot() {
    return { section: section, stack: JSON.parse(JSON.stringify(stack)), settingsOpen: settingsOpen }
  }

  function remember() {
    if (restoring) return
    var current = snapshot()
    var last = history[historyIndex]
    if (last && JSON.stringify(last) === JSON.stringify(current)) return
    var next = history.slice(0, historyIndex + 1)
    next.push(current)
    if (next.length > 100) next.shift()
    history = next
    historyIndex = next.length - 1
  }

  function restoreHistory(entry) {
    restoring = true
    viewerAsset = null
    searchBar.clear()
    section = entry.section
    stack = JSON.parse(JSON.stringify(entry.stack))
    settingsOpen = entry.settingsOpen
    restoring = false
    Qt.callLater(focusContent)
  }

  function historyBack() {
    if (!canGoBackInHistory) return
    historyIndex--
    restoreHistory(history[historyIndex])
  }

  function historyForward() {
    if (!canGoForward) return
    historyIndex++
    restoreHistory(history[historyIndex])
  }

  function setSettings(on) {
    if (settingsOpen === on) return
    settingsOpen = on
    if (on) viewerAsset = null
    remember()
  }

  // Files to upload go through the staging page: look, choose, then upload.
  function stage(paths, albumId) {
    if (!paths || paths.length === 0) return
    settingsOpen = false
    viewerAsset = null
    push({ kind: "staging", paths: paths, albumId: albumId || "" })
  }

  // Escape: leave the innermost thing first.
  function goBack() {
    if (menu.visible) { menu.close(); return }
    if (anyDialogOpen()) { closeDialogs(); return }
    if (helpOpen) { helpOpen = false; return }
    if (infoPanel.typing) { infoPanel.finishEditing(); focusContent(); return }
    if (searchBar.focused) { searchBar.clear(); focusContent(); return }
    if (viewerAsset) { closeViewer(); return }
    if (settingsOpen) { setSettings(false); focusContent(); return }
    var grid = activeGrid()
    if (grid && grid.selecting) { grid.clearSelection(); return }
    if (stack.length > 0) { pop(); return }
    if (section !== "photos") { go("photos"); return }
    requestClose()
  }

  function focusContent() {
    keyPark.forceActiveFocus()
  }

  // ---------------------------------------------------------------- key context

  readonly property string keyContext: Keymap.contextFor({
    dialog: anyDialogOpen() || helpOpen,
    page: settingsOpen || needsSetup || (contentLoader.item && contentLoader.item.isForm === true),
    searchFocused: searchBar.focused || infoPanel.typing || (contentLoader.item && contentLoader.item.typing === true),
    viewer: viewerAsset !== null,
    tiles: contentLoader.item ? contentLoader.item.kind === "tiles" : false
  })

  function anyDialogOpen() {
    return promptDialog.opened || confirmDialog.opened || pickerDialog.opened || shareDialog.opened || albumPeople.opened
  }

  function closeDialogs() {
    promptDialog.close()
    confirmDialog.close()
    pickerDialog.close()
    shareDialog.close()
    albumPeople.close()
    focusContent()
  }

  function activeGrid() {
    var item = contentLoader.item
    return item && item.grid ? item.grid : null
  }

  function runShortcut(id, sequence) {
    var item = contentLoader.item
    var grid = activeGrid()
    switch (id) {
    case "back": goBack(); return
    case "backAlt": closeViewer(); return
    case "settings": setSettings(!settingsOpen); return
    case "historyBack": historyBack(); return
    case "historyForward": historyForward(); return
    case "sync": go("sync"); return
    case "help": helpOpen = !helpOpen; return
    case "fullscreen": fullscreen = !fullscreen; return
    case "sidebar": toggleSidebar(); return
    case "search": searchBar.focusField(); return
    case "section":
      var n = Number(sequence.slice(-1))
      var index = n === 0 ? 9 : n - 1
      if (index < sections.length) go(sections[index].id)
      return
    }
    if (viewerAsset) {
      viewerAction(id, sequence)
      return
    }
    if (grid && keyContext === "grid") {
      switch (id) {
      case "left": grid.moveHorizontal(-1); return
      case "right": grid.moveHorizontal(1); return
      case "up": grid.moveVertical(-1); return
      case "down": grid.moveVertical(1); return
      case "pageDown": grid.movePage(1); return
      case "pageUp": grid.movePage(-1); return
      case "first": grid.moveToEnd(false); return
      case "last": grid.moveToEnd(true); return
      case "open": if (grid.currentAsset()) openViewer(grid.currentAsset()); return
      case "select":
        var a = grid.currentAsset()
        if (a) { grid.toggle(a); grid.lastToggled = grid.cursor }
        return
      case "selectAll": grid.selectAll(); return
      case "refresh": refreshContent(); return
      case "info":
        if (grid.currentAsset()) { setInfo(true); openViewer(grid.currentAsset()) }
        return
      }
      photoAction(id, grid.targets(), grid)
      return
    }
    if (item && typeof item.handleKey === "function") {
      if (id === "refresh") { refreshContent(); return }
      item.handleKey(id)
    }
  }

  function refreshContent() {
    service.libraryChanged()
    var item = contentLoader.item
    if (item && typeof item.reload === "function") item.reload()
  }

  function toggleSidebar() {
    sidebarCollapsed = !sidebarCollapsed
    service.setPref("sidebarCollapsed", sidebarCollapsed)
  }

  function setInfo(on) {
    infoOpen = on
    service.setPref("infoOpen", on)
  }

  function setZoom(z) {
    zoom = Math.max(0.6, Math.min(2.0, z))
    service.setPref("gridZoom", zoom)
  }

  // ---------------------------------------------------------------- viewer

  function openViewer(asset) {
    var grid = activeGrid()
    if (grid) grid.setCursorTo(asset)
    viewerAsset = asset
  }

  // A change that moves photos in the timeline (a new date) reloads the
  // grid once the viewer closes, so the open photo does not jump away.
  property bool reloadAfterViewer: false

  function closeViewer() {
    viewerAsset = null
    if (reloadAfterViewer) {
      reloadAfterViewer = false
      refreshContent()
      focusContent()
      return
    }
    var grid = activeGrid()
    if (grid) grid.reveal()
    focusContent()
  }

  function step(delta) {
    var grid = activeGrid()
    if (!grid || !viewerAsset) return
    grid.setCursorTo(viewerAsset)
    var next = grid.neighbor(grid.cursor, delta)
    if (next) {
      grid.cursor = next
      viewerAsset = grid.assetAt(next)
    } else {
      // The next month is loading; follow once it arrives.
      viewer.waitingForNext = delta
    }
  }

  Connections {
    target: contentLoader.item && contentLoader.item.grid ? contentLoader.item.grid : null
    ignoreUnknownSignals: true
    function onDragRequested(assets) { root.startDrag(assets) }
    function onCursorChanged() {
      var grid = root.activeGrid()
      if (root.viewerAsset && viewer.waitingForNext !== 0 && grid.currentAsset()
          && grid.currentAsset().id !== root.viewerAsset.id) {
        viewer.waitingForNext = 0
        root.viewerAsset = grid.currentAsset()
      }
    }
  }

  function viewerAction(id, sequence) {
    switch (id) {
    case "previous": step(-1); return
    case "next": step(1); return
    case "info": setInfo(!infoOpen); return
    case "playPause": viewer.togglePlay(); return
    case "zoomIn": viewer.zoomBy(1.4); return
    case "zoomOut": viewer.zoomBy(1 / 1.4); return
    case "zoomReset": viewer.resetZoom(); return
    case "faces": viewer.showFaces = !viewer.showFaces; return
    case "slideshow": viewer.slideshow = !viewer.slideshow; return
    case "rate":
      if (preferences.ratings === false) {
        toast.show("Ratings are turned off in your Immich account settings")
        return
      }
      var stars = Number(sequence)
      var current = viewer.details && viewer.details.exif ? Number(viewer.details.exif.rating || 0) : 0
      rate([viewerAsset], current === stars ? 0 : stars)
      return
    }
    photoAction(id, viewerAsset ? [viewerAsset] : [], activeGrid())
  }

  // ---------------------------------------------------------------- photo actions

  readonly property bool inTrash: section === "trash" && !page
  readonly property bool inArchive: section === "archive" && !page
  readonly property var albumPage: page && page.kind === "album" ? page.album : null
  readonly property var personPage: page && page.kind === "person" ? page.person : null

  function ids(assets) {
    return assets.map(function(a) { return a.id })
  }

  function failed(error) {
    toast.show(error.message, { tone: "error" })
  }

  function photoAction(id, assets, grid) {
    if (!assets || assets.length === 0) return
    // Files only on this computer have nothing in Immich to act on.
    var remote = assets.filter(function(a) { return a.id && String(a.id).indexOf("local:") !== 0 })
    if (remote.length < assets.length) {
      if (remote.length === 0) {
        toast.show(assets.length === 1 ? "This file is not in Immich yet" : "These files are not in Immich yet", {
          actionText: "Upload", action: function() { root.uploadLocal(assets) }
        })
        return
      }
      toast.show(Format.count(assets.length - remote.length, "file") + " not in Immich were left out")
      assets = remote
    }
    switch (id) {
    case "favorite": toggleFavorite(assets, grid); return
    case "archive": toggleArchive(assets, grid); return
    case "trash": if (inTrash) restore(assets, grid); else trash(assets, grid); return
    case "deleteForever": deleteForever(assets, grid); return
    case "addToAlbum": addToAlbum(assets, grid); return
    case "tag": tagAssets(assets); return
    case "share": shareAssets(assets); return
    case "download": download(assets); return
    case "editDate": editDate(assets, grid); return
    }
  }

  // Apply a change the server accepted to the grid and the viewer. The grid
  // may belong to a view that was closed while the request ran; then there is
  // nothing on screen to update, but the caller's toast must still show.
  function afterChange(grid, assets, change, leaves) {
    var list = ids(assets)
    try {
      if (leaves && grid) {
        if (viewerAsset && list.indexOf(viewerAsset.id) >= 0) {
          var nextCursor = grid.neighbor(grid.cursor, 1) || grid.neighbor(grid.cursor, -1)
          var nextAsset = nextCursor ? grid.assetAt(nextCursor) : null
          grid.dropAssets(list)
          if (nextAsset) { grid.setCursorTo(nextAsset); viewerAsset = nextAsset }
          else closeViewer()
        } else grid.dropAssets(list)
      } else if (grid) {
        grid.patchAssets(list, change)
      }
    } catch (e) {
      if (viewerAsset && list.indexOf(viewerAsset.id) >= 0 && leaves) viewerAsset = null
    }
    if (viewerAsset && list.indexOf(viewerAsset.id) >= 0 && !leaves)
      viewerAsset = Object.assign({}, viewerAsset, change)
    service.refreshStatistics()
  }

  function toggleFavorite(assets, grid) {
    var on = !assets.every(function(a) { return a.isFavorite })
    service.call("asset.update", { ids: ids(assets), isFavorite: on }, function(r, e) {
      if (e) return root.failed(e)
      var leaves = !on && section === "favorites" && !page
      root.afterChange(grid, assets, { isFavorite: on }, leaves)
      if (assets.length > 1) toast.show((on ? "Added " : "Removed ") + Format.count(assets.length, "photo") + (on ? " to" : " from") + " favourites")
    })
  }

  function toggleArchive(assets, grid) {
    var archive = !inArchive
    service.call("asset.update", { ids: ids(assets), visibility: archive ? "archive" : "timeline" }, function(r, e) {
      if (e) return root.failed(e)
      var leaves = !root.albumPage
      Qt.callLater(function() { root.afterChange(grid, assets, { visibility: archive ? "archive" : "timeline" }, leaves) })
      toast.show((archive ? "Archived " : "Unarchived ") + Format.count(assets.length, "photo"), {
        actionText: "Undo",
        action: function() {
          root.service.call("asset.update", { ids: root.ids(assets), visibility: archive ? "timeline" : "archive" }, function(r2, e2) {
            if (e2) return root.failed(e2)
            root.service.libraryChanged()
            root.refreshContent()
          })
        }
      })
    })
  }

  function trash(assets, grid) {
    service.call("asset.trash", { ids: ids(assets) }, function(r, e) {
      if (e) return root.failed(e)
      Qt.callLater(function() { root.afterChange(grid, assets, {}, true) })
      toast.show("Moved " + Format.count(assets.length, "photo") + " to the trash", {
        actionText: "Undo",
        action: function() { root.restore(assets, null, function() { root.refreshContent() }) }
      })
    })
  }

  // Why Immich kept photos in the trash, in words a person can act on.
  function keptInTrash(kept, offline) {
    if (kept === 0) return ""
    var what = Format.count(kept, "photo")
    if (offline >= kept)
      return "Immich kept " + what + " in the trash: " + (kept === 1 ? "its file is" : "their files are")
        + " missing from your external library (offline). Put " + (kept === 1 ? "the file" : "the files")
        + " back and rescan the library in Immich to bring " + (kept === 1 ? "it" : "them") + " back."
    return "Immich kept " + what + " in the trash" + (offline > 0 ? "; " + offline + " of them are offline (their files are missing)" : "") + "."
  }

  // Restore, then trust only what Immich actually restored.
  function restore(assets, grid, after) {
    service.call("asset.restore", { ids: ids(assets) }, function(r, e) {
      if (e) return root.failed(e)
      var done = assets.filter(function(a) { return r.restored.indexOf(a.id) >= 0 })
      var kept = r.notRestored.length
      if (done.length > 0) root.afterChange(grid, done, {}, true)
      if (typeof after === "function") after(done)
      if (kept > 0) {
        toast.show((done.length > 0 ? "Restored " + Format.count(done.length, "photo") + ". " : "") + root.keptInTrash(kept, r.offline.length), { tone: "error", duration: 12000 })
        return
      }
      // Restored photos go back to the date they were taken, which can be
      // far down the timeline: offer to go there.
      var first = done[0]
      toast.show("Restored " + Format.count(done.length, "photo") + " to the timeline", {
        actionText: "Show",
        action: function() { root.showInTimeline(first) }
      })
    })
  }

  function showInTimeline(asset) {
    go("photos")
    var tries = 0
    var attempt = function() {
      var grid = root.activeGrid()
      if (grid && typeof grid.revealAsset === "function") grid.revealAsset(asset.id, asset.fileCreatedAt)
      else if (++tries < 20) Qt.callLater(attempt)
    }
    Qt.callLater(attempt)
  }

  function deleteForever(assets, grid) {
    confirmDialog.ask({
      title: "Delete " + Format.count(assets.length, "photo") + " permanently?",
      message: "They are removed from Immich and from its storage. This cannot be undone.",
      confirmText: "Delete permanently",
      onConfirm: function() {
        root.service.call("asset.deleteForever", { ids: root.ids(assets) }, function(r, e) {
          if (e) return root.failed(e)
          toast.show("Deleted " + Format.count(assets.length, "photo"))
          root.afterChange(grid, assets, {}, true)
        })
      }
    })
  }

  function pad2(n) { return n < 10 ? "0" + n : String(n) }

  // "2024-05-01 14:30" in local time → ISO 8601 with this computer's offset.
  function parseLocalDate(text) {
    var m = /^\s*(\d{4})-(\d{1,2})-(\d{1,2})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}))?)?\s*$/.exec(String(text || ""))
    if (!m) return null
    var d = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]), Number(m[4] || 12), Number(m[5] || 0), Number(m[6] || 0))
    if (isNaN(d.getTime()) || d.getMonth() !== Number(m[2]) - 1) return null
    var offset = -d.getTimezoneOffset()
    var sign = offset >= 0 ? "+" : "-"
    offset = Math.abs(offset)
    return d.getFullYear() + "-" + pad2(d.getMonth() + 1) + "-" + pad2(d.getDate()) + "T" + pad2(d.getHours()) + ":"
      + pad2(d.getMinutes()) + ":" + pad2(d.getSeconds()) + ".000" + sign + pad2(Math.floor(offset / 60)) + ":" + pad2(offset % 60)
  }

  function editDate(assets, grid) {
    if (!assets || assets.length === 0) return
    var first = assets[0]
    var current = viewer.details && viewer.details.id === first.id ? (viewer.details.localDateTime || viewer.details.fileCreatedAt) : first.fileCreatedAt
    var p = /^(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2})/.exec(String(current || ""))
    promptDialog.ask({
      title: assets.length === 1 ? "Date taken" : "Date taken for " + Format.count(assets.length, "photo"),
      subtitle: assets.length === 1 ? "In this computer's time zone. The photo moves to its new place in the timeline."
        : "Every selected photo gets this date and time, in this computer's time zone.",
      value: p ? p[1] + " " + p[2] : "",
      placeholder: "YYYY-MM-DD HH:MM",
      confirmText: "Set date",
      onAccept: function(text) {
        var iso = root.parseLocalDate(text)
        if (!iso) return "Dates look like 2024-05-01 14:30"
        root.service.call("asset.update", { ids: root.ids(assets), dateTimeOriginal: iso }, function(r, e) {
          if (e) return promptDialog.finish(e.message)
          promptDialog.finish("")
          toast.show("Date changed" + (assets.length > 1 ? " for " + Format.count(assets.length, "photo") : ""))
          viewer.reloadDetails()
          if (root.viewerAsset) root.reloadAfterViewer = true
          else root.refreshContent()
        })
        return "pending"
      }
    })
  }

  function rate(assets, stars) {
    service.call("asset.update", { ids: ids(assets), rating: stars }, function(r, e) {
      if (e) return root.failed(e)
      viewer.reloadDetails()
      toast.show(stars > 0 ? "Rated " + stars + (stars === 1 ? " star" : " stars") : "Rating cleared")
    })
  }

  function albumItems() {
    return service.albums.map(function(a) {
      return {
        id: a.id,
        label: a.albumName,
        detail: Format.count(a.assetCount, "item") + (a.shared ? " · shared" : ""),
        image: a.albumThumbnailAssetId ? service.thumbUrl(a.albumThumbnailAssetId, "thumbnail", a.updatedAt) : ""
      }
    })
  }

  function addToAlbum(assets, grid) {
    service.loadAlbums(true)
    pickerDialog.ask({
      title: "Add " + Format.count(assets.length, "photo") + " to an album",
      placeholder: "Find or name an album",
      createLabel: "Create album",
      items: albumItems(),
      loading: service.albumsLoading,
      emptyText: "No albums yet. Type a name to create one.",
      onPick: function(item) {
        if (item.create) {
          root.service.call("album.create", { albumName: item.create, assetIds: root.ids(assets) }, function(r, e) {
            if (e) return pickerDialog.finish(e.message)
            pickerDialog.finish("")
            root.service.loadAlbums(true)
            toast.show("Created “" + r.albumName + "” with " + Format.count(assets.length, "photo"), {
              actionText: "Open", action: function() { root.go("albums"); root.push({ kind: "album", album: r }) }
            })
          })
        } else {
          root.service.call("album.addAssets", { id: item.id, ids: root.ids(assets) }, function(r, e) {
            if (e) return pickerDialog.finish(e.message)
            pickerDialog.finish("")
            root.service.loadAlbums(true)
            var skipped = r.requested - r.changed
            toast.show("Added " + Format.count(r.changed, "photo") + " to “" + item.label + "”"
              + (skipped > 0 ? " (" + skipped + " already there)" : ""))
          })
        }
        return "pending"
      }
    })
    if (grid) grid.clearSelection()
  }

  Connections {
    target: root.service
    function onAlbumsChanged() {
      if (pickerDialog.opened && pickerDialog.createLabel === "Create album") {
        pickerDialog.items = root.albumItems()
        pickerDialog.loading = false
      }
    }
    function onTagsChanged() {
      if (pickerDialog.opened && pickerDialog.createLabel === "Create tag") {
        pickerDialog.items = root.tagItems()
        pickerDialog.loading = false
      }
    }
  }

  function tagItems() {
    return service.tags.map(function(t) { return { id: t.id, label: t.value || t.name } })
  }

  function tagAssets(assets) {
    service.loadTags()
    pickerDialog.ask({
      title: "Tag " + Format.count(assets.length, "photo"),
      placeholder: "Find or name a tag",
      createLabel: "Create tag",
      items: tagItems(),
      loading: service.tagsLoading,
      emptyText: "No tags yet. Type a name to create one.",
      onPick: function(item) {
        var assign = function(tagId, label) {
          root.service.call("tag.assign", { id: tagId, ids: root.ids(assets) }, function(r, e) {
            if (e) return pickerDialog.finish(e.message)
            pickerDialog.finish("")
            viewer.reloadDetails()
            toast.show("Tagged " + Format.count(assets.length, "photo") + " “" + label + "”")
          })
        }
        if (item.create) {
          root.service.call("tag.create", { name: item.create }, function(t, e) {
            if (e) return pickerDialog.finish(e.message)
            root.service.loadTags()
            assign(t.id, t.value || t.name)
          })
        } else assign(item.id, item.label)
        return "pending"
      }
    })
  }

  function shareAssets(assets) {
    shareDialog.ask({ assetIds: ids(assets), title: "Share " + Format.count(assets.length, "photo") })
  }

  function shareAlbum(album) {
    shareDialog.ask({ albumId: album.id, title: "Share “" + album.albumName + "”" })
  }

  function copy(text) {
    Quickshell.execDetached(["wl-copy", "--", text])
  }

  function download(assets) {
    toast.show("Downloading " + Format.count(assets.length, "original") + "…", { duration: 60000 })
    service.call("asset.download", { ids: ids(assets) }, function(r, e) {
      if (e) return root.failed(e)
      var first = r.paths[0] || ""
      toast.show(r.paths.length === 1 ? "Saved " + first.split("/").pop() + " to " + r.directory
        : "Saved " + Format.count(r.paths.length, "file") + " to " + r.directory, {
        actionText: "Show",
        action: function() { Quickshell.execDetached(["xdg-open", r.paths.length === 1 ? first : r.directory]) }
      })
    })
  }

  // Drag photos out of the window as files. Originals are fetched into a
  // cache first (quick when they were dragged before); files already on
  // this computer are dragged as they are.
  property int dragGeneration: 0
  function startDrag(assets) {
    var local = []
    var remote = []
    for (var i = 0; i < assets.length; i++) {
      if (assets[i].localPath) local.push("file://" + assets[i].localPath)
      else if (assets[i].id && String(assets[i].id).indexOf("local:") !== 0) remote.push(assets[i].id)
    }
    var generation = ++dragGeneration
    var begin = function(urls) {
      if (generation !== root.dragGeneration || urls.length === 0) return
      dragSource.urls = urls
      dragSource.image = assets[0] && !assets[0].localPath ? root.service.thumbUrl(assets[0].id, "thumbnail", assets[0].thumbhash) : (local[0] || "")
      dragSource.Drag.active = true
    }
    if (remote.length === 0) {
      begin(local)
      return
    }
    var slow = Qt.createQmlObject("import QtQuick; Timer { interval: 400; running: true }", root)
    slow.triggered.connect(function() {
      if (generation === root.dragGeneration) toast.show("Getting " + Format.count(remote.length, "original") + " ready to drag…", { duration: 4000 })
      slow.destroy()
    })
    service.call("export.prepare", { ids: remote }, function(r, e) {
      if (e) return root.failed(e)
      begin(local.concat(r.paths.map(function(p) { return "file://" + p })))
    })
  }

  function uploadLocal(assets) {
    var paths = assets.filter(function(a) { return !!a.localPath }).map(function(a) { return a.localPath })
    service.call("sync.uploadFiles", { paths: paths }, function(r, e) {
      if (e) return root.failed(e)
      toast.show("Uploading " + Format.count(r.queued, "file") + "…", { actionText: "Show progress", action: function() { root.go("sync") } })
    })
  }

  function removeFromAlbum(assets, grid) {
    var album = albumPage
    if (!album) return
    service.call("album.removeAssets", { id: album.id, ids: ids(assets) }, function(r, e) {
      if (e) return root.failed(e)
      root.afterChange(grid, assets, {}, true)
      root.service.loadAlbums(true)
      toast.show("Removed " + Format.count(r.changed, "photo") + " from “" + album.albumName + "”")
    })
  }

  // The person's face thumbnail, cropped by Immich from this photo. Immich
  // crops it in a background job after answering, so the picture is
  // reloaded only once the person's version moves on again (or, if it never
  // does, after a while anyway); loading it at once would cache the old face.
  function setKeyPhoto(asset) {
    var person = personPage
    if (!person) return
    service.call("person.update", { id: person.id, featureFaceAssetId: asset.id }, function(r, e) {
      if (e) return root.failed(e)
      toast.show("Key photo updated" + (person.name ? " for " + person.name : ""))
      keyPhotoWait.person = person
      keyPhotoWait.version = r.version
      keyPhotoWait.tries = 0
      keyPhotoWait.restart()
    })
  }

  function showKeyPhoto(person) {
    root.service.patchPerson(person)
    if (root.page && root.page.kind === "person" && root.page.person.id === person.id)
      root.replacePage({ kind: "person", person: Object.assign({}, root.page.person, person) })
  }

  Timer {
    id: keyPhotoWait
    property var person: null
    property string version: ""
    property int tries: 0
    interval: 1000
    onTriggered: {
      var person = keyPhotoWait.person
      var version = keyPhotoWait.version
      keyPhotoWait.tries++
      root.service.call("person.get", { id: person.id }, function(r, e) {
        if (!root) return
        if (!e && r.version !== version)
          return root.showKeyPhoto(Object.assign({}, person, r))
        if (keyPhotoWait.tries < 15) return keyPhotoWait.restart()
        // The version never moved: load the picture again regardless.
        root.showKeyPhoto(Object.assign({}, person, e ? {} : r, { version: version + "k" + Date.now() }))
      })
    }
  }

  function setAlbumCover(asset) {
    var album = albumPage
    if (!album) return
    service.call("album.update", { id: album.id, albumThumbnailAssetId: asset.id }, function(r, e) {
      if (e) return root.failed(e)
      root.service.loadAlbums(true)
      toast.show("Album cover updated")
    })
  }

  // The context menu for one photo, or for the selection it belongs to.
  function showPhotoMenu(asset, item, x, y) {
    var grid = activeGrid()
    var targets = grid && grid.selecting && grid.selected[asset.id] ? grid.targets() : [asset]
    var many = targets.length > 1
    var fav = targets.every(function(a) { return a.isFavorite })
    var items = []
    if (asset.localPath) {
      var unsynced = targets.filter(function(a) { return String(a.id).indexOf("local:") === 0 })
      if (unsynced.length > 0) {
        menu.items = [
          { id: "view", label: "View", icon: "image" },
          { id: "upload", label: unsynced.length > 1 ? "Upload " + unsynced.length + " files now" : "Upload now", icon: "upload" },
          { id: "folder", label: "Show in folder", icon: "folder" }
        ]
        menu.activated.disconnect(root.menuHandler)
        root.menuHandler = function(id) {
          if (id === "view") root.openViewer(asset)
          else if (id === "upload") root.uploadLocal(unsynced)
          else if (id === "folder") Qt.openUrlExternally("file://" + asset.localPath.slice(0, asset.localPath.lastIndexOf("/")))
        }
        menu.activated.connect(root.menuHandler)
        menu.trigger = null
        menu.openAt(item, x, y)
        return
      }
    }
    if (!many) items.push({ id: "view", label: "View", icon: "image", shortcut: "enter" })
    items.push({ id: "favorite", label: fav ? "Remove from favourites" : "Add to favourites", icon: fav ? "favoriteOn" : "favorite", shortcut: "f" })
    if (!inTrash) {
      items.push({ id: "addToAlbum", label: "Add to album...", icon: "albums", shortcut: "A" })
      items.push({ id: "tag", label: "Tag...", icon: "tag", shortcut: "t" })
      items.push({ id: "share", label: "Share link...", icon: "link", shortcut: "s" })
      items.push({ id: "download", label: many ? "Download originals" : "Download original", icon: "download", shortcut: "D" })
      items.push({ id: "editDate", label: "Edit date...", icon: "calendar", shortcut: "e" })
      if (albumPage) {
        items.push({ separator: true })
        if (!many) items.push({ id: "cover", label: "Use as album cover", icon: "image" })
        items.push({ id: "removeFromAlbum", label: "Remove from album", icon: "close" })
      }
      if (personPage && !many) {
        items.push({ separator: true })
        items.push({ id: "keyPhoto", label: "Make key photo", icon: "person" })
      }
      items.push({ separator: true })
      items.push({ id: "archive", label: inArchive ? "Unarchive" : "Archive", icon: inArchive ? "unarchive" : "archive", shortcut: "a" })
      items.push({ id: "trash", label: "Move to trash", icon: "trash", shortcut: "d", danger: true })
    } else {
      items.push({ id: "trash", label: "Restore", icon: "restore", shortcut: "d" })
      items.push({ id: "deleteForever", label: "Delete permanently...", icon: "deleteForever", danger: true })
    }
    menu.items = items
    menu.activated.disconnect(root.menuHandler)
    root.menuHandler = function(id) {
      if (id === "view") root.openViewer(asset)
      else if (id === "cover") root.setAlbumCover(asset)
      else if (id === "keyPhoto") root.setKeyPhoto(asset)
      else if (id === "removeFromAlbum") root.removeFromAlbum(targets, grid)
      else root.photoAction(id, targets, grid)
    }
    menu.activated.connect(root.menuHandler)
    menu.trigger = null
    menu.openAt(item, x, y)
  }
  property var menuHandler: function() {}

  function showMenu(items, item, handler) {
    menu.items = items
    menu.activated.disconnect(root.menuHandler)
    root.menuHandler = handler
    menu.activated.connect(root.menuHandler)
    menu.openBelow(item)
  }

  // ---------------------------------------------------------------- search

  function runSearch(text) {
    var query = String(text || "").trim()
    if (!query) {
      // Enter in an empty search field: filter the whole library instead.
      settingsOpen = false
      viewerAsset = null
      var filterEntry = { kind: "search", query: "", mode: "metadata", filters: {} }
      if (page && page.kind === "search") replacePage(filterEntry)
      else push(filterEntry)
      return
    }
    var mode = "smart"
    var m = /^(file|filename|ocr|text|desc|description):\s*(.*)$/i.exec(query)
    if (m) {
      var prefix = m[1].toLowerCase()
      mode = prefix === "file" || prefix === "filename" ? "filename"
        : prefix === "ocr" || prefix === "text" ? "ocr" : "description"
      query = m[2]
    }
    if (!features().smartSearch && mode === "smart") mode = "filename"
    settingsOpen = false
    viewerAsset = null
    var entry = { kind: "search", query: query, mode: mode, filters: {} }
    if (page && page.kind === "search") replacePage(entry)
    else push(entry)
    focusContent()
  }

  function features() {
    return service && service.features ? service.features : ({})
  }

  // ---------------------------------------------------------------- window

  FloatingWindow {
    id: window
    title: "Omamich"
    color: appTheme.background
    implicitWidth: appTheme.space(1240)
    implicitHeight: appTheme.space(820)
    minimumSize: Qt.size(appTheme.space(360), appTheme.space(420))
    visible: false

    onVisibleChanged: {
      if (!visible && root.opened && !root.closingFromHost) root.requestClose()
    }

    // Everything in the window, as one item: it can be grabbed as an image.
    Item {
      id: frame
      anchors.fill: parent

    Item {
      id: keyPark
      focus: true
      anchors.fill: parent
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Alt) sidebar.showNumbers = true
      }
      Keys.onReleased: function(event) {
        if (event.key === Qt.Key_Alt) sidebar.showNumbers = false
      }
      onActiveFocusChanged: if (!activeFocus) sidebar.showNumbers = false
    }

    KeyRouter {
      context: root.keyContext
      onTriggered: function(id, sequence) { root.runShortcut(id, sequence) }
    }

    // Mouse back button steps back the way Escape does.
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.BackButton | Qt.ForwardButton
      z: -1
      onClicked: function(mouse) {
        if (mouse.button === Qt.ForwardButton) root.historyForward()
        else root.goBack()
      }
    }

    // ------------------------------------------------------------ header
    Item {
      id: header
      visible: !root.fullscreen
      anchors { left: parent.left; right: parent.right; top: parent.top }
      height: visible ? appTheme.space(52) : 0

      Row {
        id: identity
        anchors.left: parent.left
        anchors.leftMargin: appTheme.space(16)
        anchors.verticalCenter: parent.verticalCenter
        spacing: appTheme.space(10)
        Glyph {
          name: "logo"
          size: appTheme.heading + 4
          color: appTheme.accent
          font.family: appTheme.font
          anchors.verticalCenter: parent.verticalCenter
        }
        Text {
          visible: !root.narrow
          text: "Omamich"
          color: appTheme.foreground
          font.family: appTheme.font
          font.pixelSize: appTheme.heading
          anchors.verticalCenter: parent.verticalCenter
        }
        Row {
          visible: root.configured
          anchors.verticalCenter: parent.verticalCenter
          IconButton {
            theme: appTheme
            icon: "back"
            enabled: root.canGoBackInHistory
            tooltip: "Back (Alt+Left)"
            onClicked: root.historyBack()
          }
          IconButton {
            theme: appTheme
            icon: "forward"
            enabled: root.canGoForward
            tooltip: "Forward (Alt+Right)"
            onClicked: root.historyForward()
          }
        }
      }

      SearchBar {
        id: searchBar
        theme: appTheme
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(appTheme.space(560), parent.width - identity.width - actions.width - appTheme.space(80))
        visible: root.configured
        onSubmitted: function(text) { root.runSearch(text) }
        onCancelled: { clear(); root.focusContent() }
      }

      Row {
        id: actions
        anchors.right: parent.right
        anchors.rightMargin: appTheme.space(12)
        anchors.verticalCenter: parent.verticalCenter
        spacing: appTheme.space(4)
        visible: root.configured
        IconButton {
          visible: !root.narrow
          theme: appTheme
          icon: "zoomOut"
          tooltip: "Smaller thumbnails"
          onClicked: root.setZoom(root.zoom / 1.2)
        }
        IconButton {
          visible: !root.narrow
          theme: appTheme
          icon: "zoomIn"
          tooltip: "Larger thumbnails"
          onClicked: root.setZoom(root.zoom * 1.2)
        }
        IconButton {
          theme: appTheme
          icon: "refresh"
          tooltip: "Reload (r)"
          busy: root.service ? root.service.serverLoading : false
          onClicked: root.refreshContent()
        }
        IconButton {
          theme: appTheme
          icon: "upload"
          tooltip: "Upload files... (or drop them on the window)"
          onClicked: { uploadDialog.albumId = root.albumPage ? root.albumPage.id : ""; uploadDialog.open() }
        }
        IconButton {
          theme: appTheme
          icon: "settings"
          tooltip: "Settings (Ctrl+,)"
          selected: root.settingsOpen
          onClicked: root.setSettings(!root.settingsOpen)
        }
      }

      Rectangle {
        anchors.bottom: parent.bottom
        width: parent.width
        height: appTheme.borderWidth
        color: appTheme.border
      }
    }

    // ------------------------------------------------------------ body
    Item {
      id: body
      anchors { left: parent.left; right: parent.right; top: header.bottom; bottom: bottomNav.top }

      readonly property bool compact: width < appTheme.space(820)

      Sidebar {
        id: sidebar
        theme: appTheme
        visible: root.configured && !root.fullscreen && !root.narrow
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
        width: visible ? implicitWidth : 0
        sections: root.sections
        current: root.settingsOpen ? "" : root.section
        collapsed: root.sidebarCollapsed || body.compact
        footerTitle: root.service && root.service.user ? String(root.service.user.name || root.service.user.email) : "Immich"
        footerDetail: !root.service ? "" : root.service.serverError !== "" ? root.service.serverError
          : (root.service.serverVersion ? "Immich " + root.service.serverVersion + (root.service.route === "wan" ? " · away" : "") : "Connecting…")
        footerAttention: !!root.service && root.service.serverError !== ""
        footerIcon: !!root.service && root.service.serverError !== "" ? "cloudOff" : "server"
        onPicked: function(id) { root.go(id) }
        onFooterClicked: root.setSettings(true)
      }

      Item {
        id: content
        anchors { left: sidebar.right; right: infoPanel.left; top: parent.top; bottom: parent.bottom }
        clip: true

        Loader {
          id: contentLoader
          anchors.fill: parent
          active: root.configured && !root.settingsOpen
          sourceComponent: {
            var p = root.page
            if (p) {
              if (p.kind === "album") return albumPageView
              if (p.kind === "person") return personPageView
              if (p.kind === "place") return placePage
              if (p.kind === "tag") return tagPage
              if (p.kind === "search") return searchPage
              if (p.kind === "staging") return stagingPage
            }
            switch (root.section) {
            case "explore": return exploreView
            case "people": return peopleView
            case "places": return placesView
            case "albums": return albumsView
            case "sharing": return sharingView
            case "tags": return tagsView
            case "folders": return foldersView
            case "sync": return syncView
            case "computer": return localView
            case "favorites": return favoritesView
            case "archive": return archiveView
            case "trash": return trashView
            default: return photosView
            }
          }
        }

        Loader {
          anchors.fill: parent
          active: root.settingsOpen && root.configured
          sourceComponent: SettingsView {
            theme: appTheme
            service: root.service
            onClosed: { root.setSettings(false); root.focusContent() }
            onToast: function(text, tone) { toast.show(text, { tone: tone }) }
          }
        }

        Loader {
          anchors.fill: parent
          active: root.ready && root.service.settingsLoaded && !root.configured
          sourceComponent: SetupView {
            theme: appTheme
            service: root.service
          }
        }

        BackendStatus {
          anchors.fill: parent
          visible: !!root.service && !root.service.ready
          theme: appTheme
          service: root.service
        }
      }

      InfoPanel {
        id: infoPanel
        theme: appTheme
        service: root.service
        anchors { right: parent.right; top: parent.top; bottom: parent.bottom }
        visible: width > 0
        width: root.infoOpen && root.viewerAsset && !body.compact ? appTheme.space(340) : 0
        details: viewer.details
        faces: viewer.faces
        selectedFace: viewer.selectedFace
        asset: root.viewerAsset
        onClosed: root.setInfo(false)
        onToast: function(text, tone) { toast.show(text, { tone: tone }) }
        onChanged: viewer.reloadDetails()
        onPersonOpened: function(person) { root.closeViewer(); root.go("people"); root.push({ kind: "person", person: person }) }
        onAlbumOpened: function(album) { root.closeViewer(); root.go("albums"); root.push({ kind: "album", album: album }) }
        onPlaceOpened: function(place) { root.closeViewer(); root.go("places"); root.push({ kind: "place", place: place }) }
        onTagOpened: function(tag) { root.closeViewer(); root.go("tags"); root.push({ kind: "tag", tag: tag }) }
        onEditDate: root.editDate([root.viewerAsset], root.activeGrid())
        onFaceHovered: function(id) { viewer.hoverFace = id }
        onFaceClicked: function(face, item) { root.showFaceMenu(face, item) }
      }

      Viewer {
        id: viewer
        theme: appTheme
        service: root.service
        anchors { left: sidebar.right; right: infoPanel.left; top: parent.top; bottom: parent.bottom }
        asset: root.viewerAsset
        visible: root.viewerAsset !== null
        inTrash: root.inTrash
        inArchive: root.inArchive
        onCloseRequested: root.closeViewer()
        onStepRequested: function(delta) { root.step(delta) }
        onActionRequested: function(id) { root.viewerAction(id, "") }
        onInfoToggled: root.setInfo(!root.infoOpen)
        infoOpen: root.infoOpen
        onMenuRequested: function(item) { root.showPhotoMenu(root.viewerAsset, item, 0, item.height) }
        onFaceClicked: function(face, item) { root.showFaceMenu(face, item) }
      }
    }

    // ------------------------------------------------------------ bottom tabs
    BottomNav {
      id: bottomNav
      theme: appTheme
      anchors { left: parent.left; right: parent.right; bottom: statusBar.top }
      visible: root.narrow && root.configured && !root.fullscreen
      height: visible ? implicitHeight : 0
      sections: root.sections
      current: root.settingsOpen ? "" : root.section
      onPicked: function(id) { root.go(id) }
      onMoreRequested: function(item, rest) {
        root.showMenu(rest.map(function(s) { return { id: s.id, label: s.label, icon: s.icon } }), item, function(id) { root.go(id) })
      }
    }

    // ------------------------------------------------------------ status bar
    StatusBar {
      id: statusBar
      theme: appTheme
      visible: !root.fullscreen
      anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
      height: visible ? implicitHeight : 0
      context: root.keyContext
      sidebarCollapsed: root.sidebarCollapsed
      leftIcon: !root.service ? "" : root.service.syncAttention ? "warning" : root.service.syncBusy ? "sync" : "cloudCheck"
      leftBusy: !!root.service && root.service.syncBusy
      leftAttention: !!root.service && root.service.syncAttention
      leftText: root.service ? root.service.syncSummary : ""
      middleText: {
        var grid = root.activeGrid()
        if (grid && grid.selecting) return Format.count(grid.selectedCount, "selected", "selected")
        if (root.viewerAsset) return viewer.details ? viewer.details.originalFileName || "" : ""
        return contentLoader.item && contentLoader.item.statusText ? contentLoader.item.statusText : ""
      }
      onSidebarToggled: root.toggleSidebar()
      onLeftClicked: root.go("sync")
    }

    // ------------------------------------------------------------ selection bar
    SelectionBar {
      id: selectionBar
      theme: appTheme
      grid: root.activeGrid()
      visible: !!grid && grid.selecting && !root.viewerAsset
      anchors.horizontalCenter: body.horizontalCenter
      anchors.bottom: statusBar.top
      anchors.bottomMargin: appTheme.space(14)
      inTrash: root.inTrash
      inArchive: root.inArchive
      inAlbum: root.albumPage !== null
      onAction: function(id) {
        var grid = root.activeGrid()
        if (id === "removeFromAlbum") root.removeFromAlbum(grid.targets(), grid)
        else if (id === "clear") grid.clearSelection()
        else root.photoAction(id, grid.targets(), grid)
      }
    }

    // ------------------------------------------------------------ overlays
    Toast {
      id: toast
      theme: appTheme
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: statusBar.height + appTheme.space(18) + (selectionBar.visible ? selectionBar.height + appTheme.space(12) : 0)
    }

    ShortcutHelp {
      theme: appTheme
      anchors.fill: parent
      visible: root.helpOpen
      onClosed: root.helpOpen = false
    }

    PopupMenu {
      id: menu
      theme: appTheme
      parent: frame
      onClosed: root.focusContent()
    }

    PromptDialog { id: promptDialog; theme: appTheme; onDismissed: root.focusContent() }
    AlbumPeopleDialog {
      id: albumPeople
      theme: appTheme
      service: root.service
      onDismissed: root.focusContent()
      onAlbumUpdated: function(a) {
        if (root.page && root.page.kind === "album" && root.page.album.id === a.id) root.replacePage({ kind: "album", album: a })
        root.service.loadAlbums(true)
      }
    }
    ConfirmDialog { id: confirmDialog; theme: appTheme; onDismissed: root.focusContent() }
    PickerDialog { id: pickerDialog; theme: appTheme; onDismissed: root.focusContent() }
    ShareDialog {
      id: shareDialog
      theme: appTheme
      service: root.service
      onDismissed: root.focusContent()
      onCopied: function(url) { root.copy(url); toast.show("Link copied: " + url) }
    }

    UploadDialog {
      id: uploadDialog
      service: root.service
      onChosen: function(paths) { root.stage(paths, uploadDialog.albumId) }
    }

    // The far end of a drag out of the window.
    Item {
      id: dragSource
      width: 1
      height: 1
      property var urls: []
      property string image: ""
      Drag.dragType: Drag.Automatic
      Drag.supportedActions: Qt.CopyAction
      Drag.mimeData: ({ "text/uri-list": dragSource.urls })
      Drag.imageSource: dragSource.image
      Drag.onDragFinished: function(action) { dragSource.Drag.active = false }
    }

    // Files dropped on the window are uploaded.
    DropArea {
      anchors.fill: parent
      keys: ["text/uri-list"]
      onDropped: function(drop) {
        if (!drop.hasUrls || !root.configured) return
        // A drag that started in this window is not an upload.
        if (dragSource.Drag.active) return
        var paths = []
        for (var i = 0; i < drop.urls.length; i++) paths.push(String(drop.urls[i]))
        root.stage(paths, root.albumPage ? root.albumPage.id : "")
        drop.accept()
      }
    }
    }
  }

  // ---------------------------------------------------------------- views

  Component {
    id: photosView
    PhotosView {
      theme: appTheme; service: root.service; zoom: root.zoom
      title: "Photos"
      scope: ({ withPartners: true })
      emptyText: "Photos you add to Immich, or that folder sync uploads, appear here."
      onOpenAsset: function(a) { root.openViewer(a) }
      onContextRequested: function(a, item, x, y) { root.showPhotoMenu(a, item, x, y) }
    }
  }
  Component {
    id: favoritesView
    PhotosView {
      theme: appTheme; service: root.service; zoom: root.zoom
      title: "Favourites"
      scope: ({ isFavorite: true })
      emptyIcon: "favorite"
      emptyTitle: "No favourites yet"
      emptyText: "Press f on a photo, or use its menu, to keep it here."
      onOpenAsset: function(a) { root.openViewer(a) }
      onContextRequested: function(a, item, x, y) { root.showPhotoMenu(a, item, x, y) }
    }
  }
  Component {
    id: archiveView
    PhotosView {
      theme: appTheme; service: root.service; zoom: root.zoom
      title: "Archive"
      subtitle: "Archived photos stay out of the timeline but remain in albums and search."
      scope: ({ visibility: "archive" })
      emptyIcon: "archive"
      emptyTitle: "Nothing archived"
      emptyText: "Press a to archive a photo you want out of the timeline."
      onOpenAsset: function(a) { root.openViewer(a) }
      onContextRequested: function(a, item, x, y) { root.showPhotoMenu(a, item, x, y) }
    }
  }
  Component {
    id: trashView
    PhotosView {
      theme: appTheme; service: root.service; zoom: root.zoom
      title: "Trash"
      subtitle: "Photos here are deleted for good after the server's trash period."
      scope: ({ isTrashed: true })
      emptyIcon: "trash"
      emptyTitle: "The trash is empty"
      actions: [
        { id: "restoreAll", label: "Restore all", icon: "restore" },
        { id: "empty", label: "Empty trash...", icon: "deleteForever", danger: true }
      ]
      onOpenAsset: function(a) { root.openViewer(a) }
      onContextRequested: function(a, item, x, y) { root.showPhotoMenu(a, item, x, y) }
      onActionTriggered: function(id) {
        if (id === "restoreAll") {
          root.service.call("trash.restoreAll", {}, function(r, e) {
            if (e) return root.failed(e)
            root.refreshContent()
            var count = r.count === null || r.count === undefined ? "everything" : Format.count(r.count, "photo")
            if (r.left > 0) toast.show("Restored " + count + ". " + root.keptInTrash(r.left, r.left), { tone: "error", duration: 12000 })
            else toast.show("Restored " + count + " from the trash")
          })
        } else if (id === "empty") {
          confirmDialog.ask({
            title: "Empty the trash?",
            message: "Every photo in the trash is deleted from Immich for good. This cannot be undone.",
            confirmText: "Empty trash",
            onConfirm: function() {
              root.service.call("trash.empty", {}, function(r, e) {
                if (e) return root.failed(e)
                root.refreshContent()
                toast.show("The trash is being emptied")
              })
            }
          })
        }
      }
    }
  }
  Component {
    id: albumPageView
    AlbumPage {
      theme: appTheme; service: root.service; zoom: root.zoom
      album: root.page ? root.page.album : null
      onOpenAsset: function(a) { root.openViewer(a) }
      onContextRequested: function(a, item, x, y) { root.showPhotoMenu(a, item, x, y) }
      onBack: root.pop()
      onShare: root.shareAlbum(album)
      onPeople: albumPeople.ask(album)
      onRename: {
        var current = album
        promptDialog.ask({
          title: "Rename album", value: current.albumName, confirmText: "Rename",
          onAccept: function(text) {
            if (!text.trim()) return "Albums need a name"
            root.service.call("album.update", { id: current.id, albumName: text.trim() }, function(r, e) {
              if (e) return promptDialog.finish(e.message)
              promptDialog.finish("")
              root.replacePage({ kind: "album", album: r })
              root.service.loadAlbums(true)
            })
            return "pending"
          }
        })
      }
      onDescribe: {
        var current = album
        promptDialog.ask({
          title: "Album description", value: current.description || "", confirmText: "Save",
          placeholder: "What these photos are about",
          onAccept: function(text) {
            root.service.call("album.update", { id: current.id, description: text }, function(r, e) {
              if (e) return promptDialog.finish(e.message)
              promptDialog.finish("")
              root.replacePage({ kind: "album", album: r })
              root.service.loadAlbums(true)
            })
            return "pending"
          }
        })
      }
      onRemove: {
        var current = album
        confirmDialog.ask({
          title: "Delete “" + current.albumName + "”?",
          message: "The album goes away; its photos stay in your library.",
          confirmText: "Delete album",
          onConfirm: function() {
            root.service.call("album.delete", { id: current.id }, function(r, e) {
              if (e) return root.failed(e)
              root.service.loadAlbums(true)
              root.pop()
              toast.show("Deleted the album “" + current.albumName + "”")
            })
          }
        })
      }
      onToggleOrder: {
        var current = album
        root.service.call("album.update", { id: current.id, order: current.order === "asc" ? "desc" : "asc" }, function(r, e) {
          if (e) return root.failed(e)
          root.replacePage({ kind: "album", album: r })
        })
      }
    }
  }
  Component {
    id: personPageView
    PersonPage {
      theme: appTheme; service: root.service; zoom: root.zoom
      person: root.page ? root.page.person : null
      onOpenAsset: function(a) { root.openViewer(a) }
      onContextRequested: function(a, item, x, y) { root.showPhotoMenu(a, item, x, y) }
      onBack: root.pop()
      onRename: root.renamePerson(person)
      onSetBirthday: root.setBirthday(person)
      onMerge: root.mergePerson(person)
      onUpdatePerson: function(change) { root.updatePerson(person, change) }
    }
  }
  Component {
    id: placePage
    PhotosView {
      theme: appTheme; service: root.service; zoom: root.zoom
      readonly property var place: root.page ? root.page.place : null
      title: place ? (place.city || place.country) : ""
      subtitle: place ? [place.city ? place.country : "", place.count ? Format.count(place.count, "photo") : ""].filter(function(s) { return s }).join(" · ") : ""
      showBack: true
      emptyIcon: "places"
      pager: function(page, done) {
        root.service.call("place.assets", { city: place.city || "", country: place.country || "", page: page }, function(r, e) {
          if (e) return done([], false, e)
          done(r.items, r.nextPage !== null && r.nextPage !== undefined, null)
        })
      }
      onBack: root.pop()
      onOpenAsset: function(a) { root.openViewer(a) }
      onContextRequested: function(a, item, x, y) { root.showPhotoMenu(a, item, x, y) }
    }
  }
  Component {
    id: tagPage
    PhotosView {
      theme: appTheme; service: root.service; zoom: root.zoom
      readonly property var tag: root.page ? root.page.tag : null
      title: tag ? (tag.value || tag.name) : ""
      showBack: true
      scope: tag ? ({ tagId: tag.id }) : ({})
      emptyIcon: "tag"
      emptyTitle: "No photos with this tag"
      onBack: root.pop()
      onOpenAsset: function(a) { root.openViewer(a) }
      onContextRequested: function(a, item, x, y) { root.showPhotoMenu(a, item, x, y) }
    }
  }
  Component {
    id: searchPage
    SearchPage {
      theme: appTheme; service: root.service; zoom: root.zoom
      entry: root.page
      onBack: { searchBar.clear(); root.pop() }
      onOpenAsset: function(a) { root.openViewer(a) }
      onContextRequested: function(a, item, x, y) { root.showPhotoMenu(a, item, x, y) }
      onModeChanged: function(mode, filters) {
        root.replacePage(Object.assign({}, root.page, { mode: mode, filters: filters }))
      }
      onPick: function(options) { pickerDialog.ask(options) }
      onPrompt: function(options) { promptDialog.ask(options) }
    }
  }
  Component {
    id: stagingPage
    StagingPage {
      theme: appTheme; service: root.service
      entry: root.page
      onBack: root.pop()
      onFailed: function(message) { toast.show(message, { tone: "error" }) }
      onUploaded: function(count, albumName) {
        root.pop()
        toast.show("Uploading " + Format.count(count, "file") + (albumName ? " into “" + albumName + "”" : "") + "…", {
          actionText: "Show progress", action: function() { root.go("sync") }
        })
      }
      onPickAlbum: function(onPicked) {
        root.service.loadAlbums(true)
        pickerDialog.ask({
          title: "Upload into an album",
          placeholder: "Find or name an album",
          createLabel: "Create album",
          items: root.albumItems(),
          loading: root.service.albumsLoading,
          emptyText: "No albums yet. Type a name to create one.",
          onPick: function(item) { onPicked(item); return true }
        })
      }
    }
  }
  Component {
    id: exploreView
    ExploreView {
      theme: appTheme; service: root.service
      onPersonOpened: function(p) { root.go("people"); root.push({ kind: "person", person: p }) }
      onPlaceOpened: function(p) { root.go("places"); root.push({ kind: "place", place: p }) }
      onSectionOpened: function(id) { root.go(id) }
      onSearch: function(q) { searchBar.text = q; root.runSearch(q) }
      onTagOpened: function(t) { root.go("tags"); root.push({ kind: "tag", tag: t }) }
      showPeople: root.sectionAvailable("people")
      showPlaces: root.sectionAvailable("places")
      showTags: root.sectionAvailable("tags")
      showFolders: root.sectionAvailable("folders")
    }
  }
  Component {
    id: peopleView
    PeopleView {
      theme: appTheme; service: root.service
      onPersonOpened: function(p) { root.push({ kind: "person", person: p }) }
      onRename: function(p) { root.renamePerson(p) }
      onUpdatePerson: function(p, change) { root.updatePerson(p, change) }
      onMenuRequested: function(p, item) { root.showPersonMenu(p, item) }
    }
  }
  Component {
    id: placesView
    PlacesView {
      theme: appTheme; service: root.service
      onPlaceOpened: function(p) { root.push({ kind: "place", place: p }) }
    }
  }
  Component {
    id: albumsView
    AlbumsView {
      theme: appTheme; service: root.service
      onAlbumOpened: function(a) { root.push({ kind: "album", album: a }) }
      onCreate: root.createAlbum()
      onMenuRequested: function(a, item) { root.showAlbumMenu(a, item) }
    }
  }
  Component {
    id: sharingView
    SharingView {
      theme: appTheme; service: root.service
      onAlbumOpened: function(a) { root.go("albums"); root.push({ kind: "album", album: a }) }
      onCopied: function(url) { root.copy(url); toast.show("Link copied") }
      onToast: function(text, tone) { toast.show(text, { tone: tone }) }
      onConfirm: function(options) { confirmDialog.ask(options) }
      onPick: function(options) { pickerDialog.ask(options) }
      onPickFinished: function(message) { pickerDialog.finish(message) }
    }
  }
  Component {
    id: tagsView
    TagsView {
      theme: appTheme; service: root.service
      onTagOpened: function(t) { root.push({ kind: "tag", tag: t }) }
      onToast: function(text, tone) { toast.show(text, { tone: tone }) }
      onConfirm: function(options) { confirmDialog.ask(options) }
      onPrompt: function(options) { promptDialog.ask(options) }
      onPromptFinished: function(message) { promptDialog.finish(message) }
    }
  }
  Component {
    id: foldersView
    FoldersView {
      theme: appTheme; service: root.service; zoom: root.zoom
      onOpenAsset: function(a) { root.openViewer(a) }
      onContextRequested: function(a, item, x, y) { root.showPhotoMenu(a, item, x, y) }
    }
  }
  Component {
    id: localView
    LocalView {
      theme: appTheme; service: root.service; zoom: root.zoom
      onOpenAsset: function(a) { root.openViewer(a) }
      onContextRequested: function(a, item, x, y) { root.showPhotoMenu(a, item, x, y) }
      onOpenSync: root.go("sync")
    }
  }
  Component {
    id: syncView
    SyncView {
      theme: appTheme; service: root.service
      onToast: function(text, tone) { toast.show(text, { tone: tone }) }
      onConfirm: function(options) { confirmDialog.ask(options) }
    }
  }

  function replacePage(entry) {
    var next = stack.slice()
    next[next.length - 1] = entry
    stack = next
    if (!restoring && history[historyIndex]) {
      var h = history.slice()
      h[historyIndex] = snapshot()
      history = h
    }
  }

  function createAlbum() {
    promptDialog.ask({
      title: "New album", placeholder: "Album name", confirmText: "Create",
      onAccept: function(text) {
        if (!text.trim()) return "Albums need a name"
        root.service.call("album.create", { albumName: text.trim() }, function(r, e) {
          if (e) return promptDialog.finish(e.message)
          promptDialog.finish("")
          root.service.loadAlbums(true)
          root.push({ kind: "album", album: r })
        })
        return "pending"
      }
    })
  }

  function showAlbumMenu(album, item) {
    showMenu([
      { id: "open", label: "Open", icon: "albums" },
      { id: "people", label: "People...", icon: "people" },
      { id: "share", label: "Share link...", icon: "link" },
      { separator: true },
      { id: "delete", label: "Delete album...", icon: "trash", danger: true }
    ], item, function(id) {
      if (id === "open") root.push({ kind: "album", album: album })
      else if (id === "people") albumPeople.ask(album)
      else if (id === "share") root.shareAlbum(album)
      else if (id === "delete") confirmDialog.ask({
        title: "Delete “" + album.albumName + "”?",
        message: "The album goes away; its photos stay in your library.",
        confirmText: "Delete album",
        onConfirm: function() {
          root.service.call("album.delete", { id: album.id }, function(r, e) {
            if (e) return root.failed(e)
            root.service.loadAlbums(true)
            toast.show("Deleted the album “" + album.albumName + "”")
          })
        }
      })
    })
  }

  function updatePerson(person, change) {
    var params = Object.assign({ id: person.id }, change)
    service.call("person.update", params, function(r, e) {
      if (e) return root.failed(e)
      root.service.patchPerson(r)
      if (root.page && root.page.kind === "person" && root.page.person.id === r.id)
        root.replacePage({ kind: "person", person: r })
      if (change.isHidden !== undefined) toast.show(change.isHidden ? "Hidden from People" : "Shown in People again")
      if (change.isFavorite !== undefined) toast.show(change.isFavorite ? "Marked as a favourite person" : "No longer a favourite person")
    })
  }

  function renamePerson(person) {
    promptDialog.ask({
      title: person.name ? "Rename " + person.name : "Who is this?",
      value: person.name || "",
      placeholder: "Name",
      confirmText: "Save",
      onAccept: function(text) {
        root.service.call("person.update", { id: person.id, name: text.trim() }, function(r, e) {
          if (e) return promptDialog.finish(e.message)
          promptDialog.finish("")
          root.service.patchPerson(r)
          if (root.page && root.page.kind === "person" && root.page.person.id === r.id)
            root.replacePage({ kind: "person", person: r })
        })
        return "pending"
      }
    })
  }

  function setBirthday(person) {
    promptDialog.ask({
      title: "Birthday of " + (person.name || "this person"),
      subtitle: "Shown as an age on their photos. Leave empty to remove it.",
      value: person.birthDate || "",
      placeholder: "YYYY-MM-DD",
      confirmText: "Save",
      onAccept: function(text) {
        var value = text.trim()
        if (value && !/^\d{4}-\d{2}-\d{2}$/.test(value)) return "Birthdays look like 1984-04-09"
        root.service.call("person.update", { id: person.id, birthDate: value }, function(r, e) {
          if (e) return promptDialog.finish(e.message)
          promptDialog.finish("")
          root.service.patchPerson(r)
          if (root.page && root.page.kind === "person") root.replacePage({ kind: "person", person: r })
        })
        return "pending"
      }
    })
  }

  // ------------------------------------------------------------ faces

  // A face picked in Details or on the photo: it stays framed while its
  // menu, and then the person picker, are open.
  function showFaceMenu(face, item) {
    viewer.selectedFace = face.id
    var person = face.person
    var items = []
    if (person) items.push({ id: "open", label: "Open " + (person.name || "this person"), icon: "person" })
    items.push({ id: "change", label: person ? "Change person..." : "Who is this?...", icon: "edit" })
    items.push({ separator: true })
    items.push({ id: "remove", label: person ? "Remove from " + (person.name || "this person") + "..." : "Forget this face...", icon: "close", danger: true })
    menu.items = items
    menu.activated.disconnect(root.menuHandler)
    root.menuHandler = function(id) {
      if (id === "open") {
        root.closeViewer(); root.go("people")
        root.push({ kind: "person", person: { id: person.id, name: person.name, version: person.version, isHidden: false } })
      } else if (id === "change") root.changeFacePerson(face)
      else if (id === "remove") root.removeFace(face)
    }
    menu.activated.connect(root.menuHandler)
    menu.trigger = null
    menu.openAt(item, 0, item.height)
  }

  // Move one face to someone else: only this face in this photo changes.
  function changeFacePerson(face) {
    service.loadPeople()
    var was = face.person
    var asset = root.viewerAsset
    var items = service.people.filter(function(p) { return p.name && (!was || p.id !== was.id) }).map(function(p) {
      return { id: p.id, label: p.name, image: root.service.personUrl(p.id, p.version), person: p }
    })
    pickerDialog.ask({
      title: "Who is this?",
      subtitle: was ? "Only this face moves; " + (was.name || "the unnamed person") + " keeps their other photos." : "Only this face changes.",
      placeholder: "Find a person, or type a new name",
      createLabel: "New person",
      items: items,
      onPick: function(item) {
        var params = item.create ? { faceId: face.id, name: item.create } : { faceId: face.id, personId: item.id }
        root.service.call("face.reassign", params, function(r, e) {
          if (e) return pickerDialog.finish(e.message)
          pickerDialog.finish("")
          root.faceMoved(face, was, r, asset)
        })
        return "pending"
      }
    })
  }

  // Someone you do not know, or a wrong match: Immich stops tracking the
  // face. The photo stays.
  function removeFace(face) {
    var person = face.person
    var asset = root.viewerAsset
    var name = person ? (person.name || "this person") : ""
    viewer.selectedFace = face.id
    confirmDialog.ask({
      title: person ? "Remove this face from " + name + "?" : "Forget this face?",
      message: (person ? "The photo stays, but " + name + " is no longer shown in it. " : "The photo stays; Immich stops showing this face. ")
        + "This cannot be undone here; Immich finds the face again only if you rerun face detection.",
      confirmText: person ? "Remove" : "Forget",
      onConfirm: function() {
        root.service.call("face.remove", { faceId: face.id }, function(r, e) {
          if (e) return root.failed(e)
          root.service.loadPeople(true)
          if (root.viewerAsset === asset) viewer.reloadDetails()
          if (person && root.page && root.page.kind === "person") root.reloadAfterViewer = true
          toast.show(person ? "Removed from " + name : "Face forgotten")
        })
      }
    })
  }

  function faceMoved(face, was, now, asset) {
    root.service.loadPeople(true)
    if (root.viewerAsset === asset) viewer.reloadDetails()
    // The person page underneath may have gained or lost this photo.
    if (root.page && root.page.kind === "person") root.reloadAfterViewer = true
    var name = now.name || "the new person"
    toast.show("Moved to " + name, was ? {
      actionText: "Undo",
      action: function() {
        root.service.call("face.reassign", { faceId: face.id, personId: was.id }, function(r, e) {
          if (e) return root.failed(e)
          root.service.loadPeople(true)
          if (root.viewerAsset === asset) viewer.reloadDetails()
          toast.show("Moved back to " + (was.name || "the unnamed person"))
        })
      }
    } : {})
  }

  Timer {
    // A face's menu closed without opening the picker: drop its frame.
    id: faceMenuClosed
    interval: 50
    onTriggered: if (!pickerDialog.opened && !confirmDialog.opened && !menu.visible) viewer.selectedFace = ""
  }
  Connections {
    target: menu
    function onClosed() { if (viewer.selectedFace) faceMenuClosed.restart() }
  }
  Connections {
    target: pickerDialog
    function onOpenedChanged() { if (!pickerDialog.opened && viewer.selectedFace) faceMenuClosed.restart() }
  }
  Connections {
    target: confirmDialog
    function onOpenedChanged() { if (!confirmDialog.opened && viewer.selectedFace) faceMenuClosed.restart() }
  }

  function mergePerson(person) {
    service.loadPeople()
    var items = service.people.filter(function(p) { return p.id !== person.id && p.name }).map(function(p) {
      return { id: p.id, label: p.name, image: root.service.personUrl(p.id, p.version), person: p }
    })
    pickerDialog.ask({
      title: "Merge " + (person.name || "this person") + " into…",
      subtitle: "Their faces move to the person you pick. This cannot be undone.",
      placeholder: "Find a person",
      items: items,
      onPick: function(item) {
        root.service.call("person.merge", { id: item.id, ids: [person.id] }, function(r, e) {
          if (e) return pickerDialog.finish(e.message)
          pickerDialog.finish("")
          root.service.loadPeople(true)
          root.replacePage({ kind: "person", person: item.person })
          toast.show("Merged into " + item.label)
        })
        return "pending"
      }
    })
  }

  function showPersonMenu(person, item) {
    showMenu([
      { id: "open", label: "Open", icon: "person" },
      { id: "rename", label: person.name ? "Rename..." : "Name...", icon: "edit" },
      { id: "birthday", label: "Set birthday...", icon: "cake" },
      { id: "favorite", label: person.isFavorite ? "Unfavourite" : "Favourite", icon: person.isFavorite ? "starOn" : "star" },
      { id: "hide", label: person.isHidden ? "Show in People" : "Hide from People", icon: person.isHidden ? "eye" : "eyeOff" },
      { separator: true },
      { id: "merge", label: "Merge into...", icon: "merge" }
    ], item, function(id) {
      if (id === "open") root.push({ kind: "person", person: person })
      else if (id === "rename") root.renamePerson(person)
      else if (id === "birthday") root.setBirthday(person)
      else if (id === "favorite") root.updatePerson(person, { isFavorite: !person.isFavorite })
      else if (id === "hide") root.updatePerson(person, { isHidden: !person.isHidden })
      else if (id === "merge") root.mergePerson(person)
    })
  }

  Connections {
    target: root.service
    function onReadyChanged() {
      if (root.service.ready) {
        root.service.loadAlbums()
        root.service.refreshSync()
      }
    }
  }
}
