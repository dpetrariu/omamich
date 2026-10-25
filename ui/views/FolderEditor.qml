import QtQuick
import QtQuick.Dialogs
import qs.Ui
import "../components"

// One watched folder's rules. A folder without an album can only upload;
// the album-dependent rules say so instead of pretending to work.
Rectangle {
  id: root
  required property var theme
  required property var service
  property var folder: ({})
  property string error: ""
  property bool busy: false

  signal saved()
  signal cancelled()

  property bool perSubfolder: false
  readonly property bool hasAlbum: albumField.text.trim() !== "" && !perSubfolder
  readonly property bool usesAlbums: albumField.text.trim() !== "" || perSubfolder
  property string method: "upload"
  property bool ignoreHidden: true
  property bool mirrorLocal: false
  property bool mirrorRemote: false
  property bool enabledFolder: true

  function load(f) {
    folder = f || {}
    pathField.text = folder.path || ""
    albumField.text = folder.albumName || ""
    extField.text = (folder.extensions || []).join(", ")
    sizeField.text = folder.maxFileSizeMb ? String(folder.maxFileSizeMb) : ""
    method = folder.method || "upload"
    ignoreHidden = folder.ignoreHidden !== false
    mirrorLocal = folder.mirrorLocalDeletes === true
    mirrorRemote = folder.mirrorRemoteDeletes === true
    enabledFolder = folder.enabled !== false
    perSubfolder = folder.albumPerSubfolder === true
    error = ""
    busy = false
  }

  function save() {
    error = ""
    busy = true
    var next = {
      id: folder.id || "",
      path: pathField.text.trim(),
      enabled: enabledFolder,
      albumName: albumField.text.trim(),
      albumId: albumField.text.trim() === (folder.albumName || "") ? (folder.albumId || "") : "",
      method: hasAlbum ? method : "upload",
      ignoreHidden: ignoreHidden,
      maxFileSizeMb: Number(sizeField.text) || 0,
      extensions: extField.text.split(/[\s,]+/).filter(function(s) { return s }),
      albumPerSubfolder: perSubfolder,
      mirrorLocalDeletes: usesAlbums && (perSubfolder || method !== "download") && mirrorLocal,
      mirrorRemoteDeletes: hasAlbum && method !== "upload" && mirrorRemote
    }
    service.call("sync.folderSave", { folder: next }, function(r, e) { if (!root) return;
      root.busy = false
      if (e) { root.error = e.message; return }
      root.service.applySettingsResponse(r)
      root.saved()
    })
  }

  width: parent ? parent.width : 0
  height: form.implicitHeight + theme.space(28)
  radius: theme.radius
  color: theme.sunken
  border.width: theme.borderWidth
  border.color: theme.accent

  FolderDialog {
    id: picker
    title: "Choose a folder to sync"
    onAccepted: pathField.text = decodeURIComponent(String(selectedFolder).replace(/^file:\/\//, ""))
  }

  Column {
    id: form
    x: root.theme.space(14)
    y: root.theme.space(14)
    width: parent.width - root.theme.space(28)
    spacing: root.theme.space(10)

    Text { text: root.folder.id ? "Edit folder" : "Add a folder"; color: root.theme.foreground; font.family: root.theme.font; font.pixelSize: root.theme.title }

    Text { text: "Folder"; color: root.theme.dim; font.family: root.theme.font; font.pixelSize: root.theme.small }
    Row {
      width: parent.width
      spacing: root.theme.space(8)
      TextField {
        id: pathField
        width: parent.width - browse.width - root.theme.space(8)
        placeholderText: "~/Pictures/Camera"
        font.family: root.theme.font
        font.pixelSize: root.theme.body
      }
      TextButton { id: browse; theme: root.theme; text: "Browse..."; onClicked: picker.open() }
    }

    SwitchRow {
      theme: root.theme
      checked: root.perSubfolder
      text: "One album per subfolder"
      detail: "Photos in Trips/Rome go into an album called Rome. Uploads only."
      onToggled: root.perSubfolder = !root.perSubfolder
    }

    Text {
      text: root.perSubfolder ? "Album for files directly in the folder (optional)" : "Album (optional)"
      color: root.theme.dim
      font.family: root.theme.font
      font.pixelSize: root.theme.small
    }
    TextField {
      id: albumField
      width: parent.width
      placeholderText: "Leave empty to upload into the library only"
      font.family: root.theme.font
      font.pixelSize: root.theme.body
    }

    Text { text: "Direction"; color: root.theme.dim; font.family: root.theme.font; font.pixelSize: root.theme.small }
    Row {
      spacing: root.theme.space(6)
      TextButton { theme: root.theme; text: "Upload"; icon: "upload"; fontSize: root.theme.small; selected: root.method === "upload" || !root.hasAlbum; onClicked: root.method = "upload" }
      TextButton { theme: root.theme; text: "Download album"; icon: "download"; fontSize: root.theme.small; enabled: root.hasAlbum; selected: root.hasAlbum && root.method === "download"; onClicked: root.method = "download" }
      TextButton { theme: root.theme; text: "Both ways"; icon: "sync"; fontSize: root.theme.small; enabled: root.hasAlbum; selected: root.hasAlbum && root.method === "full"; onClicked: root.method = "full" }
    }
    Text {
      width: parent.width
      wrapMode: Text.Wrap
      text: root.perSubfolder ? "Each subfolder's photos go into an album named after it" + (albumField.text.trim() ? "; loose files go into “" + albumField.text.trim() + "”." : "; loose files go into an album named after this folder.")
        : !root.hasAlbum ? "Without an album, new files here upload into your library."
        : root.method === "upload" ? "New files here upload and are added to “" + albumField.text.trim() + "” (created if needed)."
        : root.method === "download" ? "Photos in “" + albumField.text.trim() + "” are downloaded into this folder."
        : "New files here upload into “" + albumField.text.trim() + "”, and photos added to it elsewhere download here."
      color: root.theme.dim
      font.family: root.theme.font
      font.pixelSize: root.theme.caption
    }

    Row {
      width: parent.width
      spacing: root.theme.space(12)
      Column {
        width: (parent.width - root.theme.space(12)) / 2
        spacing: root.theme.space(6)
        Text { text: "Only these types (optional)"; color: root.theme.dim; font.family: root.theme.font; font.pixelSize: root.theme.small }
        TextField { id: extField; width: parent.width; placeholderText: "jpg, heic, mp4"; font.family: root.theme.font; font.pixelSize: root.theme.body }
      }
      Column {
        width: (parent.width - root.theme.space(12)) / 2
        spacing: root.theme.space(6)
        Text { text: "Largest file, MB (optional)"; color: root.theme.dim; font.family: root.theme.font; font.pixelSize: root.theme.small }
        TextField { id: sizeField; width: parent.width; placeholderText: "no limit"; inputMethodHints: Qt.ImhDigitsOnly; font.family: root.theme.font; font.pixelSize: root.theme.body }
      }
    }

    SwitchRow { theme: root.theme; checked: root.ignoreHidden; text: "Skip hidden files and folders"; onToggled: root.ignoreHidden = !root.ignoreHidden }
    SwitchRow {
      theme: root.theme
      checked: root.mirrorLocal
      enabled: root.usesAlbums && (root.perSubfolder || root.method !== "download")
      text: "Deleting a file here moves it to the Immich trash"
      detail: root.usesAlbums ? "Only photos this folder uploaded. A file moved to another synced folder is not deleted." : "Needs an album."
      onToggled: root.mirrorLocal = !root.mirrorLocal
    }
    SwitchRow {
      theme: root.theme
      checked: root.mirrorRemote
      enabled: root.hasAlbum && root.method !== "upload"
      text: "Removing a photo from the album moves the file here to the trash"
      detail: root.hasAlbum ? "Files go to your desktop trash, so they can be restored." : "Needs an album."
      onToggled: root.mirrorRemote = !root.mirrorRemote
    }
    SwitchRow { theme: root.theme; checked: root.enabledFolder; text: "Sync this folder"; onToggled: root.enabledFolder = !root.enabledFolder }

    Text {
      visible: root.error !== ""
      width: parent.width
      wrapMode: Text.Wrap
      text: root.error
      color: root.theme.urgent
      font.family: root.theme.font
      font.pixelSize: root.theme.small
    }

    Row {
      anchors.right: parent.right
      spacing: root.theme.space(8)
      TextButton { theme: root.theme; text: "Cancel"; onClicked: root.cancelled() }
      TextButton { theme: root.theme; text: root.folder.id ? "Save" : "Add folder"; primary: true; busy: root.busy; onClicked: root.save() }
    }
  }
}
