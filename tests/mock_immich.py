#!/usr/bin/env python3
"""A small in-memory Immich for exercising sync without touching a real
library. It implements only the endpoints sync and the tests use.

usage: mock_immich.py PORT
"""
import base64
import hashlib
import json
import re
import sys
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

KEY = "testkey-0123456789"
LOCK = threading.Lock()
ASSETS = {}   # id -> {id, originalFileName, checksum(b64), data, isTrashed}
ALBUMS = {}   # id -> {id, albumName, assetIds: [], description, users: []}
TAGS = {}     # id -> {id, name, value, color, assetIds}
LINKS = {}    # id -> link
PEOPLE = {}   # id -> person
LOG = []
USER_ID = "11111111-1111-4111-8111-111111111111"


def checksum_b64(data):
    return base64.b64encode(hashlib.sha1(data).digest()).decode()


def parse_multipart(body, content_type):
    boundary = re.search(r"boundary=(.+)", content_type).group(1).strip('"').encode()
    parts = {}
    for chunk in body.split(b"--" + boundary):
        if b"\r\n\r\n" not in chunk:
            continue
        head, _, data = chunk.partition(b"\r\n\r\n")
        data = data[:-2] if data.endswith(b"\r\n") else data
        name = re.search(rb'name="([^"]+)"', head)
        filename = re.search(rb'filename="([^"]*)"', head)
        if name:
            parts[name.group(1).decode()] = (data, filename.group(1).decode() if filename else None)
    return parts


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, value=None, raw=None, ctype="application/json"):
        body = raw if raw is not None else (b"" if value is None else json.dumps(value).encode())
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def authed(self):
        if self.headers.get("x-api-key") != KEY:
            self.reply(401, {"message": "Invalid API key"})
            return False
        return True

    def asset_view(self, a):
        return {"id": a["id"], "originalFileName": a["originalFileName"], "type": "IMAGE", "checksum": a["checksum"],
                "isFavorite": a.get("isFavorite", False), "isTrashed": a["isTrashed"], "visibility": a.get("visibility", "timeline"),
                "exifInfo": {"description": a.get("description", ""), "rating": a.get("rating")},
                "people": [], "tags": [t for t in TAGS.values() if a["id"] in t["assetIds"]], "fileCreatedAt": "2026-01-01T00:00:00.000Z"}

    def album_view(self, album, with_assets=True):
        view = {"id": album["id"], "albumName": album["albumName"], "assetCount": len(album["assetIds"]),
                "description": album.get("description", ""), "order": album.get("order", "desc"),
                "albumThumbnailAssetId": album.get("cover"), "ownerId": USER_ID,
                "albumUsers": [{"user": {"id": u, "name": "U"}, "role": r} for u, r in album.get("users", {}).items()],
                "shared": bool(album.get("users"))}
        if with_assets:
            view["assets"] = [{"id": a, "originalFileName": ASSETS[a]["originalFileName"],
                               "checksum": ASSETS[a]["checksum"], "isTrashed": ASSETS[a]["isTrashed"]}
                              for a in album["assetIds"] if a in ASSETS]
        return view

    def do_GET(self):
        path, _, query = self.path.partition("?")
        if path == "/api/server/ping":
            return self.reply(200, {"res": "pong"})
        if path == "/api/server/version":
            return self.reply(200, {"major": 3, "minor": 3, "patch": 1})
        if path == "/_state":
            with LOCK:
                return self.reply(200, {
                    "assets": {k: {"name": v["originalFileName"], "trashed": v["isTrashed"], "favorite": v.get("isFavorite", False),
                                   "visibility": v.get("visibility", "timeline"), "rating": v.get("rating"),
                                   "description": v.get("description", "")} for k, v in ASSETS.items()},
                    "albumDetails": {k: {"name": v["albumName"], "description": v.get("description", ""), "users": v.get("users", {})} for k, v in ALBUMS.items()},
                    "tags": {k: {"name": v["name"], "assets": v["assetIds"], "color": v.get("color")} for k, v in TAGS.items()},
                    "links": list(LINKS.values()),
                    "people": PEOPLE,
                    "albums": {v["albumName"]: v["assetIds"] for v in ALBUMS.values()},
                    "log": LOG,
                })
        if not self.authed():
            return
        if path == "/api/users/me":
            return self.reply(200, {"id": str(uuid.uuid4()), "name": "Test", "email": "test@example.com"})
        if path == "/api/albums":
            with LOCK:
                albums = list(ALBUMS.values())
                if "assetId=" in query:
                    wanted = query.split("assetId=")[1].split("&")[0]
                    albums = [a for a in albums if wanted in a["assetIds"]]
                if "shared=true" in query:
                    albums = [a for a in albums if a.get("users")]
                return self.reply(200, [self.album_view(a, False) for a in albums])
        if path == "/api/tags":
            with LOCK:
                return self.reply(200, list(TAGS.values()))
        if path == "/api/shared-links":
            with LOCK:
                return self.reply(200, list(LINKS.values()))
        m = re.fullmatch(r"/api/assets/([0-9a-f-]{36})", path)
        if m:
            with LOCK:
                a = ASSETS.get(m.group(1))
                if not a:
                    return self.reply(404, {"message": "Not found"})
                return self.reply(200, self.asset_view(a))
        m = re.fullmatch(r"/api/albums/([0-9a-f-]{36})", path)
        if m:
            with LOCK:
                album = ALBUMS.get(m.group(1))
                if not album:
                    return self.reply(404, {"message": "Not found"})
                return self.reply(200, self.album_view(album, "withoutAssets=true" not in query))
        m = re.fullmatch(r"/api/assets/([0-9a-f-]{36})/original", path)
        if m:
            with LOCK:
                asset = ASSETS.get(m.group(1))
            if not asset:
                return self.reply(404, {"message": "Not found"})
            return self.reply(200, raw=asset["data"], ctype="image/jpeg")
        self.reply(404, {"message": "Not found"})

    def do_POST(self):
        path = self.path.partition("?")[0]
        if not self.authed():
            return
        raw = self.body()
        if path == "/api/assets/bulk-upload-check":
            items = json.loads(raw)["assets"]
            results = []
            with LOCK:
                for item in items:
                    b64 = base64.b64encode(bytes.fromhex(item["checksum"])).decode()
                    found = next((a for a in ASSETS.values() if a["checksum"] == b64), None)
                    if found:
                        results.append({"id": item["id"], "action": "reject", "reason": "duplicate", "assetId": found["id"],
                                        "isTrashed": found["isTrashed"]})
                    else:
                        results.append({"id": item["id"], "action": "accept"})
            return self.reply(200, {"results": results})
        if path == "/api/assets":
            parts = parse_multipart(raw, self.headers["Content-Type"])
            data, filename = parts["assetData"]
            b64 = checksum_b64(data)
            with LOCK:
                found = next((a for a in ASSETS.values() if a["checksum"] == b64), None)
                if found:
                    return self.reply(200, {"id": found["id"], "status": "duplicate"})
                asset_id = str(uuid.uuid4())
                ASSETS[asset_id] = {"id": asset_id, "originalFileName": filename, "checksum": b64, "data": data,
                                    "isTrashed": False, "sidecar": "sidecarData" in parts}
                LOG.append(["upload", filename])
            return self.reply(201, {"id": asset_id, "status": "created"})
        if path == "/api/trash/restore/assets":
            with LOCK:
                for i in json.loads(raw)["ids"]:
                    ASSETS[i]["isTrashed"] = False
            return self.reply(200, {"count": 1})
        if path == "/api/trash/restore":
            with LOCK:
                for a in ASSETS.values():
                    a["isTrashed"] = False
            return self.reply(200, {"count": 0})
        if path == "/api/trash/empty":
            with LOCK:
                for k in [k for k, a in ASSETS.items() if a["isTrashed"]]:
                    del ASSETS[k]
            return self.reply(200, {"count": 0})
        if path == "/api/tags":
            body = json.loads(raw)
            with LOCK:
                tag_id = str(uuid.uuid4())
                TAGS[tag_id] = {"id": tag_id, "name": body["name"], "value": body["name"], "color": body.get("color"), "assetIds": []}
                return self.reply(201, TAGS[tag_id])
        if path == "/api/shared-links":
            body = json.loads(raw)
            with LOCK:
                link_id = str(uuid.uuid4())
                LINKS[link_id] = dict(body, id=link_id, key="k" + link_id[:8])
                return self.reply(201, LINKS[link_id])
        m = re.fullmatch(r"/api/people/([0-9a-f-]{36})/merge", path)
        if m:
            with LOCK:
                for i in json.loads(raw)["ids"]:
                    PEOPLE.pop(i, None)
            return self.reply(200, [])
        if path == "/api/albums":
            body = json.loads(raw)
            with LOCK:
                album_id = str(uuid.uuid4())
                ALBUMS[album_id] = {"id": album_id, "albumName": body["albumName"], "assetIds": list(body.get("assetIds", []))}
                LOG.append(["album", body["albumName"]])
                return self.reply(201, self.album_view(ALBUMS[album_id], False))
        self.reply(404, {"message": "Not found"})

    def do_PATCH(self):
        path = self.path.partition("?")[0]
        if not self.authed():
            return
        body = json.loads(self.body() or b"{}")
        m = re.fullmatch(r"/api/albums/([0-9a-f-]{36})", path)
        if m:
            with LOCK:
                album = ALBUMS[m.group(1)]
                if "albumName" in body: album["albumName"] = body["albumName"]
                if "description" in body: album["description"] = body["description"]
                if "albumThumbnailAssetId" in body: album["cover"] = body["albumThumbnailAssetId"]
                if "order" in body: album["order"] = body["order"]
                return self.reply(200, self.album_view(album, False))
        m = re.fullmatch(r"/api/shared-links/([0-9a-f-]{36})", path)
        if m:
            with LOCK:
                LINKS[m.group(1)].update(body)
                return self.reply(200, LINKS[m.group(1)])
        self.reply(404, {"message": "Not found"})

    def do_PUT(self):
        path = self.path.partition("?")[0]
        if not self.authed():
            return
        body = json.loads(self.body() or b"{}")
        if path == "/api/assets":
            with LOCK:
                for i in body["ids"]:
                    for k in ("isFavorite", "visibility", "rating", "dateTimeOriginal"):
                        if k in body:
                            ASSETS[i][k] = body[k]
                LOG.append(["update", sorted(k for k in body if k != "ids")])
            return self.reply(204)
        m = re.fullmatch(r"/api/assets/([0-9a-f-]{36})", path)
        if m:
            with LOCK:
                ASSETS[m.group(1)]["description"] = body.get("description", "")
                return self.reply(200, self.asset_view(ASSETS[m.group(1)]))
        m = re.fullmatch(r"/api/albums/([0-9a-f-]{36})/users", path)
        if m:
            with LOCK:
                album = ALBUMS[m.group(1)]
                album.setdefault("users", {})
                for u in body["albumUsers"]:
                    album["users"][u["userId"]] = u["role"]
                return self.reply(200, self.album_view(album, False))
        m = re.fullmatch(r"/api/tags/([0-9a-f-]{36})/assets", path)
        if m:
            with LOCK:
                TAGS[m.group(1)]["assetIds"].extend(body["ids"])
            return self.reply(200, [{"id": i, "success": True} for i in body["ids"]])
        m = re.fullmatch(r"/api/tags/([0-9a-f-]{36})", path)
        if m:
            with LOCK:
                TAGS[m.group(1)]["color"] = body.get("color")
                return self.reply(200, TAGS[m.group(1)])
        m = re.fullmatch(r"/api/people/([0-9a-f-]{36})", path)
        if m:
            with LOCK:
                person = PEOPLE.setdefault(m.group(1), {"id": m.group(1), "name": "", "isHidden": False, "isFavorite": False, "birthDate": None})
                person.update(body)
                return self.reply(200, person)
        m = re.fullmatch(r"/api/albums/([0-9a-f-]{36})/assets", path)
        if m:
            with LOCK:
                album = ALBUMS[m.group(1)]
                out = []
                for asset_id in body["ids"]:
                    if asset_id in album["assetIds"]:
                        out.append({"id": asset_id, "success": False, "error": "duplicate"})
                    else:
                        album["assetIds"].append(asset_id)
                        out.append({"id": asset_id, "success": True})
            return self.reply(200, out)
        self.reply(404, {"message": "Not found"})

    def do_DELETE(self):
        path = self.path.partition("?")[0]
        if not self.authed():
            return
        body = json.loads(self.body() or b"{}")
        if path == "/api/assets":
            with LOCK:
                for asset_id in body["ids"]:
                    if asset_id in ASSETS:
                        if body.get("force"):
                            LOG.append(["delete", ASSETS.pop(asset_id)["originalFileName"]])
                        else:
                            ASSETS[asset_id]["isTrashed"] = True
                            LOG.append(["trash", ASSETS[asset_id]["originalFileName"]])
            return self.reply(204)
        m = re.fullmatch(r"/api/albums/([0-9a-f-]{36})/assets", path)
        if m:
            with LOCK:
                album = ALBUMS[m.group(1)]
                album["assetIds"] = [a for a in album["assetIds"] if a not in body["ids"]]
            return self.reply(200, [{"id": i, "success": True} for i in body["ids"]])
        m = re.fullmatch(r"/api/albums/([0-9a-f-]{36})/user/([0-9a-f-]{36}|me)", path)
        if m:
            with LOCK:
                ALBUMS[m.group(1)].get("users", {}).pop(m.group(2), None)
            return self.reply(204)
        m = re.fullmatch(r"/api/albums/([0-9a-f-]{36})", path)
        if m:
            with LOCK:
                ALBUMS.pop(m.group(1), None)
            return self.reply(204)
        m = re.fullmatch(r"/api/tags/([0-9a-f-]{36})/assets", path)
        if m:
            with LOCK:
                tag = TAGS[m.group(1)]
                tag["assetIds"] = [a for a in tag["assetIds"] if a not in body["ids"]]
            return self.reply(200, [])
        m = re.fullmatch(r"/api/tags/([0-9a-f-]{36})", path)
        if m:
            with LOCK:
                TAGS.pop(m.group(1), None)
            return self.reply(204)
        m = re.fullmatch(r"/api/shared-links/([0-9a-f-]{36})", path)
        if m:
            with LOCK:
                LINKS.pop(m.group(1), None)
            return self.reply(204)
        self.reply(404, {"message": "Not found"})


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
