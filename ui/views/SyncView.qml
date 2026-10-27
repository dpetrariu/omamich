import QtQuick
import QtQuick.Controls as QQC
import qs.Ui
import "../components"
import "../lib/Format.js" as Format

// Folder sync, Mimick-style: what is happening now, the folders and their
// rules, when uploads may run, and what went wrong.
Item {
  id: root
  required property var theme
  required property var service

  readonly property string kind: "tiles"
  readonly property bool isForm: editor.visible
  readonly property bool typing: quietStart.activeFocus || quietEnd.activeFocus
  readonly property var status: service.syncStatus || ({})
  readonly property var sync: service.settings && service.settings.sync ? service.settings.sync : ({})
  readonly property var folders: sync.folders || []
  readonly property string statusText: ""
  property var failedFiles: []
  property bool showFailed: false

  signal toast(string text, string tone)
  signal confirm(var options)

  function handleKey(id) {}
  function reload() { service.refreshSync() }

  function folderStatus(id) {
    var list = status.folders || []
    for (var i = 0; i < list.length; i++) if (list[i].id === id) return list[i]
    return null
  }

  function update(patch) {
    service.updateSettings({ sync: patch }, function(r, e) { if (e) root.toast(e.message, "error") })
  }

  function loadFailed() {
    service.call("sync.failed", {}, function(r, e) { if (!root) return; if (!e) root.failedFiles = r })
  }

  // Momentum scrolling with rubber-band ends.
  WheelScroller { flickable: scrollPage; notch: root.theme.space(260) }

  Flickable {
    id: scrollPage
    anchors.fill: parent
    contentHeight: column.implicitHeight + root.theme.space(48)
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    QQC.ScrollBar.vertical: QQC.ScrollBar {}

    Column {
      id: column
      x: Math.max(root.theme.space(18), (parent.width - width) / 2)
      width: Math.min(parent.width - root.theme.space(36), root.theme.space(760))
      spacing: root.theme.space(14)

      PageHeader {
        width: parent.width
        theme: root.theme
        title: "Folder sync"
        subtitle: root.service.syncSummary
        actions: [
          { id: "toggle", label: root.sync.enabled ? "Turn off" : "Turn on", icon: root.sync.enabled ? "pauseCircle" : "playCircle", primary: !root.sync.enabled }
        ]
        onActionTriggered: root.update({ enabled: !root.sync.enabled })
      }

      // Now
      Rectangle {
        width: parent.width
        height: now.implicitHeight + root.theme.space(24)
        radius: root.theme.radius
        color: root.theme.sunken
        border.width: root.theme.borderWidth
        border.color: root.service.syncAttention ? root.theme.urgent : root.theme.border
        Column {
          id: now
          x: root.theme.space(14)
          y: root.theme.space(12)
          width: parent.width - root.theme.space(28)
          spacing: root.theme.space(8)
          Row {
            spacing: root.theme.space(10)
            Glyph {
              name: root.service.syncAttention ? "warning" : root.service.syncBusy ? "sync" : root.sync.enabled ? "cloudCheck" : "cloudOff"
              size: root.theme.heading
              color: root.service.syncAttention ? root.theme.urgent : root.theme.accent
              font.family: root.theme.font
              anchors.verticalCenter: parent.verticalCenter
              RotationAnimation on rotation { running: root.service.syncBusy; from: 0; to: 360; duration: 1400; loops: Animation.Infinite }
            }
            Text {
              textFormat: Text.PlainText
              text: root.service.syncSummary
              color: root.theme.foreground
              font.family: root.theme.font
              font.pixelSize: root.theme.title
              anchors.verticalCenter: parent.verticalCenter
            }
          }
          Text {
            textFormat: Text.PlainText
            text: [root.status.uploaded ? Format.count(root.status.uploaded, "upload") : "",
              root.status.duplicates ? Format.count(root.status.duplicates, "file") + " already in Immich" : "",
              root.status.downloaded ? Format.count(root.status.downloaded, "download") : "",
              root.status.queue ? root.status.queue + " waiting" : ""].filter(function(s) { return s }).join("  ·  ") || "Nothing transferred since Omamich started"
            color: root.theme.dim
            font.family: root.theme.font
            font.pixelSize: root.theme.small
          }
          Text {
            textFormat: Text.PlainText
            visible: !!root.status.lastError
            width: parent.width
            wrapMode: Text.Wrap
            text: root.status.lastError || ""
            color: root.theme.urgent
            font.family: root.theme.font
            font.pixelSize: root.theme.small
          }
          Repeater {
            model: root.status.active || []
            delegate: Column {
              required property var modelData
              width: now.width
              spacing: root.theme.space(3)
              Text {
                width: parent.width
                text: (modelData.direction === "upload" ? "↑ " : "↓ ") + modelData.name
                  + (modelData.total > 0 ? "  " + Format.bytes(modelData.done) + " of " + Format.bytes(modelData.total) : "  " + Format.bytes(modelData.done))
                elide: Text.ElideMiddle
                textFormat: Text.PlainText
                color: root.theme.foreground
                font.family: root.theme.font
                font.pixelSize: root.theme.small
              }
              Rectangle {
                width: parent.width
                height: root.theme.space(3)
                radius: height / 2
                color: root.theme.raised
                Rectangle {
                  height: parent.height
                  radius: parent.radius
                  color: root.theme.accent
                  width: modelData.total > 0 ? parent.width * Math.min(1, modelData.done / modelData.total) : parent.width * 0.15
                }
              }
            }
          }
          Row {
            spacing: root.theme.space(6)
            TextButton {
              theme: root.theme
              text: root.status.paused ? "Resume" : "Pause"
              icon: root.status.paused ? "play" : "pause"
              fontSize: root.theme.small
              onClicked: root.service.call("sync.pause", { paused: !root.status.paused }, function(r) { if (!root) return; if (r) root.service.applySyncStatus(r) })
            }
            TextButton {
              theme: root.theme
              text: "Look for new files"
              icon: "refresh"
              fontSize: root.theme.small
              enabled: root.sync.enabled
              onClicked: root.service.call("sync.rescan", {}, function(r) { if (!root) return; if (r) root.service.applySyncStatus(r) })
            }
            TextButton {
              visible: root.status.failed > 0
              theme: root.theme
              text: "Retry " + Format.count(root.status.failed, "failed file")
              icon: "restore"
              fontSize: root.theme.small
              onClicked: root.service.call("sync.retryFailed", {}, function(r) { if (!root) return; root.toast("Retrying " + Format.count(r, "file"), "info") })
            }
            TextButton {
              visible: root.status.failed > 0
              theme: root.theme
              text: root.showFailed ? "Hide failures" : "Show failures"
              fontSize: root.theme.small
              onClicked: { root.showFailed = !root.showFailed; if (root.showFailed) root.loadFailed() }
            }
            TextButton {
              theme: root.theme
              text: "Export diagnostics..."
              fontSize: root.theme.small
              onClicked: root.service.call("diagnostics.export", {}, function(r, e) {
                if (!root) return
                if (e) return root.toast(e.message, "error")
                root.toast("Saved diagnostics to " + r.directory + ". Nothing private is in them; read them before sharing.", "info")
                Qt.openUrlExternally("file://" + r.directory)
              })
            }
            TextButton {
              visible: root.status.queue > 0
              theme: root.theme
              text: "Clear queue"
              fontSize: root.theme.small
              onClicked: root.service.call("sync.clearQueue", {}, function(r) { if (!root) return; if (r) root.service.applySyncStatus(r) })
            }
          }
          Repeater {
            model: root.showFailed ? root.failedFiles : []
            delegate: Item {
              id: failure
              required property var modelData
              width: now.width
              height: Math.max(failureText.implicitHeight, root.theme.space(28))
              Column {
                id: failureText
                anchors.left: parent.left
                anchors.right: failureButtons.left
                anchors.rightMargin: root.theme.space(8)
                anchors.verticalCenter: parent.verticalCenter
                Text {
                  width: parent.width
                  text: failure.modelData.name
                  textFormat: Text.PlainText
                  elide: Text.ElideMiddle
                  color: root.theme.foreground
                  font.family: root.theme.font
                  font.pixelSize: root.theme.small
                }
                Text {
                  width: parent.width
                  wrapMode: Text.Wrap
                  text: failure.modelData.error + (failure.modelData.attempts > 1 ? "  (" + failure.modelData.attempts + " tries)" : "")
                  textFormat: Text.PlainText
                  color: root.theme.urgent
                  font.family: root.theme.font
                  font.pixelSize: root.theme.caption
                }
              }
              Row {
                id: failureButtons
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                TextButton {
                  theme: root.theme
                  text: "Retry"
                  fontSize: root.theme.caption
                  onClicked: root.service.call("sync.retryFile", { path: failure.modelData.path }, function() { if (!root) return; root.loadFailed() })
                }
                TextButton {
                  theme: root.theme
                  text: "Dismiss"
                  fontSize: root.theme.caption
                  onClicked: root.service.call("sync.dismissFailed", { paths: [failure.modelData.path] }, function() { if (!root) return; root.loadFailed(); root.service.refreshSync() })
                }
              }
            }
          }
          TextButton {
            visible: root.showFailed && root.failedFiles.length > 1
            theme: root.theme
            text: "Dismiss all failures"
            fontSize: root.theme.small
            onClicked: root.service.call("sync.dismissFailed", {}, function() { if (!root) return; root.loadFailed(); root.service.refreshSync() })
          }
        }
      }

      // Folders
      SectionTitle { theme: root.theme; text: "Folders"; action: editor.visible ? "" : "Add a folder"; onActionClicked: { editor.load({}); editor.visible = true } }
      FolderEditor {
        id: editor
        theme: root.theme
        service: root.service
        visible: false
        onSaved: { visible = false; root.toast("Folder saved" + (root.sync.enabled ? "; looking for files" : ". Turn sync on to start"), "info") }
        onCancelled: visible = false
      }
      Text {
        visible: root.folders.length === 0 && !editor.visible
        width: parent.width
        wrapMode: Text.Wrap
        text: "No folders yet. Add one and Omamich uploads what is in it, and whatever lands in it later, to Immich."
        color: root.theme.dim
        font.family: root.theme.font
        font.pixelSize: root.theme.small
      }
      Repeater {
        model: root.folders
        delegate: Rectangle {
          id: folderRow
          required property var modelData
          readonly property var folderState: root.folderStatus(modelData.id)
          width: column.width
          height: folderText.implicitHeight + root.theme.space(20)
          radius: root.theme.radius
          color: "transparent"
          border.width: root.theme.borderWidth
          border.color: root.theme.border
          opacity: modelData.enabled ? 1 : 0.55
          Glyph {
            id: folderIcon
            x: root.theme.space(12)
            anchors.verticalCenter: parent.verticalCenter
            name: folderRow.folderState && !folderRow.folderState.exists ? "warning" : modelData.method === "download" ? "download" : modelData.method === "full" ? "sync" : "upload"
            size: root.theme.icon
            color: folderRow.folderState && !folderRow.folderState.exists ? root.theme.urgent : root.theme.accent
            font.family: root.theme.font
          }
          Column {
            id: folderText
            anchors.left: folderIcon.right
            anchors.leftMargin: root.theme.space(12)
            anchors.right: folderButtons.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: root.theme.space(2)
            Text {
              width: parent.width
              text: modelData.path
              textFormat: Text.PlainText
              elide: Text.ElideMiddle
              color: root.theme.foreground
              font.family: root.theme.font
              font.pixelSize: root.theme.body
            }
            Text {
              width: parent.width
              wrapMode: Text.Wrap
              textFormat: Text.PlainText
              text: {
                var parts = []
                parts.push(modelData.albumPerSubfolder ? "one album per subfolder"
                  : modelData.albumName ? (modelData.method === "download" ? "from" : modelData.method === "full" ? "with" : "into") + " “" + modelData.albumName + "”" : "into the library")
                var c = folderRow.folderState ? folderRow.folderState.counts : null
                if (folderRow.folderState && !folderRow.folderState.exists) parts.push("folder missing")
                else if (c) parts.push(Format.count(c.done, "file") + " synced" + (c.failed ? ", " + c.failed + " failed" : "") + (c.pending ? ", " + c.pending + " waiting" : ""))
                if (modelData.mirrorLocalDeletes) parts.push("deletes mirror to Immich")
                if (modelData.mirrorRemoteDeletes) parts.push("album removals mirror here")
                if (!modelData.enabled) parts.push("off")
                return parts.join("  ·  ")
              }
              color: root.theme.dim
              font.family: root.theme.font
              font.pixelSize: root.theme.caption
            }
          }
          Row {
            id: folderButtons
            anchors.right: parent.right
            anchors.rightMargin: root.theme.space(8)
            anchors.verticalCenter: parent.verticalCenter
            IconButton { theme: root.theme; icon: "open"; tooltip: "Open the folder"; onClicked: Qt.openUrlExternally("file://" + modelData.path) }
            IconButton { theme: root.theme; icon: "edit"; tooltip: "Edit rules..."; onClicked: { editor.load(modelData); editor.visible = true } }
            IconButton {
              theme: root.theme
              icon: "trash"
              color: root.theme.urgent
              tooltip: "Stop syncing this folder..."
              onClicked: root.confirm({
                title: "Stop syncing " + modelData.path + "?",
                message: "Nothing is deleted, here or in Immich. Omamich just stops watching the folder.",
                confirmText: "Stop syncing",
                danger: false,
                onConfirm: function() {
                  root.service.call("sync.folderRemove", { id: modelData.id }, function(r, e) { if (!root) return;
                    if (e) root.toast(e.message, "error")
                    else root.service.applySettingsResponse(r)
                  })
                }
              })
            }
          }
        }
      }

      // When
      SectionTitle { theme: root.theme; text: "When to upload" }
      SwitchRow { theme: root.theme; checked: root.sync.pauseOnMetered === true; text: "Wait while on a metered connection"; detail: "Asks NetworkManager whether the connection is metered."; onToggled: root.update({ pauseOnMetered: !root.sync.pauseOnMetered }) }
      SwitchRow { theme: root.theme; checked: root.sync.pauseOnBattery === true; text: "Wait while on battery"; onToggled: root.update({ pauseOnBattery: !root.sync.pauseOnBattery }) }
      SwitchRow { theme: root.theme; checked: root.sync.startupScan !== false; text: "Catch up on files added while Omamich was not running"; onToggled: root.update({ startupScan: root.sync.startupScan === false }) }
      SwitchRow { theme: root.theme; checked: root.sync.uploadSidecars !== false; text: "Upload XMP sidecars with their photos"; onToggled: root.update({ uploadSidecars: root.sync.uploadSidecars === false }) }
      Row {
        spacing: root.theme.space(10)
        Text { text: "Quiet hours"; color: root.theme.foreground; font.family: root.theme.font; font.pixelSize: root.theme.small; anchors.verticalCenter: parent.verticalCenter; width: root.theme.space(110) }
        TextField {
          id: quietStart
          width: root.theme.space(80)
          placeholderText: "22:00"
          text: root.sync.quietStart || ""
          font.family: root.theme.font
          font.pixelSize: root.theme.body
          onEditingFinished: if (text !== (root.sync.quietStart || "")) root.update({ quietStart: text })
        }
        Text { text: "to"; color: root.theme.dim; font.family: root.theme.font; font.pixelSize: root.theme.small; anchors.verticalCenter: parent.verticalCenter }
        TextField {
          id: quietEnd
          width: root.theme.space(80)
          placeholderText: "07:00"
          text: root.sync.quietEnd || ""
          font.family: root.theme.font
          font.pixelSize: root.theme.body
          onEditingFinished: if (text !== (root.sync.quietEnd || "")) root.update({ quietEnd: text })
        }
        Text { text: "leave empty to upload any time"; color: root.theme.dim; font.family: root.theme.font; font.pixelSize: root.theme.caption; anchors.verticalCenter: parent.verticalCenter }
      }
      Row {
        spacing: root.theme.space(6)
        Text { text: "Uploads at once"; color: root.theme.foreground; font.family: root.theme.font; font.pixelSize: root.theme.small; anchors.verticalCenter: parent.verticalCenter; width: root.theme.space(110) }
        Repeater {
          model: [1, 2, 3, 4, 6, 8]
          delegate: TextButton {
            required property var modelData
            theme: root.theme
            text: String(modelData)
            fontSize: root.theme.small
            selected: root.sync.concurrency === modelData
            onClicked: root.update({ concurrency: modelData })
          }
        }
      }

      // Activity
      SectionTitle { theme: root.theme; text: "Recent activity" }
      Text {
        visible: (root.status.events || []).length === 0
        text: "Nothing yet."
        color: root.theme.dim
        font.family: root.theme.font
        font.pixelSize: root.theme.small
      }
      Repeater {
        model: root.status.events || []
        delegate: Row {
          required property var modelData
          spacing: root.theme.space(10)
          width: column.width
          Glyph {
            name: modelData.kind === "failed" ? "error" : modelData.kind === "downloaded" ? "download" : modelData.kind === "trashed" ? "trash" : modelData.kind === "duplicate" ? "check" : "upload"
            size: root.theme.small + 1
            color: modelData.kind === "failed" ? root.theme.urgent : root.theme.dim
            font.family: root.theme.font
            width: root.theme.space(16)
          }
          Text {
            width: column.width - root.theme.space(120)
            text: modelData.name + " — " + modelData.message
            textFormat: Text.PlainText
            elide: Text.ElideMiddle
            color: modelData.kind === "failed" ? root.theme.urgent : root.theme.foreground
            font.family: root.theme.font
            font.pixelSize: root.theme.small
          }
          Text {
            textFormat: Text.PlainText
            text: Format.ago(modelData.at)
            color: root.theme.dim
            font.family: root.theme.font
            font.pixelSize: root.theme.caption
          }
        }
      }
    }
  }
}
