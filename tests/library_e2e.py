#!/usr/bin/env python3
"""End-to-end test of the library RPCs the window uses to change things,
against the mock Immich, so no real library is ever touched.

usage: library_e2e.py path/to/omamich
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
from sync_e2e import KEY, Backend, free_port, photo, wait_for, _ping  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
USER = "11111111-1111-4111-8111-111111111111"


def state(port):
    return json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/_state"))


def expect_error(backend, method, params, needle=""):
    try:
        backend.call(method, params)
    except RuntimeError as e:
        assert needle.lower() in str(e).lower(), f"{method}: unexpected error {e}"
        return
    raise AssertionError(f"{method} should have failed")


def main():
    binary = os.path.abspath(sys.argv[1])
    port = free_port()
    mock = subprocess.Popen([sys.executable, "-I", os.path.join(HERE, "mock_immich.py"), str(port)])
    root = tempfile.mkdtemp(prefix="omamich-lib-")
    backend = None
    try:
        wait_for("mock is up", lambda: _ping(port), 10)
        backend = Backend(binary, os.path.join(root, "home"))
        backend.call("settings.update", {"patch": {"serverUrl": f"127.0.0.1:{port}"}})
        backend.call("auth.setKey", {"key": KEY})
        photo(f"{root}/in/one.jpg", "one")
        photo(f"{root}/in/two.jpg", "two")
        backend.call("sync.uploadFiles", {"paths": [f"{root}/in"]})
        assets = wait_for("two photos in the mock", lambda: (lambda a: a if len(a) == 2 else None)(state(port)["assets"]))
        one, two = sorted(assets, key=lambda k: assets[k]["name"])

        # Photos
        backend.call("asset.update", {"ids": [one, two], "isFavorite": True})
        backend.call("asset.update", {"ids": [one], "visibility": "archive", "rating": 4})
        backend.call("asset.update", {"ids": [one], "description": "Lake at dawn"})
        s = state(port)["assets"]
        assert s[one]["favorite"] and s[two]["favorite"], s
        assert s[one]["visibility"] == "archive" and s[one]["rating"] == 4, s[one]
        assert s[one]["description"] == "Lake at dawn"
        expect_error(backend, "asset.update", {"ids": ["../../etc"], "isFavorite": True}, "id")
        expect_error(backend, "asset.update", {"ids": [one, two], "description": "x"}, "one photo")
        expect_error(backend, "asset.update", {"ids": [one], "rating": 9}, "rating")
        expect_error(backend, "asset.update", {"ids": [one], "visibility": "everywhere"}, "visibility")
        print("ok: photo edits")

        # Albums
        album = backend.call("album.create", {"albumName": "Holiday", "assetIds": [one]})
        assert album["albumName"] == "Holiday"
        added = backend.call("album.addAssets", {"id": album["id"], "ids": [one, two]})
        assert added == {"changed": 1, "requested": 2}, added
        assert [a["albumName"] for a in backend.call("asset.albums", {"id": two})] == ["Holiday"]
        renamed = backend.call("album.update", {"id": album["id"], "albumName": "Summer", "description": "2026", "order": "asc", "albumThumbnailAssetId": two})
        assert renamed["albumName"] == "Summer" and renamed["order"] == "asc" and renamed["albumThumbnailAssetId"] == two
        backend.call("album.removeAssets", {"id": album["id"], "ids": [one]})
        assert state(port)["albums"]["Summer"] == [two]
        shared = backend.call("album.share", {"id": album["id"], "userId": USER, "role": "viewer"})
        assert shared["shared"] and shared["users"][0]["role"] == "viewer", shared
        backend.call("album.unshare", {"id": album["id"], "userId": USER})
        expect_error(backend, "album.create", {"albumName": "   "}, "name")
        listed = backend.call("albums.list", {})
        assert [a["albumName"] for a in listed] == ["Summer"], listed
        backend.call("album.delete", {"id": album["id"]})
        assert state(port)["albums"] == {}
        print("ok: albums")

        # Tags
        tag = backend.call("tag.create", {"name": "family"})
        backend.call("tag.assign", {"id": tag["id"], "ids": [one, two]})
        backend.call("tag.unassign", {"id": tag["id"], "ids": [two]})
        backend.call("tag.update", {"id": tag["id"], "color": "#4a90d9"})
        t = state(port)["tags"][tag["id"]]
        assert t["assets"] == [one] and t["color"] == "#4a90d9", t
        expect_error(backend, "tag.update", {"id": tag["id"], "color": "red; drop"}, "colour")
        assert [x["value"] for x in backend.call("tags.list", {})] == ["family"]
        detail = backend.call("asset.get", {"id": one})
        assert [x["name"] for x in detail["tags"]] == ["family"]
        backend.call("tag.delete", {"id": tag["id"]})
        print("ok: tags")

        # Shared links
        link = backend.call("sharedLink.create", {"assetIds": [one], "allowDownload": False, "expiresInDays": 7, "password": "pw"})
        assert link["url"].startswith(f"http://127.0.0.1:{port}/share/"), link
        stored = state(port)["links"][0]
        assert stored["type"] == "INDIVIDUAL" and stored["allowDownload"] is False and stored["expiresAt"], stored
        backend.call("sharedLink.update", {"id": link["id"], "description": "for grandma"})
        assert backend.call("sharedLinks.list", {})[0]["description"] == "for grandma"
        backend.call("sharedLink.delete", {"id": link["id"]})
        assert state(port)["links"] == []
        print("ok: shared links")

        # People
        person = "22222222-2222-4222-8222-222222222222"
        updated = backend.call("person.update", {"id": person, "name": " Ada ", "birthDate": "1990-12-10", "isFavorite": True})
        assert updated["name"] == "Ada" and updated["isFavorite"] is True, updated
        expect_error(backend, "person.update", {"id": person, "birthDate": "10/12/1990"}, "birthday")
        backend.call("person.merge", {"id": "33333333-3333-4333-8333-333333333333", "ids": [person]})
        assert person not in state(port)["people"]
        print("ok: people")

        # Download, trash, restore, delete
        saved = backend.call("asset.download", {"ids": [two], "directory": f"{root}/dl"})
        assert open(saved["paths"][0], "rb").read().startswith(b"\xff\xd8"), saved
        again = backend.call("asset.download", {"ids": [two], "directory": f"{root}/dl"})
        assert again["paths"][0].endswith("two (1).jpg"), again
        backend.call("asset.trash", {"ids": [one]})
        assert state(port)["assets"][one]["trashed"]
        backend.call("asset.restore", {"ids": [one]})
        assert not state(port)["assets"][one]["trashed"]
        backend.call("asset.deleteForever", {"ids": [one]})
        assert one not in state(port)["assets"]
        print("ok: download, trash, restore and delete")

        expect_error(backend, "no.such.method", {}, "unknown method")
        print("all library checks passed")
    finally:
        if backend:
            backend.stop()
        mock.terminate()
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    main()
