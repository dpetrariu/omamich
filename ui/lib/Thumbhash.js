.pragma library

// The average colour of a photo from its ThumbHash, shown while the
// thumbnail is on its way. Only the header is decoded: it carries the DC
// terms of the L, P and Q channels, which together are the mean colour.
// Reference: https://evanw.github.io/thumbhash/

var B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function bytesOf(text) {
  var out = []
  var buffer = 0
  var bits = 0
  for (var i = 0; i < text.length; i++) {
    var c = text.charAt(i)
    if (c === "=") break
    var v = B64.indexOf(c)
    if (v < 0) return null
    buffer = (buffer << 6) | v
    bits += 6
    if (bits >= 8) {
      bits -= 8
      out.push((buffer >> bits) & 255)
    }
  }
  return out
}

// Returns "#rrggbb", or "" when the hash is missing or malformed.
function averageColor(hash) {
  if (!hash || typeof hash !== "string") return ""
  var b = bytesOf(hash)
  if (!b || b.length < 5) return ""
  var header = b[0] | (b[1] << 8) | (b[2] << 16)
  var lDc = (header & 63) / 63
  var pDc = ((header >> 6) & 63) / 31.5 - 1
  var qDc = ((header >> 12) & 63) / 31.5 - 1
  var hasAlpha = (header >> 23) !== 0
  var a = hasAlpha ? (b[5] & 15) / 15 : 1
  var bl = lDc - 2 / 3 * pDc
  var r = (3 * lDc - bl + qDc) / 2
  var g = r - qDc
  function c(x) { return Math.max(0, Math.min(255, Math.round(255 * Math.min(1, Math.max(0, x))))) }
  function h(x) { var s = c(x).toString(16); return s.length < 2 ? "0" + s : s }
  void a
  return "#" + h(r) + h(g) + h(bl)
}
