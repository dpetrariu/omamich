.pragma library

// Every key the window answers to, in one table. The shortcut sheet and the
// status-bar hints are drawn from this table, so they cannot drift from what
// the keys actually do.
//
// The window is in exactly one context at a time; App.qml derives it from
// what is on screen. A text-entry context binds no bare letters, so typing
// never fires an action.

var CONTEXTS = ["grid", "tiles", "viewer", "search", "page", "dialog"]
var BROWSE = ["grid", "tiles"]
var PHOTO = ["grid", "viewer"]
var ANY = ["*"]

var BINDINGS = [
  // Moving
  { id: "left", keys: ["h", "Left"], contexts: BROWSE, group: "Moving", label: "Move left" },
  { id: "right", keys: ["l", "Right"], contexts: BROWSE, group: "Moving", label: "Move right" },
  { id: "up", keys: ["k", "Up"], contexts: BROWSE, group: "Moving", label: "Move up",
    hintKey: "h j k l", hint: { grid: "move", tiles: "move" } },
  { id: "down", keys: ["j", "Down"], contexts: BROWSE, group: "Moving", label: "Move down" },
  { id: "pageDown", keys: ["PgDown", "Ctrl+D"], contexts: BROWSE, group: "Moving", label: "Page down" },
  { id: "pageUp", keys: ["PgUp", "Ctrl+U"], contexts: BROWSE, group: "Moving", label: "Page up" },
  { id: "first", keys: ["Home", "g"], contexts: BROWSE, group: "Moving", label: "First" },
  { id: "last", keys: ["End", "Shift+G"], contexts: BROWSE, group: "Moving", label: "Last" },
  { id: "open", keys: ["Return", "Enter", "o"], contexts: BROWSE, group: "Moving", label: "Open",
    hintKey: "enter", hint: { grid: "view", tiles: "open" } },
  { id: "previous", keys: ["h", "Left"], contexts: ["viewer"], group: "Viewing", label: "Previous photo",
    hintKey: "h / l", hint: { viewer: "prev / next" } },
  { id: "next", keys: ["l", "Right"], contexts: ["viewer"], group: "Viewing", label: "Next photo" },
  { id: "back", keys: ["Escape"], contexts: ANY, group: "Moving", label: "Back, close or clear the selection",
    hintKey: "esc", hint: { viewer: "close", page: "back", search: "cancel", dialog: "cancel" } },
  { id: "backAlt", keys: ["Backspace", "q"], contexts: ["viewer"], group: "Viewing", label: "Close the photo" },

  // Viewing
  { id: "info", keys: ["i"], contexts: PHOTO, group: "Viewing", label: "Show or hide details",
    hintKey: "i", hint: { viewer: "details", grid: "details" } },
  { id: "playPause", keys: ["Space"], contexts: ["viewer"], group: "Viewing", label: "Play or pause a video",
    hintKey: "space", hint: { viewer: "play" } },
  { id: "zoomIn", keys: ["z", "+", "="], contexts: ["viewer"], group: "Viewing", label: "Zoom in" },
  { id: "zoomOut", keys: ["Shift+Z", "-"], contexts: ["viewer"], group: "Viewing", label: "Zoom out" },
  { id: "zoomReset", keys: ["0"], contexts: ["viewer"], group: "Viewing", label: "Fit to the window" },
  { id: "slideshow", keys: ["Shift+S"], contexts: ["viewer"], group: "Viewing", label: "Start or stop a slideshow" },
  { id: "fullscreen", keys: ["F11"], contexts: ANY, group: "Viewing", label: "Focus mode: hide the bars and sidebar" },

  // Selecting
  { id: "select", keys: ["Space"], contexts: ["grid"], group: "Selecting", label: "Select or deselect",
    hintKey: "space", hint: { grid: "select" } },
  { id: "selectAll", keys: ["Ctrl+A"], contexts: ["grid"], group: "Selecting", label: "Select everything loaded" },

  // Acting on the photo under the cursor, or on the selection
  { id: "favorite", changes: true, keys: ["f"], contexts: PHOTO, group: "Photos", label: "Favourite or unfavourite",
    hintKey: "f", hint: { grid: "favourite", viewer: "favourite" } },
  { id: "archive", changes: true, keys: ["a"], contexts: PHOTO, group: "Photos", label: "Archive or unarchive" },
  { id: "trash", changes: true, keys: ["Delete", "d"], contexts: PHOTO, group: "Photos", label: "Move to the trash, or restore from it",
    hintKey: "d", hint: { grid: "trash", viewer: "trash" } },
  { id: "deleteForever", changes: true, keys: ["Shift+Delete"], contexts: PHOTO, group: "Photos", label: "Delete permanently..." },
  { id: "addToAlbum", changes: true, keys: ["Shift+A"], contexts: PHOTO, group: "Photos", label: "Add to an album..." },
  { id: "tag", changes: true, keys: ["t"], contexts: PHOTO, group: "Photos", label: "Tag..." },
  { id: "share", changes: true, keys: ["s"], contexts: PHOTO, group: "Photos", label: "Share a link..." },
  { id: "download", changes: true, keys: ["Shift+D"], contexts: PHOTO, group: "Photos", label: "Download the original" },
  { id: "rate", changes: true, keys: ["1", "2", "3", "4", "5"], contexts: ["viewer"], group: "Photos", label: "Rate 1 to 5 stars" },

  // Going places
  { id: "search", keys: ["/"], contexts: ["grid", "tiles", "viewer"], group: "Going places", label: "Search",
    hintKey: "/", hint: { grid: "search", tiles: "search" } },
  { id: "section", keys: ["Alt+1", "Alt+2", "Alt+3", "Alt+4", "Alt+5", "Alt+6", "Alt+7", "Alt+8", "Alt+9", "Alt+0"],
    contexts: ["grid", "tiles", "viewer", "page"], group: "Going places", label: "Go to a sidebar section" },
  { id: "sync", keys: ["Ctrl+Y"], contexts: ANY, group: "Going places", label: "Folder sync" },
  { id: "settings", keys: ["Ctrl+,"], contexts: ANY, group: "Going places", label: "Settings" },
  { id: "sidebar", keys: ["Ctrl+B"], contexts: ["grid", "tiles", "page"], group: "Going places", label: "Show or hide the sidebar" },
  { id: "refresh", keys: ["r", "F5"], contexts: BROWSE, group: "Going places", label: "Reload" },
  { id: "help", keys: ["?", "Shift+?"], contexts: ["grid", "tiles", "viewer"], group: "Going places", label: "All shortcuts",
    hintKey: "?", hint: { grid: "keys", tiles: "keys" } }
]

