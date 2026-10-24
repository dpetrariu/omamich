import QtQuick
import qs.Ui

// Ask for one line of text: a name, a description, a date.
Sheet {
  id: root

  property string label: ""
  property string placeholder: ""
  property string confirmText: "Save"
  property string value: ""
  property bool multiline: false
  property string error: ""
  property bool busy: false
  property var onAccept: null

  function ask(options) {
    title = options.title || ""
    subtitle = options.subtitle || ""
    label = options.label || ""
    placeholder = options.placeholder || ""
    confirmText = options.confirmText || "Save"
    value = options.value || ""
    onAccept = options.onAccept || null
    error = ""
    busy = false
    opened = true
    field.text = value
    Qt.callLater(function() { field.forceActiveFocus(); field.selectAll() })
  }

  function submit() {
    if (busy) return
    if (typeof onAccept === "function") {
      // The handler answers with an error string, true when done, or a
      // function(done) for work that finishes later.
      var result = onAccept(field.text)
      if (typeof result === "string" && result !== "") error = result
      else if (result === "pending") busy = true
      else opened = false
    } else opened = false
  }

  function finish(message) {
    busy = false
    if (message) error = message
    else opened = false
  }

  Column {
    width: parent.width
    spacing: root.theme.space(10)

    Text {
      visible: root.label !== ""
      text: root.label
      textFormat: Text.PlainText
      color: root.theme.dim
      font.family: root.theme.font
      font.pixelSize: root.theme.small
    }

    TextField {
      id: field
      width: parent.width
      placeholderText: root.placeholder
      font.family: root.theme.font
      font.pixelSize: root.theme.body
      onAccepted: root.submit()
    }

    Text {
      visible: root.error !== ""
      width: parent.width
      text: root.error
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      color: root.theme.urgent
      font.family: root.theme.font
      font.pixelSize: root.theme.small
    }

    Row {
      anchors.right: parent.right
      spacing: root.theme.space(8)
      TextButton { theme: root.theme; text: "Cancel"; onClicked: root.close() }
      TextButton { theme: root.theme; text: root.confirmText; primary: true; busy: root.busy; onClicked: root.submit() }
    }
  }
}
