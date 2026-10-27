#!/usr/bin/env python3
"""Fetch the showcase library's photos from Wikimedia Commons.

Reads library.json beside this file and, into DIR, writes images/ (the photo,
1600 px on its long side), thumbs/ (480 px), library.json (what
mock_immich.py --showcase DIR serves, with each photo's original size and
camera details from its own metadata) and CREDITS.md (every photo with its author,
licence and source page).

Each photo's licence is read from Commons' own record and anything but CC BY,
CC BY-SA, CC0 or public domain is refused, so the library can be shown
anywhere with the credits beside it. Downloads are cached in DIR/source/.

usage: fetch.py DIR
"""
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
API = "https://commons.wikimedia.org/w/api.php"
UA = {"User-Agent": "omamich-showcase/1 (https://github.com/dpetrariu/omamich)"}
FREE = re.compile(r"^(CC BY(-SA)? [0-9.]+( [a-z]{2})?|CC0|Public domain)$")


def number(value):
    """An EXIF rational ("28/10") or number as a float, or None."""
    m = re.fullmatch(r"\s*(-?[0-9.]+)\s*(?:/\s*([0-9.]+))?\s*", str(value))
    if not m:
        return None
    top, bottom = float(m.group(1)), float(m.group(2) or 1)
    return top / bottom if bottom else None


def camera(metadata):
    """Make, model and exposure from a file's embedded metadata, as Immich
    reports them (missing ones are left out)."""
    raw = {m["name"]: m["value"] for m in metadata or [] if isinstance(m.get("value"), (str, int, float))}
    out = {}
    if raw.get("Make"):
        out["make"] = str(raw["Make"]).strip()
    if raw.get("Model"):
        out["model"] = str(raw["Model"]).strip()
    if raw.get("LensModel"):
        out["lensModel"] = str(raw["LensModel"]).strip()
    f = number(raw.get("FNumber", ""))
    if f:
        out["fNumber"] = round(f, 1)
    focal = number(raw.get("FocalLength", ""))
    if focal:
        out["focalLength"] = round(focal, 1)
    iso = number(raw.get("ISOSpeedRatings", ""))
    if iso:
        out["iso"] = int(iso)
    exposure = number(raw.get("ExposureTime", ""))
    if exposure:
        out["exposureTime"] = "1/%d" % round(1 / exposure) if exposure < 1 else "%g" % exposure
    return out


def main():
    out = os.path.abspath(sys.argv[1])
    for sub in ("images", "thumbs", "source"):
        os.makedirs(os.path.join(out, sub), exist_ok=True)
    library = json.load(open(os.path.join(HERE, "library.json")))
    credits = []
    for photo in library["photos"]:
        q = {"action": "query", "titles": "File:" + photo["file"], "prop": "imageinfo", "iiprop": "url|size|extmetadata|metadata",
             "iiurlwidth": 1600, "iiextmetadatafilter": "LicenseShortName|LicenseUrl|Artist", "format": "json", "formatversion": 2}
        page = json.load(urllib.request.urlopen(urllib.request.Request(API + "?" + urllib.parse.urlencode(q), headers=UA), timeout=60))["query"]["pages"][0]
        if "imageinfo" not in page:
            sys.exit("not on Commons: " + photo["file"])
        info = page["imageinfo"][0]
        meta = {k: v.get("value", "") for k, v in info.get("extmetadata", {}).items()}
        licence = meta.get("LicenseShortName", "")
        if not FREE.match(licence):
            sys.exit("refusing %s: its licence is %r" % (photo["file"], licence))
        cache = os.path.join(out, "source", photo["key"] + ".jpg")
        if not os.path.exists(cache):
            with urllib.request.urlopen(urllib.request.Request(info["thumburl"], headers=UA), timeout=120) as resp:
                data = resp.read()
            open(cache + ".part", "wb").write(data)
            os.replace(cache + ".part", cache)
        image = os.path.join(out, "images", photo["key"] + ".jpg")
        subprocess.run(["magick", cache, "-auto-orient", "-resize", "1600x1600>", "-strip", "-quality", "86", image], check=True)
        subprocess.run(["magick", image, "-resize", "480x480>", "-quality", "82", os.path.join(out, "thumbs", photo["key"] + ".jpg")], check=True)
        size = subprocess.run(["magick", "identify", "-format", "%w %h", image], check=True, capture_output=True, text=True).stdout.split()
        photo.update(image="images/%s.jpg" % photo["key"], thumb="thumbs/%s.jpg" % photo["key"],
                     width=int(size[0]), height=int(size[1]), exif=camera(info.get("metadata")),
                     original={"width": info["width"], "height": info["height"], "bytes": info["size"]})
        author = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", "", meta.get("Artist", ""))).strip()
        credits.append((photo, {"page": info["descriptionurl"], "licence": licence, "licenceUrl": meta.get("LicenseUrl", ""), "author": author}))
        print("ok  %-24s %-14s %s" % (photo["key"], licence, photo["exif"].get("model", "")))
    json.dump(library, open(os.path.join(out, "library.json"), "w"), indent=1, ensure_ascii=False)

    lines = ["# Showcase photos", "",
             "The showcase library's photos come from Wikimedia Commons' quality images. Each was resized to fit; "
             "the dates shown with them are made up, the places are the photos' own. "
             "`preview.png`, the marketplace preview in the repository root, is the same screenshot as `docs/images/photos.webp`.", ""]
    for photo, c in credits:
        licence = "[%s](%s)" % (c["licence"], c["licenceUrl"]) if c["licenceUrl"] else c["licence"]
        lines.append("- [%s](%s), by %s, %s" % (photo["file"], c["page"], c["author"] or "unknown", licence))
    open(os.path.join(out, "CREDITS.md"), "w").write("\n".join(lines) + "\n")
    print("wrote", out)


if __name__ == "__main__":
    if len(sys.argv) != 2 or not shutil.which("magick"):
        sys.exit("usage: fetch.py DIR (needs ImageMagick)")
    main()
