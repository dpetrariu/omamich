#!/usr/bin/env python3
"""A plugin installed without a backend downloads its own, the way a fresh
`omarchy plugin add` does. The release is a local stand-in built from the
binary under test and served on 127.0.0.1, so no network is needed.

usage: fetch_e2e.py path/to/omamich
"""
import hashlib
import http.server
import json
import os
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ui_e2e import Harness, free_port, wait_for, _ping  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)


def make_release(binary, version, folder, tamper=False):
    """A stand-in release; returns the backend.sha256 line for the genuine build.
    A tampered release also ships a SHA256SUMS that matches its tampered file,
    as anyone able to replace the release's files could."""
    arch = {"x86_64": "x86_64", "amd64": "x86_64", "aarch64": "aarch64", "arm64": "aarch64"}[platform.machine()]
    asset = f"omamich-{version}-linux-{arch}.tar.gz"
    out = os.path.join(folder, f"v{version}")
    os.makedirs(out, exist_ok=True)
    path = os.path.join(out, asset)
    with tarfile.open(path, "w:gz") as tar:
        tar.add(binary, arcname="omamich")
    pin = f"{hashlib.sha256(open(path, 'rb').read()).hexdigest()}  {asset}\n"
    if tamper:
        with open(path, "ab") as f:
            f.write(b"x")
    with open(os.path.join(out, "SHA256SUMS"), "w") as f:
        f.write(f"{hashlib.sha256(open(path, 'rb').read()).hexdigest()}  {asset}\n")
    return pin


def serve(folder):
    port = free_port()
    handler = lambda *a, **k: http.server.SimpleHTTPRequestHandler(*a, directory=folder, **k)  # noqa: E731
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{port}"


def plugin_copy(root, pin):
    """The plugin as `omarchy plugin add` leaves it: code and the committed
    checksums, no bin/, no target/."""
    plugin = os.path.join(root, "plugin")
    os.makedirs(plugin)
    for name in ("ui", "scripts"):
        shutil.copytree(os.path.join(REPO, name), os.path.join(plugin, name))
    shutil.copy(os.path.join(REPO, "manifest.json"), plugin)
    with open(os.path.join(plugin, "backend.sha256"), "w") as f:
        f.write("# test pins\n" + pin)
    return plugin


def start(binary_unused, port, root, plugin, releases, version):
    h = Harness("/nonexistent", port, root, root)
    h.stop()
    env = dict(h.env)
    env.pop("OMAMICH_BIN")
    env.update(OMAMICH_UI=os.path.join(plugin, "ui"), OMAMICH_VERSION=version, OMAMICH_RELEASES_URL=releases)
    h.env = env
    h.proc = subprocess.Popen(["qs", "-p", h.shell], env=env, stdout=h.log, stderr=subprocess.STDOUT)
    return h


def main():
    binary = os.path.abspath(sys.argv[1])
    version = json.load(open(os.path.join(REPO, "manifest.json")))["version"]
    port = free_port()
    mock = subprocess.Popen([sys.executable, "-I", os.path.join(HERE, "mock_immich.py"), str(port), "--seed"])
    work = tempfile.mkdtemp(prefix="omamich-fetch-")
    servers = []
    harnesses = []
    try:
        wait_for("mock is up", lambda: _ping(port), 10)

        # A genuine release: downloaded, checked, run.
        good = os.path.join(work, "good")
        pin = make_release(binary, version, good)
        server, url = serve(good)
        servers.append(server)
        root = os.path.join(work, "a")
        os.makedirs(root)
        plugin = plugin_copy(root, pin)
        h = start(binary, port, root, plugin, url, version)
        harnesses.append(h)
        wait_for("the backend is downloaded and running", lambda: h.ipc("ready") == "yes", 60)
        out = subprocess.run([os.path.join(plugin, "bin", "omamich"), "version"], capture_output=True, text=True).stdout
        assert out.startswith(f"omamich {version} "), out
        wait_for("the library loads", lambda: h.value("app.activeGrid() ? app.activeGrid().total : 0") > 0, 30)
        h.stop()
        print("ok: a fresh install downloads, verifies and runs its backend")

        # A tampered release, its SHA256SUMS rewritten to match: refused,
        # because only the checksum committed in the plugin counts.
        bad = os.path.join(work, "bad")
        pin = make_release(binary, version, bad, tamper=True)
        server, url = serve(bad)
        servers.append(server)
        root = os.path.join(work, "b")
        os.makedirs(root)
        plugin = plugin_copy(root, pin)
        h = start(binary, port, root, plugin, url, version)
        harnesses.append(h)
        wait_for("the download is refused", lambda: h.ipc("js", "service ? service.backendState : ''") == "failed", 60)
        assert "checksum" in h.ipc("js", "service.backendMessage"), h.ipc("js", "service.backendMessage")
        assert not os.path.exists(os.path.join(plugin, "bin", "omamich"))
        h.shot("fetch-refused")
        print("ok: a tampered download is refused and nothing is installed")

        # No committed checksum for this version: nothing is downloaded at all.
        root = os.path.join(work, "c")
        os.makedirs(root)
        plugin = plugin_copy(root, "")
        h = start(binary, port, root, plugin, url, version)
        harnesses.append(h)
        wait_for("the unpinned download is refused", lambda: h.ipc("js", "service ? service.backendState : ''") == "failed", 60)
        assert "no checksum" in h.ipc("js", "service.backendMessage"), h.ipc("js", "service.backendMessage")
        assert not os.path.exists(os.path.join(plugin, "bin", "omamich"))
        print("ok: a version without a committed checksum is not downloaded")
        print("all fetch checks passed")
    finally:
        for h in harnesses:
            h.stop()
        for s in servers:
            s.shutdown()
        mock.terminate()
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
