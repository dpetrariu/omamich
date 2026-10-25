import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Window
import QtMultimedia
import "../lib/Format.js" as Format
import "../lib/Thumbhash.js" as Thumbhash

// One photo or video, as large as the window allows. The preview shows first;
// zooming in swaps in the full-size image. Videos and live photos play
// through the backend's media server, which adds the key.
Item {
  id: root

  required property var theme
  required property var service
  property var asset: null
  property bool inTrash: false
  property bool inArchive: false
  property bool infoOpen: false
  property var details: null
  property int waitingForNext: 0
  property bool slideshow: false
  property real zoom: 1
  property real panX: 0
  property real panY: 0
  property bool playingLive: false
  property string videoError: ""

  readonly property bool isVideo: !!asset && !asset.isImage
  // A file on this computer: shown from disk; its Immich copy, if any, is
  // where the details come from.
  readonly property bool isLocal: !!asset && !!asset.localPath
  readonly property string remoteId: remoteIdOf(asset)
  // Read from the asset itself, not the binding above, which may not have
  // caught up yet inside onAssetChanged.
  function remoteIdOf(a) {
    return !a ? "" : a.localPath ? (a.assetId || "") : a.id
  }
  readonly property bool hasLive: !!asset && !!asset.livePhotoVideoId
  readonly property bool zoomed: zoom > 1.01

  signal closeRequested()
  signal stepRequested(int delta)
  signal actionRequested(string id)
  signal infoToggled()
  signal menuRequested(Item item)

  onAssetChanged: {
    resetZoom()
    playingLive = false
    details = null
    if (asset) loadDetails()
    else player.stop()
  }

  function loadDetails() {
    var id = remoteIdOf(asset)
    if (!id) return
    service.call("asset.get", { id: id }, function(r, e) { if (!root) return;
      if (!root.asset || root.remoteIdOf(root.asset) !== id) return
      if (!e) root.details = r
    })
  }
  function reloadDetails() { if (asset) loadDetails() }

  function resetZoom() {
    zoom = 1
    panX = 0
    panY = 0
  }

  function zoomBy(factor, cx, cy) {
    if (isVideo) return
    var next = Math.max(1, Math.min(10, zoom * factor))
    // Keep the point under the pointer still while zooming.
    var px = cx === undefined ? stage.width / 2 : cx
    var py = cy === undefined ? stage.height / 2 : cy
    var ox = px - stage.width / 2
    var oy = py - stage.height / 2
    panX = (panX - ox) * (next / zoom) + ox
    panY = (panY - oy) * (next / zoom) + oy
    zoom = next
    clampPan()
  }

  function clampPan() {
    if (zoom <= 1.01) { panX = 0; panY = 0; return }
    var w = picture.paintedWidth * zoom
    var h = picture.paintedHeight * zoom
    var maxX = Math.max(0, (w - stage.width) / 2)
    var maxY = Math.max(0, (h - stage.height) / 2)
    panX = Math.max(-maxX, Math.min(maxX, panX))
    panY = Math.max(-maxY, Math.min(maxY, panY))
  }

  function togglePlay() {
    if (isVideo || playingLive) {
      if (player.playbackState === MediaPlayer.PlayingState) player.pause()
      else player.play()
    } else if (hasLive) {
      playingLive = true
    }
  }

  Rectangle {
    anchors.fill: parent
    color: root.theme.mix(root.theme.background, Qt.rgba(0, 0, 0, 1), 0.35)
  }

  // ------------------------------------------------------------ the picture
  Item {
    id: stage
    anchors.fill: parent
    clip: true

    Rectangle {
      id: placeholder
      anchors.centerIn: parent
      readonly property real ratio: root.asset ? Math.max(0.2, Number(root.asset.ratio) || 1) : 1
      width: Math.min(parent.width, parent.height * ratio)
      height: width / ratio
      color: Thumbhash.averageColor(root.asset ? root.asset.thumbhash : "") || root.theme.raised
      visible: !root.isVideo && preview.status !== Image.Ready
      opacity: 0.6
    }

    Image {
      id: preview
      anchors.fill: parent
      visible: !root.isVideo && !full.ready && !root.playingLive
      source: !root.asset || root.isVideo ? "" : root.isLocal ? "file://" + root.asset.localPath
        : root.service.thumbUrl(root.asset.id, "preview", root.asset.thumbhash)
      sourceSize.width: root.isLocal ? 2560 : 0
      fillMode: Image.PreserveAspectFit
      asynchronous: true
      cache: true
      smooth: true
      scale: root.zoom
      transform: Translate { x: root.panX; y: root.panY }
    }

    Image {
      id: full
      readonly property bool ready: status === Image.Ready
      anchors.fill: parent
      visible: ready && !root.isVideo && !root.playingLive
      // Full size is fetched only once the person zooms in.
      source: root.asset && !root.isVideo && !root.isLocal && root.zoom > 1.2 ? root.service.thumbUrl(root.asset.id, "fullsize", root.asset.thumbhash) : ""
      fillMode: Image.PreserveAspectFit
      asynchronous: true
      cache: false
      smooth: true
      mipmap: true
      scale: root.zoom
      transform: Translate { x: root.panX; y: root.panY }
    }

    VideoOutput {
      id: videoOut
      anchors.fill: parent
      visible: root.isVideo || root.playingLive
      fillMode: VideoOutput.PreserveAspectFit
    }

    MediaPlayer {
      id: player
      videoOutput: videoOut
      audioOutput: AudioOutput { id: audio; volume: 0.9; muted: root.playingLive }
      source: !root.asset ? "" : root.isVideo ? (root.isLocal ? "file://" + root.asset.localPath : root.service.videoUrl(root.asset.id))
        : root.playingLive ? root.service.videoUrl(root.asset.livePhotoVideoId) : ""
      onSourceChanged: {
        root.videoError = ""
        if (source != "") play()
      }
      onPlaybackStateChanged: {
        if (root.playingLive && playbackState === MediaPlayer.StoppedState) root.playingLive = false
      }
      onErrorOccurred: function(error, message) { root.videoError = message || "This video could not be played" }
      onMediaStatusChanged: {
        if (mediaStatus === MediaPlayer.EndOfMedia && root.slideshow) root.stepRequested(1)
      }
    }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton
      hoverEnabled: true
      cursorShape: root.zoomed ? (pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor) : Qt.ArrowCursor
      property real lastX: 0
      property real lastY: 0
      onPressed: function(mouse) { lastX = mouse.x; lastY = mouse.y }
      onPositionChanged: function(mouse) {
        chrome.poke()
        if (!pressed || !root.zoomed) return
        root.panX += mouse.x - lastX
        root.panY += mouse.y - lastY
        lastX = mouse.x
        lastY = mouse.y
        root.clampPan()
      }
      onDoubleClicked: function(mouse) {
        if (root.isVideo) return
        if (root.zoomed) root.resetZoom()
        else root.zoomBy(2.5, mouse.x, mouse.y)
      }
      onClicked: if (root.isVideo) root.togglePlay()
      onWheel: function(wheel) {
        if (root.isVideo) return
        var factor = wheel.angleDelta.y > 0 ? 1.18 : 1 / 1.18
        root.zoomBy(factor, wheel.x, wheel.y)
      }
    }
  }

  // Pan clamping needs the painted size of what is showing.
  readonly property Image picture: preview

  // ------------------------------------------------------------ chrome
  Item {
    id: chrome
    anchors.fill: parent
    opacity: shown ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 160 } }
    property bool shown: true
    function poke() {
      shown = true
      hideTimer.restart()
    }
    Timer {
      id: hideTimer
      interval: 2600
      onTriggered: chrome.shown = root.isVideo && player.playbackState !== MediaPlayer.PlayingState
    }

    Rectangle {
      anchors { left: parent.left; right: parent.right; top: parent.top }
      height: root.theme.space(64)
      gradient: Gradient {
        GradientStop { position: 0; color: Qt.rgba(0, 0, 0, 0.55) }
        GradientStop { position: 1; color: "transparent" }
      }
    }

    IconButton {
      id: closeButton
      theme: root.theme
      anchors { left: parent.left; top: parent.top; margins: root.theme.space(10) }
      icon: "back"
      color: "white"
      tooltip: "Back to the grid (Esc)"
      onClicked: root.closeRequested()
    }

    Column {
      anchors { left: closeButton.right; leftMargin: root.theme.space(8); verticalCenter: closeButton.verticalCenter }
      width: Math.max(0, toolbar.x - x - root.theme.space(20))
      Text {
        width: parent.width
        text: root.asset ? Format.dateLabel(root.asset.fileCreatedAt) + "  " + Format.timeLabel(root.asset.fileCreatedAt) : ""
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: "white"
        font.family: root.theme.font
        font.pixelSize: root.theme.body
      }
      Text {
        width: parent.width
        text: root.details ? [root.details.originalFileName, Format.place(root.details.exif)].filter(function(s) { return s }).join("  ·  ") : ""
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: Qt.rgba(1, 1, 1, 0.7)
        font.family: root.theme.font
        font.pixelSize: root.theme.caption
      }
    }

    Row {
      id: toolbar
      anchors { right: parent.right; top: parent.top; margins: root.theme.space(10) }
      spacing: root.theme.space(2)
      IconButton {
        visible: root.hasLive && !root.isVideo
        theme: root.theme; color: "white"
        icon: "live"
        selected: root.playingLive
        tooltip: root.playingLive ? "Stop the live photo (space)" : "Play the live photo (space)"
        onClicked: root.playingLive ? (root.playingLive = false) : (root.playingLive = true)
      }
      IconButton {
        theme: root.theme; color: "white"
        icon: root.asset && root.asset.isFavorite ? "favoriteOn" : "favorite"
        tooltip: root.asset && root.asset.isFavorite ? "Remove from favourites (f)" : "Add to favourites (f)"
        onClicked: root.actionRequested("favorite")
      }
      IconButton {
        theme: root.theme; color: "white"
        icon: "info"
        selected: root.infoOpen
        tooltip: "Details (i)"
        onClicked: root.infoToggled()
      }
      IconButton {
        theme: root.theme; color: "white"
        icon: "zoomIn"
        visible: !root.isVideo
        tooltip: "Zoom in (z), out (Shift+Z), fit (0)"
        onClicked: root.zoomed ? root.resetZoom() : root.zoomBy(2.5)
      }
      IconButton {
        theme: root.theme; color: "white"
        icon: "slideshow"
        selected: root.slideshow
        tooltip: root.slideshow ? "Stop the slideshow (Shift+S)" : "Slideshow (Shift+S)"
        onClicked: root.slideshow = !root.slideshow
      }
      IconButton {
        theme: root.theme; color: "white"
        icon: "download"
        tooltip: "Download the original (Shift+D)"
        onClicked: root.actionRequested("download")
      }
      IconButton {
        theme: root.theme; color: "white"
        icon: root.inTrash ? "restore" : "trash"
        tooltip: root.inTrash ? "Restore (d)" : "Move to trash (d)"
        onClicked: root.actionRequested("trash")
      }
      IconButton {
        id: moreButton
        theme: root.theme; color: "white"
        icon: "more"
        tooltip: "More..."
        onClicked: root.menuRequested(moreButton)
      }
    }

    // Previous and next, on the edges.
    IconButton {
      anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: root.theme.space(10) }
      theme: root.theme; color: "white"
      icon: "chevronLeft"
      iconSize: root.theme.display
      size: root.theme.space(48)
      tooltip: "Previous (h)"
      onClicked: root.stepRequested(-1)
    }
    IconButton {
      anchors { right: parent.right; verticalCenter: parent.verticalCenter; rightMargin: root.theme.space(10) }
      theme: root.theme; color: "white"
      icon: "chevronRight"
      iconSize: root.theme.display
      size: root.theme.space(48)
      tooltip: "Next (l)"
      onClicked: root.stepRequested(1)
    }

    // Video controls.
    Rectangle {
      visible: root.isVideo
      anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: root.theme.space(14) }
      height: root.theme.space(44)
      radius: root.theme.radius
      color: Qt.rgba(0, 0, 0, 0.55)
      IconButton {
        id: playButton
        theme: root.theme; color: "white"
        anchors.left: parent.left
        anchors.leftMargin: root.theme.space(6)
        anchors.verticalCenter: parent.verticalCenter
        icon: player.playbackState === MediaPlayer.PlayingState ? "pause" : "play"
        tooltip: "Play or pause (space)"
        onClicked: root.togglePlay()
      }
      Text {
        id: timeText
        anchors.left: playButton.right
        anchors.leftMargin: root.theme.space(6)
        anchors.verticalCenter: parent.verticalCenter
        text: root.clock(player.position) + " / " + root.clock(player.duration)
        color: "white"
        font.family: root.theme.font
        font.pixelSize: root.theme.small
      }
      QQC.Slider {
        id: seek
        anchors.left: timeText.right
        anchors.leftMargin: root.theme.space(12)
        anchors.right: parent.right
        anchors.rightMargin: root.theme.space(14)
        anchors.verticalCenter: parent.verticalCenter
        from: 0
        to: Math.max(1, player.duration)
        value: pressed ? value : player.position
        onMoved: player.position = value
      }
    }

    Rectangle {
      visible: root.zoomed
      anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: root.theme.space(16) }
      width: zoomText.implicitWidth + root.theme.space(18)
      height: zoomText.implicitHeight + root.theme.space(8)
      radius: root.theme.radius
      color: Qt.rgba(0, 0, 0, 0.55)
      Text {
        id: zoomText
        anchors.centerIn: parent
        text: Math.round(root.zoom * 100) + "%" + (full.ready ? "" : (root.zoom > 1.2 ? "  · loading full size" : ""))
        color: "white"
        font.family: root.theme.font
        font.pixelSize: root.theme.small
      }
    }
  }

  function clock(ms) {
    var s = Math.floor(Number(ms || 0) / 1000)
    var m = Math.floor(s / 60)
    var h = Math.floor(m / 60)
    var pad = function(n) { return n < 10 ? "0" + n : String(n) }
    return h > 0 ? h + ":" + pad(m % 60) + ":" + pad(s % 60) : m + ":" + pad(s % 60)
  }

  Timer {
    interval: 5000
    repeat: true
    running: root.slideshow && root.visible && !root.isVideo
    onTriggered: root.stepRequested(1)
  }

  Text {
    anchors.centerIn: parent
    visible: root.isVideo && root.videoError !== ""
    text: "This video could not be played"
    color: "white"
    font.family: root.theme.font
    font.pixelSize: root.theme.body
  }

  Text {
    anchors.centerIn: parent
    visible: !root.isVideo && preview.status === Image.Error
    text: "This photo could not be shown"
    color: "white"
    font.family: root.theme.font
    font.pixelSize: root.theme.body
  }

  onVisibleChanged: {
    if (!visible) {
      player.stop()
      slideshow = false
    }
    chrome.poke()
  }
}
