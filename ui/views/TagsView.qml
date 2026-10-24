import QtQuick
import qs.Ui
import "../components"
import "../lib/Format.js" as Format

// Tags as a filterable list. Open one to see its photos; rename by
// recreating, recolour or delete from the row.
Item {
  id: root

  required property var theme
  required property var service

  readonly property string kind: "tiles"
  readonly property bool typing: filter.activeFocus
  property int cursor: 0
  readonly property var tags: {
    var q = filter.text.trim().toLowerCase()
    return service.tags.filter(function(t) { return !q || String(t.value || t.name).toLowerCase().indexOf(q) >= 0 })
  }
  readonly property string statusText: Format.count(tags.length, "tag")

  signal tagOpened(var tag)
  signal toast(string text, string tone)
  signal confirm(var options)
  signal prompt(var options)
  signal promptFinished(string message)

  function reload() { service.loadTags() }
  function handleKey(id) {
    if (id === "down" || id === "right") cursor = Math.min(tags.length - 1, cursor + 1)
    else if (id === "up" || id === "left") cursor = Math.max(0, cursor - 1)
    else if (id === "first") cursor = 0
    else if (id === "last") cursor = tags.length - 1
    else if (id === "open" && tags[cursor]) root.tagOpened(tags[cursor])
    list.positionViewAtIndex(cursor, ListView.Contain)
  }

  Component.onCompleted: service.loadTags()

  function createTag() {
    root.prompt({
      title: "New tag", placeholder: "Name, or parent/child for a nested tag", confirmText: "Create",
      onAccept: function(text) {
        if (!text.trim()) return "Tags need a name"
        root.service.call("tag.create", { name: text.trim() }, function(r, e) { if (!root) return;
          root.promptFinished(e ? e.message : "")
          if (!e) root.service.loadTags()
        })
        return "pending"
      }
    })
  }

  PageHeader {
    id: header
    theme: root.theme
    anchors { left: parent.left; right: parent.right; top: parent.top }
    title: "Tags"
    subtitle: Format.count(root.tags.length, "tag")
    actions: [{ id: "new", label: "New tag...", icon: "plus", primary: true }]
    onActionTriggered: root.createTag()
  }

  TextField {
    id: filter
    anchors { left: parent.left; top: header.bottom; leftMargin: root.theme.space(18) }
    width: Math.min(root.theme.space(320), parent.width - root.theme.space(36))
    placeholderText: "Filter tags"
    font.family: root.theme.font
    font.pixelSize: root.theme.body
  }

  ListView {
    id: list
    anchors { left: parent.left; right: parent.right; top: filter.bottom; bottom: parent.bottom; topMargin: root.theme.space(10); leftMargin: root.theme.space(12); rightMargin: root.theme.space(12) }
    clip: true
    model: root.tags
    boundsBehavior: Flickable.StopAtBounds
    delegate: Item {
      id: row
      required property var modelData
      required property int index
      width: list.width
      height: root.theme.space(38)
      Rectangle {
        anchors.fill: parent
        radius: root.theme.radius
        color: root.cursor === row.index ? root.theme.selectedFill : (mouse.containsMouse ? root.theme.hoverFill : "transparent")
      }
      Rectangle {
        id: swatch
        x: root.theme.space(12)
        anchors.verticalCenter: parent.verticalCenter
        width: root.theme.space(10); height: width; radius: width / 2
        color: row.modelData.color || root.theme.faint
      }
      Text {
        anchors.left: swatch.right
        anchors.leftMargin: root.theme.space(12)
        anchors.right: buttons.left
        anchors.verticalCenter: parent.verticalCenter
        text: row.modelData.value || row.modelData.name
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: root.theme.foreground
        font.family: root.theme.font
        font.pixelSize: root.theme.body
      }
      MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: { root.cursor = row.index; root.tagOpened(row.modelData) }
      }
      Row {
        id: buttons
        anchors.right: parent.right
        anchors.rightMargin: root.theme.space(8)
        anchors.verticalCenter: parent.verticalCenter
        visible: mouse.containsMouse || root.cursor === row.index
        IconButton {
          theme: root.theme
          icon: "edit"
          tooltip: "Colour..."
          onClicked: root.prompt({
            title: "Colour for “" + (row.modelData.value || row.modelData.name) + "”",
            value: row.modelData.color || "", placeholder: "#4a90d9", confirmText: "Save",
            onAccept: function(text) {
              root.service.call("tag.update", { id: row.modelData.id, color: text.trim() }, function(r, e) { if (!root) return;
                root.promptFinished(e ? e.message : "")
                if (!e) root.service.loadTags()
              })
              return "pending"
            }
          })
        }
        IconButton {
          theme: root.theme
          icon: "trash"
          tooltip: "Delete tag..."
          color: root.theme.urgent
          onClicked: root.confirm({
            title: "Delete the tag “" + (row.modelData.value || row.modelData.name) + "”?",
            message: "The tag is removed from every photo. The photos stay.",
            confirmText: "Delete tag",
            onConfirm: function() {
              root.service.call("tag.delete", { id: row.modelData.id }, function(r, e) { if (!root) return;
                if (e) root.toast(e.message, "error")
                else root.service.loadTags()
              })
            }
          })
        }
      }
    }
  }

  Text {
    anchors.centerIn: parent
    visible: !root.service.tagsLoading && root.tags.length === 0
    text: filter.text ? "No tag matches “" + filter.text + "”" : "No tags yet. Press t on a photo to tag it."
    color: root.theme.dim
    font.family: root.theme.font
    font.pixelSize: root.theme.body
  }
}
