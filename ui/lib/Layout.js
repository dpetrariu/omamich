.pragma library

// The justified photo grid: every row is filled edge to edge, photos keep
// their shape, and only row heights vary. Pure functions so the arithmetic
// can be tested without a window.

// Split `items` (each with a `ratio`) into rows for a given width.
// Returns [{ start, count, height }] where each row's widths sum to `width`
// minus gaps. The last row is not stretched past the target height.
function rows(items, width, targetHeight, gap) {
  var out = []
  if (!items || items.length === 0 || width <= 0) return out
  var start = 0
  var sum = 0
  for (var i = 0; i < items.length; i++) {
    var ratio = clampRatio(items[i].ratio)
    sum += ratio
    var count = i - start + 1
    var available = width - gap * (count - 1)
    var height = available / sum
    if (height <= targetHeight) {
      // Taking this photo makes the row too short; decide which is closer.
      var withoutHeight = count > 1 ? (width - gap * (count - 2)) / (sum - ratio) : Infinity
      if (count > 1 && Math.abs(withoutHeight - targetHeight) < Math.abs(height - targetHeight) * 0.9) {
        out.push({ start: start, count: count - 1, height: withoutHeight })
        start = i
        sum = ratio
      } else {
        out.push({ start: start, count: count, height: height })
        start = i + 1
        sum = 0
      }
    }
  }
  if (start < items.length) out.push({ start: start, count: items.length - start, height: targetHeight })
  return out
}

// Thin panoramas and tall screenshots would wreck a row.
function clampRatio(ratio) {
  var r = Number(ratio)
  if (!isFinite(r) || r <= 0) return 1
  return Math.max(0.4, Math.min(3.2, r))
}

// The widths of one row's photos, rounded so they sum exactly to `width`.
function widths(items, row, width, gap) {
  var out = []
  if (!items || !row || row.start + row.count > items.length) {
    for (var k = 0; row && k < row.count; k++) out.push(0)
    return out
  }
  var full = row.count > 0 ? width - gap * (row.count - 1) : width
  var sum = 0
  for (var i = 0; i < row.count; i++) sum += clampRatio(items[row.start + i].ratio)
  var stretched = row.height * sum >= full - 1
  var used = 0
  for (var j = 0; j < row.count; j++) {
    var w = Math.floor(row.height * clampRatio(items[row.start + j].ratio))
    if (stretched && j === row.count - 1) w = full - used
    out.push(Math.max(1, w))
    used += w
  }
  return out
}

// About how many rows `count` photos take at this width, before they load.
function estimateRows(count, width, targetHeight, gap) {
  if (count <= 0 || width <= 0) return 0
  var perRow = Math.max(1, Math.floor((width + gap) / (targetHeight * 1.35 + gap)))
  return Math.ceil(count / perRow)
}

// Square tiles for people and albums: how many fit across.
function columns(width, minTile, gap) {
  return Math.max(1, Math.floor((width + gap) / (minTile + gap)))
}
