import QtQuick
import QtQuick.Controls as QQC
import qs.Ui
import "../components"
import "../lib/Format.js" as Format

// The server, the key, the cache and what this is. Switches apply at once;
// connection changes are tested before they are saved.
Item {
  id: root
  required property var theme
  required property var service

  readonly property bool isForm: true
  property var test: null
  property bool testing: false
  property string error: ""
  property var cache: null

  signal closed()
  signal toast(string text, string tone)

  Component.onCompleted: {
    lan.text = service.settings.serverUrl || ""
    wan.text = service.settings.externalUrl || ""
    loadCache()
  }

  function loadCache() {
    service.call("cache.info", {}, function(r, e) { if (!root) return; if (!e) root.cache = r })
  }

  function testConnection(then) {
    testing = true
    test = null
    error = ""
    service.call("auth.test", { serverUrl: lan.text, externalUrl: wan.text, key: key.text }, function(r, e) { if (!root) return;
      root.testing = false
      if (e) { root.error = e.message; return }
      root.test = r
      if (typeof then === "function") then(r)
    })
  }

  function saveConnection() {
    testConnection(function(r) {
      var anyOk = (r.lan && r.lan.ok) || (r.wan && r.wan.ok)
      if (!anyOk) { root.error = "Neither address worked with this key; nothing was saved"; return }
      root.service.updateSettings({ serverUrl: lan.text, externalUrl: wan.text, serverEnabled: lan.text.trim() !== "", externalEnabled: wan.text.trim() !== "" }, function(s, e) {
        if (e) { root.error = e.message; return }
        if (key.text.trim()) {
          root.service.call("auth.setKey", { key: key.text }, function(k, e2) { if (!root) return;
            if (e2) { root.error = e2.message; return }
            key.text = ""
            root.toast("Saved. The key is in your " + (k.storage === "keyring" ? "keyring" : "private config folder"), "info")
            root.service.refreshServer()
          })
        } else {
          root.toast("Saved", "info")
          root.service.refreshServer()
        }
      })
    })
  }

  function result(r) {
    if (!r) return ""
    return r.ok ? "Works — Immich " + r.version + " as " + (r.user.name || r.user.email) : r.error
  }

  // Momentum scrolling with rubber-band ends.
  WheelScroller { flickable: scrollPage; notch: root.theme.space(260) }

  Flickable {
    id: scrollPage
    anchors.fill: parent
    contentHeight: column.implicitHeight + root.theme.space(48)
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    QQC.ScrollBar.vertical: QQC.ScrollBar {}

    Column {
      id: column
      x: Math.max(root.theme.space(18), (parent.width - width) / 2)
      width: Math.min(parent.width - root.theme.space(36), root.theme.space(680))
      spacing: root.theme.space(12)

      PageHeader {
        width: parent.width
        theme: root.theme
        title: "Settings"
        subtitle: "Omamich " + (root.service.version || "") + (root.service.serverVersion ? "  ·  Immich " + root.service.serverVersion : "")
        showBack: true
        onBack: root.closed()
      }

      SectionTitle { theme: root.theme; text: "Server" }
      Text {
        width: parent.width
        wrapMode: Text.Wrap
        text: "Omamich tries the home address first and the away address when home does not answer."
        color: root.theme.dim
        font.family: root.theme.font
        font.pixelSize: root.theme.small
      }
      Text { text: "Home address (LAN)"; color: root.theme.dim; font.family: root.theme.font; font.pixelSize: root.theme.small }
      TextField { id: lan; width: parent.width; placeholderText: "http://192.168.1.10:2283"; font.family: root.theme.font; font.pixelSize: root.theme.body }
      Text { visible: !!root.test && !!root.test.lan; text: root.result(root.test ? root.test.lan : null); color: root.test && root.test.lan && root.test.lan.ok ? root.theme.accent : root.theme.urgent; font.family: root.theme.font; font.pixelSize: root.theme.small }
      Text { text: "Away address (optional)"; color: root.theme.dim; font.family: root.theme.font; font.pixelSize: root.theme.small }
      TextField { id: wan; width: parent.width; placeholderText: "https://photos.example.com"; font.family: root.theme.font; font.pixelSize: root.theme.body }
      Text { visible: !!root.test && !!root.test.wan; text: root.result(root.test ? root.test.wan : null); color: root.test && root.test.wan && root.test.wan.ok ? root.theme.accent : root.theme.urgent; font.family: root.theme.font; font.pixelSize: root.theme.small }
      Text { text: "API key"; color: root.theme.dim; font.family: root.theme.font; font.pixelSize: root.theme.small }
      TextField {
        id: key
        width: parent.width
        echoMode: TextInput.Password
        placeholderText: root.service.hasKey ? "Saved in your " + (root.service.keyStorage === "file" ? "private config folder" : "keyring") + "; paste a new one to replace it" : "Paste an Immich API key"
        font.family: root.theme.font
        font.pixelSize: root.theme.body
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
      Row {
        spacing: root.theme.space(8)
        TextButton { theme: root.theme; text: "Test"; busy: root.testing; onClicked: root.testConnection() }
        TextButton { theme: root.theme; text: "Save"; primary: true; busy: root.testing; onClicked: root.saveConnection() }
        TextButton {
          theme: root.theme
          text: "Use Mimick's settings"
          onClicked: root.service.call("auth.mimick", { apply: true }, function(r, e) { if (!root) return;
            if (e) return root.toast(e.message, "error")
            lan.text = r.serverUrl
            wan.text = r.externalUrl
            root.toast(r.keyFound ? "Took over Mimick's server and key" : "Took over Mimick's server; its key was not found", r.keyFound ? "info" : "error")
            root.service.refreshServer()
          })
        }
      }

      Text {
        visible: !!root.service.overview && !!root.service.overview.storage && !!root.service.overview.storage.diskSize
        width: parent.width
        wrapMode: Text.Wrap
        text: root.service.overview && root.service.overview.storage
          ? "Server storage: " + root.service.overview.storage.diskUse + " of " + root.service.overview.storage.diskSize + " used (" + Math.round(root.service.overview.storage.diskUsagePercentage) + "%), " + root.service.overview.storage.diskAvailable + " free"
            + (root.service.statistics ? ". Library: " + Format.thousands(root.service.statistics.images) + " photos, " + Format.thousands(root.service.statistics.videos) + " videos." : "")
          : ""
        color: root.theme.dim
        font.family: root.theme.font
        font.pixelSize: root.theme.small
      }

      SectionTitle { theme: root.theme; text: "Thumbnail cache" }
      Text {
        width: parent.width
        wrapMode: Text.Wrap
        text: root.cache ? Format.bytes(root.cache.bytes) + " of " + Format.bytes(root.cache.capMb * 1024 * 1024) + " used. The oldest thumbnails go first when the cache is full." : "…"
        color: root.theme.dim
        font.family: root.theme.font
        font.pixelSize: root.theme.small
      }
      Row {
        spacing: root.theme.space(6)
        Repeater {
          model: [500, 2000, 5000, 20000]
          delegate: TextButton {
            required property var modelData
            theme: root.theme
            text: Format.bytes(modelData * 1024 * 1024)
            fontSize: root.theme.small
            selected: root.service.settings.cacheCapMb === modelData
            onClicked: root.service.updateSettings({ cacheCapMb: modelData }, function() { root.loadCache() })
          }
        }
        Item { width: root.theme.space(12); height: 1 }
        TextButton {
          theme: root.theme
          text: "Clear cache"
          fontSize: root.theme.small
          onClicked: root.service.call("cache.clear", {}, function(r) { if (!root) return; root.loadCache(); root.toast("Freed " + Format.bytes(r.freed), "info") })
        }
      }

      SectionTitle { theme: root.theme; text: "Keyboard" }
      Text {
        width: parent.width
        wrapMode: Text.Wrap
        text: "Press ? in the window for every shortcut. To open Omamich from anywhere, add to ~/.config/hypr/bindings.lua:\n\no.bind(\"SUPER + SHIFT + I\", \"Omamich\", \"omarchy shell shell toggle dpetrariu.omamich '{}'\")"
        color: root.theme.dim
        font.family: root.theme.font
        font.pixelSize: root.theme.small
      }

      SectionTitle { theme: root.theme; text: "Account" }
      Text {
        width: parent.width
        wrapMode: Text.Wrap
        text: root.service.user ? (root.service.user.name + " <" + root.service.user.email + ">" + (root.service.user.isAdmin ? "  ·  admin" : "")) : "Not connected"
        color: root.theme.foreground
        font.family: root.theme.font
        font.pixelSize: root.theme.small
      }
      TextButton {
        theme: root.theme
        text: "Forget the API key..."
        danger: true
        fontSize: root.theme.small
        onClicked: root.service.call("auth.clearKey", {}, function() { if (!root) return; root.service.loadSettings(); root.toast("The key was removed from this computer", "info") })
      }
    }
  }
}
