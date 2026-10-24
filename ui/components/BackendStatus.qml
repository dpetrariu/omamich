import QtQuick

// Shown while the backend is missing, starting or has stopped: what is
// wrong, and the one thing to do about it.
Rectangle {
  id: root
  required property var theme
  required property var service
  color: theme.background

  readonly property bool missing: !!service && service.binaryChecked && !service.binaryPresent
  readonly property string failure: service && service.backend ? service.backend.failure : ""

  Column {
    anchors.centerIn: parent
    width: Math.min(parent.width - root.theme.space(48), root.theme.space(520))
    spacing: root.theme.space(12)
    Glyph {
      anchors.horizontalCenter: parent.horizontalCenter
      name: root.missing || root.failure ? "warning" : "logo"
      size: root.theme.display * 1.6
      color: root.missing || root.failure ? root.theme.urgent : root.theme.accent
      font.family: root.theme.font
    }
    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      text: root.missing ? "Omamich's backend is not built yet" : root.failure ? "Omamich's backend stopped" : "Starting…"
      color: root.theme.foreground
      font.family: root.theme.font
      font.pixelSize: root.theme.title
    }
    TextEdit {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      readOnly: true
      selectByMouse: true
      wrapMode: Text.Wrap
      text: root.missing ? "Build it once from the plugin folder:\n\ncd " + root.service.pluginDir + " && make install\n\nThen reopen this window."
        : root.failure
      color: root.theme.dim
      font.family: root.theme.font
      font.pixelSize: root.theme.small
    }
  }
}
