import QtQuick
import "../components"
import "../lib/Format.js" as Format

// Files about to be uploaded: from the file manager, a drop on the window or
// the upload button. Look at them, choose which and where, then upload.
// Files Immich already has are marked; uploading them only adds them to the
// chosen album.
Item {
  id: root

  required property var theme
  required property var service
  property var entry: null

  readonly property string kind: "tiles"
  property var items: []
  property var selected: ({})
  property var states: ({})
  property bool loading: true
  property bool truncated: false
  property int checked: 0
  property string error: ""
  property bool busy: false
  // Where the upload goes: the library, an album, or an album to create.
  property string targetKind: "library"
  property string targetAlbumId: ""
  property string targetName: ""

  readonly property int selectedCount: items.filter(function(i) { return root.selected[i.path] }).length
  readonly property int knownCount: items.filter(function(i) { return root.states[i.path] === "inImmich" }).length
  readonly property string statusText: Format.count(selectedCount, "file") + " selected"

  signal back()
  signal uploaded(int count, string albumName)
  signal pickAlbum(var onPicked)
  signal promptAlbumName(var onNamed)
  signal failed(string message)

  function handleKey(id) {
    if (id === "open") {
      var item = items[grid.cursor]
      if (item) toggle(item.path)
      return
    }
    grid.handleKey(id)
  }

  function reload() { load() }

  function toggle(path) {
    var next = Object.assign({}, selected)
    if (next[path]) delete next[path]
    else next[path] = true
    selected = next
  }

  function selectAll(on) {
    var next = {}
    if (on) for (var i = 0; i < items.length; i++) next[items[i].path] = true
    selected = next
  }

  function load() {
    loading = true
    error = ""
    var albumId = entry && entry.albumId ? entry.albumId : ""
    if (albumId) {
      targetKind = "album"
      targetAlbumId = albumId
      var match = service.albums.filter(function(a) { return a.id === albumId })[0]
      targetName = match ? match.albumName : "this album"
    }
    service.call("local.list", { paths: entry ? entry.paths : [] }, function(r, e) {
      if (!root) return
      root.loading = false
      if (e) {
        root.error = e.message
        return
      }
      root.items = r.items
      root.truncated = r.truncated
      root.selectAll(true)
      root.checked = 0
      root.checkNext()
    })
  }

  // Ask Immich about the files a few dozen at a time, so a big folder shows
  // its marks as they come in.
  function checkNext() {
    if (checked >= items.length) return
    var batch = items.slice(checked, checked + 40).map(function(i) { return i.path })
    service.call("local.check", { paths: batch }, function(r, e) {
      if (!root) return
      if (!e) {
        var next = Object.assign({}, root.states)
        for (var i = 0; i < r.length; i++) next[r[i].path] = r[i].state
        root.states = next
      }
      root.checked += batch.length
      root.checkNext()
    })
  }

  function chooseAlbum() {
    root.pickAlbum(function(album) {
      if (album.create) {
        root.targetKind = "new"
        root.targetName = album.create
        root.targetAlbumId = ""
      } else {
        root.targetKind = "album"
        root.targetAlbumId = album.id
        root.targetName = album.label
      }
    })
  }

  function upload() {
    var paths = items.filter(function(i) { return root.selected[i.path] }).map(function(i) { return i.path })
    if (paths.length === 0 || busy) return
    busy = true
    var send = function(albumId) {
      root.service.call("sync.uploadFiles", { paths: paths, albumId: albumId || "" }, function(r, e) {
        if (!root) return
        root.busy = false
        if (e) return root.failed(e.message)
        root.uploaded(r.queued, root.targetKind === "library" ? "" : root.targetName)
      })
    }
    if (targetKind === "new") {
      service.call("album.create", { albumName: targetName }, function(a, e) {
        if (!root) return
        if (e) {
          root.busy = false
          return root.failed(e.message)
        }
        root.service.loadAlbums(true)
        send(a.id)
      })
    } else send(targetKind === "album" ? targetAlbumId : "")
  }

  Component.onCompleted: load()

  PageHeader {
    id: header
    theme: root.theme
    anchors { left: parent.left; right: parent.right; top: parent.top }
    showBack: true
    title: root.loading ? "Looking at the files…" : "Upload " + Format.count(root.items.length, "photo or video", "photos and videos")
    subtitle: root.error !== "" ? root.error
      : root.loading ? ""
      : (root.checked < root.items.length ? "Checking which Immich already has… " + root.checked + " of " + root.items.length
        : (root.knownCount > 0 ? Format.thousands(root.knownCount) + " already in Immich" + (root.targetKind === "library" ? " and will be skipped" : "; they are only added to the album") : "None of them are in Immich yet"))
        + (root.truncated ? "  ·  only the first 5,000 are shown" : "")
    actions: [
      { id: "all", label: "Select all" },
      { id: "none", label: "Select none" }
    ]
    onBack: root.back()
    onActionTriggered: function(id) { root.selectAll(id === "all") }
  }

  Row {
    id: target
    anchors { left: parent.left; top: header.bottom; leftMargin: root.theme.space(18) }
    spacing: root.theme.space(6)
    Text {
      text: "Upload into"
      color: root.theme.dim
      font.family: root.theme.font
      font.pixelSize: root.theme.small
      anchors.verticalCenter: parent.verticalCenter
      rightPadding: root.theme.space(4)
    }
    TextButton {
      theme: root.theme
      text: "The library"
      icon: "photos"
      fontSize: root.theme.small
      selected: root.targetKind === "library"
      onClicked: root.targetKind = "library"
    }
    TextButton {
      theme: root.theme
      text: root.targetKind === "library" ? "An album..." : (root.targetKind === "new" ? "New album “" + root.targetName + "”" : "“" + root.targetName + "”")
      icon: "albums"
      fontSize: root.theme.small
      selected: root.targetKind !== "library"
      onClicked: root.chooseAlbum()
    }
  }

  TileGrid {
    id: grid
    theme: root.theme
    anchors { left: parent.left; right: parent.right; top: target.bottom; bottom: footer.top; topMargin: root.theme.space(12) }
    model: root.items
    minTile: root.theme.space(150)
    tileAspect: 1
    tileExtra: root.theme.space(22)
    onActivated: function(item) { if (item) root.toggle(item.path) }
    tile: Component {
      Item {
        id: t
        readonly property var item: parent ? parent.modelData : null
        readonly property bool current: parent ? parent.isCurrent : false
        readonly property bool on: !!t.item && !!root.selected[t.item.path]
        readonly property string fileState: t.item ? root.states[t.item.path] || "" : ""
        Rectangle {
          id: frame
          width: parent.width
          height: width
          radius: root.theme.radius
          color: t.on ? root.theme.accentFill : root.theme.raised
          clip: true
          Image {
            anchors.fill: parent
            anchors.margins: t.on ? parent.width * 0.06 : 0
            visible: !!t.item && t.item.isImage
            source: t.item && t.item.isImage ? "file://" + t.item.path : ""
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            sourceSize.width: 320
            sourceSize.height: 320
            opacity: t.on ? 1 : 0.55
          }
          Glyph {
            anchors.centerIn: parent
            visible: !!t.item && !t.item.isImage
            name: "video"
            size: root.theme.display
            color: root.theme.dim
            font.family: root.theme.font
          }
          Rectangle {
            anchors { top: parent.top; left: parent.left; margins: root.theme.space(6) }
            width: root.theme.space(22); height: width; radius: width / 2
            color: t.on ? root.theme.accent : Qt.rgba(0, 0, 0, 0.3)
            border.width: root.theme.space(2)
            border.color: t.on ? root.theme.accent : "white"
            Glyph { anchors.centerIn: parent; visible: t.on; name: "check"; size: root.theme.small; color: root.theme.background; font.family: root.theme.font }
          }
          Rectangle {
            visible: t.fileState === "inImmich" || t.fileState === "inTrash"
            anchors { right: parent.right; bottom: parent.bottom; margins: root.theme.space(6) }
            width: badge.implicitWidth + root.theme.space(10)
            height: badge.implicitHeight + root.theme.space(4)
            radius: root.theme.radius
            color: Qt.rgba(0, 0, 0, 0.6)
            Text {
              textFormat: Text.PlainText
              id: badge
              anchors.centerIn: parent
              text: t.fileState === "inTrash" ? "in the Immich trash" : "in Immich"
              color: "white"
              font.family: root.theme.font
              font.pixelSize: root.theme.caption
            }
          }
          Rectangle {
            anchors.fill: parent
            radius: parent.radius
            color: "transparent"
            border.width: t.current ? root.theme.space(2) : 0
            border.color: root.theme.accent
          }
        }
        Text {
          anchors { left: parent.left; right: parent.right; top: frame.bottom; topMargin: root.theme.space(4) }
          text: t.item ? t.item.name + "  " + Format.bytes(t.item.size) : ""
          textFormat: Text.PlainText
          elide: Text.ElideMiddle
          color: t.on ? root.theme.foreground : root.theme.dim
          font.family: root.theme.font
          font.pixelSize: root.theme.caption
        }
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: { grid.cursor = t.parent.index; root.toggle(t.item.path) }
        }
      }
    }
  }

  Text {
    textFormat: Text.PlainText
    anchors.centerIn: grid
    visible: !root.loading && root.items.length === 0
    text: root.error || "There are no photos or videos among these files"
    color: root.error ? root.theme.urgent : root.theme.dim
    font.family: root.theme.font
    font.pixelSize: root.theme.body
  }

  Item {
    id: footer
    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
    height: root.theme.space(56)
    Rectangle { width: parent.width; height: root.theme.borderWidth; color: root.theme.border }
    Text {
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.leftMargin: root.theme.space(18)
      anchors.verticalCenter: parent.verticalCenter
      text: Format.count(root.selectedCount, "file") + " · "
        + Format.bytes(root.items.filter(function(i) { return root.selected[i.path] }).reduce(function(a, i) { return a + i.size }, 0))
      color: root.theme.dim
      font.family: root.theme.font
      font.pixelSize: root.theme.small
    }
    TextButton {
      anchors.right: parent.right
      anchors.rightMargin: root.theme.space(18)
      anchors.verticalCenter: parent.verticalCenter
      theme: root.theme
      text: root.selectedCount > 0 ? "Upload " + Format.count(root.selectedCount, "file") : "Nothing selected"
      icon: "upload"
      primary: true
      busy: root.busy
      enabled: root.selectedCount > 0 && !root.loading
      onClicked: root.upload()
    }
  }
}
