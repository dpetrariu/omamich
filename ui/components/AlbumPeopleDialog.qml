import QtQuick
import qs.Ui
import "../lib/Format.js" as Format

// Who an album is shared with on this server, and as what: viewers can
// look, editors can also add photos. People can be added, changed and
// removed here; public links live in the Share dialog.
Sheet {
  id: root

  required property var service
  property var album: null
  property var users: []
  property bool loading: false
  property string error: ""
  property string busyId: ""
  property string addRole: "editor"
  readonly property string me: service.user ? service.user.id : ""
  readonly property bool mine: !!album && album.ownerId === me
  readonly property var members: album && album.users ? album.users : []
  readonly property var candidates: users.filter(function(u) {
    if (u.id === root.me || (root.album && u.id === root.album.ownerId)) return false
    for (var i = 0; i < root.members.length; i++) if (root.members[i].id === u.id) return false
    var q = filter.text.trim().toLowerCase()
    return !q || String(u.name || "").toLowerCase().indexOf(q) >= 0 || String(u.email || "").toLowerCase().indexOf(q) >= 0
  })

  signal albumUpdated(var album)

  function ask(a) {
    album = a
    title = "People in “" + a.albumName + "”"
    subtitle = "Share with people who have an account on this Immich server."
    error = ""
    busyId = ""
    filter.text = ""
    opened = true
    loading = true
    service.call("users.list", {}, function(r, e) { if (!root) return;
      root.loading = false
      if (e) root.error = e.message
      else root.users = r
    })
  }

  function apply(method, params, userId) {
    busyId = userId
    error = ""
    service.call(method, Object.assign({ id: album.id }, params), function(r, e) { if (!root) return;
      root.busyId = ""
      if (e) {
        root.error = e.message
        return
      }
      // Removing someone answers with nothing; read the album again.
      if (r && r.id) {
        root.album = r
        root.albumUpdated(r)
      } else {
        root.service.call("album.get", { id: root.album.id }, function(a, e2) { if (!root) return;
          if (!e2) {
            root.album = a
            root.albumUpdated(a)
          }
        })
      }
    })
  }

  Column {
    width: parent.width
    spacing: root.theme.space(10)

    Text {
      visible: root.members.length === 0
      text: "Only you can see this album."
      color: root.theme.dim
      font.family: root.theme.font
      font.pixelSize: root.theme.small
    }

    Repeater {
      model: root.members
      delegate: Item {
        id: member
        required property var modelData
        width: parent.width
        height: root.theme.space(36)
        Column {
          anchors.left: parent.left
          anchors.right: roles.left
          anchors.verticalCenter: parent.verticalCenter
          Text {
            width: parent.width
            text: member.modelData.name || member.modelData.email || ""
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: root.theme.foreground
            font.family: root.theme.font
            font.pixelSize: root.theme.body
          }
          Text {
            width: parent.width
            text: member.modelData.email || ""
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: root.theme.dim
            font.family: root.theme.font
            font.pixelSize: root.theme.caption
          }
        }
        Row {
          id: roles
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: root.theme.space(4)
          opacity: root.busyId === member.modelData.id ? 0.5 : 1
          TextButton {
            theme: root.theme
            text: "Viewer"
            fontSize: root.theme.small
            enabled: root.mine
            selected: member.modelData.role === "viewer"
            onClicked: if (member.modelData.role !== "viewer") root.apply("album.setRole", { userId: member.modelData.id, role: "viewer" }, member.modelData.id)
          }
          TextButton {
            theme: root.theme
            text: "Editor"
            fontSize: root.theme.small
            enabled: root.mine
            selected: member.modelData.role === "editor"
            onClicked: if (member.modelData.role !== "editor") root.apply("album.setRole", { userId: member.modelData.id, role: "editor" }, member.modelData.id)
          }
          IconButton {
            theme: root.theme
            icon: "close"
            color: root.theme.urgent
            visible: root.mine || member.modelData.id === root.me
            tooltip: member.modelData.id === root.me ? "Leave this album" : "Remove from the album"
            onClicked: root.apply("album.unshare", { userId: member.modelData.id === root.me ? "me" : member.modelData.id }, member.modelData.id)
          }
        }
      }
    }

    Rectangle {
      visible: root.mine
      width: parent.width
      height: root.theme.borderWidth
      color: root.theme.border
    }

    Row {
      visible: root.mine
      spacing: root.theme.space(6)
      Text {
        text: "Add as"
        color: root.theme.dim
        font.family: root.theme.font
        font.pixelSize: root.theme.small
        anchors.verticalCenter: parent.verticalCenter
      }
      TextButton { theme: root.theme; text: "Viewer"; fontSize: root.theme.small; selected: root.addRole === "viewer"; onClicked: root.addRole = "viewer" }
      TextButton { theme: root.theme; text: "Editor"; fontSize: root.theme.small; selected: root.addRole === "editor"; onClicked: root.addRole = "editor" }
    }

    TextField {
      id: filter
      visible: root.mine
      width: parent.width
      placeholderText: "Find someone on this server"
      font.family: root.theme.font
      font.pixelSize: root.theme.body
    }

    Repeater {
      model: root.mine ? root.candidates.slice(0, 8) : []
      delegate: Item {
        id: candidate
        required property var modelData
        width: parent.width
        height: root.theme.space(34)
        Rectangle {
          anchors.fill: parent
          radius: root.theme.radius
          color: addMouse.containsMouse ? root.theme.hoverFill : "transparent"
        }
        Text {
          x: root.theme.space(8)
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - root.theme.space(80)
          text: (candidate.modelData.name || "") + "  " + (candidate.modelData.email || "")
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: root.theme.foreground
          font.family: root.theme.font
          font.pixelSize: root.theme.small
        }
        Text {
          anchors.right: parent.right
          anchors.rightMargin: root.theme.space(8)
          anchors.verticalCenter: parent.verticalCenter
          text: "Add"
          color: root.theme.accent
          font.family: root.theme.font
          font.pixelSize: root.theme.small
        }
        MouseArea {
          id: addMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.apply("album.share", { userId: candidate.modelData.id, role: root.addRole }, candidate.modelData.id)
        }
      }
    }

    Text {
      visible: root.mine && !root.loading && root.candidates.length === 0
      width: parent.width
      wrapMode: Text.Wrap
      text: root.users.length <= 1 ? "Nobody else has an account on this server yet." : "Everyone matching is already in the album."
      color: root.theme.dim
      font.family: root.theme.font
      font.pixelSize: root.theme.small
    }

    Text {
      visible: root.error !== ""
      width: parent.width
      wrapMode: Text.Wrap
      text: root.error
      color: root.theme.urgent
      font.family: root.theme.font
      font.pixelSize: root.theme.small
    }

    TextButton {
      anchors.right: parent.right
      theme: root.theme
      text: "Done"
      primary: true
      onClicked: root.close()
    }
  }
}
