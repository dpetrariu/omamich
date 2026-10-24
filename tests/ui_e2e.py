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
                    or "unavailable" in line or "Error:" in line or "is not a type" in line)]

    def stop(self):
        self.proc.terminate()
        try:
            self.proc.wait(5)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def state(port):
    return json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/_state"))


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
        print("ok: people, person page and rename")

        # Places, explore, search.
        h.nav("go:places", 2.5)
        wait_for("places load", lambda: h.value("service.places.length") == 2)
        h.shot("13-places")
        h.nav("open", 2.5)
        wait_for("a place lists its photos", lambda: h.value("app.activeGrid() ? app.activeGrid().total : 0") > 0)
        h.nav("go:explore", 2.5)
        h.shot("14-explore")
        h.nav("search:sunset", 2.5)
        wait_for("search finds the sunset", lambda: h.value("app.activeGrid() ? app.activeGrid().total : 0") == 1)
        h.shot("15-search")
        print("ok: places, explore and search")

        # Trash view: restore all.
        h.nav("go:trash", 2.5)
        wait_for("the trash lists three", lambda: h.value("app.activeGrid().total") == 3)
        h.shot("16-trash")
        h.js("app.service.call('trash.restoreAll', {}, function() { app.refreshContent() })")
        wait_for("everything restored", lambda: not any(v["trashed"] for v in state(port)["assets"].values()))
        print("ok: trash view and restore all")

        # Sharing: partners.
        h.nav("go:sharing", 2.5)
        h.shot("17-sharing")
        h.js("app.activeGrid() === null")
        h.js("service.call('partner.add', { userId: '11111111-1111-4111-8111-333333333333' }, function() {})")
        wait_for("sharing with Ben", lambda: "11111111-1111-4111-8111-333333333333" in state(port)["partners"]["by"])
        print("ok: sharing view and partners")

        # The remaining views render without errors.
        for section in ("favorites", "tags", "folders", "sync"):
            h.nav("go:" + section, 2)
            h.shot("18-" + section)
        h.nav("settings", 2)
        h.shot("19-settings")
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
