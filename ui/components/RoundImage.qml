import QtQuick
import QtQuick.Effects

// An image clipped to a rounded rectangle or a circle (radius = width / 2).
// The rounding is a shader effect, which Qt's software renderer (no GPU, or
// the off-screen tests) does not draw at all: there the image is shown
// unrounded rather than not at all.
Item {
  id: root
  readonly property bool rounded: root.GraphicsInfo.api !== GraphicsInfo.Software

  property alias source: image.source
  property real radius: 0
  property color fill: "transparent"
  property int sourceSize: 256
  readonly property bool ready: image.status === Image.Ready

  Rectangle {
    anchors.fill: parent
    radius: root.radius
    color: root.fill
  }

  Image {
    id: image
    anchors.fill: parent
    visible: !root.rounded
    fillMode: Image.PreserveAspectCrop
    asynchronous: true
    cache: true
    sourceSize.width: root.sourceSize
    sourceSize.height: root.sourceSize
  }

  Item {
    id: mask
    anchors.fill: parent
    visible: false
    layer.enabled: root.rounded
    Rectangle {
      anchors.fill: parent
      radius: root.radius
      color: "black"
    }
  }

  MultiEffect {
    anchors.fill: parent
    source: image
    visible: root.rounded && image.status === Image.Ready
    maskEnabled: true
    maskSource: mask
    maskThresholdMin: 0.5
    maskSpreadAtMin: 1.0
  }
}
