#!/usr/bin/env python3
"""End-to-end sync test: a real backend against the mock Immich.

usage: sync_e2e.py path/to/omamich
"""
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
KEY = "testkey-0123456789"


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Backend:
    def __init__(self, binary, home):
        # The desktop trash too: mirrored deletions must never reach the real one.
        env = dict(os.environ, OMAMICH_HOME=home, XDG_DATA_HOME=os.path.join(home, "xdg-data"))
        self.proc = subprocess.Popen([binary, "serve"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     text=True, bufsize=1, env=env)
        self.n = 0

    def call(self, method, params=None):
        self.n += 1
        ident = str(self.n)
        self.proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": ident, "method": method, "params": params or {}}) + "\n")
        self.proc.stdin.flush()
        while True:
            line = self.proc.stdout.readline()
            if not line:
                raise RuntimeError("backend exited")
            msg = json.loads(line)
            if msg.get("id") == ident:
                if "error" in msg:
                    raise RuntimeError(f"{method}: {msg['error']['message']}")
                return msg["result"]

    def stop(self):
        try:
            self.call("system.shutdown")
        except Exception:
            pass
        self.proc.wait(5)


def state(port):
    return json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/_state"))


DEBUG = []


def wait_for(what, check, timeout=40):
    deadline = time.time() + timeout
    while time.time() < deadline:
        result = check()
        if result:
            print(f"ok: {what}")
            return result
        time.sleep(0.5)
    for hook in DEBUG:
        print(hook())
    raise AssertionError(f"timed out: {what}")


def photo(path, seed):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(b"\xff\xd8\xff\xe0" + seed.encode() * 200)
    old = time.time() - 60
    os.utime(path, (old, old))


def main():
    binary = os.path.abspath(sys.argv[1])
    port = free_port()
    mock = subprocess.Popen([sys.executable, "-I", os.path.join(HERE, "mock_immich.py"), str(port)])
    root = tempfile.mkdtemp(prefix="omamich-e2e-")
    backend = None
    try:
        wait_for("mock is up", lambda: _ping(port), 10)
        home = os.path.join(root, "home")
        a = os.path.join(root, "A")
        b = os.path.join(root, "B")
        photo(f"{a}/a.jpg", "a")
        photo(f"{a}/sub/b.jpg", "b")
        photo(f"{a}/.hidden/c.jpg", "c")
        with open(f"{a}/notes.txt", "w") as f:
            f.write("not a photo")
        with open(f"{a}/a.jpg.xmp", "w") as f:
            f.write("<x/>")

        backend = Backend(binary, home)
        DEBUG.append(lambda: json.dumps([e for e in backend.call("sync.status")["events"] if "again" in e["name"] or e["kind"] == "failed"], indent=1))
        DEBUG.append(lambda: json.dumps({k: v for k, v in backend.call("sync.status").items() if k not in ("events", "folders")}))
        DEBUG.append(lambda: json.dumps(state(port))[:2000])
        backend.call("settings.update", {"patch": {"serverUrl": f"127.0.0.1:{port}", "sync": {"pauseOnMetered": False}}})
        try:
            backend.call("auth.setKey", {"key": "bad key with spaces!"})
            raise AssertionError("a malformed key was accepted")
        except RuntimeError:
            pass
        assert backend.call("auth.setKey", {"key": KEY})["storage"] == "file"
        test = backend.call("auth.test", {})
        assert test["lan"]["ok"], test

        backend.call("sync.folderSave", {"folder": {"path": a, "albumName": "Trip"}})
        try:
            backend.call("sync.folderSave", {"folder": {"path": f"{a}/sub"}})
            raise AssertionError("an overlapping folder was accepted")
        except RuntimeError:
            pass
        backend.call("settings.update", {"patch": {"sync": {"enabled": True}}})

        s = wait_for("two photos uploaded into Trip",
                     lambda: (lambda st: st if len(st["albums"].get("Trip", [])) == 2 else None)(state(port)))
        names = sorted(v["name"] for v in s["assets"].values())
        assert names == ["a.jpg", "b.jpg"], names

        photo(f"{a}/d.jpg", "d")
        wait_for("a new file is picked up by the watcher",
                 lambda: len(state(port)["albums"]["Trip"]) == 3)

        shutil.copy(f"{a}/a.jpg", f"{a}/e.jpg")
        wait_for("a copy is recognised as a duplicate",
                 lambda: backend.call("sync.status")["duplicates"] >= 1)
        assert len(state(port)["assets"]) == 3

        backend.call("sync.folderSave", {"folder": {"path": b, "albumName": "Trip", "method": "download"}})
        wait_for("the album is downloaded into B",
                 lambda: sorted(os.listdir(b)) == ["a.jpg", "b.jpg", "d.jpg"] if os.path.isdir(b) else False)
        uploads_before = len([e for e in state(port)["log"] if e[0] == "upload"])

        folder = next(f for f in backend.call("settings.get")["settings"]["sync"]["folders"] if f["path"] == a)
        folder["mirrorLocalDeletes"] = True
        backend.call("sync.folderSave", {"folder": folder})
        os.remove(f"{a}/a.jpg")
        os.remove(f"{a}/d.jpg")
        wait_for("deleting d.jpg here trashes it in Immich",
                 lambda: any(v["name"] == "d.jpg" and v["trashed"] for v in state(port)["assets"].values()), 30)
        time.sleep(3)
        a_trashed = any(v["name"] == "a.jpg" and v["trashed"] for v in state(port)["assets"].values())
        assert not a_trashed, "a.jpg still exists as e.jpg, so it must not be trashed"

        extra = os.path.join(root, "extra")
        photo(f"{extra}/manual.jpg", "manual")
        backend.call("settings.update", {"patch": {"sync": {"enabled": False}}})
        queued = backend.call("sync.uploadFiles", {"paths": [f"file://{extra}/manual.jpg"]})["queued"]
        assert queued == 1
        wait_for("a hand-picked file uploads even with sync off",
                 lambda: any(v["name"] == "manual.jpg" for v in state(port)["assets"].values()))
        uploads_after = len([e for e in state(port)["log"] if e[0] == "upload"])
        assert uploads_after == uploads_before + 1, "downloaded files must not be uploaded again"
        status = backend.call("sync.status")
        assert status["failed"] == 0, status

        # A folder that disappears (an unmounted drive) must not empty Immich.
        backend.call("settings.update", {"patch": {"sync": {"enabled": True}}})
        mass = os.path.join(root, "M")
        for i in range(30):
            photo(f"{mass}/m{i}.jpg", f"mass{i}")
        backend.call("sync.folderSave", {"folder": {"path": mass, "albumName": "Mass", "mirrorLocalDeletes": True}})
        wait_for("thirty photos uploaded", lambda: len(state(port)["albums"].get("Mass", [])) == 30, 60)
        os.rename(mass, mass + "-unmounted")
        backend.call("sync.rescan")
        time.sleep(16)
        trashed = [v for v in state(port)["assets"].values() if v["name"].startswith("m") and v["trashed"]]
        assert not trashed, f"{len(trashed)} photos were trashed because their folder vanished"
        os.makedirs(mass)
        for i in range(25):
            photo(f"{mass}/m{i + 100}.jpg", f"other{i}")
        backend.call("sync.rescan")
        time.sleep(16)
        trashed = [v for v in state(port)["assets"].values() if v["name"].startswith("m") and v["trashed"]]
        assert not trashed, f"{len(trashed)} photos trashed when most of a folder vanished at once"
        print("ok: a vanished or emptied folder does not trash Immich")

        # Pointing a download folder at another album must not trash its files.
        down = os.path.join(root, "D")
        backend.call("sync.folderSave", {"folder": {"path": down, "albumName": "Trip", "method": "download", "mirrorRemoteDeletes": True}})
        wait_for("Trip downloaded into D", lambda: os.path.isdir(down) and len(os.listdir(down)) >= 2)
        before = sorted(os.listdir(down))
        folder = next(f for f in backend.call("settings.get")["settings"]["sync"]["folders"] if f["path"] == down)
        folder["albumName"] = "Mass"
        backend.call("sync.folderSave", {"folder": folder})
        time.sleep(8)
        assert all(os.path.exists(os.path.join(down, n)) for n in before), "files were trashed after an album change"
        trash_dir = os.path.join(home, "xdg-data", "Trash", "files")
        assert not os.path.isdir(trash_dir) or not os.listdir(trash_dir), os.listdir(trash_dir)
        print("ok: changing a folder's album keeps its files")

        # A file whose Immich copy is in the trash brings it back.
        trashed_id = next(k for k, v in state(port)["assets"].items() if v["name"] == "d.jpg")
        assert state(port)["assets"][trashed_id]["trashed"]
        photo(f"{a}/d-again.jpg", "d")
        wait_for("the trashed copy is restored", lambda: not state(port)["assets"][trashed_id]["trashed"])
        print("all sync checks passed")
    finally:
        if backend:
            backend.stop()
        mock.terminate()
        shutil.rmtree(root, ignore_errors=True)


def _ping(port):
    try:
        return json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/api/server/ping"))["res"] == "pong"
    except Exception:
        return False


if __name__ == "__main__":
    main()
