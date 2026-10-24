.pragma library

// Words and numbers as the window shows them.

var MONTHS = ["January", "February", "March", "April", "May", "June", "July",
  "August", "September", "October", "November", "December"]
var SHORT_MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
var DAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

// A cache-busting token for a media URL: only letters and digits survive.
function versionOf(value) {
  return String(value === undefined || value === null ? "" : value).replace(/[^A-Za-z0-9]/g, "").slice(0, 24)
}

// "2026-10-01" (Immich's bucket key) → { year, month } without time zones.
function bucketParts(bucket) {
  var m = /^(\d{4})-(\d{2})/.exec(String(bucket || ""))
  if (!m) return null
  return { year: Number(m[1]), month: Number(m[2]) - 1 }
}

function bucketLabel(bucket, currentYear) {
  var p = bucketParts(bucket)
  if (!p) return String(bucket || "")
  return p.year === currentYear ? MONTHS[p.month] : MONTHS[p.month] + " " + p.year
}

function bucketYear(bucket) {
  var p = bucketParts(bucket)
  return p ? p.year : 0
}

// Immich's local timestamps carry no zone; read their digits as written.
function localParts(text) {
  var m = /^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}))?)?/.exec(String(text || ""))
  if (!m) return null
  return { year: Number(m[1]), month: Number(m[2]) - 1, day: Number(m[3]),
    hour: Number(m[4] || 0), minute: Number(m[5] || 0), second: Number(m[6] || 0) }
}

function pad(n) { return n < 10 ? "0" + n : String(n) }

function dateLabel(text) {
  var p = localParts(text)
  if (!p) return ""
  var weekday = DAYS[new Date(p.year, p.month, p.day).getDay()]
  return weekday + ", " + p.day + " " + MONTHS[p.month] + " " + p.year
}

function shortDate(text) {
  var p = localParts(text)
  if (!p) return ""
  return p.day + " " + SHORT_MONTHS[p.month] + " " + p.year
}

function timeLabel(text) {
  var p = localParts(text)
  if (!p) return ""
  return pad(p.hour) + ":" + pad(p.minute)
}

function dayKey(text) {
  var p = localParts(text)
  return p ? p.year + "-" + pad(p.month + 1) + "-" + pad(p.day) : ""
}

function dateRange(start, end) {
  var a = localParts(start)
  var b = localParts(end)
  if (!a) return ""
  if (!b || (a.year === b.year && a.month === b.month && a.day === b.day)) return shortDate(start)
  if (a.year === b.year && a.month === b.month) return a.day + "–" + b.day + " " + SHORT_MONTHS[a.month] + " " + a.year
  if (a.year === b.year) return a.day + " " + SHORT_MONTHS[a.month] + " – " + b.day + " " + SHORT_MONTHS[b.month] + " " + a.year
  return shortDate(start) + " – " + shortDate(end)
}

function bytes(n) {
  n = Number(n || 0)
  if (n < 1024) return n + " B"
  var units = ["KB", "MB", "GB", "TB"]
  var value = n
  var i = -1
  do { value /= 1024; i++ } while (value >= 1024 && i < units.length - 1)
  return (value >= 100 ? value.toFixed(0) : value.toFixed(1)) + " " + units[i]
}

function count(n, one, many) {
  n = Number(n || 0)
  return thousands(n) + " " + (n === 1 ? one : (many || one + "s"))
}

function thousands(n) {
  var s = String(Math.round(Number(n || 0)))
  return s.replace(/\B(?=(\d{3})+(?!\d))/g, ",")
}

// "just now", "5 min ago", "3 h ago", or a date.
function ago(seconds, nowMs) {
  if (!seconds) return ""
  var diff = Math.max(0, Math.round(((nowMs || Date.now()) / 1000) - Number(seconds)))
  if (diff < 45) return "just now"
  if (diff < 3600) return Math.round(diff / 60) + " min ago"
  if (diff < 86400) return Math.round(diff / 3600) + " h ago"
  var d = new Date(Number(seconds) * 1000)
  return d.getDate() + " " + SHORT_MONTHS[d.getMonth()]
}

function exposure(value) {
  if (value === null || value === undefined || value === "") return ""
  var text = String(value)
  if (text.indexOf("/") >= 0) return text + " s"
  var n = Number(text)
  if (!isFinite(n) || n <= 0) return ""
  if (n < 1) return "1/" + Math.round(1 / n) + " s"
  return n + " s"
}

function camera(exif) {
  if (!exif) return ""
  var make = String(exif.make || "").trim()
  var model = String(exif.model || "").trim()
  if (make && model.toLowerCase().indexOf(make.toLowerCase()) === 0) return model
  return [make, model].filter(function(s) { return s }).join(" ")
}

function settingsLine(exif) {
  if (!exif) return ""
  var parts = []
  if (exif.fNumber) parts.push("ƒ/" + Number(exif.fNumber).toFixed(1).replace(/\.0$/, ""))
  var exp = exposure(exif.exposureTime)
  if (exp) parts.push(exp)
  if (exif.focalLength) parts.push(Math.round(Number(exif.focalLength)) + " mm")
  if (exif.iso) parts.push("ISO " + exif.iso)
  return parts.join("  ·  ")
}

function place(row) {
  if (!row) return ""
  return [row.city, row.state, row.country].filter(function(s) { return !!s }).join(", ")
}

function megapixels(w, h) {
  if (!w || !h) return ""
  return (Number(w) * Number(h) / 1e6).toFixed(1) + " MP"
}

// One line for the status bar and the bar tooltip.
function syncSummary(status) {
  if (!status) return "Sync is starting"
  var queue = Number(status.queue || 0)
  var active = status.active ? status.active.length : 0
  switch (String(status.phase)) {
  case "disabled": return "Folder sync is off"
  case "paused": return "Sync paused"
  case "waiting": return "Sync waiting: " + String(status.pauseReason || "")
  case "uploading": return "Uploading " + (queue + active) + " " + (queue + active === 1 ? "file" : "files")
  case "downloading": return "Downloading from albums"
  case "scanning": return status.scanNote ? String(status.scanNote) : "Looking for new photos"
  case "offline": return "Immich unreachable, will retry"
  case "queued": return queue + " waiting to upload"
  default:
    if (Number(status.failed || 0) > 0) return count(status.failed, "file") + " could not upload"
    return status.lastSyncAt ? "Synced " + ago(status.lastSyncAt) : "Folders up to date"
  }
}
