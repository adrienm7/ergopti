import os
import subprocess
import tempfile
import struct
import zlib
import random
import shutil

env = os.environ.copy()
env["LUA_PATH"] = "./?.lua;./?/init.lua;../_shared/?.lua;../_shared/?/init.lua;;"
assert os.access("/usr/bin/convert", os.X_OK), "ImageMagick convert is required"
assert_luajit = shutil.which("luajit")
assert assert_luajit, "LuaJIT is required"
script = subprocess.check_output(
    [assert_luajit, "-e", "io.write(require('adapters.screen_capture').SCRIPT)"], env=env
).decode()
with tempfile.TemporaryDirectory(prefix="ergopti-resize-native-") as temp:

    def chunk(kind, data):
        return (
            struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
        )

    rng = random.Random(42)
    raw = b"".join(b"\0" + bytes(rng.randrange(256) for _ in range(64 * 3)) for _ in range(64))
    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", 64, 64, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw))
        + chunk(b"IEND", b"")
    )
    source = temp + "/original.png"
    open(source, "wb").write(png)
    bindir = temp + "/bin"
    os.mkdir(bindir)
    open(bindir + "/grim", "w").write('#!/bin/sh\n/bin/cp -- "$SOURCE_PNG" "$1"\n')
    open(bindir + "/convert", "w").write(
        '#!/usr/bin/python3\nimport os,resource,sys\nresource.setrlimit(resource.RLIMIT_CORE,(0,0))\nresource.setrlimit(resource.RLIMIT_FSIZE,(128,128))\nos.execv("/usr/bin/convert",["convert"]+sys.argv[1:])\n'
    )
    for name in ["grim", "convert"]:
        os.chmod(bindir + "/" + name, 0o700)
    for name in ["rm", "mv"]:
        os.symlink("/bin/" + name, bindir + "/" + name)
    # A genuine write failure, proved by a pair instead of ImageMagick 6's
    # « WriteBlob Failed » text (ImageMagick 7 on Ubuntu 26.04 words it
    # differently): the size-limited convert fails on this input and the same
    # unlimited convert succeeds.
    probe = [source, "-resize", "50%"]
    limited = subprocess.run(
        [bindir + "/convert", *probe, temp + "/limited.png"], capture_output=True
    )
    assert limited.returncode != 0, "the size-limited convert must fail to write"
    unlimited = subprocess.run(
        ["/usr/bin/convert", *probe, temp + "/unlimited.png"], capture_output=True
    )
    assert unlimited.returncode == 0, unlimited.stderr
    env.update(PATH=bindir, SOURCE_PNG=source, WAYLAND_DISPLAY="")
    out = temp + "/screen.png"
    result = subprocess.run(
        ["/bin/sh", "-c", script, "sh", out, "64", "full"], env=env, capture_output=True
    )
    data = open(out, "rb").read()
    assert result.returncode == 0, "capture must retain the original on resize failure"
    assert result.stdout.decode().strip() == "ergopti-unscaled"
    assert data == png, "failed ImageMagick write must not truncate the original"
    assert not os.path.exists(out + ".scaled.png"), "partial resized output must be removed"
    print("PASS native ImageMagick write failure preserves original PNG")
