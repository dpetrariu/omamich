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
  signal tagOpened(var tag)

  property bool showPeople: true
  property bool showPlaces: true
  property bool showTags: true
  property bool showFolders: true
  property var tagCovers: ({})
  // The most used tags, once their counts are known.
  readonly property var topTags: service.tags.filter(function(t) { return root.tagCovers[t.id] && root.tagCovers[t.id].count > 0 })
    .sort(function(a, b) { return root.tagCovers[b.id].count - root.tagCovers[a.id].count }).slice(0, 14)

  function loadTagCovers() {
    if (!showTags || service.tags.length === 0) return
    service.call("tags.covers", { ids: service.tags.slice(0, 60).map(function(t) { return t.id }) }, function(r, e) {
      if (!root) return
      if (!e) root.tagCovers = r
    })
  }
  Connections {
    target: root.service
    function onTagsChanged() { root.loadTagCovers() }
  }
  signal search(string query)

  function reload() { load(); service.loadPeople(true); service.loadPlaces(true) }
  function handleKey(id) {}

  function load() {
    service.call("explore", {}, function(r, e) { if (!root) return;
      root.error = e ? e.message : ""
      if (!e) root.explore = r
    })
  }

  Component.onCompleted: {
    load()
    if (showPeople) service.loadPeople()
    if (showPlaces) service.loadPlaces()
    if (showTags) service.loadTags()
  }

  readonly property var topPeople: service.people.filter(function(p) { return p.name && !p.isHidden }).slice(0, 16)
  readonly property var topPlaces: service.places.slice(0, 16)
  readonly property var suggestions: ["Sunset", "Beach", "Snow", "Mountains", "Food", "Dog", "Cat", "Birthday cake", "City at night", "Forest", "Car", "Flowers"]

  // Momentum scrolling. A sideways swipe or Shift+wheel over the people,
  // places or tags goes to that row, which glides and stretches on its own.
  WheelScroller {
    id: pageWheel
    flickable: page
    notch: root.theme.space(320)
    rowAt: function(y) {
      for (var i = 0; i < column.children.length; i++) {
        var row = column.children[i]
        if (!row.rowWheel || !row.visible) continue
        var p = row.mapToItem(root, 0, 0)
        if (y >= p.y && y < p.y + row.height) return row.rowWheel
      }
      return null
    }
  }
  property alias wheel: pageWheel
  property alias peopleRow: peopleRow

  // A row's own sideways scroller: a child of the row itself (not of its
  // content), fed by the page.
  component RowWheel: WheelScroller {
    horizontal: true
    takesWheel: false
    notch: root.theme.space(360)
  }

  Flickable {
    id: page
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

      SectionTitle { visible: root.showPeople; theme: root.theme; text: "People"; action: "All people"; onActionClicked: root.sectionOpened("people") }
      ListView {
        visible: root.showPeople
        width: parent.width
        height: root.theme.space(124)
        orientation: ListView.Horizontal
        id: peopleRow
        readonly property var rowWheel: peopleWheel
        RowWheel { id: peopleWheel; parent: peopleRow; flickable: peopleRow }
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

      SectionTitle { visible: root.showPlaces; theme: root.theme; text: "Places"; action: "All places"; onActionClicked: root.sectionOpened("places") }
      ListView {
        visible: root.showPlaces
        width: parent.width
        height: root.theme.space(170)
        orientation: ListView.Horizontal
        id: placesRow
        readonly property var rowWheel: placesWheel
        RowWheel { id: placesWheel; parent: placesRow; flickable: placesRow }
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

      SectionTitle { visible: root.showTags && root.topTags.length > 0; theme: root.theme; text: "Tags"; action: "All tags"; onActionClicked: root.sectionOpened("tags") }
      ListView {
        visible: root.showTags && root.topTags.length > 0
        width: parent.width
        height: root.theme.space(170)
        orientation: ListView.Horizontal
        id: tagsRow
        readonly property var rowWheel: tagsWheel
        RowWheel { id: tagsWheel; parent: tagsRow; flickable: tagsRow }
        spacing: root.theme.space(12)
        clip: true
        model: root.topTags
        boundsBehavior: Flickable.StopAtBounds
        delegate: Item {
          required property var modelData
          width: root.theme.space(150)
          height: root.theme.space(170)
          RoundImage {
            id: tagCover
            width: parent.width; height: root.theme.space(130)
            radius: root.theme.radius + root.theme.space(4)
            fill: root.theme.raised
            sourceSize: 300
            source: root.tagCovers[modelData.id] && root.tagCovers[modelData.id].assetId ? root.service.thumbUrl(root.tagCovers[modelData.id].assetId, "thumbnail", "") : ""
          }
          Text {
            anchors { top: tagCover.bottom; topMargin: root.theme.space(6); left: parent.left; right: parent.right }
            text: (modelData.value || modelData.name) + "  ·  " + Format.thousands(root.tagCovers[modelData.id] ? root.tagCovers[modelData.id].count : 0)
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: root.theme.foreground
            font.family: root.theme.font
            font.pixelSize: root.theme.small
          }
          MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.tagOpened(modelData) }
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
            { id: "tags", label: "Tags", icon: "tags", hidden: !root.showTags },
            { id: "folders", label: "Folders", icon: "folders", hidden: !root.showFolders },
            { id: "archive", label: "Archive", icon: "archive" }
          ]
          delegate: TextButton {
            required property var modelData
            visible: !modelData.hidden
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
