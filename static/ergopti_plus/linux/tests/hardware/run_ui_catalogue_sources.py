#!/usr/bin/env python3
"""Exercise UI catalogue readers against real regular and special inodes."""

import argparse
import os
from pathlib import Path
import socket
import subprocess
import tempfile

WORKER = r"""
require("core.lifecycle.engine.compat.utf8").install()
local paths = require("core.fs.engine.paths")
local original = paths.shared
local kind, endpoint = os.getenv("UI_SOURCE_KIND"), os.getenv("UI_SOURCE_PATH")
local target = kind == "catalogue" and require("onboarding.engine.answers").CATALOGUE_PATH
    or kind == "locale" and "core/i18n/data/locales/en.json" or "ai/data/models.json"
paths.shared = function(name) if name == target then return endpoint end return original(name) end
local regular = os.getenv("UI_SOURCE_REGULAR") == "1"
if kind == "catalogue" then
    local ok = pcall(require("ui.onboarding.bridge").config_values, {})
    assert(ok == regular, "onboarding catalogue admission")
elseif kind == "locale" then
    local bridge = require("ui.onboarding.bridge")
    local state = { i18n = { list_locales = function() return { "en" } end },
        webview_manager = { eval_js = function() return true end, set_title = function() return true end } }
    local result = bridge.on_message({ action = "previewLocale", locale = "en" }, state)
    assert(type(result) == "table" and result.pushed == regular, "onboarding locale admission")
else
    local bridge = require("ui.model_browser.bridge")
    local identity = {}
    local llm = { get_cached_models = function() return {} end,
                  get_cached_models_status = function() return {}, true, identity end, get_current_model = function() return "" end,
        refresh_models = function() return {} end }
    local f = require("tests.support.document_fixture").new("model_browser", bridge, { llm = llm })
    f.handshake()
    local ready = f.send("ready")
    assert(type(ready) == "table" and ready.pushed == true, "model page remains usable")
    assert((#ready.data.models > 0) == regular, "model catalogue admission")
    assert(f.close())
end
"""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", required=True)
    parser.add_argument("--driver", type=Path, required=True)
    args = parser.parse_args()
    sources = {
        "catalogue": "ui/_generated/onboarding_catalogue.json",
        "locale": "core/i18n/data/locales/en.json",
        "models": "ai/data/models.json",
    }
    total = 0
    with tempfile.TemporaryDirectory(prefix="ergopti-ui-sources-") as root_text:
        root = Path(root_text)
        for kind, relative in sources.items():
            for shape in (
                "regular",
                "file-link",
                "fifo",
                "fifo-link",
                "fifo-peer",
                "directory",
                "socket",
            ):
                case = root / (kind + "-" + shape)
                case.mkdir()
                endpoint = case / "source"
                peer = None
                sock = None
                if shape in ("regular", "file-link"):
                    actual = case / "target" if shape == "file-link" else endpoint
                    actual.write_bytes((args.driver.parent / "_shared" / relative).read_bytes())
                    if shape == "file-link":
                        endpoint.symlink_to(actual)
                elif shape.startswith("fifo"):
                    actual = case / "pipe" if shape == "fifo-link" else endpoint
                    os.mkfifo(actual)
                    if shape == "fifo-link":
                        endpoint.symlink_to(actual)
                    if shape == "fifo-peer":
                        peer = os.open(actual, os.O_RDWR | os.O_NONBLOCK)
                        os.write(peer, b'{"unexpected":true}')
                elif shape == "directory":
                    endpoint.mkdir()
                else:
                    sock = socket.socket(socket.AF_UNIX)
                    sock.bind(str(endpoint))
                before = endpoint.lstat()
                env = dict(
                    os.environ,
                    UI_SOURCE_KIND=kind,
                    UI_SOURCE_PATH=str(endpoint),
                    UI_SOURCE_REGULAR="1" if shape in ("regular", "file-link") else "0",
                    XDG_CONFIG_HOME=str(root / "config"),
                    LUA_PATH="./?.lua;./?/init.lua;../_shared/?.lua;../_shared/?/init.lua;;",
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
                        kind,
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
                        assert os.read(peer, 64) == b'{"unexpected":true}', (
                            "FIFO bytes must remain unconsumed"
                        )
                    total += 1
                finally:
                    if peer is not None:
                        os.close(peer)
                    if sock is not None:
                        sock.close()
    print(f"UI source admission: {total} real inode cases passed")


if __name__ == "__main__":
    main()
