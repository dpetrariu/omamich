import QtQuick
import QtQuick.Controls as QQC
import "../lib/Layout.js" as Layout

// A grid of equal tiles (albums, people, places, tags) with a keyboard
// cursor. The caller supplies the tile as a Component; each tile gets
// `modelData`, `index` and `isCurrent`.
GridView {
  id: root

  required property var theme
  property Component tile: null
  property real minTile: theme.space(180)
  property real tileAspect: 1.25         // height / width
  property real tileExtra: 0             // fixed height under the tile (labels)
  property int cursor: 0
  readonly property int perRow: Layout.columns(width - theme.space(24), minTile, theme.space(12))

  signal activated(var item, int index)

  leftMargin: theme.space(18)
  rightMargin: theme.space(6)
  topMargin: theme.space(4)
  bottomMargin: theme.space(18)
  clip: true
  boundsBehavior: Flickable.StopAtBounds
  cellWidth: Math.floor((width - leftMargin - rightMargin) / perRow)
  cellHeight: Math.round((cellWidth - theme.space(12)) * tileAspect + tileExtra + theme.space(14))
  currentIndex: cursor
  highlightFollowsCurrentItem: false
  cacheBuffer: 600
  QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

  function moveBy(step) {
    var n = count
    if (n === 0) return
    cursor = Math.max(0, Math.min(n - 1, cursor + step))
    positionViewAtIndex(cursor, GridView.Contain)
  }

  function handleKey(id) {
    switch (id) {
    case "left": moveBy(-1); return true
    case "right": moveBy(1); return true
    case "up": moveBy(-perRow); return true
    case "down": moveBy(perRow); return true
    case "pageDown": moveBy(perRow * Math.max(1, Math.floor(height / cellHeight))); return true
    case "pageUp": moveBy(-perRow * Math.max(1, Math.floor(height / cellHeight))); return true
    case "first": cursor = 0; positionViewAtBeginning(); return true
    case "last": cursor = Math.max(0, count - 1); positionViewAtEnd(); return true
    case "open":
      if (count > 0 && model) root.activated(model[cursor] || null, cursor)
      return true
    }
    return false
  }

  onCountChanged: if (cursor >= count) cursor = Math.max(0, count - 1)

  delegate: Item {
    id: cell
    required property var modelData
    required property int index
    width: root.cellWidth
    height: root.cellHeight

    Loader {
      id: loader
      anchors.fill: parent
      anchors.margins: root.theme.space(6)
      sourceComponent: root.tile
      property var modelData: cell.modelData
      property int index: cell.index
      property bool isCurrent: root.cursor === cell.index
    }
  }
}
