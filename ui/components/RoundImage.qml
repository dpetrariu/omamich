import QtQuick
import QtQuick.Effects

// An image clipped to a rounded rectangle or a circle (radius = width / 2).
Item {
  id: root

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
    visible: false
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
    layer.enabled: true
    Rectangle {
      anchors.fill: parent
      radius: root.radius
      color: "black"
    }
  }

  MultiEffect {
    anchors.fill: parent
    source: image
    visible: image.status === Image.Ready
    maskEnabled: true
    maskSource: mask
    maskThresholdMin: 0.5
    maskSpreadAtMin: 1.0
  }
}