function contextFor(state) {
  if (state.dialog) return "dialog"
  if (state.page) return "page"
  if (state.searchFocused) return "search"
  if (state.viewer) return "viewer"
  if (state.tiles) return "tiles"
  return "grid"
}

function matches(binding, context) {
  return binding.contexts.indexOf("*") >= 0 || binding.contexts.indexOf(context) >= 0
}

// Text-entry contexts take only modified keys, Escape and function keys.
function typingSafe(sequence) {
  return /^(Ctrl|Alt|Meta)\+/.test(sequence) || sequence === "Escape" || /^F\d+$/.test(sequence)
}

function textContext(context) {
  return context === "search" || context === "page" || context === "dialog"
}

// [{ id, sequence }] live in this context.
function sequencesFor(context) {
  var out = []
  var seen = {}
  for (var i = 0; i < BINDINGS.length; i++) {
    var b = BINDINGS[i]
    if (!matches(b, context)) continue
    for (var k = 0; k < b.keys.length; k++) {
      var seq = b.keys[k]
      if (textContext(context) && !typingSafe(seq)) continue
      if (seen[seq]) continue
      seen[seq] = true
      // Holding a key that changes the library must not repeat it down the grid.
      out.push({ id: b.id, sequence: seq, repeat: b.changes !== true })
    }
  }
  return out
}

function hintsFor(context) {
  var out = []
  for (var i = 0; i < BINDINGS.length; i++) {
    var b = BINDINGS[i]
    if (!b.hint || !b.hint[context] || !matches(b, context)) continue
    out.push({ key: b.hintKey || b.keys[0], label: b.hint[context] })
  }
  return out
}

function readable(sequence) {
  return String(sequence)
    .replace("Return", "enter").replace("Escape", "esc").replace("Delete", "del")
    .replace("PgDown", "pgdn").replace("PgUp", "pgup").replace("Shift+?", "?")
}

function unique(list) {
  var out = []
  for (var i = 0; i < list.length; i++) {
    var key = String(list[i]).toLowerCase()
    var seen = false
    for (var j = 0; j < out.length; j++) if (String(out[j]).toLowerCase() === key) seen = true
    if (!seen) out.push(list[i])
  }
  return out
}

function helpGroups() {
  var groups = []
  var index = {}
  for (var i = 0; i < BINDINGS.length; i++) {
    var b = BINDINGS[i]
    if (index[b.group] === undefined) {
      index[b.group] = groups.length
      groups.push({ title: b.group, rows: [] })
    }
    var keys = b.id === "section" ? ["Alt+1 … Alt+0"] : unique(b.keys.map(readable))
    if (b.id === "rate") keys = ["1 … 5"]
    groups[index[b.group]].rows.push({ keys: keys.join("  "), label: b.label })
  }
  return groups
}

// Two bindings in one context on one key would make a key mean two things.
function conflicts() {
  var found = []
  for (var c = 0; c < CONTEXTS.length; c++) {
    var context = CONTEXTS[c]
    var owner = {}
    for (var i = 0; i < BINDINGS.length; i++) {
      var b = BINDINGS[i]
      if (!matches(b, context)) continue
      for (var k = 0; k < b.keys.length; k++) {
        var seq = b.keys[k]
        if (owner[seq] && owner[seq] !== b.id) found.push(context + ": " + seq + " is " + owner[seq] + " and " + b.id)
        owner[seq] = b.id
      }
    }
  }
  return found
}
