import QtQuick
import QtTest
import "../../ui/components"

// Hovering and clicking a photo tile with a real (synthetic) mouse.
Item {
  id: scene
  width: 400
  height: 300

  QtObject {
    id: theme
    property color foreground: "white"
    property color background: "black"
    property color accent: "steelblue"
    property color accentFill: "#334455"
    property color raised: "#222222"
    property color urgent: "red"
    property color dim: "grey"
    property int radius: 0
    property string font: "monospace"
    property int icon: 14
    property int small: 11
    property int caption: 10
    property int display: 24
    function space(px) { return px }
  }

  QtObject {
    id: service
    function thumbUrl(id, size, version) { return "" }
  }

  PhotoTile {
    id: tile
    x: 20
    y: 20
    width: 240
    height: 180
    theme: theme
    service: service
    asset: ({ id: "a", isImage: true, ratio: 1.33, isFavorite: false })
  }

  SignalSpy { id: opened; target: tile; signalName: "clicked" }
  SignalSpy { id: toggled; target: tile; signalName: "toggleSelect" }

  TestCase {
    name: "PhotoTile"
    when: windowShown

    function circle() {
      return findChild(tile, "selectCircle")
    }

    function test_circle_stays_while_hovered_and_selects() {
      opened.clear()
      toggled.clear()
      mouseMove(scene, 140, 110)                 // over the photo
      tryVerify(function() { return circle().visible }, 500, "the circle shows on hover")
      var c = circle().mapToItem(scene, circle().width / 2, circle().height / 2)
      // Move onto the circle in small steps; it must never disappear.
      for (var i = 0; i <= 10; i++) {
        mouseMove(scene, 140 + (c.x - 140) * i / 10, 110 + (c.y - 110) * i / 10)
        wait(15)
        verify(circle().visible, "the circle vanished at step " + i)
      }
      wait(100)
      verify(circle().visible, "the circle stays while the pointer is on it")
      mouseClick(scene, c.x, c.y)
      compare(toggled.count, 1, "clicking the circle selects")
      compare(opened.count, 0, "clicking the circle does not open the photo")
    }

    function test_clicking_the_photo_opens_it() {
      opened.clear()
      toggled.clear()
      mouseMove(scene, 160, 150)
      mouseClick(scene, 160, 150)
      compare(opened.count, 1)
      compare(toggled.count, 0)
    }
  }
}
