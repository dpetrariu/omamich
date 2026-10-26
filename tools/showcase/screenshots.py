#!/usr/bin/env python3
"""Take the README's screenshots: the real Omamich window, off-screen,
connected to the mock Immich serving the showcase library (photos from
Wikimedia Commons, fetched by fetch.py). Nothing appears on the desktop and
no real library is involved.

usage: screenshots.py path/to/omamich SHOWCASE_DIR OUT_DIR

Writes OUT_DIR/{photos,viewer,albums,places}.webp and copies the showcase
CREDITS.md beside them.
"""
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.join(os.path.dirname(os.path.dirname(HERE)), "tests")
sys.path.insert(0, TESTS)
from sync_e2e import _ping, free_port, wait_for  # noqa: E402
from ui_e2e import Harness, asset_named  # noqa: E402


def main():
    binary, showcase, out = (os.path.abspath(a) for a in sys.argv[1:4])
    os.makedirs(out, exist_ok=True)
    port = free_port()
    root = tempfile.mkdtemp(prefix="omamich-shots-")
    mock = subprocess.Popen([sys.executable, "-I", os.path.join(TESTS, "mock_immich.py"), str(port), "--showcase", showcase])
    h = None
    try:
        wait_for("the mock is up", lambda: _ping(port), 10)
        h = Harness(binary, port, root, os.path.join(root, "shots"))
        os.makedirs(h.shots)
        wait_for("the window is up and connected", lambda: h.ipc("ready") == "yes", 30)
        wait_for("the timeline loads", lambda: h.value("app.activeGrid() ? app.activeGrid().total : 0") == 37, 20)

        def shot(name, settle=3):
            time.sleep(settle)  # thumbnails load and fade in
            png = h.shot(name)
            subprocess.run(["magick", png, "-quality", "88", os.path.join(out, name + ".webp")], check=True)

        shot("photos")
        seal = asset_named(port, "SEAL.JPG")
        h.js(f"app.openViewer({{ id: '{seal}', isImage: true, ratio: 1.5, thumbhash: null, fileCreatedAt: '2026-10-19T11:20:00' }})")
        wait_for("the viewer", lambda: h.value("app.viewerAsset ? app.viewerAsset.id : ''") == seal, 10)
        h.nav("info", 1.5)
        wait_for("details load", lambda: h.value("hooks.viewer.details ? hooks.viewer.details.originalFileName : ''") == "SEAL.JPG", 10)
        shot("viewer", 4)
        h.nav("back", 1)
        h.nav("go:albums", 2)
        wait_for("albums load", lambda: h.value("service.albums.length") == 6, 10)
        shot("albums")
        h.nav("go:places", 2)
        wait_for("places load", lambda: h.value("service.places.length") > 10, 10)
        shot("places")
        errors = h.errors()
        assert not errors, "".join(errors)
        shutil.copy(os.path.join(showcase, "CREDITS.md"), os.path.join(out, "CREDITS.md"))
        print("wrote", out)
    finally:
        if h:
            h.stop()
        mock.terminate()


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main()
