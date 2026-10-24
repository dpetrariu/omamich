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
ALBUMS = {}   # id -> {id, albumName, assetIds: []}
LOG = []


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

    def album_view(self, album, with_assets=True):
        view = {"id": album["id"], "albumName": album["albumName"], "assetCount": len(album["assetIds"]),
                "albumUsers": [], "shared": False}
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
                    "assets": {k: {"name": v["originalFileName"], "trashed": v["isTrashed"]} for k, v in ASSETS.items()},
                    "albums": {v["albumName"]: v["assetIds"] for v in ALBUMS.values()},
                    "log": LOG,
                })
        if not self.authed():
            return
        if path == "/api/users/me":
            return self.reply(200, {"id": str(uuid.uuid4()), "name": "Test", "email": "test@example.com"})
        if path == "/api/albums":
            with LOCK:
                return self.reply(200, [self.album_view(a, False) for a in ALBUMS.values()])
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
                        results.append({"id": item["id"], "action": "reject", "reason": "duplicate", "assetId": found["id"]})
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
        if path == "/api/albums":
            body = json.loads(raw)
            with LOCK:
                album_id = str(uuid.uuid4())
                ALBUMS[album_id] = {"id": album_id, "albumName": body["albumName"], "assetIds": list(body.get("assetIds", []))}
                LOG.append(["album", body["albumName"]])
                return self.reply(201, self.album_view(ALBUMS[album_id], False))
        self.reply(404, {"message": "Not found"})

    def do_PUT(self):
        path = self.path.partition("?")[0]
        if not self.authed():
            return
        body = json.loads(self.body() or b"{}")
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
                        ASSETS[asset_id]["isTrashed"] = True
                        LOG.append(["trash", ASSETS[asset_id]["originalFileName"]])
            return self.reply(204)
        m = re.fullmatch(r"/api/albums/([0-9a-f-]{36})/assets", path)
        if m:
            with LOCK:
                album = ALBUMS[m.group(1)]
                album["assetIds"] = [a for a in album["assetIds"] if a not in body["ids"]]
            return self.reply(200, [{"id": i, "success": True} for i in body["ids"]])
        self.reply(404, {"message": "Not found"})


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
