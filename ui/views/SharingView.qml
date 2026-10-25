import QtQuick
import QtQuick.Controls as QQC
import "../components"
import "../lib/Format.js" as Format

// What you share and what is shared with you: public links, shared albums
// and partners.
Item {
  id: root

  required property var theme
  required property var service

  readonly property string kind: "tiles"
  property var links: []
  property var partners: ({ sharedBy: [], sharedWith: [] })
  property bool loading: false
  property string error: ""
  readonly property var sharedAlbums: service.albums.filter(function(a) { return a.shared })
  readonly property string statusText: Format.count(links.length, "link")

  signal albumOpened(var album)
  signal copied(string url)
  signal toast(string text, string tone)
  signal confirm(var options)
  signal pick(var options)
  signal pickFinished(string message)

  function addPartner() {
    root.service.call("users.list", {}, function(users, e) { if (!root) return;
      if (e) return root.toast(e.message, "error")
      var me = root.service.user ? root.service.user.id : ""
      var taken = {}
      for (var i = 0; i < root.partners.sharedBy.length; i++) taken[root.partners.sharedBy[i].id] = true
      var items = users.filter(function(u) { return u.id !== me && !taken[u.id] }).map(function(u) {
        return { id: u.id, label: u.name || u.email, detail: u.email }
      })
      root.pick({
        title: "Share your library with…",
        subtitle: "They will see all your photos and videos except archived ones.",
        placeholder: "Find someone on this server",
        items: items,
        emptyText: "Nobody else on this server to share with.",
        onPick: function(item) {
          root.service.call("partner.add", { userId: item.id }, function(r, e2) { if (!root) return;
            root.pickFinished(e2 ? e2.message : "")
            if (!e2) root.reload()
          })
          return "pending"
        }
      })
    })
  }

  function handleKey(id) {}
  function reload() {
    loading = true
    service.call("sharedLinks.list", {}, function(r, e) { if (!root) return;
      root.loading = false
      root.error = e ? e.message : ""
      if (!e) root.links = r
    })
    service.call("partners.list", {}, function(r, e) { if (!root) return; if (!e) root.partners = r })
    service.loadAlbums(true)
  }
  Component.onCompleted: reload()

  // Momentum scrolling with rubber-band ends.
  WheelScroller { flickable: scrollPage; notch: root.theme.space(260) }

  Flickable {
    id: scrollPage
    anchors.fill: parent
    contentHeight: column.implicitHeight + root.theme.space(40)
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    QQC.ScrollBar.vertical: QQC.ScrollBar {}

    Column {
      id: column
      x: root.theme.space(18)
      width: parent.width - root.theme.space(36)
      spacing: root.theme.space(16)

      PageHeader {
        x: -root.theme.space(18)
        width: parent.width + root.theme.space(36)
        theme: root.theme
        title: "Sharing"
        subtitle: "Links anyone can open, albums shared with people on this server, and partners"
      }

      SectionTitle { theme: root.theme; text: "Shared links" }
      Text {
        visible: root.links.length === 0
        text: root.loading ? "Loading…" : (root.error || "No links yet. Press s on a photo, or Share on an album, to make one.")
        color: root.error ? root.theme.urgent : root.theme.dim
        font.family: root.theme.font
        font.pixelSize: root.theme.small
      }
      Repeater {
        model: root.links
        delegate: Item {
          id: link
          required property var modelData
          width: column.width
          height: root.theme.space(64)
          Rectangle {
            anchors.fill: parent
            radius: root.theme.radius
            color: hover.containsMouse ? root.theme.hoverFill : "transparent"
            border.width: root.theme.borderWidth
            border.color: root.theme.border
          }
          MouseArea { id: hover; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
          RoundImage {
            id: cover
            x: root.theme.space(10)
            anchors.verticalCenter: parent.verticalCenter
            width: root.theme.space(44); height: width
            radius: root.theme.radius
            fill: root.theme.raised
            sourceSize: 120
            source: link.modelData.coverAssetId ? root.service.thumbUrl(link.modelData.coverAssetId, "thumbnail", "") : ""
          }
          Column {
            anchors.left: cover.right
            anchors.leftMargin: root.theme.space(12)
            anchors.right: linkButtons.left
            anchors.rightMargin: root.theme.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: root.theme.space(2)
            Text {
              width: parent.width
              text: link.modelData.description || (link.modelData.albumName ? "Album “" + link.modelData.albumName + "”" : Format.count(link.modelData.assetCount || 0, "photo"))
              textFormat: Text.PlainText
              elide: Text.ElideRight
              color: root.theme.foreground
              font.family: root.theme.font
              font.pixelSize: root.theme.body
            }
            Text {
              width: parent.width
              text: link.modelData.url
              textFormat: Text.PlainText
              elide: Text.ElideMiddle
              color: root.theme.accent
              font.family: root.theme.font
              font.pixelSize: root.theme.caption
            }
            Text {
              width: parent.width
              text: [link.modelData.expiresAt ? "expires " + Format.shortDate(link.modelData.expiresAt) : "never expires",
                link.modelData.hasPassword ? "password" : "",
                link.modelData.allowDownload ? "downloads allowed" : "view only",
                link.modelData.allowUpload ? "uploads allowed" : ""].filter(function(s) { return s }).join(" · ")
              textFormat: Text.PlainText
              elide: Text.ElideRight
              color: root.theme.dim
              font.family: root.theme.font
              font.pixelSize: root.theme.caption
            }
          }
          Row {
            id: linkButtons
            anchors.right: parent.right
            anchors.rightMargin: root.theme.space(8)
            anchors.verticalCenter: parent.verticalCenter
            IconButton { theme: root.theme; icon: "copy"; tooltip: "Copy link"; onClicked: root.copied(link.modelData.url) }
            IconButton {
              theme: root.theme
              icon: "open"
              tooltip: "Open in the browser"
              onClicked: Qt.openUrlExternally(link.modelData.url)
            }
            IconButton {
              theme: root.theme
              icon: "trash"
              color: root.theme.urgent
              tooltip: "Delete link..."
              onClicked: root.confirm({
                title: "Delete this link?",
                message: "Anyone who has it will no longer be able to open it.",
                confirmText: "Delete link",
                onConfirm: function() {
                  root.service.call("sharedLink.delete", { id: link.modelData.id }, function(r, e) { if (!root) return;
                    if (e) root.toast(e.message, "error")
                    else root.reload()
                  })
                }
              })
            }
          }
        }
      }

      SectionTitle { theme: root.theme; text: "Shared albums" }
      Text {
        visible: root.sharedAlbums.length === 0
        text: "No albums are shared with or by you."
        color: root.theme.dim
        font.family: root.theme.font
        font.pixelSize: root.theme.small
      }
      Flow {
        width: parent.width
        spacing: root.theme.space(8)
        Repeater {
          model: root.sharedAlbums
          delegate: TextButton {
            required property var modelData
            theme: root.theme
            text: modelData.albumName + "  ·  " + (modelData.ownerName && root.service.user && modelData.ownerId !== root.service.user.id ? "from " + modelData.ownerName : Format.count((modelData.users || []).length, "person", "people"))
            icon: "albums"
            onClicked: root.albumOpened(modelData)
          }
        }
      }

      SectionTitle {
        theme: root.theme
        text: "Partners"
        action: "Share my library..."
        onActionClicked: root.addPartner()
      }
      Text {
        width: parent.width
        wrapMode: Text.Wrap
        text: "A partner sees all your photos and videos (not archived ones), and can show them in their own timeline."
        color: root.theme.dim
        font.family: root.theme.font
        font.pixelSize: root.theme.small
      }
      Text {
        visible: root.partners.sharedBy.length === 0
        text: "You do not share your library with anyone."
        color: root.theme.dim
        font.family: root.theme.font
        font.pixelSize: root.theme.small
      }
      Repeater {
        model: root.partners.sharedBy
        delegate: PartnerRow {
          required property var modelData
          theme: root.theme
          width: column.width
          partner: modelData
          detail: "can see your library"
          actionText: "Stop sharing..."
          onAction: root.confirm({
            title: "Stop sharing your library with " + (modelData.name || modelData.email) + "?",
            message: "They will no longer see your photos. Nothing is deleted.",
            confirmText: "Stop sharing",
            danger: false,
            onConfirm: function() {
              root.service.call("partner.remove", { userId: modelData.id }, function(r, e) { if (!root) return;
                if (e) root.toast(e.message, "error")
                else root.reload()
              })
            }
          })
        }
      }
      Text {
        visible: root.partners.sharedWith.length > 0
        topPadding: root.theme.space(6)
        text: "Shared with you"
        color: root.theme.foreground
        font.family: root.theme.font
        font.pixelSize: root.theme.body
      }
      Repeater {
        model: root.partners.sharedWith
        delegate: PartnerRow {
          required property var modelData
          theme: root.theme
          width: column.width
          partner: modelData
          detail: modelData.inTimeline ? "their photos are in your timeline" : "their photos are not in your timeline"
          actionText: modelData.inTimeline ? "Hide from my timeline" : "Show in my timeline"
          onAction: root.service.call("partner.timeline", { userId: modelData.id, inTimeline: !modelData.inTimeline }, function(r, e) { if (!root) return;
            if (e) return root.toast(e.message, "error")
            root.reload()
            root.service.libraryChanged()
          })
        }
      }
    }
  }
}
