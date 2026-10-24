import QtQuick

// What can be done to the selected photos, floating above the grid while a
// selection exists. Every action also has a key; the tooltips name it.
Rectangle {
  id: root

  required property var theme
  property var grid: null
  property bool inTrash: false
  property bool inArchive: false
  property bool inAlbum: false

  signal action(string id)

  width: row.implicitWidth + theme.space(16)
  height: theme.space(44)
  radius: theme.radius + theme.space(2)
  color: theme.popupBackground
  border.width: theme.borderWidth
  border.color: theme.popupBorder
  z: 300

  Row {
    id: row
    anchors.centerIn: parent
    spacing: root.theme.space(2)
    IconButton { theme: root.theme; icon: "close"; tooltip: "Clear the selection (Esc)"; onClicked: root.action("clear") }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: root.grid ? root.grid.selectedCount + " selected" : ""
      color: root.theme.foreground
      font.family: root.theme.font
      font.pixelSize: root.theme.body
      rightPadding: root.theme.space(10)
      leftPadding: root.theme.space(4)
    }
    IconButton { theme: root.theme; icon: "favorite"; tooltip: "Favourite (f)"; onClicked: root.action("favorite") }
    IconButton { visible: !root.inTrash; theme: root.theme; icon: "albums"; tooltip: "Add to album... (Shift+A)"; onClicked: root.action("addToAlbum") }
    IconButton { visible: !root.inTrash; theme: root.theme; icon: "tag"; tooltip: "Tag... (t)"; onClicked: root.action("tag") }
    IconButton { visible: !root.inTrash; theme: root.theme; icon: "link"; tooltip: "Share link... (s)"; onClicked: root.action("share") }
    IconButton { visible: !root.inTrash; theme: root.theme; icon: "download"; tooltip: "Download originals (Shift+D)"; onClicked: root.action("download") }
    IconButton { visible: !root.inTrash; theme: root.theme; icon: root.inArchive ? "unarchive" : "archive"; tooltip: root.inArchive ? "Unarchive (a)" : "Archive (a)"; onClicked: root.action("archive") }
    IconButton { visible: root.inAlbum; theme: root.theme; icon: "close"; tooltip: "Remove from this album"; onClicked: root.action("removeFromAlbum") }
    IconButton {
      theme: root.theme
      icon: root.inTrash ? "restore" : "trash"
      color: root.inTrash ? root.theme.foreground : root.theme.urgent
      tooltip: root.inTrash ? "Restore (d)" : "Move to trash (d)"
      onClicked: root.action("trash")
    }
    IconButton {
      visible: root.inTrash
      theme: root.theme
      icon: "deleteForever"
      color: root.theme.urgent
      tooltip: "Delete permanently... (Shift+Delete)"
      onClicked: root.action("deleteForever")
    }
  }
}
