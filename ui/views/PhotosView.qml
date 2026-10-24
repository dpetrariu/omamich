import QtQuick
import "../components"
import "../lib/Format.js" as Format

// A titled photo grid: the timeline, favourites, archive, trash, a tag or a
// place. Either a timeline scope or a pager feeds it.
Item {
  id: root

  required property var theme
  required property var service
  property real zoom: 1
  property string title: ""
  property string subtitle: ""
  property bool showBack: false
  property var scope: ({})
  property var pager: null
  property var actions: []
  property string emptyIcon: "photos"
  property string emptyTitle: "No photos here"
  property string emptyText: ""

  readonly property string kind: "grid"
  readonly property alias grid: timeline
  readonly property string statusText: timeline.total > 0 ? Format.count(timeline.total, "item") : ""

  signal openAsset(var asset)
  signal contextRequested(var asset, Item item, real x, real y)
  signal back()
  signal actionTriggered(string id)

  function reload() { timeline.reload() }

  PageHeader {
    id: header
    theme: root.theme
    anchors { left: parent.left; right: parent.right; top: parent.top }
    title: root.title
    subtitle: root.subtitle !== "" ? root.subtitle
      : (timeline.total > 0 ? Format.count(timeline.total, "item") : "")
    showBack: root.showBack
    actions: root.actions
    onBack: root.back()
    onActionTriggered: function(id) { root.actionTriggered(id) }
  }

  Timeline {
    id: timeline
    theme: root.theme
    service: root.service
    anchors { left: parent.left; right: parent.right; top: header.bottom; bottom: parent.bottom }
    scope: root.scope
    pager: root.pager
    zoom: root.zoom
    emptyIcon: root.emptyIcon
    emptyTitle: root.emptyTitle
    emptyText: root.emptyText
    onOpened: function(a) { root.openAsset(a) }
    onContextRequested: function(a, item, x, y) { root.contextRequested(a, item, x, y) }
  }

  Connections {
    target: root.service
    function onLibraryRevisionChanged() { timeline.reload() }
  }
}
