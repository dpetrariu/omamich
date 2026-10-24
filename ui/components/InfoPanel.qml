import QtQuick
import QtQuick.Controls as QQC
import "../lib/Format.js" as Format

// Everything known about the open photo: when, where, with what, who is in
// it, which albums and tags hold it, and its description and rating, which
// can be edited here.
Item {
  id: root

  required property var theme
  required property var service
  property var asset: null
  property var details: null
  property var albums: []

  signal closed()
  signal toast(string text, string tone)
  signal changed()
  signal personOpened(var person)
  signal albumOpened(var album)
  signal placeOpened(var place)
  signal tagOpened(var tag)
  signal editDate()

  readonly property var exif: details && details.exif ? details.exif : ({})
  readonly property bool typing: description.activeFocus

  // The description being written belongs to the photo it was started on,
  // even if the viewer moves on before it is saved.
  property string editingId: ""
  property string editingText: ""
  property string savedText: ""

  function flushDescription() {
    if (!editingId) return
    var id = editingId
    var text = editingText
    editingId = ""
    if (text === savedText) return
    service.call("asset.update", { ids: [id], description: text }, function(r, e) { if (!root) return;
      if (e) root.toast(e.message, "error")
      else root.changed()
    })
  }

  function finishEditing() {
    flushDescription()
    description.focus = false
  }

  Timer {
    id: descriptionTimer
    interval: 900
    onTriggered: root.flushDescription()
  }

  onAssetChanged: {
    flushDescription()
    loadAlbums()
  }
  function loadAlbums() {
    albums = []
    if (!asset || width === 0) return
    var id = asset.id
    service.call("asset.albums", { id: id }, function(r, e) { if (!root) return;
      if (root.asset && root.asset.id === id && !e) root.albums = r
    })
  }
  onWidthChanged: if (width > 0 && albums.length === 0) loadAlbums()

  function setRating(stars) {
    if (!details) return
    var next = Number(exif.rating || 0) === stars ? 0 : stars
    service.call("asset.update", { ids: [details.id], rating: next }, function(r, e) { if (!root) return;
      if (e) root.toast(e.message, "error")
      else root.changed()
    })
  }

  Rectangle {
    anchors.fill: parent
    color: root.theme.background
  }
  Rectangle {
    width: root.theme.borderWidth
    height: parent.height
    color: root.theme.border
  }

  Item {
    id: top
    anchors { left: parent.left; right: parent.right; top: parent.top }
    height: root.theme.space(48)
    Text {
      anchors.left: parent.left
      anchors.leftMargin: root.theme.space(18)
      anchors.verticalCenter: parent.verticalCenter
      text: "Details"
      color: root.theme.foreground
      font.family: root.theme.font
      font.pixelSize: root.theme.title
    }
    IconButton {
      theme: root.theme
      anchors.right: parent.right
      anchors.rightMargin: root.theme.space(8)
      anchors.verticalCenter: parent.verticalCenter
      icon: "close"
      tooltip: "Hide details (i)"
      onClicked: root.closed()
    }
  }

  Flickable {
    anchors { left: parent.left; right: parent.right; top: top.bottom; bottom: parent.bottom }
    contentHeight: column.implicitHeight + root.theme.space(30)
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    QQC.ScrollBar.vertical: QQC.ScrollBar {}

    Column {
      id: column
      x: root.theme.space(18)
      width: parent.width - root.theme.space(36)
      spacing: root.theme.space(16)

      Text {
        visible: !root.details
        text: "Loading…"
        color: root.theme.dim
        font.family: root.theme.font
        font.pixelSize: root.theme.small
      }

      // Description
      QQC.TextArea {
        id: description
        visible: !!root.details
        width: parent.width
        placeholderText: "Add a description"
        text: root.exif.description || ""
        wrapMode: TextEdit.Wrap
        color: root.theme.foreground
        placeholderTextColor: root.theme.dim
        font.family: root.theme.font
        font.pixelSize: root.theme.body
        background: Rectangle {
          color: description.activeFocus ? root.theme.sunken : "transparent"
          border.width: root.theme.borderWidth
          border.color: description.activeFocus ? root.theme.accent : root.theme.border
          radius: root.theme.radius
        }
        onActiveFocusChanged: {
          if (activeFocus && root.details) {
            root.editingId = root.details.id
            root.savedText = root.exif.description || ""
            root.editingText = text
          } else if (!activeFocus) root.flushDescription()
        }
        onTextChanged: if (activeFocus && root.editingId) {
          root.editingText = text
          descriptionTimer.restart()
        }
      }

      // Rating
      Row {
        visible: !!root.details
        spacing: root.theme.space(2)
        Repeater {
          model: 5
          delegate: IconButton {
            required property int index
            theme: root.theme
            icon: Number(root.exif.rating || 0) > index ? "starOn" : "star"
            color: Number(root.exif.rating || 0) > index ? root.theme.accent : root.theme.dim
            tooltip: "Rate " + (index + 1) + " (press " + (index + 1) + ")"
            onClicked: root.setRating(index + 1)
          }
        }
      }

      InfoRow {
        theme: root.theme
        icon: "calendar"
        visible: !!root.details
        title: root.details ? Format.dateLabel(root.details.localDateTime || root.details.fileCreatedAt) : ""
        detail: root.details ? Format.timeLabel(root.details.localDateTime || root.details.fileCreatedAt) + (root.exif.timeZone ? "  " + root.exif.timeZone : "") : ""
        link: "Edit..."
        onLinkClicked: root.editDate()
      }

      InfoRow {
        theme: root.theme
        icon: root.asset && !root.asset.isImage ? "video" : "image"
        visible: !!root.details
        title: root.details ? root.details.originalFileName || "" : ""
        detail: root.details ? [Format.megapixels(root.details.width || root.exif.exifImageWidth, root.details.height || root.exif.exifImageHeight),
          (root.details.width || root.exif.exifImageWidth) ? (root.details.width || root.exif.exifImageWidth) + " × " + (root.details.height || root.exif.exifImageHeight) : "",
          root.exif.fileSizeInByte ? Format.bytes(root.exif.fileSizeInByte) : ""].filter(function(s) { return s }).join("  ·  ") : ""
        selectable: true
      }

      InfoRow {
        theme: root.theme
        icon: "camera"
        visible: Format.camera(root.exif) !== "" || Format.settingsLine(root.exif) !== ""
        title: Format.camera(root.exif) || "Camera"
        detail: [root.exif.lensModel || "", Format.settingsLine(root.exif)].filter(function(s) { return s }).join("\n")
      }

      InfoRow {
        theme: root.theme
        icon: "places"
        visible: !!root.exif.city || !!root.exif.country || !!root.exif.latitude
        title: Format.place(root.exif) || "Somewhere"
        detail: root.exif.latitude ? Number(root.exif.latitude).toFixed(5) + ", " + Number(root.exif.longitude).toFixed(5) : ""
        link: root.exif.latitude ? "Map..." : ""
        onLinkClicked: Qt.openUrlExternally("https://www.openstreetmap.org/?mlat=" + root.exif.latitude + "&mlon=" + root.exif.longitude + "#map=15/" + root.exif.latitude + "/" + root.exif.longitude)
        onTitleClicked: if (root.exif.city || root.exif.country) root.placeOpened({ city: root.exif.city || "", country: root.exif.country || "" })
      }

      // People
      Column {
        visible: !!root.details && root.details.people.length > 0
        width: parent.width
        spacing: root.theme.space(8)
        Text {
          text: "People"
          color: root.theme.dim
          font.family: root.theme.font
          font.pixelSize: root.theme.small
        }
        Flow {
          width: parent.width
          spacing: root.theme.space(10)
          Repeater {
            model: root.details ? root.details.people.filter(function(p) { return !p.isHidden }) : []
            delegate: Item {
              required property var modelData
              width: root.theme.space(64)
              height: root.theme.space(84)
              RoundImage {
                id: face
                width: parent.width; height: width
                radius: width / 2
                fill: root.theme.raised
                sourceSize: 160
                source: root.service.personUrl(modelData.id, modelData.version)
              }
              Text {
                anchors { top: face.bottom; topMargin: root.theme.space(4); left: parent.left; right: parent.right }
                horizontalAlignment: Text.AlignHCenter
                text: modelData.name || "Unnamed"
                textFormat: Text.PlainText
                elide: Text.ElideRight
                color: modelData.name ? root.theme.foreground : root.theme.dim
                font.family: root.theme.font
                font.pixelSize: root.theme.caption
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.personOpened({ id: modelData.id, name: modelData.name, version: modelData.version, isHidden: false })
              }
            }
          }
        }
      }

      // Albums
      Column {
        visible: root.albums.length > 0
        width: parent.width
        spacing: root.theme.space(6)
        Text { text: "In albums"; color: root.theme.dim; font.family: root.theme.font; font.pixelSize: root.theme.small }
        Repeater {
          model: root.albums
          delegate: InfoRow {
            required property var modelData
            theme: root.theme
            icon: "albums"
            title: modelData.albumName
            detail: Format.count(modelData.assetCount, "item")
            onTitleClicked: root.albumOpened(modelData)
          }
        }
      }

      // Tags
      Column {
        visible: !!root.details && root.details.tags.length > 0
        width: parent.width
        spacing: root.theme.space(6)
        Text { text: "Tags"; color: root.theme.dim; font.family: root.theme.font; font.pixelSize: root.theme.small }
        Flow {
          width: parent.width
          spacing: root.theme.space(6)
          Repeater {
            model: root.details ? root.details.tags : []
            delegate: TextButton {
              required property var modelData
              theme: root.theme
              text: modelData.value || modelData.name
              icon: "tag"
              fontSize: root.theme.small
              onClicked: root.tagOpened(modelData)
            }
          }
        }
      }

      InfoRow {
        theme: root.theme
        icon: "person"
        visible: !!root.details && !!root.details.ownerName && !!root.service.user && root.details.ownerId !== root.service.user.id
        title: root.details ? "Shared by " + root.details.ownerName : ""
      }

      InfoRow {
        theme: root.theme
        icon: "folder"
        visible: !!root.details && !!root.details.originalPath
        title: "On the server"
        detail: root.details ? root.details.originalPath || "" : ""
        selectable: true
      }
    }
  }
}
