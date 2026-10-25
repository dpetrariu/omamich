import QtQuick
import "../components"
import "../lib/Format.js" as Format

// The synced folders as they are on this computer: every photo and video,
// with whether Immich has it, is about to get it, or could not take it.
Item {
  id: root

  required property var theme
  required property var service
  property real zoom: 1

  readonly property string kind: "grid"
  readonly property alias grid: timeline
  readonly property var folders: service.settings && service.settings.sync ? service.settings.sync.folders || [] : []
  property string folderId: service.pref("localFolder", "")
  readonly property var folder: {
    for (var i = 0; i < folders.length; i++) if (folders[i].id === folderId) return folders[i]
    return folders.length ? folders[0] : null
  }
  property string sortMode: "newest"
  property int localTotal: 0
  readonly property string statusText: localTotal > 0 ? Format.count(localTotal, "file") : ""

  signal openAsset(var asset)
  signal contextRequested(var asset, Item item, real x, real y)
  signal openSync()

  function reload() { timeline.reload() }

  // Seconds since 1970 → the timestamp shape the grid sorts and groups by.
  function stamp(seconds) {
    var d = new Date(Number(seconds) * 1000)
    var pad = function(n) { return n < 10 ? "0" + n : String(n) }
    return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate()) + "T" + pad(d.getHours()) + ":" + pad(d.getMinutes()) + ":" + pad(d.getSeconds())
  }

  PageHeader {
    id: header
    theme: root.theme
    anchors { left: parent.left; right: parent.right; top: parent.top }
    title: "On this computer"
    subtitle: root.folder ? root.folder.path + (root.localTotal ? "  ·  " + Format.count(root.localTotal, "file") : "") : "No synced folders yet"
    actions: [
      { id: "newest", label: "Newest", selected: root.sortMode === "newest" },
      { id: "name", label: "Name", selected: root.sortMode === "name" },
      { id: "type", label: "Type", selected: root.sortMode === "type" },
      { id: "sync", label: "Sync state", selected: root.sortMode === "sync" }
    ]
    onActionTriggered: function(id) { root.sortMode = id }
  }

  Flow {
    id: chips
    anchors { left: parent.left; right: parent.right; top: header.bottom; leftMargin: root.theme.space(18); rightMargin: root.theme.space(18) }
    spacing: root.theme.space(6)
    Repeater {
      model: root.folders
      delegate: TextButton {
        required property var modelData
        theme: root.theme
        text: modelData.path.split("/").pop() || modelData.path
        icon: "folder"
        fontSize: root.theme.small
        selected: !!root.folder && root.folder.id === modelData.id
        onClicked: {
          root.folderId = modelData.id
          root.service.setPref("localFolder", modelData.id)
        }
      }
    }
  }

  Row {
    id: legend
    anchors { left: parent.left; top: chips.bottom; leftMargin: root.theme.space(18); topMargin: root.theme.space(8) }
    spacing: root.theme.space(14)
    visible: !!root.folder
    Repeater {
      model: [
        { icon: "cloudCheck", label: "in Immich" },
        { icon: "sync", label: "waiting" },
        { icon: "cloudOff", label: "only here" },
        { icon: "warning", label: "failed" },
        { icon: "eyeOff", label: "skipped by the folder's rules" }
      ]
      delegate: Row {
        required property var modelData
        spacing: root.theme.space(4)
        Glyph { name: modelData.icon; size: root.theme.small; color: root.theme.dim; font.family: root.theme.font }
        Text { text: modelData.label; color: root.theme.dim; font.family: root.theme.font; font.pixelSize: root.theme.caption }
      }
    }
  }

  Timeline {
    id: timeline
    theme: root.theme
    service: root.service
    anchors { left: parent.left; right: parent.right; top: legend.bottom; bottom: parent.bottom; topMargin: root.theme.space(8) }
    zoom: root.zoom
    listOnly: true
    sortMode: root.sortMode
    emptyIcon: "computer"
    emptyTitle: root.folder ? "No photos or videos in this folder" : "No synced folders"
    emptyText: root.folder ? "" : "Add a folder in Folder sync and its photos show up here, with whether Immich has them."
    pager: root.folder ? (function(folderId) {
      return function(page, done) {
        root.service.call("local.folderFiles", { folderId: folderId, page: page }, function(r, e) {
          if (!root) return
          if (e) return done([], false, e)
          root.localTotal = r.total
          done(r.items.map(function(f) {
            return {
              id: f.assetId || ("local:" + f.path),
              assetId: f.assetId,
              localPath: f.path,
              originalFileName: f.name,
              isImage: f.isImage,
              ratio: 1,
              fileCreatedAt: root.stamp(f.mtime),
              syncState: f.syncState,
              syncError: f.syncError,
              size: f.size
            }
          }), r.nextPage !== null && r.nextPage !== undefined, null)
        })
      }
    })(root.folder.id) : null
    onOpened: function(a) { root.openAsset(a) }
    onContextRequested: function(a, item, x, y) { root.contextRequested(a, item, x, y) }
  }

  TextButton {
    visible: !root.folder
    anchors.horizontalCenter: timeline.horizontalCenter
    y: timeline.y + timeline.height / 2 + root.theme.space(60)
    theme: root.theme
    text: "Folder sync..."
    icon: "cloudSync"
    onClicked: root.openSync()
  }

  Connections {
    target: root.service
    function onSyncStatusChanged() {
      // Uploads finishing change the marks; refresh at most every few seconds.
      if (root.service.syncPhase === "idle" && root.folder) refreshTimer.restart()
    }
  }
  Timer {
    id: refreshTimer
    interval: 2500
    onTriggered: timeline.reload()
  }
}
