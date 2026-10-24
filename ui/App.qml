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
    // From the file manager: "Upload to Immich" hands files over here.
    if (payload.upload && service) {
      var paths = []
      for (var i = 0; i < payload.upload.length && i < 5000; i++) paths.push(String(payload.upload[i]))
      service.call("sync.uploadFiles", { paths: paths }, function(r, e) {
        if (e) return root.failed(e)
        toast.show("Uploading " + Format.count(r.queued, "file") + "…", {
          actionText: "Show progress", action: function() { root.go("sync") }
        })
      })
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
    "zoomReset", "fullscreen", "settings", "sync", "select", "selectAll"]
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

  function requestClose() {
    if (shell && typeof shell.hide === "function") shell.hide(pluginId)
    else close()
  }

  onOpenedChanged: Qt.callLater(function() { window.visible = root.opened })

  // ---------------------------------------------------------------- navigation

  readonly property var sections: [
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

  readonly property bool needsSetup: ready && service.settingsLoaded && !configured

  function go(id) {
    if (id === "settings") {
      settingsOpen = true
      return
    }
    settingsOpen = false
    viewerAsset = null
    stack = []
    searchBar.clear()
    section = id
    Qt.callLater(focusContent)
  }

  function push(entry) {
    viewerAsset = null
    var next = stack.slice()
    next.push(entry)
    stack = next
    Qt.callLater(focusContent)
  }

  function pop() {
    var next = stack.slice()
    next.pop()
    stack = next
    Qt.callLater(focusContent)
  }

  // Escape: leave the innermost thing first.
  function goBack() {
    if (menu.visible) { menu.close(); return }
    if (anyDialogOpen()) { closeDialogs(); return }
    if (helpOpen) { helpOpen = false; return }
    if (searchBar.focused) { searchBar.clear(); focusContent(); return }
    if (viewerAsset) { closeViewer(); return }
    if (settingsOpen) { settingsOpen = false; focusContent(); return }
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
    dialog: anyDialogOpen(),
    page: settingsOpen || needsSetup || (contentLoader.item && contentLoader.item.isForm === true),
    searchFocused: searchBar.focused || (contentLoader.item && contentLoader.item.typing === true),
    viewer: viewerAsset !== null,
    tiles: contentLoader.item ? contentLoader.item.kind === "tiles" : false
  })

  function anyDialogOpen() {
    return promptDialog.opened || confirmDialog.opened || pickerDialog.opened || shareDialog.opened
  }

  function closeDialogs() {
    promptDialog.close()
    confirmDialog.close()
    pickerDialog.close()
    shareDialog.close()
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
    case "settings": settingsOpen = !settingsOpen; return
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

  function closeViewer() {
    viewerAsset = null
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
    case "slideshow": viewer.slideshow = !viewer.slideshow; return
    case "rate":
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

  function ids(assets) {
    return assets.map(function(a) { return a.id })
  }

  function failed(error) {
    toast.show(error.message, { tone: "error" })
  }

  function photoAction(id, assets, grid) {
    if (!assets || assets.length === 0) return
    switch (id) {
    case "favorite": toggleFavorite(assets, grid); return
    case "archive": toggleArchive(assets, grid); return
    case "trash": if (inTrash) restore(assets, grid); else trash(assets, grid); return
    case "deleteForever": deleteForever(assets, grid); return
    case "addToAlbum": addToAlbum(assets, grid); return
    case "tag": tagAssets(assets); return
    case "share": shareAssets(assets); return
    case "download": download(assets); return
    }
  }

  function afterChange(grid, assets, change, leaves) {
    var list = ids(assets)
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
      root.afterChange(grid, assets, { visibility: archive ? "archive" : "timeline" }, leaves)
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
      root.afterChange(grid, assets, {}, true)
      toast.show("Moved " + Format.count(assets.length, "photo") + " to the trash", {
        actionText: "Undo",
        action: function() {
          root.service.call("asset.restore", { ids: root.ids(assets) }, function(r2, e2) {
            if (e2) return root.failed(e2)
            root.refreshContent()
          })
        }
      })
    })
  }

  function restore(assets, grid) {
    service.call("asset.restore", { ids: ids(assets) }, function(r, e) {
      if (e) return root.failed(e)
      root.afterChange(grid, assets, {}, true)
      toast.show("Restored " + Format.count(assets.length, "photo"))
    })
  }

  function deleteForever(assets, grid) {
    confirmDialog.ask({
      title: "Delete " + Format.count(assets.length, "photo") + " permanently?",
      message: "They are removed from Immich and from its storage. This cannot be undone.",
      confirmText: "Delete permanently",
      onConfirm: function() {
        root.service.call("asset.deleteForever", { ids: root.ids(assets) }, function(r, e) {
          if (e) return root.failed(e)
          root.afterChange(grid, assets, {}, true)
          toast.show("Deleted " + Format.count(assets.length, "photo"))
        })
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
    if (!many) items.push({ id: "view", label: "View", icon: "image", shortcut: "enter" })
    items.push({ id: "favorite", label: fav ? "Remove from favourites" : "Add to favourites", icon: fav ? "favoriteOn" : "favorite", shortcut: "f" })
    if (!inTrash) {
      items.push({ id: "addToAlbum", label: "Add to album...", icon: "albums", shortcut: "A" })
      items.push({ id: "tag", label: "Tag...", icon: "tag", shortcut: "t" })
      items.push({ id: "share", label: "Share link...", icon: "link", shortcut: "s" })
      items.push({ id: "download", label: many ? "Download originals" : "Download original", icon: "download", shortcut: "D" })
      if (albumPage) {
        items.push({ separator: true })
        if (!many) items.push({ id: "cover", label: "Use as album cover", icon: "image" })
        items.push({ id: "removeFromAlbum", label: "Remove from album", icon: "close" })
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
    if (!query) return
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
    if (page && page.kind === "search") {
      var next = stack.slice()
      next[next.length - 1] = entry
      stack = next
    } else push(entry)
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
    minimumSize: Qt.size(appTheme.space(640), appTheme.space(460))
    visible: false

    onVisibleChanged: {
      if (!visible && root.opened && !root.closingFromHost) root.requestClose()
    }

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
      acceptedButtons: Qt.BackButton
      z: -1
      onClicked: root.goBack()
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
          text: "Omamich"
          color: appTheme.foreground
          font.family: appTheme.font
          font.pixelSize: appTheme.heading
          anchors.verticalCenter: parent.verticalCenter
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
          theme: appTheme
          icon: "zoomOut"
          tooltip: "Smaller thumbnails"
          onClicked: root.setZoom(root.zoom / 1.2)
        }
        IconButton {
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
          onClicked: uploadDialog.open()
        }
        IconButton {
          theme: appTheme
          icon: "settings"
          tooltip: "Settings (Ctrl+,)"
          selected: root.settingsOpen
          onClicked: root.settingsOpen = !root.settingsOpen
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
      anchors { left: parent.left; right: parent.right; top: header.bottom; bottom: statusBar.top }

      readonly property bool compact: width < appTheme.space(820)

      Sidebar {
        id: sidebar
        theme: appTheme
        visible: root.configured && !root.fullscreen
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
        onFooterClicked: root.settingsOpen = true
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
              if (p.kind === "album") return albumPage
              if (p.kind === "person") return personPage
              if (p.kind === "place") return placePage
              if (p.kind === "tag") return tagPage
              if (p.kind === "search") return searchPage
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
            onClosed: { root.settingsOpen = false; root.focusContent() }
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
        asset: root.viewerAsset
        onClosed: root.setInfo(false)
        onToast: function(text, tone) { toast.show(text, { tone: tone }) }
        onChanged: viewer.reloadDetails()
        onPersonOpened: function(person) { root.closeViewer(); root.go("people"); root.push({ kind: "person", person: person }) }
        onAlbumOpened: function(album) { root.closeViewer(); root.go("albums"); root.push({ kind: "album", album: album }) }
        onPlaceOpened: function(place) { root.closeViewer(); root.go("places"); root.push({ kind: "place", place: place }) }
        onTagOpened: function(tag) { root.closeViewer(); root.go("tags"); root.push({ kind: "tag", tag: tag }) }
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
      parent: window.contentItem
      onClosed: root.focusContent()
    }

    PromptDialog { id: promptDialog; theme: appTheme; onDismissed: root.focusContent() }
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
      onQueued: function(count) {
        toast.show(count > 0 ? "Uploading " + Format.count(count, "file") + "…" : "Nothing to upload there", {
          actionText: count > 0 ? "Show progress" : "", action: function() { root.go("sync") }
        })
      }
    }

    // Files dropped on the window are uploaded.
    DropArea {
      anchors.fill: parent
      keys: ["text/uri-list"]
      onDropped: function(drop) {
        if (!drop.hasUrls || !root.configured) return
        var paths = []
        for (var i = 0; i < drop.urls.length; i++) paths.push(String(drop.urls[i]))
        var album = root.albumPage ? root.albumPage.id : ""
        root.service.call("sync.uploadFiles", { paths: paths, albumId: album }, function(r, e) {
          if (e) return root.failed(e)
          toast.show("Uploading " + Format.count(r.queued, "file") + (album ? " into this album" : "") + "…", {
            actionText: "Show progress", action: function() { root.go("sync") }
          })
        })
        drop.accept()
      }
    }
  }

  // ---------------------------------------------------------------- views

  Component {
    id: photosView
    PhotosView {
      theme: appTheme; service: root.service; zoom: root.zoom
      title: "Photos"
      scope: ({})
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
            toast.show("Restored everything in the trash")
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
    id: albumPage
    AlbumPage {
      theme: appTheme; service: root.service; zoom: root.zoom
      album: root.page ? root.page.album : null
      onOpenAsset: function(a) { root.openViewer(a) }
      onContextRequested: function(a, item, x, y) { root.showPhotoMenu(a, item, x, y) }
      onBack: root.pop()
      onShare: root.shareAlbum(album)
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
    id: personPage
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
        var next = root.stack.slice()
        next[next.length - 1] = Object.assign({}, root.page, { mode: mode, filters: filters })
        root.stack = next
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
      { id: "share", label: "Share link...", icon: "link" },
      { separator: true },
      { id: "delete", label: "Delete album...", icon: "trash", danger: true }
    ], item, function(id) {
      if (id === "open") root.push({ kind: "album", album: album })
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
