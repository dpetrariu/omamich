import QtQuick
import qs.Ui
import "../components"
import "../lib/Format.js" as Format

// Every album, newest first, as covers. Filter by name; show yours, shared
// or all.
Item {
  id: root

  required property var theme
  required property var service

  readonly property string kind: "tiles"
  readonly property bool typing: filter.activeFocus
  property string show: "all"
  readonly property var albums: {
    var q = filter.text.trim().toLowerCase()
    var me = service.user ? service.user.id : ""
    return service.albums.filter(function(a) {
      if (root.show === "mine" && a.ownerId !== me) return false
      if (root.show === "shared" && !a.shared) return false
      return !q || String(a.albumName || "").toLowerCase().indexOf(q) >= 0
    })
  }
  readonly property string statusText: Format.count(albums.length, "album")

  signal albumOpened(var album)
  signal create()
  signal menuRequested(var album, Item item)

  function reload() { service.loadAlbums(true) }
  function handleKey(id) { grid.handleKey(id) }

  Component.onCompleted: service.loadAlbums()

  PageHeader {
    id: header
    theme: root.theme
    anchors { left: parent.left; right: parent.right; top: parent.top }
    title: "Albums"
    subtitle: root.service.albumsLoading && root.service.albums.length === 0 ? "Loading…" : Format.count(root.albums.length, "album")
    actions: [
      { id: "all", label: "All", selected: root.show === "all" },
      { id: "mine", label: "Mine", selected: root.show === "mine" },
      { id: "shared", label: "Shared", selected: root.show === "shared" },
      { id: "new", label: "New album...", icon: "plus", primary: true }
    ]
    onActionTriggered: function(id) {
      if (id === "new") root.create()
      else root.show = id
    }
  }

  TextField {
    id: filter
    anchors { left: parent.left; top: header.bottom; leftMargin: root.theme.space(18) }
    width: Math.min(root.theme.space(320), parent.width - root.theme.space(36))
    placeholderText: "Filter albums"
    font.family: root.theme.font
    font.pixelSize: root.theme.body
    Keys.onEscapePressed: function(e) { text = ""; e.accepted = false }
  }

  TileGrid {
    id: grid
    theme: root.theme
    anchors { left: parent.left; right: parent.right; top: filter.bottom; bottom: parent.bottom; topMargin: root.theme.space(12) }
    model: root.albums
    minTile: root.theme.space(200)
    tileAspect: 1
    tileExtra: root.theme.space(44)
    onActivated: function(a) { if (a) root.albumOpened(a) }
    tile: Component {
      Item {
        id: t
        readonly property var album: parent ? parent.modelData : null
        readonly property bool current: parent ? parent.isCurrent : false
        RoundImage {
          id: cover
          width: parent.width
          height: width
          radius: root.theme.radius + root.theme.space(4)
          fill: root.theme.raised
          sourceSize: 400
          source: t.album && t.album.albumThumbnailAssetId
            ? root.service.thumbUrl(t.album.albumThumbnailAssetId, "thumbnail", t.album.updatedAt) : ""
          Glyph {
            anchors.centerIn: parent
            visible: !cover.ready
            name: "albums"
            size: root.theme.display
            color: root.theme.faint
            font.family: root.theme.font
          }
        }
        Rectangle {
          anchors.fill: cover
          color: "transparent"
          radius: cover.radius
          border.width: t.current ? root.theme.space(2) : 0
          border.color: root.theme.accent
        }
        Rectangle {
          visible: !!t.album && t.album.shared
          anchors { right: cover.right; top: cover.top; margins: root.theme.space(8) }
          width: root.theme.space(26); height: width
          radius: width / 2
          color: Qt.rgba(0, 0, 0, 0.45)
          Glyph { anchors.centerIn: parent; name: "shared"; size: root.theme.small; color: "white"; font.family: root.theme.font }
        }
        Column {
          anchors { left: parent.left; right: parent.right; top: cover.bottom; topMargin: root.theme.space(8) }
          spacing: root.theme.space(2)
          Text {
            width: parent.width
            text: t.album ? t.album.albumName : ""
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: root.theme.foreground
            font.family: root.theme.font
            font.pixelSize: root.theme.body
          }
          Text {
            width: parent.width
            text: t.album ? [Format.count(t.album.assetCount, "item"), Format.dateRange(t.album.startDate, t.album.endDate)].filter(function(s) { return s }).join(" · ") : ""
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: root.theme.dim
            font.family: root.theme.font
            font.pixelSize: root.theme.caption
          }
        }
        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.LeftButton | Qt.RightButton
          cursorShape: Qt.PointingHandCursor
          onClicked: function(mouse) {
            grid.cursor = t.parent.index
            if (mouse.button === Qt.RightButton) root.menuRequested(t.album, t)
            else root.albumOpened(t.album)
          }
        }
      }
    }
  }

  Column {
    anchors.centerIn: parent
    visible: !root.service.albumsLoading && root.albums.length === 0
    spacing: root.theme.space(10)
    Glyph { anchors.horizontalCenter: parent.horizontalCenter; name: "albums"; size: root.theme.display * 1.6; color: root.theme.faint; font.family: root.theme.font }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: root.service.albumsError || (filter.text ? "No album matches “" + filter.text + "”" : "No albums yet")
      color: root.service.albumsError ? root.theme.urgent : root.theme.foreground
      font.family: root.theme.font
      font.pixelSize: root.theme.title
    }
    TextButton {
      anchors.horizontalCenter: parent.horizontalCenter
      theme: root.theme
      text: "New album..."
      icon: "plus"
      primary: true
      onClicked: root.create()
    }
  }
}
