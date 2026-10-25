import QtQuick
import qs.Ui
import "../components"
import "../lib/Format.js" as Format

// Tags as a tree: `trip/2026` sits under `trip`. Each row has its colour
// and photo count; open one to see its photos, or recolour or delete it.
// Filtering shows matching tags flat, with their full path.
Item {
  id: root

  required property var theme
  required property var service

  readonly property string kind: "tiles"
  readonly property bool typing: filter.activeFocus
  property int cursor: 0
  property var collapsed: ({})
  property var counts: ({})
  readonly property string query: filter.text.trim().toLowerCase()

  // Every tag with its depth and whether it has children, in tree order.
  readonly property var tree: {
    var list = service.tags.slice().sort(function(a, b) {
      return String(a.value || a.name).toLowerCase().localeCompare(String(b.value || b.name).toLowerCase())
    })
    var values = {}
    for (var i = 0; i < list.length; i++) values[String(list[i].value || list[i].name)] = true
    return list.map(function(t) {
      var value = String(t.value || t.name)
      var parts = value.split("/")
      var prefix = value + "/"
      var hasChildren = list.some(function(o) { return String(o.value || o.name).indexOf(prefix) === 0 })
      return { tag: t, value: value, label: parts[parts.length - 1], depth: parts.length - 1, hasChildren: hasChildren }
    })
  }
  readonly property var rows: {
    if (query) return tree.filter(function(r) { return r.value.toLowerCase().indexOf(root.query) >= 0 })
    return tree.filter(function(r) {
      var parts = r.value.split("/")
      for (var i = 1; i < parts.length; i++) if (root.collapsed[parts.slice(0, i).join("/")]) return false
      return true
    })
  }
  readonly property string statusText: Format.count(service.tags.length, "tag")

  signal tagOpened(var tag)
  signal toast(string text, string tone)
  signal confirm(var options)
  signal prompt(var options)
  signal promptFinished(string message)

  function reload() { service.loadTags() }
  function handleKey(id) {
    var row = rows[cursor]
    if (id === "down") cursor = Math.min(rows.length - 1, cursor + 1)
    else if (id === "up") cursor = Math.max(0, cursor - 1)
    else if (id === "right" && row && row.hasChildren) setCollapsed(row.value, false)
    else if (id === "left" && row && row.hasChildren) setCollapsed(row.value, true)
    else if (id === "first") cursor = 0
    else if (id === "last") cursor = rows.length - 1
    else if (id === "open" && row) root.tagOpened(row.tag)
    list.positionViewAtIndex(cursor, ListView.Contain)
  }

  function setCollapsed(value, on) {
    var next = Object.assign({}, collapsed)
    if (on) next[value] = true
    else delete next[value]
    collapsed = next
  }

  function loadCounts() {
    if (service.tags.length === 0) return
    service.call("tags.covers", { ids: service.tags.map(function(t) { return t.id }) }, function(r, e) {
      if (!root) return
      if (!e) root.counts = r
    })
  }

  Component.onCompleted: service.loadTags()
  Connections {
    target: root.service
    function onTagsChanged() { root.loadCounts() }
  }

  function createTag(parentValue) {
    root.prompt({
      title: parentValue ? "New tag under “" + parentValue + "”" : "New tag",
      subtitle: "Use / for levels: Trips/2024 makes 2024 under Trips.",
      placeholder: parentValue ? "Name" : "Name, or Parent/Child",
      confirmText: "Create",
      onAccept: function(text) {
        var name = text.trim()
        if (!name) return "Tags need a name"
        root.service.call("tag.create", { name: parentValue ? parentValue + "/" + name : name }, function(r, e) {
          if (!root) return
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
    subtitle: Format.count(root.service.tags.length, "tag")
    actions: [{ id: "new", label: "New tag...", icon: "plus", primary: true }]
    onActionTriggered: root.createTag("")
  }

  TextField {
    id: filter
    anchors { left: parent.left; top: header.bottom; leftMargin: root.theme.space(18) }
    width: Math.min(root.theme.space(320), parent.width - root.theme.space(36))
    placeholderText: "Filter tags"
    font.family: root.theme.font
    font.pixelSize: root.theme.body
    onTextChanged: root.cursor = 0
  }

  ListView {
    id: list
    anchors { left: parent.left; right: parent.right; top: filter.bottom; bottom: parent.bottom; topMargin: root.theme.space(10); leftMargin: root.theme.space(12); rightMargin: root.theme.space(12) }
    clip: true
    model: root.rows
    boundsBehavior: Flickable.StopAtBounds
    delegate: Item {
      id: row
      required property var modelData
      required property int index
      readonly property var info: root.counts[modelData.tag.id]
      readonly property real indent: root.query ? 0 : modelData.depth * root.theme.space(20)
      width: list.width
      height: root.theme.space(36)
      Rectangle {
        anchors.fill: parent
        radius: root.theme.radius
        color: root.cursor === row.index ? root.theme.selectedFill : (mouse.containsMouse ? root.theme.hoverFill : "transparent")
      }
      MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: { root.cursor = row.index; root.tagOpened(row.modelData.tag) }
      }
      IconButton {
        id: twisty
        x: row.indent + root.theme.space(4)
        anchors.verticalCenter: parent.verticalCenter
        visible: row.modelData.hasChildren && !root.query
        theme: root.theme
        size: root.theme.space(24)
        iconSize: root.theme.small + 2
        icon: root.collapsed[row.modelData.value] ? "chevronRight" : "chevronDown"
        tooltip: root.collapsed[row.modelData.value] ? "Show the tags inside" : "Hide the tags inside"
        onClicked: root.setCollapsed(row.modelData.value, !root.collapsed[row.modelData.value])
      }
      Rectangle {
        id: swatch
        x: row.indent + root.theme.space(34)
        anchors.verticalCenter: parent.verticalCenter
        width: root.theme.space(10); height: width; radius: width / 2
        color: row.modelData.tag.color || root.theme.faint
      }
      Text {
        anchors.left: swatch.right
        anchors.leftMargin: root.theme.space(12)
        anchors.right: count.left
        anchors.rightMargin: root.theme.space(10)
        anchors.verticalCenter: parent.verticalCenter
        text: root.query ? row.modelData.value : row.modelData.label
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: root.theme.foreground
        font.family: root.theme.font
        font.pixelSize: root.theme.body
      }
      Text {
        id: count
        anchors.right: buttons.visible ? buttons.left : parent.right
        anchors.rightMargin: root.theme.space(12)
        anchors.verticalCenter: parent.verticalCenter
        text: row.info && row.info.count !== null && row.info.count !== undefined ? Format.count(row.info.count, "photo") : ""
        color: root.theme.dim
        font.family: root.theme.font
        font.pixelSize: root.theme.small
      }
      Row {
        id: buttons
        anchors.right: parent.right
        anchors.rightMargin: root.theme.space(8)
        anchors.verticalCenter: parent.verticalCenter
        visible: mouse.containsMouse || root.cursor === row.index
        IconButton {
          theme: root.theme
          icon: "plus"
          tooltip: "New tag inside..."
          onClicked: root.createTag(row.modelData.value)
        }
        IconButton {
          theme: root.theme
          icon: "edit"
          tooltip: "Colour..."
          onClicked: root.prompt({
            title: "Colour for “" + row.modelData.value + "”",
            value: row.modelData.tag.color || "", placeholder: "#4a90d9", confirmText: "Save",
            onAccept: function(text) {
              root.service.call("tag.update", { id: row.modelData.tag.id, color: text.trim() }, function(r, e) {
                if (!root) return
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
            title: "Delete the tag “" + row.modelData.value + "”?",
            message: row.modelData.hasChildren ? "The tags inside it are deleted too. The photos stay." : "The tag is removed from every photo. The photos stay.",
            confirmText: "Delete tag",
            onConfirm: function() {
              root.service.call("tag.delete", { id: row.modelData.tag.id }, function(r, e) {
                if (!root) return
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
    visible: !root.service.tagsLoading && root.rows.length === 0
    text: root.query ? "No tag matches “" + filter.text + "”" : "No tags yet. Press t on a photo to tag it."
    color: root.theme.dim
    font.family: root.theme.font
    font.pixelSize: root.theme.body
  }
}
