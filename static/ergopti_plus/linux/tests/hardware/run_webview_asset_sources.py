#!/usr/bin/env python3
"""Check actual UI asset consumers against nonblocking native source types."""

import argparse
import os
from pathlib import Path
import socket
import subprocess
import tempfile

WORKER = r"""
require("compat.utf8").install()
local role, root = os.getenv("UI_ASSET_ROLE"), os.getenv("UI_ASSET_ROOT")
local regular = os.getenv("UI_ASSET_REGULAR") == "1"
local host = require("ui.webkit_host")
if role == "root" then
    assert((host.resolve_ui_root(root .. "/driver") ~= "") == regular)
elseif role == "locale" then
    assert((host.resolve_locales_dir(root .. "/driver") ~= "") == regular)
elseif role == "app" then
    assert((host.resolve_app_dir(root .. "/assets", "demo") ~= "") == regular)
elseif role == "html" or role == "script" or role == "style" then
    local content = host.build_injected_html(root .. "/assets/demo")
    assert((not content:find("Build error", 1, true)) == regular, role .. " admission")
    if regular and role == "script" then assert(content:find("ui_native_marker", 1, true)) end
    if regular and role == "style" then assert(content:find("ui_native_marker", 1, true)) end
else
    local paths = require("infra.paths")
    local original = paths.shared
    paths.shared = function(name)
        if name == "ui/apps.manifest.json" then return root .. "/geometry" end
        return original(name)
    end
    local handler = { bridge_name = "changelog_bridge", on_message = function() return {} end }
    local fixture = require("tests.support.document_fixture").new("changelog", handler, {})
    assert(fixture.windows[1].properties.default_width == (regular and 1011 or 800), "geometry fallback")
    assert(fixture.close())
end
"""


def bind_unix_socket(sock, path):
    """Bind by name from the parent directory: sun_path holds 108 bytes.

    The distribution jobs nest TMPDIR several levels deep, and the longest
    asset endpoint then overflowed the absolute path the kernel accepts.
    """
    previous = os.getcwd()
    os.chdir(path.parent)
    try:
        sock.bind(path.name)
    finally:
        os.chdir(previous)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", required=True)
    parser.add_argument("--driver", type=Path, required=True)
    args = parser.parse_args()
    total = 0
    with tempfile.TemporaryDirectory(prefix="ergopti-webview-sources-") as root_text:
        root = Path(root_text)
        for role in ("root", "locale", "app", "html", "script", "style", "geometry"):
            shapes = (
                "regular",
                "file-link",
                "fifo",
                "fifo-peer",
                "fifo-link",
                "directory",
                "socket",
            )
            for shape in shapes + (("invalid",) if role == "geometry" else ()):
                case = root / (role + "-" + shape)
                (case / "driver").mkdir(parents=True)
                assets = case / "assets" / "demo"
                assets.mkdir(parents=True)
                shared_ui = case / "_shared" / "ui"
                locales = case / "_shared" / "data" / "locales"
                shared_ui.mkdir(parents=True)
                locales.mkdir(parents=True)
                targets = {
                    "root": shared_ui / "host_bridge.js",
                    "locale": locales / "fr.json",
                    "app": assets / "index.html",
                    "html": assets / "index.html",
                    "script": assets / "script.js",
                    "style": assets / "style.css",
                    "geometry": case / "geometry",
                }
                endpoint = targets[role]
                if role == "script":
                    (assets / "index.html").write_text(
                        '<html><script src="script.js"></script></html>'
                    )
                if role == "style":
                    (assets / "index.html").write_text(
                        '<html><link rel="stylesheet" href="style.css"></html>'
                    )
                payload = {
                    "root": "// bridge",
                    "locale": "{}",
                    "app": "<html></html>",
                    "html": "<html></html>",
                    "script": "window.ui_native_marker = true;",
                    "style": "/* ui_native_marker */",
                    "geometry": '{"apps":{"changelog":{"width":1011}}}',
                }[role].encode()
                peer, sock = None, None
                if shape == "invalid":
                    endpoint.write_text("{invalid json")
                elif shape in ("regular", "file-link"):
                    actual = case / "regular-target" if shape == "file-link" else endpoint
                    actual.write_bytes(payload)
                    if shape == "file-link":
                        endpoint.symlink_to(actual)
                elif shape.startswith("fifo"):
                    actual = case / "pipe" if shape == "fifo-link" else endpoint
                    os.mkfifo(actual)
                    if shape == "fifo-link":
                        endpoint.symlink_to(actual)
                    if shape == "fifo-peer":
                        peer = os.open(actual, os.O_RDWR | os.O_NONBLOCK)
                        os.write(peer, b"do-not-consume")
                elif shape == "directory":
                    endpoint.mkdir()
                else:
                    sock = socket.socket(socket.AF_UNIX)
                    bind_unix_socket(sock, endpoint)
                before = endpoint.lstat()
                env = dict(
                    os.environ,
                    UI_ASSET_ROLE=role,
                    UI_ASSET_ROOT=str(case),
                    UI_ASSET_REGULAR="1" if shape in ("regular", "file-link") else "0",
                    XDG_CONFIG_HOME=str(root / "config"),
                    LUA_PATH="./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;;",
                )
                try:
                    result = subprocess.run(
                        [args.runtime, "-e", WORKER],
                        cwd=args.driver,
                        env=env,
                        capture_output=True,
                        text=True,
                        timeout=3,
                        check=False,
                    )
                    assert result.returncode == 0, (
                        role,
                        shape,
                        result.stdout[-1200:],
                        result.stderr[-1200:],
                    )
                    after = endpoint.lstat()
                    assert (before.st_dev, before.st_ino, before.st_mode) == (
                        after.st_dev,
                        after.st_ino,
                        after.st_mode,
                    )
                    if peer is not None:
                        assert os.read(peer, 64) == b"do-not-consume"
                    total += 1
                finally:
                    if peer is not None:
                        os.close(peer)
                    if sock is not None:
                        sock.close()
    print(f"WebView asset admission: {total} real inode cases passed")


if __name__ == "__main__":
    main()
