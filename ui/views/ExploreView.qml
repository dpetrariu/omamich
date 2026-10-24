import QtQuick
import QtQuick.Controls as QQC
import "../components"
import "../lib/Format.js" as Format

// A front page for wandering: the people you photograph most, the places
// you have been, and quick ways in.
Item {
  id: root

  required property var theme
  required property var service

  readonly property string kind: "tiles"
  property var explore: []
  property string error: ""
  readonly property string statusText: ""

  signal personOpened(var person)
  signal placeOpened(var place)
  signal sectionOpened(string id)
  signal search(string query)

  function reload() { load(); service.loadPeople(true); service.loadPlaces(true) }
  function handleKey(id) {}

  function load() {
    service.call("explore", {}, function(r, e) { if (!root) return;
      root.error = e ? e.message : ""
      if (!e) root.explore = r
    })
  }

  Component.onCompleted: { load(); service.loadPeople(); service.loadPlaces() }

  readonly property var topPeople: service.people.filter(function(p) { return p.name && !p.isHidden }).slice(0, 16)
  readonly property var topPlaces: service.places.slice(0, 16)
  readonly property var suggestions: ["Sunset", "Beach", "Snow", "Mountains", "Food", "Dog", "Cat", "Birthday cake", "City at night", "Forest", "Car", "Flowers"]

  Flickable {
    anchors.fill: parent
    contentHeight: column.implicitHeight + root.theme.space(40)
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    QQC.ScrollBar.vertical: QQC.ScrollBar {}

    Column {
      id: column
      x: root.theme.space(18)
      width: parent.width - root.theme.space(36)
      spacing: root.theme.space(22)

      PageHeader {
        x: -root.theme.space(18)
        width: parent.width + root.theme.space(36)
        theme: root.theme
        title: "Explore"
        subtitle: root.service.statistics ? Format.thousands(root.service.statistics.images) + " photos and " + Format.thousands(root.service.statistics.videos) + " videos" : ""
      }

      SectionTitle { theme: root.theme; text: "People"; action: "All people"; onActionClicked: root.sectionOpened("people") }
      ListView {
        width: parent.width
        height: root.theme.space(124)
        orientation: ListView.Horizontal
        spacing: root.theme.space(14)
        clip: true
        model: root.topPeople
        boundsBehavior: Flickable.StopAtBounds
        delegate: Item {
          required property var modelData
          width: root.theme.space(92)
          height: root.theme.space(124)
          RoundImage {
            id: face
            width: parent.width; height: width
            radius: width / 2
            fill: root.theme.raised
            sourceSize: 200
            source: root.service.personUrl(modelData.id, modelData.version)
          }
          Text {
            anchors { top: face.bottom; topMargin: root.theme.space(6); left: parent.left; right: parent.right }
            horizontalAlignment: Text.AlignHCenter
            text: modelData.name
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: root.theme.foreground
            font.family: root.theme.font
            font.pixelSize: root.theme.small
          }
          MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.personOpened(modelData) }
        }
        Text {
          visible: parent.count === 0
          text: root.service.peopleLoading ? "Loading people…" : "Name people in People and they appear here."
          color: root.theme.dim
          font.family: root.theme.font
          font.pixelSize: root.theme.small
        }
      }

      SectionTitle { theme: root.theme; text: "Places"; action: "All places"; onActionClicked: root.sectionOpened("places") }
      ListView {
        width: parent.width
        height: root.theme.space(170)
        orientation: ListView.Horizontal
        spacing: root.theme.space(12)
        clip: true
        model: root.topPlaces
        boundsBehavior: Flickable.StopAtBounds
        delegate: Item {
          required property var modelData
          width: root.theme.space(150)
          height: root.theme.space(170)
          RoundImage {
            id: cover
            width: parent.width; height: root.theme.space(130)
            radius: root.theme.radius + root.theme.space(4)
            fill: root.theme.raised
            sourceSize: 300
            source: root.service.thumbUrl(modelData.assetId, "thumbnail", "")
          }
          Text {
            anchors { top: cover.bottom; topMargin: root.theme.space(6); left: parent.left; right: parent.right }
            text: modelData.city || modelData.country
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: root.theme.foreground
            font.family: root.theme.font
            font.pixelSize: root.theme.small
          }
          MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.placeOpened(modelData) }
        }
        Text {
          visible: parent.count === 0
          text: root.service.placesLoading ? "Loading places…" : "No places yet."
          color: root.theme.dim
          font.family: root.theme.font
          font.pixelSize: root.theme.small
        }
      }

      SectionTitle { theme: root.theme; text: "Try a search"; visible: root.service.features.smartSearch !== false }
      Flow {
        width: parent.width
        spacing: root.theme.space(8)
        visible: root.service.features.smartSearch !== false
        Repeater {
          model: root.suggestions
          delegate: TextButton {
            required property var modelData
            theme: root.theme
            text: modelData
            icon: "search"
            fontSize: root.theme.small
            onClicked: root.search(modelData)
          }
        }
      }

      SectionTitle { theme: root.theme; text: "Collections" }
      Flow {
        width: parent.width
        spacing: root.theme.space(8)
        Repeater {
          model: [
            { id: "favorites", label: "Favourites", icon: "favorite" },
            { id: "albums", label: "Albums", icon: "albums" },
            { id: "tags", label: "Tags", icon: "tags" },
            { id: "folders", label: "Folders", icon: "folders" },
            { id: "archive", label: "Archive", icon: "archive" }
          ]
          delegate: TextButton {
            required property var modelData
            theme: root.theme
            text: modelData.label
            icon: modelData.icon
            onClicked: root.sectionOpened(modelData.id)
          }
        }
      }

      Text {
        visible: root.error !== ""
        text: root.error
        color: root.theme.urgent
        font.family: root.theme.font
        font.pixelSize: root.theme.small
      }
    }
  }
}
