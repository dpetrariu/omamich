#!/usr/bin/env python3
"""Drive the real Omamich window off-screen against the seeded mock Immich.

Quickshell runs with QT_QPA_PLATFORM=offscreen and tests/ui/shell.qml as its
shell, so nothing appears on the desktop and no real library is involved.
Screenshots of each step land in $OMAMICH_UI_SHOTS (or a temp folder).

usage: ui_e2e.py path/to/omamich
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sync_e2e import KEY, free_port, wait_for, _ping  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
SHELL = "/usr/share/omarchy/shell"


class Harness:
    def __init__(self, binary, port, root, shots):
        self.root = root
        self.shots = shots
        self.port = port
        qs_dir = os.path.join(root, "qs")
        os.makedirs(qs_dir)
        for name in ("Commons", "Ui"):
            os.symlink(os.path.join(SHELL, name), os.path.join(qs_dir, name))
        shutil.copy(os.path.join(HERE, "ui", "shell.qml"), qs_dir)
        self.shell = os.path.join(qs_dir, "shell.qml")
        home = os.path.join(root, "home")
        os.makedirs(os.path.join(home, "config"))
        with open(os.path.join(home, "config", "config.json"), "w") as f:
            json.dump({"serverUrl": f"http://127.0.0.1:{port}", "serverEnabled": True}, f)
        with open(os.path.join(home, "config", "api-key"), "w") as f:
            f.write(KEY)
        self.env = dict(os.environ, QT_QPA_PLATFORM="offscreen", WAYLAND_DISPLAY="",
                        OMAMICH_UI=os.path.join(REPO, "ui"), OMAMICH_BIN=binary, OMAMICH_HOME=home,
                        XDG_DATA_HOME=os.path.join(root, "xdg"))
        self.log = open(os.path.join(root, "qs.log"), "w")
        self.proc = subprocess.Popen(["qs", "-p", self.shell], env=self.env, stdout=self.log, stderr=subprocess.STDOUT)

    def ipc(self, *args):
        out = subprocess.run(["qs", "-p", self.shell, "ipc", "call", "test", *args], env=self.env,
                             capture_output=True, text=True, timeout=30)
        return out.stdout.strip()

    def js(self, code):
        result = self.ipc("js", code)
        if result.startswith("error:"):
            raise AssertionError(f"{code} -> {result}")
        return result

    def value(self, code):
        return json.loads(self.js(f"JSON.stringify({code})"))

    def nav(self, action, settle=0.6):
        assert self.ipc("nav", action) == "ok", action
        time.sleep(settle)

    def key(self, action, settle=0.6):
        self.ipc("key", action)
        time.sleep(settle)

    def shot(self, name):
        path = os.path.join(self.shots, name + ".png")
        self.ipc("shot", path)
        time.sleep(0.8)
        return path

    def errors(self):
        self.log.flush()
        with open(os.path.join(self.root, "qs.log")) as f:
            return [line for line in f if "omamich" in line and ("TypeError" in line or "ReferenceError" in line
                    or "unavailable" in line or "Error:" in line or "is not a type" in line or "Unable to assign" in line
                    or "Cannot assign" in line or "Binding loop" in line)]

    def stop(self):
        self.proc.terminate()
        try:
            self.proc.wait(5)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def state(port):
    return json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/_state"))


def fetch(port, path):
    request = urllib.request.Request(f"http://127.0.0.1:{port}{path}", headers={"x-api-key": KEY})
    return urllib.request.urlopen(request).read()


def set_prefs(port, **prefs):
    request = urllib.request.Request(f"http://127.0.0.1:{port}/_prefs", data=json.dumps(prefs).encode(),
                                     headers={"x-api-key": KEY, "Content-Type": "application/json"}, method="POST")
    urllib.request.urlopen(request).read()


def mock_png(color):
    sys.path.insert(0, HERE)
    import mock_immich
    return mock_immich.png(64, 48, color)


def asset_named(port, name):
    return next(k for k, v in state(port)["assets"].items() if v["name"] == name)


def main():
    binary = os.path.abspath(sys.argv[1])
    port = free_port()
    mock = subprocess.Popen([sys.executable, "-I", os.path.join(HERE, "mock_immich.py"), str(port), "--seed"])
    root = tempfile.mkdtemp(prefix="omamich-ui-")
    shots = os.environ.get("OMAMICH_UI_SHOTS") or os.path.join(root, "shots")
    os.makedirs(shots, exist_ok=True)
    h = None
    try:
        wait_for("mock is up", lambda: _ping(port), 10)
        h = Harness(binary, port, root, shots)
        wait_for("the window is up and connected", lambda: h.ipc("ready") == "yes", 30)
        wait_for("the timeline loads", lambda: h.value("app.activeGrid() ? app.activeGrid().total : 0") == 40, 20)
        time.sleep(1.5)
        h.shot("01-photos")

        # Partner photos join the timeline once shown there.
        h.js("service.call('partner.timeline', { userId: '11111111-1111-4111-8111-222222222222', inTimeline: true }, function() { app.refreshContent() })")
        wait_for("partner photos appear", lambda: h.value("app.activeGrid().total") == 44, 15)
        print("ok: timeline, months and partner photos")

        # Momentum scrolling: a wheel notch glides a good step and settles; a
        # flick into the top stretches past it and springs back; a key catches
        # a glide.
        w = "app.activeGrid().wheel"
        lv = "app.activeGrid().scrollView"
        h.js(f"{w}.scrollBy(-1000000)")
        time.sleep(0.4)
        top = h.value(f"{lv}.originY - {lv}.topMargin")
        bottom = h.value(f"{lv}.originY + {lv}.contentHeight + {lv}.bottomMargin - {lv}.height")
        assert bottom - top > 300, ("the timeline is too short to scroll", top, bottom)
        notch = h.value(w + ".notch")
        h.js(f"{w}.handle(0, -120, 0, 0, false, 200, 0)")
        time.sleep(1.6)
        moved = h.value(lv + ".contentY") - top
        assert abs(moved - min(notch, bottom - top)) < notch * 0.03 + 2 and h.value(w + ".active") is False, (moved, notch)
        h.js(f"{w}.scrollBy(-1000000)")
        h.js(f"{w}.scrollBy({min(600, bottom - top)})")
        time.sleep(0.3)
        h.js(f"({w}.handle(0, 0, 0, 0, false, 200, 1, 1000), " + ", ".join(f"{w}.handle(0, 0, 0, 60, false, 200, 2, {1000 + 16 * (i + 1)})" for i in range(6)) + f", {w}.handle(0, 0, 0, 0, false, 200, 3, 1100))")
        time.sleep(2.0)
        assert h.value(w + ".peakStretch") > 10, h.value(w + ".peakStretch")
        assert abs(h.value(lv + ".contentY") - top) < 0.5 and h.value(w + ".active") is False, "the bounce did not settle on the top"
        h.js(f"({w}.handle(0, 0, 0, 0, false, 200, 1, 5000), " + ", ".join(f"{w}.handle(0, 0, 0, -40, false, 200, 2, {5000 + 16 * (i + 1)})" for i in range(6)) + f", {w}.handle(0, 0, 0, 0, false, 200, 3, 5100))")
        time.sleep(0.1)
        h.nav("down")
        assert h.value(w + ".active") is False, "a key did not stop the glide"
        h.nav("first")
        print("ok: momentum scrolling and rubber-band ends")

        # Keyboard movement and the viewer.
        first = h.value("app.activeGrid().currentAsset().id")
        h.nav("right")
        assert h.value("app.activeGrid().currentAsset().id") != first
        h.nav("down")
        h.nav("open", 1.5)
        viewing = h.value("app.viewerAsset.id")
        assert viewing == h.value("app.activeGrid().currentAsset().id")
        h.nav("info", 1.5)
        wait_for("details load", lambda: h.value("hooks.viewer.details ? hooks.viewer.details.originalFileName : ''") != "")
        h.shot("02-viewer-details")
        h.nav("next", 1)
        assert h.value("app.viewerAsset.id") != viewing
        h.nav("previous", 1)
        assert h.value("app.viewerAsset.id") == viewing
        print("ok: cursor, viewer, details, next and previous")

        # Photo actions from the viewer.
        h.key("favorite", 1)
        assert state(port)["assets"][viewing]["favorite"] is True
        h.key("favorite", 1)
        assert state(port)["assets"][viewing]["favorite"] is False
        h.js("app.runShortcut('rate', '3')")
        time.sleep(1)
        assert state(port)["assets"][viewing]["rating"] == 3
        h.key("editDate", 0.8)
        assert h.value("hooks.prompt.opened") is True
        h.js("hooks.prompt.submitText('not a date')")
        time.sleep(0.4)
        assert "look like" in h.value("hooks.prompt.error")
        h.js("hooks.prompt.submitText('2023-07-14 09:30')")
        wait_for("the date changes", lambda: state(port)["assets"][viewing]["date"].startswith("2023-07-14"))
        assert h.value("hooks.prompt.opened") is False
        h.shot("03-after-date-edit")
        h.nav("back", 2)
        assert h.value("app.viewerAsset") is None
        wait_for("the photo moved to its new month", lambda: h.value("app.activeGrid().buckets.map(function(b){return b.key}).indexOf('2023-07-01') >= 0"))
        print("ok: favourite, rating, date edit and the grid reloading after it")

        # Selection, trash and Undo.
        h.nav("first")
        a = h.value("app.activeGrid().currentAsset().id")
        h.nav("select")
        h.nav("right")
        b = h.value("app.activeGrid().currentAsset().id")
        h.nav("select")
        assert h.value("app.activeGrid().selectedCount") == 2
        h.shot("04-selection")
        h.key("trash", 1.2)
        assert state(port)["assets"][a]["trashed"] and state(port)["assets"][b]["trashed"]
        assert h.value("app.activeGrid().total") == 42
        assert "trash" in h.value("hooks.toast.message")
        h.js("hooks.toast.action()")
        wait_for("Undo restores both", lambda: not state(port)["assets"][a]["trashed"] and not state(port)["assets"][b]["trashed"])
        print("ok: selection, trash and Undo")

        # Archive moves a photo out of the timeline and into Archive.
        h.nav("refresh", 1.5)
        target = h.value("app.activeGrid().currentAsset().id")
        h.key("archive", 1.2)
        assert state(port)["assets"][target]["visibility"] == "archive"
        h.nav("go:archive", 2)
        wait_for("Archive lists three", lambda: h.value("app.activeGrid().total") == 3)
        h.shot("05-archive")
        h.nav("go:photos", 2)
        print("ok: archive")

        # Albums: add to an existing one, create one, then the album page.
        wait_for("the timeline is back", lambda: h.value("app.activeGrid() ? app.activeGrid().total : 0") > 0)
        photo = h.value("app.activeGrid().currentAsset().id")
        h.key("addToAlbum", 1.5)
        assert h.value("hooks.picker.opened") is True
        h.js("hooks.picker.choose('Summer')")
        wait_for("added to Summer", lambda: photo in state(port)["albums"]["Summer"])
        h.key("addToAlbum", 1.5)
        h.js("hooks.picker.choose('Road trip')")
        wait_for("Road trip created with the photo", lambda: state(port)["albums"].get("Road trip") == [photo])
        h.nav("go:albums", 2)
        h.shot("06-albums")
        names = h.value("service.albums.map(function(a){return a.albumName})")
        assert {"Summer", "Road trip", "Ana's garden"} <= set(names), names
        print("ok: add to album, create album")

        summer = next(k for k, v in state(port)["albumDetails"].items() if v["name"] == "Summer")
        h.js(f"app.push({{ kind: 'album', album: service.albums.filter(function(a){{return a.id === '{summer}'}})[0] }})")
        time.sleep(2)
        h.shot("07-album-page")
        h.js("hooks.albumPeople.ask(app.page.album)")
        wait_for("users load", lambda: h.value("hooks.albumPeople.candidates.length") == 2)
        h.shot("08-album-people")
        h.js("hooks.albumPeople.addRole = 'viewer'")
        h.js("hooks.albumPeople.apply('album.share', { userId: '11111111-1111-4111-8111-333333333333', role: hooks.albumPeople.addRole }, 'x')")
        wait_for("Ben joins as a viewer", lambda: state(port)["albumDetails"][summer]["users"] == {"11111111-1111-4111-8111-333333333333": "viewer"})
        h.js("hooks.albumPeople.apply('album.setRole', { userId: '11111111-1111-4111-8111-333333333333', role: 'editor' }, 'x')")
        wait_for("Ben becomes an editor", lambda: state(port)["albumDetails"][summer]["users"] == {"11111111-1111-4111-8111-333333333333": "editor"})
        wait_for("the page says shared", lambda: h.value("app.page.album.shared") is True)
        h.shot("09-album-people-after")
        h.js("hooks.albumPeople.apply('album.unshare', { userId: '11111111-1111-4111-8111-333333333333' }, 'x')")
        wait_for("Ben leaves", lambda: state(port)["albumDetails"][summer]["users"] == {})
        h.js("hooks.albumPeople.close()")
        h.js("app.page && app.runShortcut('back', '')")
        print("ok: album page and sharing an album with people, with roles")

        # Tags and shared links on a photo.
        h.nav("go:photos", 2)
        wait_for("the timeline is back", lambda: h.value("app.activeGrid() ? app.activeGrid().total : 0") > 0)
        photo = h.value("app.activeGrid().currentAsset().id")
        h.key("tag", 1.2)
        h.js("hooks.picker.choose('beach')")
        wait_for("tagged beach", lambda: any(t["name"] == "beach" and photo in t["assets"] for t in state(port)["tags"].values()))
        h.key("share", 1)
        assert h.value("hooks.share.opened") is True
        h.js("hooks.share.create()")
        wait_for("a link is made", lambda: h.value("hooks.share.created ? hooks.share.created.url : ''").startswith("http://127.0.0.1"))
        h.shot("10-share-link")
        # Copied inside the shell: no wl-copy holding the link in its arguments.
        assert h.value("hooks.clipboard()") == h.value("hooks.share.created.url"), "the link is on the clipboard"
        h.js("hooks.share.close()")
        print("ok: tag and shared link")

        # People, a person, renaming.
        h.nav("go:people", 2.5)
        wait_for("people load", lambda: h.value("service.people.length") == 5)
        h.shot("11-people")
        h.nav("open", 2)
        assert h.value("app.page.kind") == "person"
        h.shot("12-person")
        person = h.value("app.page.person.id")
        h.js("app.renamePerson(app.page.person)")
        h.js("hooks.prompt.submitText('Jenny')")
        wait_for("renamed", lambda: state(port)["people"][person]["name"] == "Jenny")
        # Right-click a photo of theirs: use it as their key photo.
        wait_for("their photos", lambda: h.value("app.activeGrid() && app.activeGrid().currentAsset() ? 1 : 0") == 1, 10)
        photo = h.value("app.activeGrid().currentAsset().id")
        before = h.value("app.page.person.version")
        h.js("app.showPhotoMenu(app.activeGrid().currentAsset(), hooks.content, 10, 10)")
        labels = h.value("hooks.menu.items.map(function(i) { return i.label || '' })")
        assert "Make key photo" in labels and "Use as album cover" not in labels, labels
        h.js("app.menuHandler('keyPhoto')")
        wait_for("the key photo", lambda: state(port)["people"][person].get("faceAssetId") == photo, 10)
        # The picture reloads only after Immich's crop job touched the person.
        final = "202601010000" + "%02d" % state(port)["people"][person]["updated"]
        wait_for("the thumbnail refreshed after the crop", lambda: h.value("app.page.person.version") == final, 10)
        print("ok: people, person page, rename and key photo")

        # Faces: a photo of Jenny with a stranger Immich did not recognise.
        photo = h.value("app.activeGrid().currentAsset().id")
        stranger = next((k for k, f in state(port)["faces"].items() if f["assetId"] == photo and f["personId"] is None), None)
        if not stranger:
            req = urllib.request.Request(f"http://127.0.0.1:{port}/_face", method="POST", headers={"x-api-key": KEY},
                                         data=json.dumps({"assetId": photo, "personId": None, "slot": 3}).encode())
            stranger = json.load(urllib.request.urlopen(req))["id"]
        jenny_face = next(k for k, f in state(port)["faces"].items() if f["assetId"] == photo and f["personId"] == person)
        h.nav("open", 1.5)
        wait_for("the faces", lambda: h.value("hooks.viewer.faces.length") == 2, 10)
        h.js("app.setInfo(true)")
        h.key("faces", 1.0)
        assert h.value("hooks.viewer.showFaces") is True
        assert h.value("hooks.info.faceList.map(function(f) { return f.person ? f.person.name : '?' }).join(',')") == "Jenny,?"
        h.shot("12b-faces")
        h.key("faces", 0.3)
        # Name the stranger: they become Alvar, in this photo only.
        alvar = next(k for k, p in state(port)["people"].items() if p["name"] == "Alvar")
        h.js(f"app.showFaceMenu(hooks.viewer.faces[1], hooks.info)")
        assert h.value("hooks.viewer.selectedFace") == stranger
        assert h.value("hooks.menu.items.filter(function(i) { return !i.separator }).map(function(i) { return i.label })") == ["Who is this?...", "Forget this face..."]
        h.js("hooks.menu.activate(hooks.menu.items.map(function(i) { return i.id }).indexOf('change'))")
        wait_for("the picker", lambda: h.value("hooks.picker.opened") is True)
        h.js("hooks.picker.choose('Alvar')")
        wait_for("the stranger is Alvar", lambda: state(port)["faces"][stranger]["personId"] == alvar, 10)
        wait_for("the details follow", lambda: h.value("hooks.info.faceList.map(function(f) { return f.person ? f.person.name : '?' }).join(',')") == "Jenny,Alvar", 10)
        # Jenny's face moves to Emma, and Undo moves it back.
        emma = next(k for k, p in state(port)["people"].items() if p["name"] == "Emma")
        h.js("app.showFaceMenu(hooks.viewer.faces[0], hooks.info)")
        assert h.value("hooks.menu.items.filter(function(i) { return !i.separator }).map(function(i) { return i.label })") == ["Open Jenny", "Change person...", "Remove from Jenny..."]
        h.js("hooks.menu.activate(hooks.menu.items.map(function(i) { return i.id }).indexOf('change'))")
        wait_for("the picker", lambda: h.value("hooks.picker.opened") is True)
        h.js("hooks.picker.choose('Emma')")
        wait_for("Jenny's face is Emma's", lambda: state(port)["faces"][jenny_face]["personId"] == emma, 10)
        assert h.value("hooks.toast.message") == "Moved to Emma"
        h.js("hooks.toast.action()")
        wait_for("Undo gives it back", lambda: state(port)["faces"][jenny_face]["personId"] == person, 10)
        wait_for("the frame is let go", lambda: h.value("hooks.viewer.selectedFace") == "", 5)
        # Alvar was a stranger after all: take the face away from him.
        h.js("app.showFaceMenu(hooks.viewer.faces[1], hooks.info)")
        assert h.value("hooks.menu.items.filter(function(i) { return !i.separator }).map(function(i) { return i.label })")[-1] == "Remove from Alvar..."
        time.sleep(0.4)
        # The menu is as wide as its longest row.
        assert h.value("hooks.menu.contentItem.implicitWidth >= hooks.menu.widest - 0.5") is True, h.value("[hooks.menu.width, hooks.menu.widest]")
        h.js("hooks.menu.activate(hooks.menu.items.map(function(i) { return i.id }).indexOf('remove'))")
        wait_for("asked first", lambda: h.value("hooks.confirm.opened") is True)
        assert h.value("hooks.viewer.selectedFace") == stranger
        assert stranger in state(port)["faces"]
        h.js("hooks.confirm.confirm()")
        wait_for("the face is gone", lambda: stranger not in state(port)["faces"], 10)
        wait_for("the details follow", lambda: h.value("hooks.info.faceList.map(function(f) { return f.person ? f.person.name : '?' }).join(',')") == "Jenny", 10)
        wait_for("the frame is let go", lambda: h.value("hooks.viewer.selectedFace") == "", 5)
        # A video: its faces were found on its preview still. Framing them
        # pauses the video and shows that still; playing hides them again.
        video = next(k for k, a in state(port)["assets"].items() if a["name"].endswith(".MP4"))
        req = urllib.request.Request(f"http://127.0.0.1:{port}/_face", method="POST", headers={"x-api-key": KEY},
                                     data=json.dumps({"assetId": video, "personId": person, "slot": 1}).encode())
        video_face = json.load(urllib.request.urlopen(req))["id"]
        h.js(f"app.openViewer({{ id: '{video}', isImage: false, ratio: 1.5, thumbhash: null, fileCreatedAt: '2026-10-01T10:00:00' }})")
        count = sum(1 for f in state(port)["faces"].values() if f["assetId"] == video)
        wait_for("the video's faces", lambda: h.value("hooks.viewer.faces.length") == count, 10)
        mine = h.value(f"hooks.viewer.faces.map(function(f) {{ return f.id }}).indexOf('{video_face}')")
        assert h.value("hooks.viewer.facesStill") is False
        h.js(f"hooks.info.faceHovered('{video_face}')")
        wait_for("the still with its frame", lambda: h.value("hooks.viewer.facesStill") is True, 5)
        h.js("hooks.info.faceHovered('')")
        h.key("faces", 1.0)
        assert h.value("hooks.viewer.facesStill") is True
        h.shot("12d-video-faces")
        h.js(f"app.showFaceMenu(hooks.viewer.faces[{mine}], hooks.info)")
        h.js("hooks.menu.activate(hooks.menu.items.map(function(i) { return i.id }).indexOf('change'))")
        wait_for("the picker", lambda: h.value("hooks.picker.opened") is True)
        h.js("hooks.picker.choose('Emma')")
        wait_for("the video's face is Emma's", lambda: state(port)["faces"][video_face]["personId"] == emma, 10)
        h.key("playPause", 0.5)
        assert h.value("hooks.viewer.facesStill") is False and h.value("hooks.viewer.showFaces") is False
        h.js("app.setInfo(false)")
        h.nav("back", 1.5)
        h.nav("back")
        print("ok: face frames, naming a stranger, moving a face, Undo, removing a face, and faces on a video")

        # Places, explore, search.
        h.nav("go:places", 2.5)
        wait_for("places load", lambda: h.value("service.places.length") == 2)
        h.shot("13-places")
        h.nav("open", 2.5)
        wait_for("a place lists its photos", lambda: h.value("app.activeGrid() ? app.activeGrid().total : 0") > 0)
        h.nav("go:explore", 2.5)
        h.shot("14-explore")
        # A sideways swipe over People goes to that row: it stretches past
        # its start and springs back, and the page stays where it is.
        ex = "hooks.content.item"
        row = ex + ".peopleRow"
        ry = h.value(f"{row}.mapToItem({ex}, 0, 40).y")
        page_y = h.value(f"{ex}.wheel.flickable.contentY")
        assert h.value(f"{ex}.wheel.rowAt({ry}) === {row}.rowWheel") is True
        w = ex + ".wheel"
        start = h.value(f"{row}.originX - {row}.leftMargin")
        h.js(f"({w}.handle(0, 0, 0, 0, false, {ry}, 1, 1000), " + ", ".join(f"{w}.handle(0, 0, 60, 1, false, {ry}, 2, {1000 + 16 * (i + 1)})" for i in range(6)) + ")")
        time.sleep(0.4)
        stretched = start - h.value(f"{row}.contentX")
        assert 10 < stretched < 6 * 60 * 1.25, ("the row did not stretch past its start", stretched)
        h.js(f"{w}.handle(0, 0, 0, 0, false, {ry}, 3, 1500)")
        time.sleep(1.2)
        assert abs(h.value(f"{row}.contentX") - start) < 0.5 and h.value(f"{row}.rowWheel.active") is False, "the row did not settle"
        assert abs(h.value(f"{ex}.wheel.flickable.contentY") - page_y) < 1, "the page moved with a sideways swipe"
        h.nav("search:sunset", 2.5)
        wait_for("search finds the sunset", lambda: h.value("app.activeGrid() ? app.activeGrid().total : 0") == 1)
        h.shot("15-search")
        print("ok: places, explore and search")

        # Trash view: restore all.
        h.nav("go:trash", 2.5)
        wait_for("the trash lists three", lambda: h.value("app.activeGrid().total") == 3)
        h.shot("16-trash")
        h.nav("first")
        h.nav("select")
        h.nav("right")
        h.nav("select")
        picked = h.value("app.activeGrid().targets().map(function(a){return a.id})")
        h.key("trash", 1.5)
        assert all(not state(port)["assets"][i]["trashed"] for i in picked), "restoring from the trash"
        assert "Restored 2 photos" in h.value("hooks.toast.message")
        h.js("hooks.toast.action()")
        wait_for("Show lands on a restored photo in the timeline", lambda: h.value(
            "app.section === 'photos' && app.activeGrid() && app.activeGrid().currentAsset() ? app.activeGrid().currentAsset().id : ''") in picked, 20)
        h.shot("16b-restored-shown")
        print("ok: restoring from the trash, and Show finds the photos in the timeline")
        h.nav("go:trash", 2)
        wait_for("one left in the trash", lambda: h.value("app.activeGrid().total") == 1)
        # The last one is offline: its file left the external library, so Immich keeps it.
        offline_id = h.value("app.activeGrid().assetAt({ bucket: app.activeGrid().buckets[0].key, index: 0 }).id")
        h.nav("first")
        h.key("trash", 2)
        assert state(port)["assets"][offline_id]["trashed"], "the mock keeps offline photos in the trash"
        message = h.value("hooks.toast.message")
        assert "offline" in message and "Restored" not in message, message
        assert h.value("app.activeGrid().total") == 1, "a photo Immich kept must stay in the trash view"
        h.shot("16c-offline-kept")
        h.nav("open", 1.5)
        wait_for("details say offline", lambda: h.value("hooks.viewer.details ? hooks.viewer.details.isOffline : false") is True)
        h.nav("back", 1)
        print("ok: an offline photo Immich will not restore is reported, not hidden")

        print("ok: trash view and restore")

        # Sharing: partners.
        h.nav("go:sharing", 2.5)
        h.shot("17-sharing")
        h.js("app.activeGrid() === null")
        h.js("service.call('partner.add', { userId: '11111111-1111-4111-8111-333333333333' }, function() {})")
        wait_for("sharing with Ben", lambda: "11111111-1111-4111-8111-333333333333" in state(port)["partners"]["by"])
        print("ok: sharing view and partners")

        # Pages turned off in the Immich account are left out.
        set_prefs(port, folders=False, tags=False)
        h.js("service.refreshServer()")
        wait_for("Folders and Tags leave the sidebar", lambda: not ({"folders", "tags"} & set(h.value("app.sections.map(function(s){return s.id})"))))
        h.nav("go:explore", 2)
        assert h.value("hooks.content.item.showTags") is False
        set_prefs(port, folders=True, tags=True)
        h.js("service.refreshServer()")
        wait_for("they come back", lambda: {"folders", "tags"} <= set(h.value("app.sections.map(function(s){return s.id})")))
        print("ok: account preferences hide pages")

        # Back and forward through history.
        h.nav("go:people", 1)
        h.nav("go:albums", 1)
        h.nav("historyBack", 1)
        assert h.value("app.section") == "people"
        h.nav("historyForward", 1)
        assert h.value("app.section") == "albums"
        assert h.value("app.canGoForward") is False
        print("ok: back and forward")

        # Oldest first.
        h.nav("go:photos", 2)
        wait_for("timeline", lambda: h.value("app.activeGrid() ? app.activeGrid().buckets.length : 0") > 0)
        newest = h.value("app.activeGrid().buckets[0].key")
        h.js("hooks.content.item.order = 'asc'")
        wait_for("oldest month first", lambda: h.value("app.activeGrid().buckets.length ? app.activeGrid().buckets[0].key : ''") not in ("", newest))
        assert h.value("app.activeGrid().buckets[0].key") < newest
        h.js("hooks.content.item.order = 'desc'")
        print("ok: oldest first")

        # Search filters, with and without words.
        h.nav("search:", 2)
        assert h.value("app.page.kind") == "search" and h.value("app.page.query") == ""
        wait_for("unfiltered results", lambda: h.value("app.activeGrid().total") > 0)
        everything = h.value("app.activeGrid().total")
        h.js("service.loadPeople()")
        wait_for("people known", lambda: h.value("service.people.length") == 5)
        h.js("hooks.content.item.choosePerson()")
        h.js("hooks.picker.choose('Alvar')")
        wait_for("only Alvar", lambda: 0 < h.value("app.activeGrid().total") < everything)
        alvar = h.value("app.activeGrid().total")
        h.shot("21-filter-person")
        h.js("hooks.content.item.chooseDates()")
        h.js("hooks.prompt.submitText('nonsense')")
        assert "Try" in h.value("hooks.prompt.error")
        h.js("hooks.prompt.submitText('2026-09')")
        wait_for("Alvar in September", lambda: h.value("app.activeGrid().total") < alvar)
        h.js("hooks.content.item.setFilters({ personIds: null, takenAfter: null, takenBefore: null }, { people: null, dates: null })")
        wait_for("filters cleared", lambda: h.value("app.activeGrid().total") == everything)
        h.js("hooks.content.item.chooseCamera()")
        time.sleep(1)
        h.js("hooks.picker.choose('Fujifilm')")
        wait_for("model picker", lambda: h.value("hooks.picker.opened && hooks.picker.title === 'Fujifilm'") is True)
        h.js("hooks.picker.choose('Any')")
        wait_for("only Fujifilm photos", lambda: 0 < h.value("app.activeGrid().total") < everything)
        h.shot("22-filter-camera")
        h.js("hooks.content.item.sortMode = 'name'")
        time.sleep(0.5)
        names = h.value("app.activeGrid().assetsOf._list.map(function(a){return a.originalFileName})")
        assert names == sorted(names, key=str.lower), names
        print("ok: search filters by person, dates and camera, and sorting results")

        # Tags as a tree, with counts and nested creation.
        h.nav("go:tags", 2)
        wait_for("tag counts", lambda: len(h.value("Object.keys(hooks.content.item.counts)")) >= 3)
        h.js("hooks.content.item.createTag('')")
        h.js("hooks.prompt.submitText('Trips/2024')")
        wait_for("nested tag created", lambda: {"Trips", "Trips/2024"} <= {t["name"] if "/" not in t["name"] else t["name"] for t in state(port)["tags"].values()} or {"Trips", "2024"} <= {t["name"] for t in state(port)["tags"].values()})
        wait_for("the tree shows it under Trips", lambda: any(r["value"] == "Trips/2024" and r["depth"] == 1 for r in h.value("hooks.content.item.rows.map(function(r){return {value: r.value, depth: r.depth}})")))
        h.js("hooks.content.item.setCollapsed('Trips', true)")
        assert not any(r == "Trips/2024" for r in h.value("hooks.content.item.rows.map(function(r){return r.value})"))
        h.shot("23-tags-tree")
        h.nav("go:explore", 3)
        wait_for("explore shows tags", lambda: h.value("hooks.content.item.topTags.length") > 0)
        h.shot("24-explore-tags")
        print("ok: tag tree, counts, nested tags and explore tags")

        # Upload staging: look, choose an album, upload.
        stage = os.path.join(root, "to-upload")
        os.makedirs(os.path.join(stage, "more"))
        some_id = next(iter(state(port)["assets"]))
        with open(os.path.join(stage, "same.png"), "wb") as f:
            f.write(fetch(port, f"/api/assets/{some_id}/original"))
        for name, color in (("fresh.png", (10, 200, 30)), ("more/also.png", (200, 10, 30))):
            with open(os.path.join(stage, name), "wb") as f:
                f.write(mock_png(color))
        h.js(f"app.stage(['{stage}'], '')")
        wait_for("staging lists three", lambda: h.value("app.page && app.page.kind === 'staging' && hooks.content.item ? hooks.content.item.items.length : 0") == 3)
        wait_for("one is already in Immich", lambda: h.value("hooks.content.item.knownCount") == 1)
        h.shot("25-staging")
        h.js("hooks.content.item.chooseAlbum()")
        h.js("hooks.picker.choose('Holiday 2026')")
        assert h.value("hooks.content.item.targetKind") == "new"
        h.js("hooks.content.item.upload()")
        wait_for("all three end up in the new album", lambda: len(state(port)["albums"].get("Holiday 2026", [])) == 3, 40)
        assert h.value("app.page") is None, "staging closes after uploading"
        print("ok: upload staging into a new album")

        # The synced folder as seen from the library.
        h.js(f"service.call('sync.folderSave', {{ folder: {{ path: '{stage}' }} }}, function(r) {{ service.applySettingsResponse(r) }})")
        wait_for("On this computer appears", lambda: "computer" in h.value("app.sections.map(function(s){return s.id})"))
        h.nav("go:computer", 2)
        wait_for("it lists the files", lambda: h.value("hooks.content.item.localTotal") == 3)
        h.js("service.updateSettings({ sync: { enabled: true, pauseOnMetered: false } })")
        wait_for("sync marks them as in Immich", lambda: h.value("app.activeGrid().assetsOf._list ? app.activeGrid().assetsOf._list.filter(function(a){return a.syncState === 'done'}).length : 0") == 3, 40)
        h.shot("26-on-this-computer")
        h.nav("first")
        h.nav("open", 1.5)
        assert h.value("app.viewerAsset.localPath").startswith(stage)
        wait_for("details from Immich", lambda: h.value("hooks.viewer.details ? hooks.viewer.details.id : ''") != "")
        h.shot("27-local-viewer")
        h.nav("back", 1)
        h.js("service.updateSettings({ sync: { enabled: false } })")
        print("ok: on this computer, with sync states and the viewer")

        # A phone-width window: tabs at the bottom.
        h.js("app.narrowOverride = true")
        wait_for("narrow layout", lambda: h.value("app.narrow") is True)
        time.sleep(1)
        assert h.value("app.sections.length") > 5
        h.shot("28-narrow")
        h.js("app.narrowOverride = false")
        wait_for("wide again", lambda: h.value("app.narrow") is False)
        print("ok: narrow layout")

        # The remaining views render without errors.
        for section in ("favorites", "tags", "folders", "sync"):
            h.nav("go:" + section, 2)
            h.shot("18-" + section)
        h.nav("settings", 2)
        h.shot("19-settings")
        # An http:// address across the internet is called out; a home one is not.
        h.js("hooks.settings.item.awayAddress = 'http://192.168.1.20:2283'")
        time.sleep(0.3)
        assert h.value("hooks.settings.item.warnsUnencrypted") is False
        h.js("hooks.settings.item.awayAddress = 'http://photos.example.com'")
        time.sleep(0.3)
        assert h.value("hooks.settings.item.warnsUnencrypted") is True
        h.shot("19b-settings-unencrypted")
        h.nav("settings", 1)
        h.nav("help", 1)
        assert h.value("app.keyContext") == "dialog", "the shortcut sheet must block photo keys"
        h.shot("20-help")
        h.nav("back", 0.5)
        assert h.value("app.helpOpen") is False

        errors = h.errors()
        assert not errors, "QML errors:\n" + "".join(errors[:20])
        print(f"all UI checks passed; screenshots in {shots}")
    finally:
        if h:
            h.stop()
        mock.terminate()
        if not os.environ.get("OMAMICH_UI_SHOTS"):
            shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    main()
