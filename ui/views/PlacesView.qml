import QtQuick
import qs.Ui
import "../components"
import "../lib/Format.js" as Format

// Every place with photos, the most photographed first. Filter by city or
// country.
Item {
  id: root

  required property var theme
  required property var service

  readonly property string kind: "tiles"
  readonly property bool typing: filter.activeFocus
  readonly property var places: {
    var q = filter.text.trim().toLowerCase()
    if (!q) return service.places
    return service.places.filter(function(p) {
      return String(p.city || "").toLowerCase().indexOf(q) >= 0 || String(p.country || "").toLowerCase().indexOf(q) >= 0
    })
  }
  readonly property string statusText: Format.count(places.length, "place")

  signal placeOpened(var place)

  function reload() { service.loadPlaces(true) }
  function handleKey(id) { grid.handleKey(id) }

  Component.onCompleted: service.loadPlaces()

  PageHeader {
    id: header
    theme: root.theme
    anchors { left: parent.left; right: parent.right; top: parent.top }
    title: "Places"
    subtitle: root.service.placesLoading && root.service.places.length === 0 ? "Gathering places from the map…" : Format.count(root.places.length, "place")
  }

  TextField {
    id: filter
    anchors { left: parent.left; top: header.bottom; leftMargin: root.theme.space(18) }
    width: Math.min(root.theme.space(320), parent.width - root.theme.space(36))
    placeholderText: "Filter by city or country"
    font.family: root.theme.font
    font.pixelSize: root.theme.body
  }

  TileGrid {
    id: grid
    theme: root.theme
    anchors { left: parent.left; right: parent.right; top: filter.bottom; bottom: parent.bottom; topMargin: root.theme.space(12) }
    model: root.places
    minTile: root.theme.space(170)
    tileAspect: 1
    tileExtra: root.theme.space(40)
    onActivated: function(p) { if (p) root.placeOpened(p) }
    tile: Component {
      Item {
        id: t
        readonly property var place: parent ? parent.modelData : null
        readonly property bool current: parent ? parent.isCurrent : false
        RoundImage {
          id: cover
          width: parent.width
          height: width
          radius: root.theme.radius + root.theme.space(4)
          fill: root.theme.raised
          sourceSize: 360
          source: t.place ? root.service.thumbUrl(t.place.assetId, "thumbnail", "") : ""
        }
        Rectangle {
          anchors.fill: cover
          radius: cover.radius
          color: "transparent"
          border.width: t.current ? root.theme.space(2) : 0
          border.color: root.theme.accent
        }
        Column {
          anchors { left: parent.left; right: parent.right; top: cover.bottom; topMargin: root.theme.space(6) }
          Text {
            width: parent.width
            text: t.place ? (t.place.city || t.place.country) : ""
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: root.theme.foreground
            font.family: root.theme.font
            font.pixelSize: root.theme.body
          }
          Text {
            width: parent.width
            text: t.place ? [t.place.city ? t.place.country : "", Format.count(t.place.count, "photo")].filter(function(s) { return s }).join(" · ") : ""
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: root.theme.dim
            font.family: root.theme.font
            font.pixelSize: root.theme.caption
          }
        }
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: { grid.cursor = t.parent.index; root.placeOpened(t.place) }
        }
      }
    }
  }

  Text {
    textFormat: Text.PlainText
    anchors.centerIn: parent
    visible: !root.service.placesLoading && root.places.length === 0
    text: root.service.placesError || "No photos have a place yet"
    color: root.service.placesError ? root.theme.urgent : root.theme.dim
    font.family: root.theme.font
    font.pixelSize: root.theme.body
  }
}
