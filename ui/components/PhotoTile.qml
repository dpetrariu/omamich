import QtQuick
import QtQuick.Window
import "../lib/Thumbhash.js" as Thumbhash

// One photo in the grid. The average colour from its ThumbHash stands in until
// the thumbnail arrives; badges say video, live, favourite and stack without
// relying on colour alone.
Item {
  id: root

  required property var theme
  required property var service
  required property var asset
  property bool selected: false
  property bool selecting: false
  property bool cursor: false

  signal clicked(var mouse)
  signal doubleClicked()
  signal rightClicked(real x, real y)
  signal toggleSelect(var mouse)
  // Pressed and moved: the person wants to drag the photo out as a file.
  signal dragRequested()

  readonly property bool hovered: tileMouse.containsMouse
  readonly property string placeholderColor: Thumbhash.averageColor(asset ? asset.thumbhash : "")

  Rectangle {
    anchors.fill: parent
    color: root.selected ? root.theme.accentFill : "transparent"
  }

  Item {
    id: frame
    anchors.fill: parent
    anchors.margins: root.selected ? Math.min(width, height) * 0.08 : 0
    Behavior on anchors.margins { NumberAnimation { duration: 90 } }
    clip: true

    Rectangle {
      anchors.fill: parent
      color: root.placeholderColor !== "" ? root.placeholderColor : root.theme.raised
      radius: root.selected ? root.theme.radius : 0
    }

    Image {
      id: image
      anchors.fill: parent
      source: !root.asset ? ""
        : root.asset.localPath ? (root.asset.isImage ? "file://" + root.asset.localPath : "")
        : root.service.thumbUrl(root.asset.id, "thumbnail", root.asset.thumbhash)
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: true
      smooth: true
      sourceSize.width: Math.ceil(root.width * Screen.devicePixelRatio)
      sourceSize.height: Math.ceil(root.height * Screen.devicePixelRatio)
      opacity: status === Image.Ready ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 120 } }
    }

    // A wash at the top so badges read on bright photos.
    Rectangle {
      anchors { left: parent.left; right: parent.right; top: parent.top }
      height: root.theme.space(34)
      visible: root.hovered || root.selecting || !!(root.asset && (!root.asset.isImage || root.asset.livePhotoVideoId))
      gradient: Gradient {
        GradientStop { position: 0; color: Qt.rgba(0, 0, 0, 0.45) }
        GradientStop { position: 1; color: "transparent" }
      }
    }
    Rectangle {
      anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
      height: root.theme.space(28)
      visible: !!(root.asset && (root.asset.isFavorite || root.asset.stackCount))
      gradient: Gradient {
        GradientStop { position: 0; color: "transparent" }
        GradientStop { position: 1; color: Qt.rgba(0, 0, 0, 0.4) }
      }
    }

    Row {
      anchors { top: parent.top; right: parent.right; margins: root.theme.space(6) }
      spacing: root.theme.space(4)
      visible: !!root.asset && (!root.asset.isImage || !!root.asset.livePhotoVideoId)
      Text {
        visible: !!root.asset && !root.asset.isImage && !!root.asset.duration
        text: root.asset && root.asset.duration ? root.asset.duration : ""
        color: "white"
        font.family: root.theme.font
        font.pixelSize: root.theme.caption
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
      }
      Glyph {
        name: root.asset && !root.asset.isImage ? "play" : "live"
        size: root.theme.icon
        color: "white"
        font.family: root.theme.font
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Glyph {
      visible: !!root.asset && root.asset.isFavorite === true
      anchors { left: parent.left; bottom: parent.bottom; margins: root.theme.space(6) }
      name: "favoriteOn"
      size: root.theme.icon
      color: "white"
      font.family: root.theme.font
    }

    Row {
      visible: !!root.asset && !!root.asset.stackCount
      anchors { right: parent.right; bottom: parent.bottom; margins: root.theme.space(6) }
      spacing: root.theme.space(3)
      Text {
        text: root.asset && root.asset.stackCount ? String(root.asset.stackCount) : ""
        color: "white"
        font.family: root.theme.font
        font.pixelSize: root.theme.caption
        textFormat: Text.PlainText
      }
      Glyph { name: "stack"; size: root.theme.small; color: "white"; font.family: root.theme.font }
    }
  }

  // Where a file on this computer stands with Immich.
  Rectangle {
    visible: !!root.asset && !!root.asset.syncState
    anchors { right: parent.right; bottom: parent.bottom; margins: root.theme.space(6) }
    width: root.theme.space(22)
    height: width
    radius: width / 2
    z: 2
    color: root.asset && root.asset.syncState === "failed" ? root.theme.urgent : Qt.rgba(0, 0, 0, 0.55)
    Glyph {
      anchors.centerIn: parent
      size: root.theme.small
      color: "white"
      font.family: root.theme.font
      name: {
        switch (root.asset ? root.asset.syncState : "") {
        case "done": return "cloudCheck"
        case "pending": return "sync"
        case "failed": return "warning"
        case "skipped": return "eyeOff"
        default: return "cloudOff"
        }
      }
    }
  }

  // A local video has no thumbnail; say what it is.
  Glyph {
    visible: !!root.asset && !!root.asset.localPath && !root.asset.isImage
    anchors.centerIn: parent
    name: "video"
    size: root.theme.display
    color: root.theme.dim
    font.family: root.theme.font
  }

  // The keyboard cursor: a ring, so it reads on any photo.
  Rectangle {
    anchors.fill: parent
    visible: root.cursor
    color: "transparent"
    border.width: root.theme.space(2)
    border.color: root.theme.accent
    z: 3
  }

  // The selection check, top left.
  Item {
    id: check
    visible: root.selecting || root.hovered || root.selected
    anchors { top: parent.top; left: parent.left; margins: root.theme.space(5) }
    width: root.theme.space(22)
    height: width
    z: 4
    Rectangle {
      anchors.fill: parent
      radius: width / 2
      color: root.selected ? root.theme.accent : Qt.rgba(0, 0, 0, 0.25)
      border.width: root.theme.space(2)
      border.color: root.selected ? root.theme.accent : "white"
      opacity: checkMouse.containsMouse || root.selected ? 1 : 0.8
    }
    Glyph {
      anchors.centerIn: parent
      visible: root.selected
      name: "check"
      size: root.theme.small
      color: root.theme.background
      font.family: root.theme.font
    }
    MouseArea {
      id: checkMouse
      anchors.fill: parent
      anchors.margins: -root.theme.space(4)
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: function(mouse) { root.toggleSelect(mouse) }
    }
  }

  MouseArea {
    id: tileMouse
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    cursorShape: dragging ? Qt.DragCopyCursor : Qt.PointingHandCursor
    preventStealing: dragging
    property point start
    property bool dragging: false
    onPressed: function(mouse) {
      start = Qt.point(mouse.x, mouse.y)
      dragging = false
    }
    onPositionChanged: function(mouse) {
      if (!pressed || dragging || !(mouse.buttons & Qt.LeftButton)) return
      if (Math.abs(mouse.x - start.x) + Math.abs(mouse.y - start.y) > 14) {
        dragging = true
        root.dragRequested()
      }
    }
    onReleased: Qt.callLater(function() { tileMouse.dragging = false })
    onClicked: function(mouse) {
      if (dragging) return
      if (mouse.button === Qt.RightButton) root.rightClicked(mouse.x, mouse.y)
      else root.clicked(mouse)
    }
    onDoubleClicked: root.doubleClicked()
  }
}
