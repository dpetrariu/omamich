import QtQuick
import qs.Ui
import "../components"
import "../lib/Format.js" as Format

// The people Immich recognised. Named people first, favourites first among
// them; the unnamed follow, so naming someone is always a click away.
Item {
  id: root

  required property var theme
  required property var service

  readonly property string kind: "tiles"
  readonly property bool typing: filter.activeFocus
  property bool showHidden: false
  readonly property var people: {
    var q = filter.text.trim().toLowerCase()
    var list = service.people.filter(function(p) {
      if (!root.showHidden && p.isHidden) return false
      if (q) return String(p.name || "").toLowerCase().indexOf(q) >= 0
      return true
    })
    // Favourites, then named, then the rest, keeping Immich's order within each.
    var fav = [], named = [], rest = []
    for (var i = 0; i < list.length; i++) {
      if (list[i].isFavorite) fav.push(list[i])
      else if (list[i].name) named.push(list[i])
      else rest.push(list[i])
    }
    return fav.concat(named).concat(rest)
  }
  readonly property string statusText: Format.count(people.length, "person", "people")

  signal personOpened(var person)
  signal rename(var person)
  signal updatePerson(var person, var change)
  signal menuRequested(var person, Item item)

  function reload() { service.loadPeople(true) }
  function handleKey(id) { grid.handleKey(id) }

  Component.onCompleted: service.loadPeople()

  PageHeader {
    id: header
    theme: root.theme
    anchors { left: parent.left; right: parent.right; top: parent.top }
    title: "People"
    subtitle: root.service.peopleLoading && root.service.people.length === 0 ? "Loading everyone Immich recognised…"
      : Format.count(root.people.length, "person", "people") + (root.service.peopleLoading ? " · refreshing" : "")
    actions: [{ id: "hidden", label: root.showHidden ? "Hide hidden" : "Show hidden", icon: root.showHidden ? "eyeOff" : "eye" }]
    onActionTriggered: root.showHidden = !root.showHidden
  }

  TextField {
    id: filter
    anchors { left: parent.left; top: header.bottom; leftMargin: root.theme.space(18) }
    width: Math.min(root.theme.space(320), parent.width - root.theme.space(36))
    placeholderText: "Find a person"
    font.family: root.theme.font
    font.pixelSize: root.theme.body
  }

  TileGrid {
    id: grid
    theme: root.theme
    anchors { left: parent.left; right: parent.right; top: filter.bottom; bottom: parent.bottom; topMargin: root.theme.space(12) }
    model: root.people
    minTile: root.theme.space(124)
    tileAspect: 1
    tileExtra: root.theme.space(24)
    onActivated: function(p) { if (p) root.personOpened(p) }
    tile: Component {
      Item {
        id: t
        readonly property var person: parent ? parent.modelData : null
        readonly property bool current: parent ? parent.isCurrent : false
        RoundImage {
          id: face
          width: Math.min(parent.width, parent.height - root.theme.space(24))
          height: width
          anchors.horizontalCenter: parent.horizontalCenter
          radius: width / 2
          fill: root.theme.raised
          sourceSize: 240
          source: t.person ? root.service.personUrl(t.person.id, t.person.version) : ""
          opacity: t.person && t.person.isHidden ? 0.45 : 1
        }
        Rectangle {
          anchors.fill: face
          radius: width / 2
          color: "transparent"
          border.width: t.current ? root.theme.space(2) : 0
          border.color: root.theme.accent
        }
        Glyph {
          visible: !!t.person && t.person.isFavorite
          anchors { right: face.right; top: face.top }
          name: "starOn"
          size: root.theme.icon
          color: root.theme.accent
          font.family: root.theme.font
        }
        Text {
          anchors { left: parent.left; right: parent.right; top: face.bottom; topMargin: root.theme.space(6) }
          horizontalAlignment: Text.AlignHCenter
          text: t.person && t.person.name ? t.person.name : "Add a name"
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: t.person && t.person.name ? root.theme.foreground : root.theme.dim
          font.family: root.theme.font
          font.pixelSize: root.theme.small
        }
        MouseArea {
          anchors.fill: parent
          acceptedButtons: Qt.LeftButton | Qt.RightButton
          cursorShape: Qt.PointingHandCursor
          onClicked: function(mouse) {
            grid.cursor = t.parent.index
            if (mouse.button === Qt.RightButton) root.menuRequested(t.person, t)
            else root.personOpened(t.person)
          }
        }
      }
    }
  }

  Text {
    textFormat: Text.PlainText
    anchors.centerIn: parent
    visible: !root.service.peopleLoading && root.people.length === 0
    text: root.service.peopleError || (filter.text ? "Nobody called “" + filter.text + "”" : "Immich has not recognised any faces yet")
    color: root.service.peopleError ? root.theme.urgent : root.theme.dim
    font.family: root.theme.font
    font.pixelSize: root.theme.body
  }
}
