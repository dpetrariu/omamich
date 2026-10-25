#!/usr/bin/env python3
"""An in-memory Immich for tests, so no real library is ever touched.

It implements the endpoints Omamich uses. Started plainly it is empty (the
sync tests upload into it); with --seed it holds a small synthetic library
with people, places, albums, tags, partners, trash and generated images, for
driving the whole window.

usage: mock_immich.py PORT [--seed]
"""
import base64
import hashlib
import json
import re
import struct
import sys
import threading
import uuid
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote

KEY = "testkey-0123456789"
LOCK = threading.Lock()
ME = "11111111-1111-4111-8111-111111111111"
ANA = "11111111-1111-4111-8111-222222222222"
BEN = "11111111-1111-4111-8111-333333333333"
USERS = {
    ME: {"id": ME, "name": "Test", "email": "test@example.com", "avatarColor": "blue"},
    ANA: {"id": ANA, "name": "Ana", "email": "ana@example.com", "avatarColor": "pink"},
    BEN: {"id": BEN, "name": "Ben", "email": "ben@example.com", "avatarColor": "green"},
}
ASSETS = {}    # id -> asset dict
ALBUMS = {}    # id -> {id, albumName, assetIds, description, order, cover, ownerId, users{uid: role}}
TAGS = {}      # id -> {id, name, value, color, assetIds}
LINKS = {}     # id -> link
PEOPLE = {}    # id -> {id, name, birthDate, isHidden, isFavorite, assetIds}
PREFS = {"folders": True, "tags": True, "people": True, "sharedLinks": True, "ratings": True}
PARTNERS = {"by": {}, "with": {}}   # by: I share with uid; with: uid shares with me {uid: inTimeline}
LOG = []


# ------------------------------------------------------------------ helpers

def png(width, height, rgb):
    raw = b"".join(b"\x00" + bytes(rgb) * width for _ in range(height))
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def color_of(text):
    digest = hashlib.sha1(text.encode()).digest()
    return (60 + digest[0] % 160, 60 + digest[1] % 160, 60 + digest[2] % 160)


def checksum_b64(data):
    return base64.b64encode(hashlib.sha1(data).digest()).decode()


def new_asset(name, data, created="2026-01-01T12:00:00.000Z", **extra):
    asset_id = str(uuid.uuid4())
    asset = {"id": asset_id, "originalFileName": name, "checksum": checksum_b64(data), "data": data,
             "isTrashed": False, "isFavorite": False, "visibility": "timeline", "rating": None, "description": "",
             "fileCreatedAt": created, "type": "IMAGE", "ratio": 1.5, "duration": None, "ownerId": ME,
             "city": None, "country": None, "lat": None, "lon": None, "livePhotoVideoId": None,
             "make": None, "model": None, "path": "/photos/" + created[:7].replace("-", "/") + "/" + name}
    asset.update(extra)
    ASSETS[asset_id] = asset
    return asset_id


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


def visible_to_me(a, with_partners=False):
    if a["ownerId"] == ME:
        return True
    return with_partners and PARTNERS["with"].get(a["ownerId"], False)


def scoped(query):
    """Assets matching a timeline scope, newest first."""
    q = {k: v[0] for k, v in parse_qs(query).items()}
    out = []
    for a in ASSETS.values():
        if "albumId" in q:
            album = ALBUMS.get(q["albumId"])
            if not album or a["id"] not in album["assetIds"]:
                continue
        elif "personId" in q:
            person = PEOPLE.get(q["personId"])
            if not person or a["id"] not in person["assetIds"]:
                continue
        elif "tagId" in q:
            tag = TAGS.get(q["tagId"])
            if not tag or a["id"] not in tag["assetIds"]:
                continue
        elif not visible_to_me(a, q.get("withPartners") == "true"):
            continue
        if (q.get("isTrashed") == "true") != a["isTrashed"]:
            continue
        if "isFavorite" in q and (q["isFavorite"] == "true") != a["isFavorite"]:
            continue
        if "visibility" in q and a["visibility"] != q["visibility"]:
            continue
        out.append(a)
    out.sort(key=lambda a: a["fileCreatedAt"], reverse=q.get("order") != "asc")
    return out


