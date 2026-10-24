import QtQuick

// An icon, a line and the detail under it. The title can be a way in
// (a place, an album); `link` adds a trailing action.
Item {
  id: root
  required property var theme
  property string icon: ""
  property string title: ""
  property string detail: ""
  property string link: ""
  property bool selectable: false
  signal titleClicked()
  signal linkClicked()

  width: parent ? parent.width : 0
  implicitHeight: Math.max(theme.space(24), texts.implicitHeight)

  Glyph {
    id: glyph
    y: root.theme.space(1)
    width: root.theme.space(22)
    name: root.icon
    size: root.theme.icon
    color: root.theme.dim
    font.family: root.theme.font
    horizontalAlignment: Text.AlignLeft
  }

  Column {
    id: texts
    anchors.left: glyph.right
    anchors.leftMargin: root.theme.space(8)
    anchors.right: linkText.left
    spacing: root.theme.space(2)
    TextEdit {
      width: parent.width
      text: root.title
      readOnly: true
      selectByMouse: root.selectable
      textFormat: TextEdit.PlainText
      wrapMode: TextEdit.Wrap
      color: titleMouse.containsMouse ? root.theme.accent : root.theme.foreground
      font.family: root.theme.font
      font.pixelSize: root.theme.body
      MouseArea {
        id: titleMouse
        anchors.fill: parent
        enabled: !root.selectable
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.titleClicked()
      }
    }
    TextEdit {
      visible: root.detail !== ""
      width: parent.width
      text: root.detail
      readOnly: true
      selectByMouse: true
      textFormat: TextEdit.PlainText
      wrapMode: TextEdit.Wrap
      color: root.theme.dim
      font.family: root.theme.font
      font.pixelSize: root.theme.small
    }
  }

  Text {
    id: linkText
    anchors.right: parent.right
    y: root.theme.space(2)
    width: root.link ? implicitWidth : 0
    text: root.link
    color: linkMouse.containsMouse ? root.theme.foreground : root.theme.accent
    font.family: root.theme.font
    font.pixelSize: root.theme.small
    MouseArea { id: linkMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.linkClicked() }
  }
}
