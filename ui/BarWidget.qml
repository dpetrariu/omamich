import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "components"

// One icon and one click. A dot says folder sync is working; the icon turns
// the urgent colour when sync needs attention. The tooltip says which.
BarWidget {
  id: root

  moduleName: "dpetrariu.omamich"

  readonly property var service: bar && bar.shell ? bar.shell.serviceFor("dpetrariu.omamich") : null
  readonly property color foreground: bar ? bar.barForeground : Commons.Color.foreground

  function pushSettings() {
    if (service && typeof service.applySettings === "function") service.applySettings(settings)
  }
  onSettingsChanged: pushSettings()
  onServiceChanged: pushSettings()
  Component.onCompleted: pushSettings()

  function openWindow(payload) {
    if (!bar || !bar.shell) return
    var text = JSON.stringify(payload || {})
    if (payload && typeof bar.shell.summon === "function") bar.shell.summon("dpetrariu.omamich", text)
    else if (typeof bar.shell.toggle === "function") bar.shell.toggle("dpetrariu.omamich", text)
  }

  readonly property bool drawsIcon: !service || service.showBarIcon
  visible: drawsIcon
  implicitWidth: drawsIcon ? button.implicitWidth : 0
  implicitHeight: drawsIcon ? button.implicitHeight : 0

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: {
      if (!root.service) return "Omamich"
      if (!root.service.ready) return "Omamich — starting"
      if (!root.service.configured) return "Omamich — add your Immich server"
      return "Omamich — " + root.service.syncSummary
    }

    readonly property bool busy: !!root.service && root.service.syncBusy
    readonly property bool attention: !!root.service && root.service.syncAttention

    iconComponent: Component {
      Item {
        Mark {
          anchors.centerIn: parent
          size: Style.bar.iconFont
          color: button.attention ? Commons.Color.urgent : root.foreground
        }
        Rectangle {
          visible: button.busy
          width: Style.space(5)
          height: width
          radius: width / 2
          color: Commons.Color.accent
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.rightMargin: -Style.space(1)
        }
      }
    }

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.openWindow({ section: "sync" })
      else root.openWindow(null)
    }
  }

  Rectangle {
    readonly property bool vertical: !!root.bar && root.bar.vertical
    visible: !!root.service && root.service.windowOpen
    color: Commons.Color.accent
    radius: Math.min(width, height) / 2
    width: vertical ? Style.space(2) : Style.space(10)
    height: vertical ? Style.space(10) : Style.space(2)
    x: vertical ? (root.bar.position === "left" ? root.width - width - Style.space(2) : Style.space(2))
      : Math.round((root.width - width) / 2)
    y: vertical ? Math.round((root.height - height) / 2)
      : (root.bar && root.bar.position === "top" ? root.height - height - Style.space(2) : Style.space(2))
  }
}
