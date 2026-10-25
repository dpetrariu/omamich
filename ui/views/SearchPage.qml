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
  signal pick(var options)
  signal prompt(var options)
  signal promptFinished(string message)

  readonly property var labels: filters.labels || ({})
  readonly property bool filtersOnly: !!entry && entry.query === ""
  property string sortMode: ""

  function setFilters(patch, labelPatch) {
    var next = Object.assign({}, filters)
    for (var k in patch) {
      if (patch[k] === null || patch[k] === undefined || patch[k] === "" || patch[k] === false) delete next[k]
      else next[k] = patch[k]
    }
    var l = Object.assign({}, labels)
    for (var j in (labelPatch || {})) {
      if (labelPatch[j]) l[j] = labelPatch[j]
      else delete l[j]
    }
    next.labels = l
    root.modeChanged(entry.mode, next)
  }

  function choosePerson() {
    root.service.loadPeople()
    var taken = root.filters.personIds || []
    root.pick({
      title: "Photos with…",
      subtitle: taken.length ? "Each person you add must be in the photo." : "",
      placeholder: "Find a person",
      items: root.service.people.filter(function(p) { return p.name && taken.indexOf(p.id) < 0 }).map(function(p) {
        return { id: p.id, label: p.name, image: root.service.personUrl(p.id, p.version) }
      }),
      emptyText: root.service.peopleLoading ? "Loading people…" : "No named people. Name them in People first.",
      onPick: function(item) {
        var names = (root.labels.people || []).concat([item.label])
        root.setFilters({ personIds: taken.concat([item.id]) }, { people: names })
        return true
      }
    })
  }

  function choosePlace() {
    root.service.loadPlaces()
    var countries = {}
    var items = []
    for (var i = 0; i < root.service.places.length; i++) {
      var p = root.service.places[i]
      if (p.city) items.push({ id: "c" + i, label: p.city + (p.country ? ", " + p.country : ""), detail: Format.count(p.count, "photo"), city: p.city, country: p.country })
      if (p.country && !countries[p.country]) {
        countries[p.country] = true
        items.push({ id: "k" + i, label: p.country, detail: "the whole country", country: p.country })
      }
    }
    root.pick({
      title: "Photos taken in…",
      placeholder: "Find a city or country",
      items: items,
      emptyText: root.service.placesLoading ? "Loading places…" : "No photos have a place yet.",
      onPick: function(item) {
        root.setFilters({ city: item.city || null, country: item.country || null }, { place: item.label })
        return true
      }
    })
  }

  function chooseCamera() {
    root.service.call("search.suggestions", { type: "camera-make" }, function(makes, e) {
      if (!root || e) return
      root.pick({
        title: "Photos taken with…",
        placeholder: "Find a camera maker",
        items: makes.map(function(m) { return { id: m, label: m } }),
        emptyText: "No camera information in the library.",
        onPick: function(item) {
          root.service.call("search.suggestions", { type: "camera-model", make: item.label }, function(models, e2) {
            if (!root) return
            var list = [{ id: "_any", label: "Any " + item.label + " camera" }].concat((e2 ? [] : models).map(function(m) { return { id: m, label: m } }))
            root.pick({
              title: item.label,
              placeholder: "Find a model",
              items: list,
              onPick: function(model) {
                var any = model.id === "_any"
                root.setFilters({ make: item.label, model: any ? null : model.label }, { camera: any ? item.label : item.label + " " + model.label })
                return true
              }
            })
          })
          return true
        }
      })
    })
  }

  // "2019", "2019-06", "2019-06-01 to 2019-08-31".
  function parseRange(text) {
    var t = String(text || "").trim()
    var parts = t.split(/\s+(?:to|-|–|until)\s+/)
    function start(x) {
      var m = /^(\d{4})(?:-(\d{1,2}))?(?:-(\d{1,2}))?$/.exec(x)
      if (!m) return null
      return { y: Number(m[1]), m: m[2] ? Number(m[2]) : 0, d: m[3] ? Number(m[3]) : 0 }
    }
    var a = start(parts[0])
    var b = parts.length > 1 ? start(parts[1]) : a
    if (!a || !b) return null
    var pad = function(n) { return n < 10 ? "0" + n : String(n) }
    var from = a.y + "-" + pad(a.m || 1) + "-" + pad(a.d || 1) + "T00:00:00.000Z"
    var lastMonth = b.m || 12
    var lastDay = b.d || new Date(b.y, lastMonth, 0).getDate()
    var to = b.y + "-" + pad(lastMonth) + "-" + pad(lastDay) + "T23:59:59.999Z"
    if (from > to) return null
    return { takenAfter: from, takenBefore: to }
  }

  function chooseDates() {
    root.prompt({
      title: "Photos taken…",
      subtitle: "A year, a month or a range: 2019, 2019-06, or 2019-06-01 to 2019-08-31.",
      placeholder: "2019-06 to 2019-08",
      value: root.labels.dates || "",
      confirmText: "Filter",
      onAccept: function(text) {
        var range = root.parseRange(text)
        if (!range) return "Try 2019, 2019-06, or 2019-06-01 to 2019-08-31"
        root.setFilters(range, { dates: text.trim() })
        return true
      }
    })
  }

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
    title: !root.entry ? "" : root.filtersOnly ? "Filter your photos" : "“" + root.entry.query + "”"
    subtitle: timeline.total > 0 ? Format.count(timeline.total, "result") + (timeline.hasMore ? " so far" : "") : ""
    actions: [{ id: "sort", label: { "": root.filtersOnly ? "Newest first" : "Best match", newest: "Newest first", oldest: "Oldest first", name: "By name", type: "Photos, then videos" }[root.sortMode], icon: "sort" }]
    onBack: root.back()
    onActionTriggered: function(id, button) { sortMenu.openBelow(button) }
  }

  PopupMenu {
    id: sortMenu
    theme: root.theme
    parent: root
    items: [
      { id: "", label: root.filtersOnly ? "Newest first" : "Best match" },
      { id: "newest", label: "Newest first" },
      { id: "oldest", label: "Oldest first" },
      { id: "name", label: "By name" },
      { id: "type", label: "Photos, then videos" }
    ]
    onActivated: function(id) { root.sortMode = id }
  }

  Row {
    id: chips
    anchors { left: parent.left; top: header.bottom; leftMargin: root.theme.space(18) }
    spacing: root.theme.space(6)
    Repeater {
      model: root.modes
      delegate: TextButton {
        required property var modelData
        visible: modelData.enabled && !root.filtersOnly
        theme: root.theme
        text: modelData.label
        fontSize: root.theme.small
        selected: !!root.entry && root.entry.mode === modelData.id
        onClicked: root.modeChanged(modelData.id, root.filters)
      }
    }
    Item { width: root.filtersOnly ? 0 : root.theme.space(14); height: 1 }
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

  Flow {
    id: filterRow
    anchors { left: parent.left; right: parent.right; top: chips.bottom; leftMargin: root.theme.space(18); rightMargin: root.theme.space(18); topMargin: root.theme.space(6) }
    spacing: root.theme.space(6)
    FilterChip {
      theme: root.theme
      icon: "personSearch"
      label: "Person"
      value: (root.labels.people || []).join(" & ")
      onChoose: root.choosePerson()
      onClear: root.setFilters({ personIds: null }, { people: null })
    }
    FilterChip {
      theme: root.theme
      icon: "places"
      label: "Place"
      value: root.labels.place || ""
      onChoose: root.choosePlace()
      onClear: root.setFilters({ city: null, country: null }, { place: null })
    }
    FilterChip {
      theme: root.theme
      icon: "lens"
      label: "Camera"
      value: root.labels.camera || ""
      onChoose: root.chooseCamera()
      onClear: root.setFilters({ make: null, model: null }, { camera: null })
    }
    FilterChip {
      theme: root.theme
      icon: "dates"
      label: "Dates"
      value: root.labels.dates || ""
      onChoose: root.chooseDates()
      onClear: root.setFilters({ takenAfter: null, takenBefore: null }, { dates: null })
    }
  }

  Timeline {
    id: timeline
    theme: root.theme
    service: root.service
    sortMode: root.sortMode
    anchors { left: parent.left; right: parent.right; top: filterRow.bottom; bottom: parent.bottom; topMargin: root.theme.space(8) }
    zoom: root.zoom
    emptyIcon: "search"
    emptyTitle: "Nothing found"
    emptyText: root.entry && root.entry.mode === "smart"
      ? "Smart search looks for what is in the photo. Try other words, or search by file name."
      : "Try other words or another way of matching."
    pager: root.entry ? function(page, done) {
      root.service.call("search", { mode: root.filtersOnly ? "metadata" : root.entry.mode, query: root.entry.query, page: page, size: 150, filters: root.filters }, function(r, e) { if (!root) return;
        if (e) return done([], false, e)
        done(r.items, r.nextPage !== null && r.nextPage !== undefined && r.items.length > 0, null)
      })
    } : null
    onOpened: function(a) { root.openAsset(a) }
    onContextRequested: function(a, item, x, y) { root.contextRequested(a, item, x, y) }
  }
}