def bucket_of(a):
    return a["fileCreatedAt"][:7] + "-01"


def asset_view(a):
    tags = [{"id": t["id"], "name": t["name"], "value": t["value"], "color": t.get("color")}
            for t in TAGS.values() if a["id"] in t["assetIds"]]
    people = [{"id": p["id"], "name": p["name"], "isHidden": p["isHidden"], "updatedAt": "2026-01-01T00:00:00Z"}
              for p in PEOPLE.values() if a["id"] in p["assetIds"]]
    w = 1200
    h = int(w / a["ratio"])
    return {
        "id": a["id"], "originalFileName": a["originalFileName"], "type": a["type"], "checksum": a["checksum"],
        "isFavorite": a["isFavorite"], "isTrashed": a["isTrashed"], "visibility": a["visibility"],
        "fileCreatedAt": a["fileCreatedAt"], "localDateTime": a["fileCreatedAt"], "width": w, "height": h,
        "duration": a["duration"], "livePhotoVideoId": a["livePhotoVideoId"], "ownerId": a["ownerId"],
        "owner": {"id": a["ownerId"], "name": USERS[a["ownerId"]]["name"]}, "originalPath": a["path"],
        "originalMimeType": "image/png", "thumbhash": None, "isOffline": False, "isEdited": False,
        "exifInfo": {"description": a["description"], "rating": a["rating"], "city": a["city"], "country": a["country"],
                     "state": None, "latitude": a["lat"], "longitude": a["lon"], "make": a["make"], "model": a["model"],
                     "exifImageWidth": w, "exifImageHeight": h, "fileSizeInByte": len(a["data"]),
                     "dateTimeOriginal": a["fileCreatedAt"], "fNumber": 1.8 if a["make"] else None,
                     "focalLength": 26 if a["make"] else None, "iso": 100 if a["make"] else None,
                     "exposureTime": "1/250" if a["make"] else None, "lensModel": None, "timeZone": None},
        "people": people, "tags": tags,
    }


def columns(assets):
    keys = ["id", "ratio", "isImage", "isFavorite", "isTrashed", "visibility", "duration", "livePhotoVideoId",
            "fileCreatedAt", "localOffsetHours", "ownerId", "projectionType", "thumbhash", "city", "country"]
    out = {k: [] for k in keys}
    for a in assets:
        out["id"].append(a["id"])
        out["ratio"].append(a["ratio"])
        out["isImage"].append(a["type"] == "IMAGE")
        out["isFavorite"].append(a["isFavorite"])
        out["isTrashed"].append(a["isTrashed"])
        out["visibility"].append(a["visibility"])
        out["duration"].append(a["duration"])
        out["livePhotoVideoId"].append(a["livePhotoVideoId"])
        out["fileCreatedAt"].append(a["fileCreatedAt"].replace(".000Z", ""))
        out["localOffsetHours"].append(0)
        out["ownerId"].append(a["ownerId"])
        out["projectionType"].append(None)
        out["thumbhash"].append(None)
        out["city"].append(a["city"])
        out["country"].append(a["country"])
    return out


def search_page(items, body):
    page = int(body.get("page", 1))
    size = int(body.get("size", 100))
    chunk = items[(page - 1) * size: page * size]
    more = page * size < len(items)
    return {"albums": {"items": [], "total": 0, "count": 0}, "assets": {
        "items": [asset_view(a) for a in chunk], "total": len(items), "count": len(chunk),
        "nextPage": str(page + 1) if more else None, "facets": []}}


