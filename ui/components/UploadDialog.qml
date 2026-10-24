import QtQuick
import QtQuick.Dialogs

// Pick files to upload by hand. They go through the same queue as folder
// sync, so progress shows in Folder sync.
Item {
  id: root
  required property var service
  property string albumId: ""
  signal queued(int count)

  function open() { picker.open() }

  FileDialog {
    id: picker
    title: "Upload photos and videos to Immich"
    fileMode: FileDialog.OpenFiles
    nameFilters: ["Photos and videos (*.jpg *.jpeg *.png *.heic *.heif *.webp *.avif *.gif *.tif *.tiff *.dng *.cr2 *.cr3 *.nef *.arw *.raf *.orf *.rw2 *.jxl *.mp4 *.mov *.m4v *.mkv *.webm *.avi *.3gp *.mts)", "All files (*)"]
    onAccepted: {
      var paths = []
      for (var i = 0; i < selectedFiles.length; i++) paths.push(String(selectedFiles[i]))
      root.service.call("sync.uploadFiles", { paths: paths, albumId: root.albumId }, function(r, e) { if (!root) return;
        root.queued(e ? 0 : r.queued)
      })
    }
  }
}
