import QtQuick
import "../components"
import "../lib/Format.js" as Format

// Results for a query. The chips switch how the words are matched; the
// filters narrow any of them.
Item {
  id: root

  required property var theme
  required property var service
  property real zoom: 1
  property var entry: null

  readonly property string kind: "grid"
  readonly property alias grid: timeline
  readonly property string statusText: timeline.total > 0 ? Format.count(timeline.total, "result") : ""
  readonly property var features: service.features || ({})
  readonly property var filters: entry && entry.filters ? entry.filters : ({})

  signal openAsset(var asset)
  signal contextRequested(var asset, Item item, real x, real y)
  signal back()
  signal modeChanged(string mode, var filters)

  function reload() { timeline.reload() }

  readonly property var modes: [
    { id: "smart", label: "Smart", hint: "What is in the photo", enabled: features.smartSearch !== false },
    { id: "filename", label: "File name", hint: "Part of the original file name", enabled: true },
    { id: "description", label: "Description", hint: "Words in the description", enabled: true },
    { id: "ocr", label: "Text in photo", hint: "Text Immich read in the photo", enabled: features.ocr === true }
  ]

  function setFilter(key, value) {
    var next = Object.assign({}, filters)
    if (value === null || value === undefined || value === false || value === "") delete next[key]
    else next[key] = value
    root.modeChanged(entry.mode, next)
  }

  PageHeader {
    id: header
    theme: root.theme
    anchors { left: parent.left; right: parent.right; top: parent.top }
    showBack: true
    title: root.entry ? "“" + root.entry.query + "”" : ""
    subtitle: timeline.total > 0 ? Format.count(timeline.total, "result") + (timeline.hasMore ? " so far" : "") : ""
    onBack: root.back()
  }

  Row {
    id: chips
    anchors { left: parent.left; top: header.bottom; leftMargin: root.theme.space(18) }
    spacing: root.theme.space(6)
    Repeater {
      model: root.modes
      delegate: TextButton {
        required property var modelData
        visible: modelData.enabled
        theme: root.theme
        text: modelData.label
        fontSize: root.theme.small
        selected: !!root.entry && root.entry.mode === modelData.id
        onClicked: root.modeChanged(modelData.id, root.filters)
      }
    }
    Item { width: root.theme.space(14); height: 1 }
    TextButton {
      theme: root.theme
      text: "Photos"
      icon: "image"
      fontSize: root.theme.small
      selected: root.filters.type === "IMAGE"
      onClicked: root.setFilter("type", root.filters.type === "IMAGE" ? "" : "IMAGE")
    }
    TextButton {
      theme: root.theme
      text: "Videos"
      icon: "video"
      fontSize: root.theme.small
      selected: root.filters.type === "VIDEO"
      onClicked: root.setFilter("type", root.filters.type === "VIDEO" ? "" : "VIDEO")
    }
    TextButton {
      theme: root.theme
      text: "Favourites"
      icon: "favorite"
      fontSize: root.theme.small
      selected: root.filters.isFavorite === true
      onClicked: root.setFilter("isFavorite", !root.filters.isFavorite)
    }
    TextButton {
      theme: root.theme
      text: "Not in an album"
      icon: "albums"
      fontSize: root.theme.small
      selected: root.filters.isNotInAlbum === true
      onClicked: root.setFilter("isNotInAlbum", !root.filters.isNotInAlbum)
    }
  }

  Timeline {
    id: timeline
    theme: root.theme
    service: root.service
    anchors { left: parent.left; right: parent.right; top: chips.bottom; bottom: parent.bottom; topMargin: root.theme.space(8) }
    zoom: root.zoom
    emptyIcon: "search"
    emptyTitle: "Nothing found"
    emptyText: root.entry && root.entry.mode === "smart"
      ? "Smart search looks for what is in the photo. Try other words, or search by file name."
      : "Try other words or another way of matching."
    pager: root.entry ? function(page, done) {
      root.service.call("search", { mode: root.entry.mode, query: root.entry.query, page: page, size: 150, filters: root.filters }, function(r, e) {
        if (e) return done([], false, e)
        done(r.items, r.nextPage !== null && r.nextPage !== undefined && r.items.length > 0, null)
      })
    } : null
    onOpened: function(a) { root.openAsset(a) }
    onContextRequested: function(a, item, x, y) { root.contextRequested(a, item, x, y) }
  }
}
