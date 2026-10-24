import QtQuick
import qs.Ui
import "../components"

// First run: the server address and an API key, or both taken over from
// Mimick in one click.
Item {
  id: root
  required property var theme
  required property var service

  readonly property bool isForm: true
  property var mimick: null
  property string error: ""
  property string result: ""
  property bool busy: false

  Component.onCompleted: {
    service.call("auth.mimick", { apply: false }, function(r, e) { if (!root) return; if (root && !e) root.mimick = r })
    url.text = service.settings && service.settings.serverUrl ? service.settings.serverUrl : ""
  }

  function save() {
    error = ""
    result = ""
    if (!url.text.trim()) { error = "Enter your Immich address"; return }
    if (!key.text.trim() && !service.hasKey) { error = "Paste an API key"; return }
    busy = true
    service.call("auth.test", { serverUrl: url.text, key: key.text }, function(r, e) { if (!root) return;
      if (e) { root.busy = false; root.error = e.message; return }
      if (!r.lan.ok) { root.busy = false; root.error = r.lan.error; return }
      root.service.updateSettings({ serverUrl: url.text, serverEnabled: true }, function(s, e2) {
        if (e2) { root.busy = false; root.error = e2.message; return }
        if (!key.text.trim()) { root.busy = false; root.service.refreshServer(); return }
        root.service.call("auth.setKey", { key: key.text }, function(k, e3) { if (!root) return;
          root.busy = false
          if (e3) { root.error = e3.message; return }
          root.service.refreshServer()
        })
      })
    })
  }

  function importMimick() {
    busy = true
    service.call("auth.mimick", { apply: true }, function(r, e) { if (!root) return;
      root.busy = false
      if (e) { root.error = e.message; return }
      root.service.refreshServer()
    })
  }

  Column {
    anchors.centerIn: parent
    width: Math.min(parent.width - root.theme.space(48), root.theme.space(520))
    spacing: root.theme.space(14)

    Glyph {
      anchors.horizontalCenter: parent.horizontalCenter
      name: "logo"
      size: root.theme.display * 2
      color: root.theme.accent
      font.family: root.theme.font
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: "Connect to your Immich"
      color: root.theme.foreground
      font.family: root.theme.font
      font.pixelSize: root.theme.heading
    }
    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.Wrap
      text: "Omamich shows your Immich library here and can upload folders to it. It needs the server address and an API key from Immich: profile picture → Account Settings → API Keys → New API Key."
      color: root.theme.dim
      font.family: root.theme.font
      font.pixelSize: root.theme.small
      lineHeight: 1.25
    }

    Rectangle {
      visible: !!root.mimick && !!root.mimick.serverUrl
      width: parent.width
      height: mimickRow.implicitHeight + root.theme.space(20)
      radius: root.theme.radius
      color: root.theme.sunken
      border.width: root.theme.borderWidth
      border.color: root.theme.accent
      Row {
        id: mimickRow
        anchors.centerIn: parent
        width: parent.width - root.theme.space(20)
        spacing: root.theme.space(12)
        Text {
          width: parent.width - useButton.width - root.theme.space(12)
          anchors.verticalCenter: parent.verticalCenter
          wrapMode: Text.Wrap
          text: root.mimick ? "Mimick is set up for " + root.mimick.serverUrl + (root.mimick.keyFound ? " with a key." : ", but its key was not found.") : ""
          color: root.theme.foreground
          font.family: root.theme.font
          font.pixelSize: root.theme.small
        }
        TextButton {
          id: useButton
          theme: root.theme
          anchors.verticalCenter: parent.verticalCenter
          text: "Use Mimick's"
          primary: true
          busy: root.busy
          enabled: !!root.mimick && root.mimick.keyFound
          onClicked: root.importMimick()
        }
      }
    }

    Text { text: "Server address"; color: root.theme.dim; font.family: root.theme.font; font.pixelSize: root.theme.small }
    TextField {
      id: url
      width: parent.width
      placeholderText: "http://192.168.1.10:2283 or https://photos.example.com"
      font.family: root.theme.font
      font.pixelSize: root.theme.body
      onAccepted: key.forceActiveFocus()
    }
    Text { text: "API key"; color: root.theme.dim; font.family: root.theme.font; font.pixelSize: root.theme.small }
    TextField {
      id: key
      width: parent.width
      echoMode: TextInput.Password
      placeholderText: root.service.hasKey ? "A key is saved; paste a new one to replace it" : "Paste the key Immich showed you"
      font.family: root.theme.font
      font.pixelSize: root.theme.body
      onAccepted: root.save()
    }
    Text {
      visible: root.error !== ""
      width: parent.width
      wrapMode: Text.Wrap
      text: root.error
      color: root.theme.urgent
      font.family: root.theme.font
      font.pixelSize: root.theme.small
    }
    TextButton {
      anchors.right: parent.right
      theme: root.theme
      text: "Connect"
      primary: true
      busy: root.busy
      onClicked: root.save()
    }
  }
}
