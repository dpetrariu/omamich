import QtQuick
import QtQuick.Controls as QQC
import "../components"
import "../lib/Format.js" as Format

// The library by the folders it was imported from: subfolders on the left,
// the photos of the open folder on the right.
Item {
  id: root

  required property var theme
  required property var service
  property real zoom: 1

  property var paths: []
  property bool loading: false
  property string error: ""
  property string current: ""
  readonly property string kind: "grid"
  readonly property alias grid: timeline
  readonly property string statusText: Format.count(children.length, "folder") + (timeline.total > 0 ? " · " + Format.count(timeline.total, "item") : "")

  signal openAsset(var asset)
  signal contextRequested(var asset, Item item, real x, real y)

  readonly property string base: {
    if (paths.length === 0) return ""
    var first = paths[0].split("/")
    var prefix = first.length
    for (var i = 1; i < paths.length; i++) {
      var parts = paths[i].split("/")
      var n = 0
      while (n < prefix && n < parts.length && parts[n] === first[n]) n++
      prefix = n
    }
    return first.slice(0, prefix).join("/")
  }
  readonly property string folder: current || base
  readonly property var children: {
    var seen = {}
    var out = []
    var prefix = folder === "/" ? "/" : folder + "/"
    for (var i = 0; i < paths.length; i++) {
      var p = paths[i]
      if (p.indexOf(prefix) !== 0) continue
      var name = p.slice(prefix.length).split("/")[0]
      if (name && !seen[name]) {
        seen[name] = true
        out.push(name)
      }
    }
    out.sort()
    return out
  }
  readonly property bool hasPhotos: paths.indexOf(folder) >= 0

  function reload() {
    loading = true
    service.call("folders.paths", {}, function(r, e) {
      root.loading = false
      root.error = e ? e.message : ""
      if (!e) root.paths = r
    })
  }

  Component.onCompleted: reload()

  function up() {
    if (folder === base || !folder) return
    current = folder.slice(0, folder.lastIndexOf("/")) || "/"
    if (current.length < base.length) current = base
  }

  PageHeader {
    id: header
    theme: root.theme
    anchors { left: parent.left; right: parent.right; top: parent.top }
    title: root.folder ? root.folder.split("/").pop() || "/" : "Folders"
    subtitle: root.loading ? "Reading folders…" : root.folder
    showBack: root.folder !== root.base && root.folder !== ""
    onBack: root.up()
  }

  ListView {
    id: tree
    anchors { left: parent.left; top: header.bottom; bottom: parent.bottom; leftMargin: root.theme.space(12) }
    width: root.hasPhotos ? Math.min(root.theme.space(260), parent.width * 0.3) : parent.width - root.theme.space(24)
    clip: true
    model: root.children
    boundsBehavior: Flickable.StopAtBounds
    QQC.ScrollBar.vertical: QQC.ScrollBar {}
    delegate: Item {
      required property var modelData
      width: tree.width
      height: root.theme.space(32)
      Rectangle {
        anchors.fill: parent
        radius: root.theme.radius
        color: mouse.containsMouse ? root.theme.hoverFill : "transparent"
      }
      Glyph {
        id: icon
        x: root.theme.space(10)
        anchors.verticalCenter: parent.verticalCenter
        name: "folder"
        size: root.theme.icon
        color: root.theme.dim
        font.family: root.theme.font
      }
      Text {
        anchors.left: icon.right
        anchors.leftMargin: root.theme.space(10)
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: modelData
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: root.theme.foreground
        font.family: root.theme.font
        font.pixelSize: root.theme.body
      }
      MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.current = (root.folder === "/" ? "" : root.folder) + "/" + modelData
      }
    }
  }

  Rectangle {
    visible: root.hasPhotos
    anchors { left: tree.right; top: header.bottom; bottom: parent.bottom; leftMargin: root.theme.space(6) }
    width: root.theme.borderWidth
    color: root.theme.border
  }

  Timeline {
    id: timeline
    visible: root.hasPhotos
    theme: root.theme
    service: root.service
    anchors { left: tree.right; right: parent.right; top: header.bottom; bottom: parent.bottom; leftMargin: root.theme.space(8) }
    zoom: root.zoom
    listOnly: true
    pager: root.hasPhotos ? (function(folder) {
      return function(page, done) {
        if (page > 1) return done([], false, null)
        root.service.call("folder.assets", { path: folder }, function(r, e) {
          if (e) return done([], false, e)
          done(r, false, null)
        })
      }
    })(root.folder) : null
    onOpened: function(a) { root.openAsset(a) }
    onContextRequested: function(a, item, x, y) { root.contextRequested(a, item, x, y) }
  }

  Text {
    anchors.centerIn: parent
    visible: !root.loading && root.paths.length === 0
    text: root.error || "Immich has no folder information for this library"
    color: root.error ? root.theme.urgent : root.theme.dim
    font.family: root.theme.font
    font.pixelSize: root.theme.body
  }
}
