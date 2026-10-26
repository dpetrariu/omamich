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
        promoted = backend.call("album.setRole", {"id": album["id"], "userId": USER, "role": "editor"})
        assert promoted["users"][0]["role"] == "editor", promoted
        expect_error(backend, "album.setRole", {"id": album["id"], "userId": USER, "role": "owner"}, "role")
        backend.call("album.unshare", {"id": album["id"], "userId": USER})
        assert state(port)["albumDetails"][album["id"]]["users"] == {}
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
        nested = backend.call("tag.create", {"name": "Trips/2024/"})
        assert nested["value"] == "Trips/2024" and nested["parentId"], nested
        values = sorted(t["value"] for t in backend.call("tags.list", {}))
        assert values == ["Trips", "Trips/2024", "family"], values
        covers = backend.call("tags.covers", {"ids": [tag["id"], nested["id"], "../x"]})
        assert covers[tag["id"]]["count"] == 1 and covers[tag["id"]]["assetId"] == one, covers
        assert covers[nested["id"]]["count"] == 0 and "../x" not in covers, covers
        expect_error(backend, "tag.create", {"name": "a//b"}, "levels")
        backend.call("tag.delete", {"id": tag["id"]})
        print("ok: tags, nested tags and counts")

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
        # A key photo must be one the person is in; Immich refuses others.
        expect_error(backend, "person.update", {"id": person, "featureFaceAssetId": one}, "does not show this person")
        expect_error(backend, "person.update", {"id": person, "featureFaceAssetId": "../x"}, "")
        # Faces: where they are and who they are; one moves to someone else.
        def add_face(asset, person_id, slot):
            req = urllib.request.Request(f"http://127.0.0.1:{port}/_face", method="POST",
                                         data=json.dumps({"assetId": asset, "personId": person_id, "slot": slot}).encode(),
                                         headers={"x-api-key": "testkey-0123456789"})
            return json.load(urllib.request.urlopen(req))["id"]
        ada_face = add_face(one, person, 0)
        stranger = add_face(one, None, 1)
        faces = backend.call("asset.faces", {"id": one})
        assert [f["id"] for f in faces] == [ada_face, stranger], faces
        assert faces[0]["person"]["name"] == "Ada" and faces[1]["person"] is None, faces
        assert abs(faces[0]["x1"] - 120 / 1440) < 1e-9 and abs(faces[0]["y2"] - 560 / 1080) < 1e-9, faces[0]
        expect_error(backend, "asset.faces", {"id": "../x"}, "")
        moved = backend.call("face.reassign", {"faceId": stranger, "personId": person})
        assert moved["name"] == "Ada" and state(port)["faces"][stranger]["personId"] == person
        made = backend.call("face.reassign", {"faceId": ada_face, "name": "  Bea "})
        assert made["name"] == "Bea" and state(port)["faces"][ada_face]["personId"] == made["id"]
        assert one in state(port)["people"][made["id"]].get("assetIds", [one])
        expect_error(backend, "face.reassign", {"faceId": ada_face}, "pick a person")
        expect_error(backend, "face.reassign", {"faceId": ada_face, "personId": "../x"}, "")
        expect_error(backend, "face.reassign", {"faceId": "nope", "personId": person}, "")
        assert backend.call("face.remove", {"faceId": ada_face}) is True
        assert ada_face not in state(port)["faces"]
        expect_error(backend, "face.remove", {"faceId": ada_face}, "")
        expect_error(backend, "face.remove", {"faceId": "../x"}, "")
        print("ok: faces")
        backend.call("person.merge", {"id": "33333333-3333-4333-8333-333333333333", "ids": [person]})
        assert person not in state(port)["people"]
        print("ok: people")

        # Partners
        ana = "11111111-1111-4111-8111-222222222222"
        backend.call("partner.add", {"userId": ana})
        assert ana in state(port)["partners"]["by"]
        assert [p["name"] for p in backend.call("partners.list", {})["sharedBy"]] == ["Ana"]
        backend.call("partner.remove", {"userId": ana})
        assert state(port)["partners"]["by"] == {}
        backend.call("partner.timeline", {"userId": ana, "inTimeline": True})
        assert state(port)["partners"]["with"][ana] is True
        users = backend.call("users.list", {})
        assert {u["name"] for u in users} >= {"Test", "Ana"} and all(set(u) <= {"id", "name", "email", "avatarColor"} for u in users)
        print("ok: partners")

        # Dates
        backend.call("asset.update", {"ids": [two], "dateTimeOriginal": "2024-05-01T14:30:00.000+02:00"})
        assert state(port)["assets"][two]["date"].startswith("2024-05-01T14:30"), state(port)["assets"][two]
        expect_error(backend, "asset.update", {"ids": [two], "dateTimeOriginal": "yesterday"}, "dates")
        print("ok: dates")

        # Download, trash, restore, delete
        saved = backend.call("asset.download", {"ids": [two], "directory": f"{root}/dl"})
        assert open(saved["paths"][0], "rb").read().startswith(b"\xff\xd8"), saved
        again = backend.call("asset.download", {"ids": [two], "directory": f"{root}/dl"})
        assert again["paths"][0].endswith("two (1).jpg"), again
        backend.call("asset.trash", {"ids": [one]})
        assert state(port)["assets"][one]["trashed"]
        restored = backend.call("asset.restore", {"ids": [one]})
        assert restored["restored"] == [one] and restored["notRestored"] == [], restored
        assert not state(port)["assets"][one]["trashed"]
        backend.call("asset.deleteForever", {"ids": [one]})
        assert one not in state(port)["assets"]
        print("ok: download, trash, restore and delete")

        # Drag-out export: originals into the cache, reused the second time.
        exported = backend.call("export.prepare", {"ids": [two]})["paths"]
        assert exported[0].endswith("/two.jpg") and open(exported[0], "rb").read().startswith(b"\xff\xd8"), exported
        again = backend.call("export.prepare", {"ids": [two]})["paths"]
        assert again == exported
        expect_error(backend, "export.prepare", {"ids": ["nope"]}, "id")
        print("ok: drag-out export")

        # Local files for the staging page.
        photo(f"{root}/stage/new.jpg", "brand new")
        photo(f"{root}/stage/sub/old.jpg", "two")
        photo(f"{root}/stage/.hidden/skip.jpg", "hidden")
        with open(f"{root}/stage/notes.txt", "w") as f:
            f.write("x")
        listed = backend.call("local.list", {"paths": [f"file://{root}/stage"]})
        names = sorted(i["name"] for i in listed["items"])
        assert names == ["new.jpg", "old.jpg"] and not listed["truncated"], listed
        checked = {os.path.basename(c["path"]): c["state"] for c in backend.call("local.check", {"paths": [i["path"] for i in listed["items"]]})}
        assert checked == {"new.jpg": "new", "old.jpg": "inImmich"}, checked
        print("ok: staging list and duplicate check")

        # Diagnostics leave out everything private.
        bundle = backend.call("diagnostics.export", {"directory": f"{root}/diag"})["directory"]
        files = sorted(os.listdir(bundle))
        assert files == ["config.redacted.json", "failed.redacted.json", "privacy-note.txt", "status.redacted.json", "summary.txt"], files
        text = "".join(open(os.path.join(bundle, f)).read() for f in files)
        for secret in (KEY, f"127.0.0.1:{port}", root):
            assert secret not in text, f"diagnostics leak {secret}"
        print("ok: diagnostics")

        expect_error(backend, "no.such.method", {}, "unknown method")
        print("all library checks passed")
    finally:
        if backend:
            backend.stop()
        mock.terminate()
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    main()
