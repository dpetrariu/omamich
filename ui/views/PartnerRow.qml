import QtQuick
import "../components"

// One partner: who, what the sharing means, and the one thing to change.
Item {
  id: root
  required property var theme
  property var partner: null
  property string detail: ""
  property string actionText: ""
  signal action()

  height: theme.space(48)

  Column {
    anchors.left: parent.left
    anchors.right: button.left
    anchors.rightMargin: root.theme.space(10)
    anchors.verticalCenter: parent.verticalCenter
    Text {
      width: parent.width
      text: root.partner ? (root.partner.name || root.partner.email) : ""
      textFormat: Text.PlainText
      elide: Text.ElideRight
      color: root.theme.foreground
      font.family: root.theme.font
      font.pixelSize: root.theme.body
    }
    Text {
      width: parent.width
      text: (root.partner && root.partner.email ? root.partner.email + "  ·  " : "") + root.detail
      textFormat: Text.PlainText
      elide: Text.ElideRight
      color: root.theme.dim
      font.family: root.theme.font
      font.pixelSize: root.theme.caption
    }
  }
  TextButton {
    id: button
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    theme: root.theme
    text: root.actionText
    fontSize: root.theme.small
    onClicked: root.action()
  }
}
