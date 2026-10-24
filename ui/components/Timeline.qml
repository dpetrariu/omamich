import QtQuick
import QtQuick.Controls as QQC
import "../lib/Layout.js" as Layout
import "../lib/Format.js" as Format

// A library-sized photo grid. In bucket mode it shows a timeline scope one
// month at a time: the month index loads first, each month loads when it
// comes near the screen, and a scrubber on the right jumps through the years.
// In list mode a `pager` feeds it pages of results (search, places, folders).
//
// The ListView holds rows, not photos: a month header, then justified rows,
// or one tall placeholder for a month that has not loaded. Only rows near the
// screen exist as items, so a library of any size scrolls the same.
Item {
  id: root

  required property var theme
  required property var service
  property var scope: ({})
  property var pager: null
  property string listTitle: ""
  property bool groupByDay: true
  property string emptyIcon: "photos"
  property string emptyTitle: "No photos here"
  property string emptyText: ""
  property real zoom: 1.0
  property Component headerComponent: null
  // The person's place in a view survives reloads of the same scope.
  property bool showScrubber: !listMode
  // Only ever fed by a pager; without one it shows nothing rather than the
  // whole timeline.
  property bool listOnly: false

  readonly property bool listMode: typeof pager === "function"
  readonly property real targetHeight: Math.round(theme.space(200) * zoom)
  readonly property real gap: theme.space(3)
  readonly property real headerHeight: theme.space(44)
  readonly property real dayHeight: theme.space(30)
  readonly property real contentWidth: Math.max(100, list.width - (showScrubber ? scrubber.width : 0) - theme.space(12))

  property var buckets: []
  property var assetsOf: ({})
  property var layoutOf: ({})
  property var loading: ({})
  property bool indexLoading: false
  property string error: ""
  property int page: 0
  property bool hasMore: false
  property int generation: 0
  property int total: 0

  property var cursor: null              // { bucket, index }
  property var selected: ({})
  property int selectedCount: 0
  readonly property bool selecting: selectedCount > 0

  signal opened(var asset)
  signal contextRequested(var asset, Item item, real x, real y)

  // ------------------------------------------------------------- loading

  onScopeChanged: if (!listMode) Qt.callLater(reload)
  onPagerChanged: Qt.callLater(reload)
  onContentWidthChanged: relayoutTimer.restart()
  onZoomChanged: relayoutTimer.restart()

  Timer {
    id: relayoutTimer
    interval: 120
    onTriggered: root.relayout()
  }

  function reload() {
    generation++
    buckets = []
    assetsOf = ({})
    layoutOf = ({})
    loading = ({})
    error = ""
    page = 0
    hasMore = false
    total = 0
    clearSelection()
    rows.clear()
    if (!service || !service.ready) return
    if (listOnly && !listMode) return
    if (listMode) {
      buckets = [{ key: "_list", count: 0, label: listTitle }]
      loadPage()
      return
    }
    indexLoading = true
    var gen = generation
    service.call("timeline.buckets", { scope: scope }, function(result, err) {
      if (!root || gen !== root.generation) return
      root.indexLoading = false
      if (err) {
        root.error = err.message
        return
      }
      var list = []
      var sum = 0
      for (var i = 0; i < result.length; i++) {
        list.push({ key: result[i].timeBucket, count: result[i].count })
        sum += result[i].count
      }
      root.total = sum
      root.buckets = list
      root.rebuild()
      if (root.cursor === null && list.length > 0) root.cursor = { bucket: list[0].key, index: 0 }
    })
  }

  function loadPage() {
    if (loading._list) return
    var gen = generation
    var next = page + 1
    var l = Object.assign({}, loading)
    l._list = true
    loading = l
    pager(next, function(items, more, err) {
      if (!root || gen !== root.generation) return
      var l2 = Object.assign({}, root.loading)
      delete l2._list
      root.loading = l2
      if (err) {
        root.error = err.message || String(err)
        root.rebuild()
        return
      }
      root.page = next
      root.hasMore = !!more
      var existing = root.assetsOf._list || []
      var combined = existing.concat(items || [])
      var map = Object.assign({}, root.assetsOf)
      map._list = combined
      root.assetsOf = map
      root.total = combined.length
      root.buckets = [{ key: "_list", count: combined.length, label: root.listTitle }]
      root.layoutBucket("_list")
      root.rebuild()
      if (root.cursor === null && combined.length > 0) root.cursor = { bucket: "_list", index: 0 }
    })
  }

  function ensureLoaded(key) {
    if (listMode || assetsOf[key] || loading[key]) return
    var l = Object.assign({}, loading)
    l[key] = true
    loading = l
    var gen = generation
    service.call("timeline.bucket", { scope: scope, timeBucket: key }, function(result, err) {
      if (!root || gen !== root.generation) return
      var l2 = Object.assign({}, root.loading)
      delete l2[key]
      root.loading = l2
      if (err) {
        root.error = err.message
        return
      }
      var map = Object.assign({}, root.assetsOf)
      map[key] = result
      root.assetsOf = map
      root.layoutBucket(key)
      root.replaceBucketRows(key)
      if (root.pendingMove && root.pendingMove.bucket === key) {
        var move = root.pendingMove
        root.pendingMove = null
        root.cursor = { bucket: key, index: move.index < 0 ? result.length - 1 : 0 }
        root.reveal()
      }
    })
  }

  // ------------------------------------------------------------- layout

  // Rows of one bucket, with day headers folded in: [{ day, start, count, height }].
  function layoutBucket(key) {
    var assets = assetsOf[key] || []
    var out = []
    if (groupByDay && !listMode) {
      var start = 0
      while (start < assets.length) {
        var day = Format.dayKey(assets[start].fileCreatedAt)
        var end = start
        while (end < assets.length && Format.dayKey(assets[end].fileCreatedAt) === day) end++
        var slice = assets.slice(start, end)
        out.push({ day: day, label: Format.dateLabel(assets[start].fileCreatedAt), start: start, count: 0, height: dayHeight })
        var r = Layout.rows(slice, contentWidth, targetHeight, gap)
        for (var i = 0; i < r.length; i++) out.push({ day: "", start: start + r[i].start, count: r[i].count, height: r[i].height })
        start = end
      }
    } else {
      var rr = Layout.rows(assets, contentWidth, targetHeight, gap)
      for (var j = 0; j < rr.length; j++) out.push({ day: "", start: rr[j].start, count: rr[j].count, height: rr[j].height })
    }
    var map = Object.assign({}, layoutOf)
    map[key] = out
    layoutOf = map
  }

  function relayout() {
    for (var key in assetsOf) layoutBucket(key)
    rebuild()
  }

  function estimateHeight(bucket) {
    var count = Layout.estimateRows(bucket.count, contentWidth, targetHeight, gap)
    return Math.max(targetHeight, count * (targetHeight + gap))
  }

  function pushBucketRows(bucket) {
    var key = bucket.key
    var label = key === "_list" ? listTitle : Format.bucketLabel(key, new Date().getFullYear())
    if (label !== "" || key !== "_list")
      rows.append({ kind: "header", bucket: key, start: 0, n: bucket.count, h: headerHeight, label: label })
    var layout = layoutOf[key]
    if (layout) {
      for (var i = 0; i < layout.length; i++) {
        var r = layout[i]
        if (r.count === 0)
          rows.append({ kind: "day", bucket: key, start: r.start, n: 0, h: r.height, label: r.label })
        else
          rows.append({ kind: "row", bucket: key, start: r.start, n: r.count, h: r.height + gap, label: "" })
      }
    } else {
      rows.append({ kind: "placeholder", bucket: key, start: 0, n: bucket.count, h: estimateHeight(bucket), label: "" })
    }
  }

  function rebuild() {
    var keep = list.contentY
    var anchorKey = firstVisibleBucket()
    rows.clear()
    for (var i = 0; i < buckets.length; i++) pushBucketRows(buckets[i])
    if (listMode && (hasMore || loading._list))
      rows.append({ kind: "more", bucket: "_list", start: 0, n: 0, h: theme.space(80), label: "" })
    if (anchorKey) Qt.callLater(function() { root.scrollToBucket(anchorKey) })
    else list.contentY = keep
  }

  // Swap a month's placeholder for its rows without disturbing the others.
  function replaceBucketRows(key) {
    for (var i = 0; i < rows.count; i++) {
      var r = rows.get(i)
      if (r.bucket === key && r.kind === "placeholder") {
        rows.remove(i)
        var layout = layoutOf[key] || []
        for (var j = 0; j < layout.length; j++) {
          var l = layout[j]
          if (l.count === 0)
            rows.insert(i + j, { kind: "day", bucket: key, start: l.start, n: 0, h: l.height, label: l.label })
          else
            rows.insert(i + j, { kind: "row", bucket: key, start: l.start, n: l.count, h: l.height + gap, label: "" })
        }
        return
      }
    }
  }

  // ------------------------------------------------------------- cursor & selection

  property var pendingMove: null

  function bucketIndex(key) {
    for (var i = 0; i < buckets.length; i++) if (buckets[i].key === key) return i
    return -1
  }

  function assetAt(c) {
    if (!c) return null
    var list = assetsOf[c.bucket]
    return list && c.index >= 0 && c.index < list.length ? list[c.index] : null
  }

  function currentAsset() { return assetAt(cursor) }

  // The photo after or before `c` in display order, loading the next month
  // when needed. Returns null while it loads.
  function neighbor(c, step) {
    if (!c) return null
    var list = assetsOf[c.bucket] || []
    var index = c.index + step
    if (index >= 0 && index < list.length) return { bucket: c.bucket, index: index }
    var b = bucketIndex(c.bucket) + (step > 0 ? 1 : -1)
    if (b < 0 || b >= buckets.length) {
      if (listMode && step > 0 && hasMore) loadPage()
      return null
    }
    var key = buckets[b].key
    var other = assetsOf[key]
    if (!other) {
      pendingMove = { bucket: key, index: step > 0 ? 0 : -1 }
      ensureLoaded(key)
      return null
    }
    return { bucket: key, index: step > 0 ? 0 : other.length - 1 }
  }

  function rowOf(c) {
    var layout = layoutOf[c.bucket] || []
    for (var i = 0; i < layout.length; i++) {
      var r = layout[i]
      if (r.count > 0 && c.index >= r.start && c.index < r.start + r.count) return i
    }
    return -1
  }

  function centerOf(c, rowIndex) {
    var r = layoutOf[c.bucket][rowIndex]
    var widths = Layout.widths(assetsOf[c.bucket], r, contentWidth, gap)
    var x = 0
    for (var i = 0; i < r.count; i++) {
      if (r.start + i === c.index) return x + widths[i] / 2
      x += widths[i] + gap
    }
    return 0
  }

  function nearestIn(key, rowIndex, center) {
    var r = layoutOf[key][rowIndex]
    var widths = Layout.widths(assetsOf[key], r, contentWidth, gap)
    var x = 0
    var best = r.start
    var bestDistance = Infinity
    for (var i = 0; i < r.count; i++) {
      var d = Math.abs(x + widths[i] / 2 - center)
      if (d < bestDistance) { bestDistance = d; best = r.start + i }
      x += widths[i] + gap
    }
    return { bucket: key, index: best }
  }

  function moveVertical(step) {
    if (!cursor || !assetsOf[cursor.bucket]) return
    var rowIndex = rowOf(cursor)
    if (rowIndex < 0) return
    var center = centerOf(cursor, rowIndex)
    var layout = layoutOf[cursor.bucket]
    var target = rowIndex + step
    while (target >= 0 && target < layout.length && layout[target].count === 0) target += step
    if (target >= 0 && target < layout.length) {
      cursor = nearestIn(cursor.bucket, target, center)
    } else {
      var b = bucketIndex(cursor.bucket) + step
      if (b < 0 || b >= buckets.length) return
      var key = buckets[b].key
      if (!layoutOf[key]) {
        pendingMove = { bucket: key, index: step > 0 ? 0 : -1 }
        ensureLoaded(key)
        return
      }
      var other = layoutOf[key]
      var t = step > 0 ? 0 : other.length - 1
      while (t >= 0 && t < other.length && other[t].count === 0) t += step
      if (t >= 0 && t < other.length) cursor = nearestIn(key, t, center)
    }
    reveal()
  }

  function moveHorizontal(step) {
    var next = neighbor(cursor, step)
    if (next) {
      cursor = next
      reveal()
    }
  }

  function movePage(step) {
    var rowsPerPage = Math.max(1, Math.floor(list.height / (targetHeight + gap)) - 1)
    for (var i = 0; i < rowsPerPage; i++) moveVertical(step)
  }

  function moveToEnd(last) {
    if (buckets.length === 0) return
    var key = buckets[last ? buckets.length - 1 : 0].key
    if (!assetsOf[key]) {
      pendingMove = { bucket: key, index: last ? -1 : 0 }
      ensureLoaded(key)
      scrollToBucket(key)
      return
    }
    cursor = { bucket: key, index: last ? assetsOf[key].length - 1 : 0 }
    reveal()
  }

  // Scroll just enough to show the cursor's row.
  function reveal() {
    if (!cursor) return
    for (var i = 0; i < rows.count; i++) {
      var r = rows.get(i)
      if (r.bucket === cursor.bucket && r.kind === "row" && cursor.index >= r.start && cursor.index < r.start + r.n) {
        list.positionViewAtIndex(i, ListView.Contain)
        return
      }
    }
    scrollToBucket(cursor.bucket)
  }

  function setCursorTo(asset) {
    for (var key in assetsOf) {
      var list = assetsOf[key]
      for (var i = 0; i < list.length; i++) if (list[i].id === asset.id) {
        cursor = { bucket: key, index: i }
        return
      }
    }
  }

  function toggle(asset) {
    var next = Object.assign({}, selected)
    if (next[asset.id]) delete next[asset.id]
    else next[asset.id] = true
    selected = next
    selectedCount = Object.keys(next).length
  }

  property var lastToggled: null
  function selectRange(toCursor) {
    if (!lastToggled) return
    var order = flatOrder()
    var a = indexInOrder(order, lastToggled)
    var b = indexInOrder(order, toCursor)
    if (a < 0 || b < 0) return
    var next = Object.assign({}, selected)
    for (var i = Math.min(a, b); i <= Math.max(a, b); i++) next[order[i].id] = true
    selected = next
    selectedCount = Object.keys(next).length
  }

  function flatOrder() {
    var out = []
    for (var i = 0; i < buckets.length; i++) {
      var list = assetsOf[buckets[i].key] || []
      for (var j = 0; j < list.length; j++) out.push({ id: list[j].id, bucket: buckets[i].key, index: j })
    }
    return out
  }

  function indexInOrder(order, c) {
    for (var i = 0; i < order.length; i++) if (order[i].bucket === c.bucket && order[i].index === c.index) return i
    return -1
  }

  function selectAll() {
    var next = {}
    for (var key in assetsOf) {
      var list = assetsOf[key]
      for (var i = 0; i < list.length; i++) next[list[i].id] = true
    }
    selected = next
    selectedCount = Object.keys(next).length
  }

  function selectBucket(key) {
    var list = assetsOf[key] || []
    var all = list.length > 0 && list.every(function(a) { return root.selected[a.id] })
    var next = Object.assign({}, selected)
    for (var i = 0; i < list.length; i++) {
      if (all) delete next[list[i].id]
      else next[list[i].id] = true
    }
    selected = next
    selectedCount = Object.keys(next).length
  }

  function clearSelection() {
    selected = ({})
    selectedCount = 0
    lastToggled = null
  }

  // The photos an action applies to: the selection, else the cursor's photo.
  function targets() {
    if (selecting) {
      var out = []
      for (var key in assetsOf) {
        var list = assetsOf[key]
        for (var i = 0; i < list.length; i++) if (selected[list[i].id]) out.push(list[i])
      }
      return out
    }
    var a = currentAsset()
    return a ? [a] : []
  }

  // Apply a change the server accepted without reloading the month.
  function patchAssets(ids, change) {
    var set = {}
    for (var i = 0; i < ids.length; i++) set[ids[i]] = true
    var map = Object.assign({}, assetsOf)
    for (var key in map) {
      var changed = false
      var list = map[key].slice()
      for (var j = 0; j < list.length; j++) {
        if (set[list[j].id]) {
          list[j] = Object.assign({}, list[j], change)
          changed = true
        }
      }
      if (changed) map[key] = list
    }
    assetsOf = map
  }

  // Photos that left this view (archived, trashed, removed from the album).
  function dropAssets(ids) {
    var set = {}
    for (var i = 0; i < ids.length; i++) set[ids[i]] = true
    var map = Object.assign({}, assetsOf)
    var nextBuckets = []
    for (var b = 0; b < buckets.length; b++) {
      var key = buckets[b].key
      var list = map[key]
      if (list) {
        list = list.filter(function(a) { return !set[a.id] })
        map[key] = list
        if (list.length === 0 && key !== "_list") continue
        nextBuckets.push({ key: key, count: list.length, label: buckets[b].label })
      } else nextBuckets.push(buckets[b])
    }
    assetsOf = map
    buckets = nextBuckets
    var sel = Object.assign({}, selected)
    for (var id in set) delete sel[id]
    selected = sel
    selectedCount = Object.keys(sel).length
    for (var k in map) layoutBucket(k)
    if (cursor && map[cursor.bucket] && cursor.index >= map[cursor.bucket].length)
      cursor = map[cursor.bucket].length > 0 ? { bucket: cursor.bucket, index: map[cursor.bucket].length - 1 } : null
    total = Math.max(0, total - ids.length)
    rebuild()
  }

  // ------------------------------------------------------------- scrolling

  function firstVisibleBucket() {
    if (rows.count === 0) return ""
    var index = list.indexAt(list.width / 2, list.contentY + 1)
    if (index < 0) return ""
    var r = rows.get(index)
    return r && list.contentY > 1 ? r.bucket : ""
  }

  function scrollToBucket(key) {
    for (var i = 0; i < rows.count; i++) {
      if (rows.get(i).bucket === key) {
        list.positionViewAtIndex(i, ListView.Beginning)
        return
      }
    }
  }

  // ------------------------------------------------------------- view

  ListModel { id: rows }

  ListView {
    id: list
    anchors.fill: parent
    anchors.leftMargin: root.theme.space(12)
    model: rows
    clip: true
    cacheBuffer: Math.max(800, height * 1.5)
    boundsBehavior: Flickable.StopAtBounds
    reuseItems: false
    header: root.headerComponent
    flickDeceleration: 4000
    maximumFlickVelocity: 6000
    QQC.ScrollBar.vertical: QQC.ScrollBar { policy: root.showScrubber ? QQC.ScrollBar.AlwaysOff : QQC.ScrollBar.AsNeeded }

    delegate: Item {
      id: rowItem
      required property string kind
      required property string bucket
      required property int start
      required property int n
      required property real h
      required property string label
      width: root.contentWidth
      height: h

      Loader {
        anchors.fill: parent
        sourceComponent: rowItem.kind === "header" ? headerRow
          : rowItem.kind === "day" ? dayRow
          : rowItem.kind === "row" ? photoRow
          : rowItem.kind === "more" ? moreRow
          : placeholderRow
      }

      Component {
        id: headerRow
        Item {
          readonly property bool loaded: !!root.assetsOf[rowItem.bucket]
          readonly property bool allSelected: loaded && root.selecting
            && root.assetsOf[rowItem.bucket].every(function(a) { return root.selected[a.id] })
          Text {
            id: monthLabel
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            anchors.bottomMargin: root.theme.space(10)
            text: rowItem.label
            textFormat: Text.PlainText
            color: root.theme.foreground
            font.family: root.theme.font
            font.pixelSize: root.theme.heading
            font.bold: true
          }
          Text {
            anchors.left: monthLabel.right
            anchors.leftMargin: root.theme.space(10)
            anchors.baseline: monthLabel.baseline
            text: Format.count(rowItem.n, "item")
            textFormat: Text.PlainText
            color: root.theme.dim
            font.family: root.theme.font
            font.pixelSize: root.theme.small
          }
          TextButton {
            visible: parent.loaded && (headerHover.containsMouse || root.selecting)
            anchors.right: parent.right
            anchors.verticalCenter: monthLabel.verticalCenter
            theme: root.theme
            text: parent.allSelected ? "Deselect month" : "Select month"
            icon: "select"
            fontSize: root.theme.small
            onClicked: root.selectBucket(rowItem.bucket)
          }
          MouseArea {
            id: headerHover
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.NoButton
          }
        }
      }

      Component {
        id: dayRow
        Item {
          Text {
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            anchors.bottomMargin: root.theme.space(7)
            text: rowItem.label
            textFormat: Text.PlainText
            color: root.theme.dim
            font.family: root.theme.font
            font.pixelSize: root.theme.small
          }
        }
      }

      Component {
        id: photoRow
        Item {
          id: photoRowRoot
          readonly property var assets: root.assetsOf[rowItem.bucket] || []
          readonly property var widths: Layout.widths(assets, { start: rowItem.start, count: rowItem.n, height: rowItem.h - root.gap }, root.contentWidth, root.gap)
          Row {
            spacing: root.gap
            Repeater {
              model: rowItem.n
              delegate: PhotoTile {
                required property int index
                readonly property int assetIndex: rowItem.start + index
                theme: root.theme
                service: root.service
                asset: photoRowRoot.assets[assetIndex] || null
                width: photoRowRoot.widths[index] || 0
                height: rowItem.h - root.gap
                selected: !!asset && !!root.selected[asset.id]
                selecting: root.selecting
                cursor: !!root.cursor && root.cursor.bucket === rowItem.bucket && root.cursor.index === assetIndex
                onClicked: function(mouse) {
                  root.cursor = { bucket: rowItem.bucket, index: assetIndex }
                  if ((mouse.modifiers & Qt.ShiftModifier) && root.lastToggled) {
                    root.selectRange(root.cursor)
                  } else if (root.selecting || (mouse.modifiers & Qt.ControlModifier)) {
                    root.toggle(asset)
                    root.lastToggled = root.cursor
                  } else root.opened(asset)
                }
                onToggleSelect: function(mouse) {
                  root.cursor = { bucket: rowItem.bucket, index: assetIndex }
                  if ((mouse.modifiers & Qt.ShiftModifier) && root.lastToggled) root.selectRange(root.cursor)
                  else {
                    root.toggle(asset)
                    root.lastToggled = root.cursor
                  }
                }
                onRightClicked: function(x, y) {
                  root.cursor = { bucket: rowItem.bucket, index: assetIndex }
                  root.contextRequested(asset, this, x, y)
                }
              }
            }
          }
        }
      }

      Component {
        id: placeholderRow
        Item {
          Component.onCompleted: root.ensureLoaded(rowItem.bucket)
          Grid {
            anchors.fill: parent
            columns: Math.max(1, Math.floor((root.contentWidth + root.gap) / (root.targetHeight * 1.35 + root.gap)))
            spacing: root.gap
            clip: true
            Repeater {
              model: Math.min(rowItem.n, 60)
              Rectangle {
                width: (root.contentWidth - root.gap * (parent.columns - 1)) / parent.columns
                height: root.targetHeight
                color: root.theme.sunken
              }
            }
          }
        }
      }

      Component {
        id: moreRow
        Item {
          Component.onCompleted: if (root.hasMore) root.loadPage()
          Text {
            anchors.centerIn: parent
            text: root.loading._list === true ? "Loading more…" : ""
            color: root.theme.dim
            font.family: root.theme.font
            font.pixelSize: root.theme.small
          }
        }
      }
    }
  }

  // ------------------------------------------------------------- scrubber

  Item {
    id: scrubber
    visible: root.showScrubber && root.buckets.length > 1
    anchors { right: parent.right; top: parent.top; bottom: parent.bottom }
    width: visible ? root.theme.space(56) : 0

    // Each year's share of the scrubber follows its share of photos.
    readonly property var years: {
      var out = []
      var total = 0
      for (var i = 0; i < root.buckets.length; i++) total += Math.max(1, root.buckets[i].count)
      var acc = 0
      var lastYear = -1
      for (var j = 0; j < root.buckets.length; j++) {
        var y = Format.bucketYear(root.buckets[j].key)
        if (y !== lastYear) {
          out.push({ year: y, at: total > 0 ? acc / total : 0, bucket: root.buckets[j].key })
          lastYear = y
        }
        acc += Math.max(1, root.buckets[j].count)
      }
      return out
    }

    function bucketAt(fraction) {
      var total = 0
      for (var i = 0; i < root.buckets.length; i++) total += Math.max(1, root.buckets[i].count)
      var target = fraction * total
      var acc = 0
      for (var j = 0; j < root.buckets.length; j++) {
        acc += Math.max(1, root.buckets[j].count)
        if (acc >= target) return root.buckets[j].key
      }
      return root.buckets.length ? root.buckets[root.buckets.length - 1].key : ""
    }

    function fractionOf(key) {
      var total = 0
      var before = 0
      var found = false
      for (var i = 0; i < root.buckets.length; i++) {
        if (root.buckets[i].key === key) found = true
        if (!found) before += Math.max(1, root.buckets[i].count)
        total += Math.max(1, root.buckets[i].count)
      }
      return total > 0 ? before / total : 0
    }

    property string hoverBucket: ""
    readonly property string currentBucket: {
      void list.contentY
      return root.firstVisibleBucket() || (root.buckets.length ? root.buckets[0].key : "")
    }

    // Leave room at the bottom so the last label is not clipped.
    readonly property real track: height - root.theme.space(24)

    Repeater {
      model: scrubber.years
      delegate: Text {
        required property var modelData
        required property int index
        readonly property real yPos: modelData.at * scrubber.track + root.theme.space(8)
        // Years too close to the one above make way rather than overlap.
        visible: index === 0 || (modelData.at - scrubber.years[index - 1].at) * scrubber.track > root.theme.space(16)
        x: scrubber.width - width - root.theme.space(8)
        y: yPos
        text: String(modelData.year)
        textFormat: Text.PlainText
        color: root.theme.dim
        font.family: root.theme.font
        font.pixelSize: root.theme.caption
      }
    }

    Rectangle {
      x: scrubber.width - root.theme.space(4)
      width: root.theme.space(3)
      height: root.theme.space(18)
      radius: width / 2
      y: scrubber.fractionOf(scrubber.currentBucket) * scrubber.track + root.theme.space(8)
      color: root.theme.accent
    }

    Rectangle {
      visible: scrubArea.containsMouse || scrubArea.pressed
      x: -width + root.theme.space(8)
      y: Math.max(0, Math.min(scrubber.height - height, scrubArea.mouseY - height / 2))
      width: bubble.implicitWidth + root.theme.space(16)
      height: bubble.implicitHeight + root.theme.space(8)
      radius: root.theme.radius
      color: root.theme.popupBackground
      border.width: root.theme.borderWidth
      border.color: root.theme.popupBorder
      Text {
        id: bubble
        anchors.centerIn: parent
        text: Format.bucketLabel(scrubber.hoverBucket, 0)
        textFormat: Text.PlainText
        color: root.theme.foreground
        font.family: root.theme.font
        font.pixelSize: root.theme.small
      }
    }

    MouseArea {
      id: scrubArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.SizeVerCursor
      function at(y) { return Math.max(0, Math.min(1, (y - root.theme.space(8)) / scrubber.track)) }
      onPositionChanged: function(mouse) {
        scrubber.hoverBucket = scrubber.bucketAt(at(mouse.y))
        if (pressed) root.scrollToBucket(scrubber.hoverBucket)
      }
      onPressed: function(mouse) {
        scrubber.hoverBucket = scrubber.bucketAt(at(mouse.y))
        root.scrollToBucket(scrubber.hoverBucket)
      }
    }
  }

  // ------------------------------------------------------------- empty & error

  Column {
    anchors.centerIn: parent
    width: Math.min(parent.width - root.theme.space(48), root.theme.space(420))
    spacing: root.theme.space(10)
    visible: !root.indexLoading && root.loading._list !== true && root.total === 0
      && (root.listMode ? root.page > 0 || root.error !== "" : !root.listOnly) && !!root.service && root.service.ready === true
    Glyph {
      anchors.horizontalCenter: parent.horizontalCenter
      name: root.error ? "error" : root.emptyIcon
      size: root.theme.display * 1.6
      color: root.error ? root.theme.urgent : root.theme.faint
      font.family: root.theme.font
    }
    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      text: root.error ? "Could not load photos" : root.emptyTitle
      textFormat: Text.PlainText
      color: root.theme.foreground
      font.family: root.theme.font
      font.pixelSize: root.theme.title
    }
    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.Wrap
      text: root.error || root.emptyText
      textFormat: Text.PlainText
      color: root.theme.dim
      font.family: root.theme.font
      font.pixelSize: root.theme.small
    }
    TextButton {
      visible: root.error !== ""
      anchors.horizontalCenter: parent.horizontalCenter
      theme: root.theme
      text: "Try again"
      icon: "refresh"
      onClicked: root.reload()
    }
  }

  Text {
    anchors.centerIn: parent
    visible: root.indexLoading || (root.listMode && root.loading._list === true && root.total === 0)
    text: "Loading…"
    textFormat: Text.PlainText
    color: root.theme.dim
    font.family: root.theme.font
    font.pixelSize: root.theme.body
  }

  Component.onCompleted: Qt.callLater(reload)
  Connections {
    target: root.service
    function onReadyChanged() { if (root.service.ready) root.reload() }
  }
}
