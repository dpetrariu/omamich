import QtQuick
import qs.Ui

// Make a public link for photos or an album, with the few options that
// matter: how long it lasts, a password, and whether visitors may download.
Sheet {
  id: root

  required property var service
  property var assetIds: []
  property string albumId: ""
  property bool allowDownload: true
  property bool showMetadata: true
  property int expiresInDays: 0
  property bool busy: false
  property string error: ""
  property var created: null

  signal copied(string url)

  function ask(options) {
    title = options.title || "Share"
    subtitle = "Anyone with the link can see these photos, without an Immich account."
    assetIds = options.assetIds || []
    albumId = options.albumId || ""
    allowDownload = true
    showMetadata = true
    expiresInDays = 0
    busy = false
    error = ""
    created = null
    password.text = ""
    description.text = ""
    opened = true
  }

  function create() {
    busy = true
    var params = {
      allowDownload: allowDownload, showMetadata: showMetadata,
      expiresInDays: expiresInDays, password: password.text, description: description.text
    }
    if (albumId) params.albumId = albumId
    else params.assetIds = assetIds
    service.call("sharedLink.create", params, function(r, e) {
      root.busy = false
      if (e) {
        root.error = e.message
        return
      }
      root.created = r
      root.copied(r.url)
    })
  }

  Column {
    width: parent.width
    spacing: root.theme.space(12)

    Column {
      visible: !root.created
      width: parent.width
      spacing: root.theme.space(12)

      TextField {
        id: description
        width: parent.width
        placeholderText: "Description (optional)"
        font.family: root.theme.font
        font.pixelSize: root.theme.body
      }
      TextField {
        id: password
        width: parent.width
        placeholderText: "Password (optional)"
        echoMode: TextInput.Password
        font.family: root.theme.font
        font.pixelSize: root.theme.body
      }
      Row {
        spacing: root.theme.space(6)
        Text {
          text: "Expires"
          color: root.theme.dim
          font.family: root.theme.font
          font.pixelSize: root.theme.small
          anchors.verticalCenter: parent.verticalCenter
          width: root.theme.space(70)
        }
        Repeater {
          model: [{ d: 0, l: "Never" }, { d: 1, l: "1 day" }, { d: 7, l: "7 days" }, { d: 30, l: "30 days" }, { d: 365, l: "1 year" }]
          delegate: TextButton {
            required property var modelData
            theme: root.theme
            text: modelData.l
            fontSize: root.theme.small
            selected: root.expiresInDays === modelData.d
            onClicked: root.expiresInDays = modelData.d
          }
        }
      }
      Row {
        spacing: root.theme.space(10)
        ToggleSwitch { checked: root.allowDownload; onToggled: root.allowDownload = !root.allowDownload }
        Text {
          text: "Visitors may download the originals"
          color: root.theme.foreground
          font.family: root.theme.font
          font.pixelSize: root.theme.small
          anchors.verticalCenter: parent.verticalCenter
        }
      }
      Row {
        spacing: root.theme.space(10)
        ToggleSwitch { checked: root.showMetadata; onToggled: root.showMetadata = !root.showMetadata }
        Text {
          text: "Show camera and place details"
          color: root.theme.foreground
          font.family: root.theme.font
          font.pixelSize: root.theme.small
          anchors.verticalCenter: parent.verticalCenter
        }
      }
    }

    Column {
      visible: !!root.created
      width: parent.width
      spacing: root.theme.space(8)
      Text {
        text: "Link created and copied to the clipboard"
        color: root.theme.foreground
        font.family: root.theme.font
        font.pixelSize: root.theme.body
      }
      TextField {
        width: parent.width
        readOnly: true
        text: root.created ? root.created.url : ""
        font.family: root.theme.font
        font.pixelSize: root.theme.small
      }
    }

    Text {
      visible: root.error !== ""
      width: parent.width
      text: root.error
      wrapMode: Text.Wrap
      color: root.theme.urgent
      font.family: root.theme.font
      font.pixelSize: root.theme.small
    }

    Row {
      anchors.right: parent.right
      spacing: root.theme.space(8)
      TextButton { theme: root.theme; text: root.created ? "Done" : "Cancel"; onClicked: root.close() }
      TextButton {
        visible: !root.created
        theme: root.theme
        text: "Create link"
        icon: "link"
        primary: true
        busy: root.busy
        onClicked: root.create()
      }
      TextButton {
        visible: !!root.created
        theme: root.theme
        text: "Copy again"
        icon: "copy"
        onClicked: root.copied(root.created.url)
      }
    }
  }
}