def album_view(album, with_assets=True):
    assets = [ASSETS[a] for a in album["assetIds"] if a in ASSETS]
    dates = sorted(a["fileCreatedAt"] for a in assets)
    view = {"id": album["id"], "albumName": album["albumName"], "assetCount": len(album["assetIds"]),
            "description": album.get("description", ""), "order": album.get("order", "desc"),
            "albumThumbnailAssetId": album.get("cover") or (album["assetIds"][0] if album["assetIds"] else None),
            "ownerId": album.get("ownerId", ME), "owner": USERS[album.get("ownerId", ME)],
            "startDate": dates[0] if dates else None, "endDate": dates[-1] if dates else None,
            "updatedAt": "2026-01-01T00:00:00Z", "createdAt": "2026-01-01T00:00:00Z",
            "albumUsers": [{"user": USERS.get(u, {"id": u, "name": "U"}), "role": r} for u, r in album.get("users", {}).items()],
            "shared": bool(album.get("users"))}
    if with_assets:
        view["assets"] = [{"id": a["id"], "originalFileName": a["originalFileName"], "checksum": a["checksum"],
                           "isTrashed": a["isTrashed"]} for a in assets]
    return view


def seed():
    """A small library that exercises every view."""
    months = [("2026-10", 14), ("2026-09", 22), ("2025-12", 9)]
    cities = [("Lausanne", "Switzerland", 46.52, 6.63), ("Turku", "Finland", 60.45, 22.27), (None, None, None, None)]
    ratios = [1.5, 0.75, 1.333, 1.778, 1.0, 0.5625, 2.4]
    ids = []
    n = 0
    for month, count in months:
        for i in range(count):
            n += 1
            day = 28 - (i * 2) % 27
            created = f"{month}-{day:02d}T{8 + i % 12:02d}:{(i * 7) % 60:02d}:00.000Z"
            city, country, lat, lon = cities[n % 3]
            name = f"IMG_{1000 + n}.JPG"
            ratio = ratios[n % len(ratios)]
            w = 96
            data = png(w, max(8, int(w / ratio)), color_of(name))
            extra = {"ratio": ratio, "city": city, "country": country, "lat": lat, "lon": lon}
            if n % 5 == 0:
                extra.update(make="Fujifilm", model="X-T5")
            if n in (3, 17):
                extra.update(type="VIDEO", duration="0:00:12.000", originalFileName=f"VID_{1000 + n}.MP4")
            ids.append(new_asset(name, data, created, **extra))
    ASSETS[ids[1]]["isFavorite"] = True
    ASSETS[ids[4]]["isFavorite"] = True
    ASSETS[ids[6]]["livePhotoVideoId"] = ids[3]
    ASSETS[ids[7]]["description"] = "Sunset over the lake"
    for k in (10, 11):
        ASSETS[ids[k]]["visibility"] = "archive"
    for k in (20, 21, 22):
        ASSETS[ids[k]]["isTrashed"] = True
    # Ana's photos, shared with me as a partner.
    for i in range(4):
        new_asset(f"ANA_{i}.JPG", png(96, 64, color_of(f"ana{i}")), f"2026-10-0{i + 1}T10:00:00.000Z", ownerId=ANA)
    PARTNERS["with"][ANA] = False
    people = [("Jenni", "1984-04-09"), ("Alvar", "2017-05-15"), ("Emma", None), ("", None), ("", None)]
    for p, (name, birth) in enumerate(people):
        pid = str(uuid.uuid4())
        PEOPLE[pid] = {"id": pid, "name": name, "birthDate": birth, "isHidden": False, "isFavorite": p == 0,
                       "assetIds": [ids[k] for k in range(p, len(ids), 4)]}
    for name, members in (("family", ids[0:6]), ("trip/2026", ids[12:18])):
        tid = str(uuid.uuid4())
        TAGS[tid] = {"id": tid, "name": name.split("/")[-1], "value": name, "color": "#4a90d9" if name == "family" else None,
                     "parentId": None, "assetIds": list(members)}
    trip = next(t for t in TAGS.values() if t["value"] == "trip/2026")
    parent_id = str(uuid.uuid4())
    TAGS[parent_id] = {"id": parent_id, "name": "trip", "value": "trip", "color": None, "parentId": None, "assetIds": []}
    trip["parentId"] = parent_id
    summer = str(uuid.uuid4())
    ALBUMS[summer] = {"id": summer, "albumName": "Summer", "assetIds": ids[14:24], "description": "Lake days",
                      "order": "desc", "cover": None, "ownerId": ME, "users": {}}
    from_ana = str(uuid.uuid4())
    ALBUMS[from_ana] = {"id": from_ana, "albumName": "Ana's garden", "assetIds": ids[30:34], "description": "",
                        "order": "desc", "cover": None, "ownerId": ANA, "users": {ME: "viewer"}}
    link = str(uuid.uuid4())
    LINKS[link] = {"id": link, "key": "seedkey", "type": "ALBUM", "description": "For grandma", "expiresAt": None,
                   "allowDownload": True, "allowUpload": False, "showMetadata": True, "password": None,
                   "album": {"id": summer, "albumName": "Summer", "albumThumbnailAssetId": ids[14]}, "assets": []}


