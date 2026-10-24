import QtQuick
import qs.Ui

// Choose one item from a long list by typing: an album to add photos to, a
// tag, a person to merge into. When `createLabel` is set, a typed name that
// matches nothing can be created on the spot.
Sheet {
  id: root

  property var items: []          // [{ id, label, detail, image }]
  property string placeholder: "Filter"
  property string createLabel: "" // e.g. "Create album"
  property string emptyText: "Nothing here yet"
  property bool loading: false
  property string error: ""
  property bool busy: false
  property var onPick: null       // function(item) where item.create is the new name
  property int current: 0

  readonly property string query: field.text.trim()
  readonly property var filtered: {
    var q = query.toLowerCase()
    var list = []
    for (var i = 0; i < items.length; i++) {
      var it = items[i]
      if (!q || String(it.label || "").toLowerCase().indexOf(q) >= 0) list.push(it)
      if (list.length >= 300) break
    }
    var exact = items.some(function(it) { return String(it.label || "").toLowerCase() === q })
    if (createLabel && q && !exact) list.unshift({ id: "", label: createLabel + " “" + query + "”", create: query })
    return list
  }

  function ask(options) {
    title = options.title || ""
    subtitle = options.subtitle || ""
    items = options.items || []
    placeholder = options.placeholder || "Filter"
    createLabel = options.createLabel || ""
    emptyText = options.emptyText || "Nothing here yet"
    onPick = options.onPick || null
    loading = options.loading === true
    error = ""
    busy = false
    current = 0
    field.text = ""
    opened = true
    Qt.callLater(function() { field.forceActiveFocus() })
  }

  function pick(index) {
    var item = filtered[index]
    if (!item || busy) return
    if (typeof onPick === "function") {
      var result = onPick(item)
      if (result === "pending") busy = true
      else if (typeof result === "string" && result) error = result
      else opened = false
    } else opened = false
  }

  // Type a filter and take the first match, as typing and Enter would.
  function choose(text) {
    field.text = text
    pick(0)
  }

  function finish(message) {
    busy = false
    if (message) error = message
    else opened = false
  }

  onQueryChanged: current = 0

  Column {
    width: parent.width
    spacing: root.theme.space(10)

    TextField {
      id: field
      width: parent.width
      placeholderText: root.placeholder
      font.family: root.theme.font
      font.pixelSize: root.theme.body
      onAccepted: root.pick(root.current)
      Keys.onDownPressed: root.current = Math.min(root.filtered.length - 1, root.current + 1)
      Keys.onUpPressed: root.current = Math.max(0, root.current - 1)
    }

    ListView {
      id: list
      width: parent.width
      height: Math.min(root.theme.space(320), Math.max(root.theme.space(40), contentHeight))
      clip: true
      model: root.filtered
      currentIndex: root.current
      boundsBehavior: Flickable.StopAtBounds
      onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
      delegate: Item {
        id: entry
        required property var modelData
        required property int index
        width: list.width
        height: root.theme.space(modelData.image ? 44 : 32)

        Rectangle {
          anchors.fill: parent
          radius: root.theme.radius
          color: entry.index === root.current ? root.theme.selectedFill
            : hover.containsMouse ? root.theme.hoverFill : "transparent"
        }
        Rectangle {
          id: thumb
          visible: !!entry.modelData.image
          x: root.theme.space(6)
          anchors.verticalCenter: parent.verticalCenter
          width: root.theme.space(34); height: width
          radius: root.theme.radius
          color: root.theme.raised
          clip: true
          Image {
            anchors.fill: parent
            source: entry.modelData.image || ""
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            sourceSize.width: 96; sourceSize.height: 96
          }
        }
        Glyph {
          visible: !!entry.modelData.create
          x: root.theme.space(8)
          anchors.verticalCenter: parent.verticalCenter
          name: "plus"
          size: root.theme.icon
          color: root.theme.accent
          font.family: root.theme.font
        }
        Column {
          anchors.verticalCenter: parent.verticalCenter
          x: entry.modelData.image ? thumb.x + thumb.width + root.theme.space(10)
            : root.theme.space(entry.modelData.create ? 32 : 10)
          width: parent.width - x - root.theme.space(8)
          Text {
            width: parent.width
            text: entry.modelData.label || ""
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: entry.modelData.create ? root.theme.accent : root.theme.foreground
            font.family: root.theme.font
            font.pixelSize: root.theme.body
          }
          Text {
            visible: !!entry.modelData.detail
            width: parent.width
            text: entry.modelData.detail || ""
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: root.theme.dim
            font.family: root.theme.font
            font.pixelSize: root.theme.caption
          }
        }
        MouseArea {
          id: hover
          anchors.fill: parent
          hoverEnabled: true
          onClicked: root.pick(entry.index)
        }
      }
    }

    Text {
      visible: root.filtered.length === 0
      text: root.loading ? "Loading…" : root.emptyText
      textFormat: Text.PlainText
      color: root.theme.dim
      font.family: root.theme.font
      font.pixelSize: root.theme.small
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
  }
}
