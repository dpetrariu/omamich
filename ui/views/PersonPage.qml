import QtQuick
import QtQuick.Window
import "../components"
import "../lib/Format.js" as Format

// Everyone's photos of one person, with their face, name, age and the ways
// to correct who they are.
Item {
  id: root

  required property var theme
  required property var service
  property real zoom: 1
  property var person: null
  property var stats: null

  readonly property string kind: "grid"
  readonly property alias grid: timeline
  readonly property string statusText: Format.count(timeline.total, "photo")

  signal openAsset(var asset)
  signal contextRequested(var asset, Item item, real x, real y)
  signal back()
  signal rename()
  signal setBirthday()
  signal merge()
  signal updatePerson(var change)

  function reload() { timeline.reload() }

  function age(birth) {
    var m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(birth || ""))
    if (!m) return ""
    var now = new Date()
    var years = now.getFullYear() - Number(m[1])
    if (now.getMonth() + 1 < Number(m[2]) || (now.getMonth() + 1 === Number(m[2]) && now.getDate() < Number(m[3]))) years--
    return years >= 0 ? "age " + years : ""
  }

  Item {
    id: header
    anchors { left: parent.left; right: parent.right; top: parent.top }
    height: root.theme.space(92)

    IconButton {
      id: backButton
      theme: root.theme
      anchors.left: parent.left
      anchors.leftMargin: root.theme.space(10)
      anchors.verticalCenter: parent.verticalCenter
      icon: "back"
      tooltip: "Back (Esc)"
      onClicked: root.back()
    }

    RoundImage {
      id: face
      anchors.left: backButton.right
      anchors.leftMargin: root.theme.space(8)
      anchors.verticalCenter: parent.verticalCenter
      width: root.theme.space(64)
      height: width
      radius: width / 2
      fill: root.theme.raised
      sourceSize: 160
      source: root.person ? root.service.personUrl(root.person.id, root.person.version) : ""
    }

    Column {
      anchors.left: face.right
      anchors.leftMargin: root.theme.space(14)
      anchors.right: actions.left
      anchors.verticalCenter: parent.verticalCenter
      spacing: root.theme.space(4)
      Text {
        width: parent.width
        text: root.person && root.person.name ? root.person.name : "Someone without a name"
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: root.person && root.person.name ? root.theme.foreground : root.theme.dim
        font.family: root.theme.font
        font.pixelSize: root.theme.display * 0.8
      }
      Text {
        text: [Format.count(timeline.total, "photo"),
          root.person && root.person.birthDate ? "born " + Format.shortDate(root.person.birthDate) + " (" + root.age(root.person.birthDate) + ")" : "",
          root.person && root.person.isHidden ? "hidden from People" : "",
          root.person && root.person.isFavorite ? "favourite" : ""].filter(function(s) { return s }).join("  ·  ")
        textFormat: Text.PlainText
        color: root.theme.dim
        font.family: root.theme.font
        font.pixelSize: root.theme.small
      }
    }

    Row {
      id: actions
      anchors.right: parent.right
      anchors.rightMargin: root.theme.space(16)
      anchors.verticalCenter: parent.verticalCenter
      spacing: root.theme.space(6)
      TextButton { theme: root.theme; text: root.person && root.person.name ? "Rename..." : "Name..."; icon: "edit"; fontSize: root.theme.small; onClicked: root.rename() }
      TextButton { theme: root.theme; text: "Birthday..."; icon: "cake"; fontSize: root.theme.small; onClicked: root.setBirthday() }
      IconButton {
        theme: root.theme
        icon: root.person && root.person.isFavorite ? "starOn" : "star"
        tooltip: root.person && root.person.isFavorite ? "Unfavourite" : "Favourite"
        selected: !!root.person && root.person.isFavorite
        onClicked: root.updatePerson({ isFavorite: !root.person.isFavorite })
      }
      IconButton {
        theme: root.theme
        icon: root.person && root.person.isHidden ? "eye" : "eyeOff"
        tooltip: root.person && root.person.isHidden ? "Show in People" : "Hide from People"
        onClicked: root.updatePerson({ isHidden: !root.person.isHidden })
      }
      IconButton { theme: root.theme; icon: "merge"; tooltip: "Merge into another person..."; onClicked: root.merge() }
    }
  }

  Timeline {
    id: timeline
    theme: root.theme
    service: root.service
    anchors { left: parent.left; right: parent.right; top: header.bottom; bottom: parent.bottom }
    scope: root.person ? ({ personId: root.person.id }) : ({})
    zoom: root.zoom
    emptyIcon: "person"
    emptyTitle: "No photos of this person"
    onOpened: function(a) { root.openAsset(a) }
    onContextRequested: function(a, item, x, y) { root.contextRequested(a, item, x, y) }
  }
}
