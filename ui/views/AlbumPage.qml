import QtQuick
import "../components"
import "../lib/Format.js" as Format

// One album: its photos, and what can be done to the album itself.
Item {
  id: root

  required property var theme
  required property var service
  property real zoom: 1
  property var album: null

  readonly property string kind: "grid"
  readonly property alias grid: timeline
  readonly property string statusText: album ? Format.count(timeline.total, "item") : ""

  signal openAsset(var asset)
  signal contextRequested(var asset, Item item, real x, real y)
  signal back()
  signal share()
  signal people()
  signal rename()
  signal describe()
  signal remove()
  signal toggleOrder()

  function reload() { timeline.reload() }

  PageHeader {
    id: header
    theme: root.theme
    anchors { left: parent.left; right: parent.right; top: parent.top }
    showBack: true
    title: root.album ? root.album.albumName : ""
    subtitle: {
      if (!root.album) return ""
      var parts = [Format.count(root.album.assetCount, "item")]
      var range = Format.dateRange(root.album.startDate, root.album.endDate)
      if (range) parts.push(range)
      if (root.album.shared) parts.push("shared with " + (root.album.users || []).map(function(u) { return u.name }).join(", "))
      if (root.album.description) parts.push(root.album.description)
      return parts.join("  ·  ")
    }
    actions: [
      { id: "people", label: "People...", icon: "people" },
      { id: "share", label: "Share link...", icon: "link" },
      { id: "order", label: root.album && root.album.order === "asc" ? "Oldest first" : "Newest first", icon: "calendar" },
      { id: "more", label: "", icon: "more" }
    ]
    onBack: root.back()
    onActionTriggered: function(id, button) {
      if (id === "share") root.share()
      else if (id === "people") root.people()
      else if (id === "order") root.toggleOrder()
      else if (id === "more") moreMenu.openBelow(button)
    }
  }

  PopupMenu {
    id: moreMenu
    theme: root.theme
    parent: root
    items: [
      { id: "rename", label: "Rename...", icon: "edit" },
      { id: "describe", label: "Edit description...", icon: "text" },
      { separator: true },
      { id: "delete", label: "Delete album...", icon: "trash", danger: true }
    ]
    onActivated: function(id) {
      if (id === "rename") root.rename()
      else if (id === "describe") root.describe()
      else if (id === "delete") root.remove()
    }
  }

  Timeline {
    id: timeline
    theme: root.theme
    service: root.service
    anchors { left: parent.left; right: parent.right; top: header.bottom; bottom: parent.bottom }
    scope: root.album ? ({ albumId: root.album.id, order: root.album.order === "asc" ? "asc" : "desc" }) : ({})
    zoom: root.zoom
    emptyIcon: "albums"
    emptyTitle: "This album is empty"
    emptyText: "Select photos anywhere and press Shift+A to add them, or drop files here to upload them into it."
    onOpened: function(a) { root.openAsset(a) }
    onContextRequested: function(a, item, x, y) { root.contextRequested(a, item, x, y) }
  }

  Connections {
    target: root.service
    function onLibraryRevisionChanged() { timeline.reload() }
  }
}