# ------------------------------------------------------------------ server

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

    def not_found(self):
        self.reply(404, {"message": "Not found"})

    # ------------------------------------------------------------ GET
    def do_GET(self):
        path, _, query = self.path.partition("?")
        q = {k: v[0] for k, v in parse_qs(query).items()}
        if path == "/api/server/ping":
            return self.reply(200, {"res": "pong"})
        if path == "/api/server/version":
            return self.reply(200, {"major": 3, "minor": 3, "patch": 1})
        if path == "/_state":
            return self.state()
        if not self.authed():
            return
        with LOCK:
            return self.get(path, query, q)

    def state(self):
        with LOCK:
            return self.reply(200, {
                "assets": {k: {"name": v["originalFileName"], "trashed": v["isTrashed"], "favorite": v["isFavorite"],
                               "visibility": v["visibility"], "rating": v["rating"], "description": v["description"],
                               "date": v["fileCreatedAt"]} for k, v in ASSETS.items()},
                "albums": {v["albumName"]: v["assetIds"] for v in ALBUMS.values()},
                "albumDetails": {k: {"name": v["albumName"], "description": v.get("description", ""),
                                     "users": v.get("users", {})} for k, v in ALBUMS.items()},
                "tags": {k: {"name": v["name"], "assets": v["assetIds"], "color": v.get("color")} for k, v in TAGS.items()},
                "links": list(LINKS.values()),
                "people": {k: {kk: vv for kk, vv in v.items() if kk != "assetIds"} for k, v in PEOPLE.items()},
                "partners": PARTNERS,
                "log": LOG,
            })

    def get(self, path, query, q):
        if path == "/api/users/me":
            return self.reply(200, dict(USERS[ME], isAdmin=True, quotaUsageInBytes=0, quotaSizeInBytes=None))
        if path == "/api/users":
            return self.reply(200, list(USERS.values()))
        if path == "/api/users/me/preferences":
            return self.reply(200, {k: {"enabled": v} for k, v in PREFS.items()})
        if path == "/api/server/about":
            return self.reply(200, {"version": "v3.3.1", "build": "test", "repository": "immich-app/immich", "licensed": False})
        if path == "/api/server/features":
            return self.reply(200, {"smartSearch": True, "facialRecognition": True, "map": True, "ocr": True, "trash": True})
        if path == "/api/server/storage":
            return self.reply(200, {"diskSize": "1 TiB", "diskUse": "100 GiB", "diskAvailable": "924 GiB", "diskUsagePercentage": 9.8})
        if path == "/api/assets/statistics":
            items = scoped(query)
            images = sum(1 for a in items if a["type"] == "IMAGE")
            return self.reply(200, {"images": images, "videos": len(items) - images, "total": len(items)})
        if path == "/api/timeline/buckets":
            counts = {}
            for a in scoped(query):
                counts[bucket_of(a)] = counts.get(bucket_of(a), 0) + 1
            order = sorted(counts, reverse=q.get("order") != "asc")
            return self.reply(200, [{"timeBucket": b, "count": counts[b]} for b in order])
        if path == "/api/timeline/bucket":
            items = [a for a in scoped(query) if bucket_of(a) == q.get("timeBucket")]
            return self.reply(200, columns(items))
        if path == "/api/albums":
            albums = list(ALBUMS.values())
            if "assetId" in q:
                albums = [a for a in albums if q["assetId"] in a["assetIds"]]
            if q.get("shared") == "true":
                albums = [a for a in albums if a.get("users")]
            elif q.get("shared") == "false":
                albums = [a for a in albums if not a.get("users")]
            return self.reply(200, [album_view(a, False) for a in albums])
        m = re.fullmatch(r"/api/albums/([0-9a-f-]{36})", path)
        if m:
            album = ALBUMS.get(m.group(1))
            return self.reply(200, album_view(album, q.get("withoutAssets") != "true")) if album else self.not_found()
        m = re.fullmatch(r"/api/assets/([0-9a-f-]{36})(/[a-z/]+)?", path)
        if m:
            a = ASSETS.get(m.group(1))
            if not a:
                return self.not_found()
            if m.group(2) is None:
                return self.reply(200, asset_view(a))
            if m.group(2) in ("/thumbnail", "/original"):
                return self.reply(200, raw=a["data"], ctype="image/png")
            return self.not_found()
        if path == "/api/people":
            people = [p for p in PEOPLE.values() if q.get("withHidden") == "true" or not p["isHidden"]]
            page, size = int(q.get("page", 1)), int(q.get("size", 500))
            chunk = people[(page - 1) * size: page * size]
            return self.reply(200, {"people": [self.person(p) for p in chunk], "total": len(people),
                                    "hidden": sum(p["isHidden"] for p in PEOPLE.values()),
                                    "hasNextPage": page * size < len(people)})
        m = re.fullmatch(r"/api/people/([0-9a-f-]{36})(/[a-z]+)?", path)
        if m:
            p = PEOPLE.get(m.group(1))
            if not p:
                return self.not_found()
            if m.group(2) == "/thumbnail":
                return self.reply(200, raw=png(64, 64, color_of(p["id"])), ctype="image/png")
            if m.group(2) == "/statistics":
                return self.reply(200, {"assets": len(p["assetIds"])})
            return self.reply(200, self.person(p))
        m = re.fullmatch(r"/api/users/([0-9a-f-]{36})/profile-image", path)
        if m:
            return self.reply(200, raw=png(32, 32, color_of(m.group(1))), ctype="image/png")
        if path == "/api/search/explore":
            seen = {}
            for a in ASSETS.values():
                if a["city"] and a["city"] not in seen:
                    seen[a["city"]] = a["id"]
            return self.reply(200, [{"fieldName": "exifInfo.city", "items": [{"value": c, "data": {"id": i}} for c, i in seen.items()]}])
        if path == "/api/map/markers":
            return self.reply(200, [{"id": a["id"], "lat": a["lat"], "lon": a["lon"], "city": a["city"], "state": None,
                                     "country": a["country"]} for a in ASSETS.values() if a["lat"] is not None and not a["isTrashed"]])
        if path == "/api/search/suggestions":
            if q.get("type") == "camera-make":
                return self.reply(200, sorted({a["make"] for a in ASSETS.values() if a["make"]}))
            if q.get("type") == "camera-model":
                return self.reply(200, sorted({a["model"] for a in ASSETS.values() if a["model"] and a["make"] == q.get("make")}))
            if q.get("type") == "country":
                return self.reply(200, sorted({a["country"] for a in ASSETS.values() if a["country"]}))
            return self.reply(200, sorted({a["city"] for a in ASSETS.values() if a["city"]}))
        if path == "/api/tags":
            return self.reply(200, [{k: v for k, v in t.items() if k != "assetIds"} for t in TAGS.values()])
        if path == "/api/shared-links":
            return self.reply(200, list(LINKS.values()))
        if path == "/api/partners":
            side = PARTNERS["by"] if q.get("direction") == "shared-by" else PARTNERS["with"]
            return self.reply(200, [dict(USERS[u], inTimeline=v) for u, v in side.items()])
        if path == "/api/view/folder/unique-paths":
            return self.reply(200, sorted({a["path"].rsplit("/", 1)[0] for a in ASSETS.values()}))
        if path == "/api/view/folder":
            folder = unquote(q.get("path", ""))
            return self.reply(200, [asset_view(a) for a in ASSETS.values() if a["path"].rsplit("/", 1)[0] == folder])
        self.not_found()

    def person(self, p):
        return {"id": p["id"], "name": p["name"], "birthDate": p["birthDate"], "isHidden": p["isHidden"],
                "isFavorite": p["isFavorite"], "updatedAt": "2026-01-01T00:00:00Z"}

    # ------------------------------------------------------------ POST
    def do_POST(self):
        path = self.path.partition("?")[0]
        if not self.authed():
            return
        raw = self.body()
        if path == "/_prefs":
            with LOCK:
                PREFS.update(json.loads(raw))
            return self.reply(200, PREFS)
        if path == "/api/assets":
            parts = parse_multipart(raw, self.headers["Content-Type"])
            data, filename = parts["assetData"]
            if "broken" in filename:
                return self.reply(400, {"message": "Unsupported file"})
            b64 = checksum_b64(data)
            with LOCK:
                found = next((a for a in ASSETS.values() if a["checksum"] == b64), None)
                if found:
                    return self.reply(200, {"id": found["id"], "status": "duplicate"})
                created = parts.get("fileCreatedAt", (b"2026-01-01T00:00:00.000Z", None))[0].decode()
                asset_id = new_asset(filename, data, created, sidecar="sidecarData" in parts)
                LOG.append(["upload", filename])
            return self.reply(201, {"id": asset_id, "status": "created"})
        body = json.loads(raw or b"{}")
        with LOCK:
            return self.post(path, body)

    def post(self, path, body):
        if path == "/api/assets/bulk-upload-check":
            results = []
            for item in body["assets"]:
                b64 = base64.b64encode(bytes.fromhex(item["checksum"])).decode()
                found = next((a for a in ASSETS.values() if a["checksum"] == b64), None)
                if found:
                    results.append({"id": item["id"], "action": "reject", "reason": "duplicate",
                                    "assetId": found["id"], "isTrashed": found["isTrashed"]})
                else:
                    results.append({"id": item["id"], "action": "accept"})
            return self.reply(200, {"results": results})
        if path == "/api/trash/restore/assets":
            for i in body["ids"]:
                ASSETS[i]["isTrashed"] = False
            return self.reply(200, {"count": len(body["ids"])})
        if path == "/api/trash/restore":
            for a in ASSETS.values():
                a["isTrashed"] = False
            return self.reply(200, {"count": 0})
        if path == "/api/trash/empty":
            for k in [k for k, a in ASSETS.items() if a["isTrashed"]]:
                del ASSETS[k]
            return self.reply(200, {"count": 0})
        if path in ("/api/search/metadata", "/api/search/smart"):
            items = [a for a in ASSETS.values() if not a["isTrashed"] and a["ownerId"] == ME]
            if body.get("visibility"):
                items = [a for a in items if a["visibility"] == body["visibility"]]
            for key in ("city", "country"):
                if body.get(key):
                    items = [a for a in items if a[key] == body[key]]
            if body.get("originalFileName"):
                items = [a for a in items if body["originalFileName"].lower() in a["originalFileName"].lower()]
            if body.get("description"):
                items = [a for a in items if body["description"].lower() in a["description"].lower()]
            if body.get("query"):
                words = body["query"].lower().split()
                items = [a for a in items if any(w in (a["description"] + " " + a["originalFileName"]).lower() for w in words)]
            if body.get("type"):
                items = [a for a in items if a["type"] == body["type"]]
            if body.get("isFavorite"):
                items = [a for a in items if a["isFavorite"]]
            for person_id in body.get("personIds", []):
                members = PEOPLE.get(person_id, {}).get("assetIds", [])
                items = [a for a in items if a["id"] in members]
            for tag_id in body.get("tagIds", []):
                members = TAGS.get(tag_id, {}).get("assetIds", [])
                items = [a for a in items if a["id"] in members]
            if body.get("takenAfter"):
                items = [a for a in items if a["fileCreatedAt"] >= body["takenAfter"]]
            if body.get("takenBefore"):
                items = [a for a in items if a["fileCreatedAt"] <= body["takenBefore"]]
            if body.get("make"):
                items = [a for a in items if a["make"] == body["make"]]
            if body.get("model"):
                items = [a for a in items if a["model"] == body["model"]]
            if body.get("isNotInAlbum"):
                in_albums = {i for al in ALBUMS.values() for i in al["assetIds"]}
                items = [a for a in items if a["id"] not in in_albums]
            items.sort(key=lambda a: a["fileCreatedAt"], reverse=True)
            return self.reply(200, search_page(items, body))
        if path == "/api/albums":
            album_id = str(uuid.uuid4())
            ALBUMS[album_id] = {"id": album_id, "albumName": body["albumName"], "assetIds": list(body.get("assetIds", [])),
                                "description": body.get("description", ""), "ownerId": ME, "users": {}}
            LOG.append(["album", body["albumName"]])
            return self.reply(201, album_view(ALBUMS[album_id], False))
        if path == "/api/tags":
            tag_id = str(uuid.uuid4())
            TAGS[tag_id] = {"id": tag_id, "name": body["name"], "value": body["name"], "color": body.get("color"), "assetIds": []}
            return self.reply(201, {k: v for k, v in TAGS[tag_id].items() if k != "assetIds"})
        if path == "/api/shared-links":
            link_id = str(uuid.uuid4())
            LINKS[link_id] = dict(body, id=link_id, key="k" + link_id[:8], assets=[{"id": i} for i in body.get("assetIds", [])])
            return self.reply(201, LINKS[link_id])
        if path == "/api/partners":
            PARTNERS["by"][body["sharedWithId"]] = False
            return self.reply(201, USERS[body["sharedWithId"]])
        m = re.fullmatch(r"/api/people/([0-9a-f-]{36})/merge", path)
        if m:
            target = PEOPLE.get(m.group(1))
            for i in body["ids"]:
                gone = PEOPLE.pop(i, None)
                if gone and target:
                    target["assetIds"].extend(gone["assetIds"])
            return self.reply(200, [])
        self.not_found()

    # ------------------------------------------------------------ PUT / PATCH / DELETE
    def do_PUT(self):
        self.write("PUT")

    def do_PATCH(self):
        self.write("PATCH")

    def do_DELETE(self):
        self.write("DELETE")

    def write(self, method):
        path = self.path.partition("?")[0]
        if not self.authed():
            return
        body = json.loads(self.body() or b"{}")
        with LOCK:
            return getattr(self, method.lower())(path, body)

    def put(self, path, body):
        if path == "/api/tags":
            # Upsert by path, creating parents, like Immich.
            out = []
            for full in body["tags"]:
                parent = None
                parts = [p for p in full.split("/") if p]
                for depth in range(len(parts)):
                    value = "/".join(parts[:depth + 1])
                    tag = next((t for t in TAGS.values() if t["value"] == value), None)
                    if not tag:
                        tag_id = str(uuid.uuid4())
                        tag = TAGS[tag_id] = {"id": tag_id, "name": parts[depth], "value": value, "color": None,
                                              "parentId": parent, "assetIds": []}
                    parent = tag["id"]
                out.append({k: v for k, v in tag.items() if k != "assetIds"})
            return self.reply(200, out)
        if path == "/api/assets":
            for i in body["ids"]:
                for k in ("isFavorite", "visibility", "rating"):
                    if k in body:
                        ASSETS[i][k] = body[k]
                if "dateTimeOriginal" in body:
                    ASSETS[i]["fileCreatedAt"] = body["dateTimeOriginal"][:19] + ".000Z"
            LOG.append(["update", sorted(k for k in body if k != "ids")])
            return self.reply(204)
        m = re.fullmatch(r"/api/assets/([0-9a-f-]{36})", path)
        if m:
            ASSETS[m.group(1)]["description"] = body.get("description", "")
            return self.reply(200, asset_view(ASSETS[m.group(1)]))
        m = re.fullmatch(r"/api/albums/([0-9a-f-]{36})/assets", path)
        if m:
            album = ALBUMS[m.group(1)]
            out = []
            for asset_id in body["ids"]:
                if asset_id in album["assetIds"]:
                    out.append({"id": asset_id, "success": False, "error": "duplicate"})
                else:
                    album["assetIds"].append(asset_id)
                    out.append({"id": asset_id, "success": True})
            return self.reply(200, out)
        m = re.fullmatch(r"/api/albums/([0-9a-f-]{36})/users", path)
        if m:
            album = ALBUMS[m.group(1)]
            for u in body["albumUsers"]:
                album.setdefault("users", {})[u["userId"]] = u["role"]
            return self.reply(200, album_view(album, False))
        m = re.fullmatch(r"/api/albums/([0-9a-f-]{36})/user/([0-9a-f-]{36})", path)
        if m:
            album = ALBUMS[m.group(1)]
            if m.group(2) not in album.get("users", {}):
                return self.reply(400, {"message": "Not a member"})
            album["users"][m.group(2)] = body["role"]
            return self.reply(204)
        m = re.fullmatch(r"/api/tags/([0-9a-f-]{36})/assets", path)
        if m:
            TAGS[m.group(1)]["assetIds"].extend(body["ids"])
            return self.reply(200, [{"id": i, "success": True} for i in body["ids"]])
        m = re.fullmatch(r"/api/tags/([0-9a-f-]{36})", path)
        if m:
            TAGS[m.group(1)]["color"] = body.get("color")
            return self.reply(200, {k: v for k, v in TAGS[m.group(1)].items() if k != "assetIds"})
        m = re.fullmatch(r"/api/people/([0-9a-f-]{36})", path)
        if m:
            person = PEOPLE.setdefault(m.group(1), {"id": m.group(1), "name": "", "isHidden": False, "isFavorite": False,
                                                    "birthDate": None, "assetIds": []})
            person.update(body)
            return self.reply(200, self.person(person))
        m = re.fullmatch(r"/api/partners/([0-9a-f-]{36})", path)
        if m:
            PARTNERS["with"][m.group(1)] = bool(body.get("inTimeline"))
            return self.reply(200, dict(USERS[m.group(1)], inTimeline=PARTNERS["with"][m.group(1)]))
        self.not_found()

    def patch(self, path, body):
        m = re.fullmatch(r"/api/albums/([0-9a-f-]{36})", path)
        if m:
            album = ALBUMS[m.group(1)]
            for key, field in (("albumName", "albumName"), ("description", "description"),
                               ("albumThumbnailAssetId", "cover"), ("order", "order")):
                if key in body:
                    album[field] = body[key]
            return self.reply(200, album_view(album, False))
        m = re.fullmatch(r"/api/shared-links/([0-9a-f-]{36})", path)
        if m:
            LINKS[m.group(1)].update(body)
            return self.reply(200, LINKS[m.group(1)])
        self.not_found()

    def delete(self, path, body):
        if path == "/api/assets":
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
            album = ALBUMS[m.group(1)]
            album["assetIds"] = [a for a in album["assetIds"] if a not in body["ids"]]
            return self.reply(200, [{"id": i, "success": True} for i in body["ids"]])
        m = re.fullmatch(r"/api/albums/([0-9a-f-]{36})/user/([0-9a-f-]{36}|me)", path)
        if m:
            user = ME if m.group(2) == "me" else m.group(2)
            ALBUMS[m.group(1)].get("users", {}).pop(user, None)
            return self.reply(204)
        m = re.fullmatch(r"/api/albums/([0-9a-f-]{36})", path)
        if m:
            ALBUMS.pop(m.group(1), None)
            return self.reply(204)
        m = re.fullmatch(r"/api/tags/([0-9a-f-]{36})/assets", path)
        if m:
            tag = TAGS[m.group(1)]
            tag["assetIds"] = [a for a in tag["assetIds"] if a not in body["ids"]]
            return self.reply(200, [])
        m = re.fullmatch(r"/api/tags/([0-9a-f-]{36})", path)
        if m:
            TAGS.pop(m.group(1), None)
            return self.reply(204)
        m = re.fullmatch(r"/api/shared-links/([0-9a-f-]{36})", path)
        if m:
            LINKS.pop(m.group(1), None)
            return self.reply(204)
        m = re.fullmatch(r"/api/partners/([0-9a-f-]{36})", path)
        if m:
            PARTNERS["by"].pop(m.group(1), None)
            return self.reply(204)
        self.not_found()


if __name__ == "__main__":
    if "--seed" in sys.argv:
        seed()
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
