# tools/diagnostics/macos_stream_payload_mode_test.py
"""Qualify both real Lua payload writers under an explicit POSIX child umask."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

CONTROL_TIMEOUT_SECONDS = 60
LUA_REPLAY = r"""
local root = assert(arg[1])
assert(_VERSION == "Lua 5.4", "The private-file control requires Lua 5.4")
package.path = table.concat({ root .. "/?.lua", root .. "/?/init.lua",
    root .. "/../_shared/lua/?.lua", root .. "/../_shared/lua/?/init.lua", package.path }, ";")
require("test.runner_home").isolate()
_G.hs = require("tests.stubs.hs")
local fixture = require("tests.support.modules.llm.streaming_payload_fixture")
local observations = {}
for _, backend in ipairs({ "mlx", "ollama" }) do
    observations[backend] = fixture.assert_private_payload(backend)
end
print(assert(require("json").encode({ passed = 2, observations = observations })))
os.exit(0)
"""


def main():
    if os.name != "posix":
        raise RuntimeError("The native private-file control requires a POSIX host")
    root = Path(sys.argv[1]).resolve(strict=True)
    lua = shutil.which("lua")
    if not lua:
        raise RuntimeError("Lua 5.4 is required for the native private-file control")
    original_umask = os.umask(0)
    os.umask(original_umask)
    result = subprocess.run(
        [lua, "-", str(root)],
        cwd=root,
        input=LUA_REPLAY,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        preexec_fn=lambda: os.umask(0o022),
        timeout=CONTROL_TIMEOUT_SECONDS,
        check=False,
    )
    observed_umask = os.umask(0)
    os.umask(observed_umask)
    if observed_umask != original_umask:
        raise RuntimeError("The native control changed its parent's umask")
    if result.returncode != 0:
        raise RuntimeError("Native payload cases failed:\n" + result.stdout)
    receipt = json.loads(result.stdout)
    if receipt.get("passed") != 2 or set(receipt.get("observations", {})) != {
        "mlx",
        "ollama",
    }:
        raise RuntimeError("Both payload writers must report native observations")
    for observation in receipt["observations"].values():
        allocated = observation["allocated"]
        transported = observation["transport"]
        for record in (allocated, transported):
            if record["permissions"] != 0o600 or record["regular"] is not True:
                raise RuntimeError("A streaming payload lost its private file mode")
        if (allocated["device"], allocated["inode"]) != (
            transported["device"],
            transported["inode"],
        ):
            raise RuntimeError("Transport did not retain the allocated private inode")
    receipt.update({"umask": "0022", "parent_umask_preserved": True})
    print(json.dumps(receipt))


if __name__ == "__main__":
    main()
