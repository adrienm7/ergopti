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
    for name in ["rm", "mv", "tail", "od", "tr"]:
        os.symlink("/bin/" + name, bindir + "/" + name)
    # A genuine write failure, proved by a pair instead of ImageMagick's
    # wording: the size-limited convert cannot write this resize whole (IM6
    # exits nonzero; IM7, Ubuntu 26.04, exits 0 and leaves a truncated file),
    # and the same unlimited convert writes it whole. A whole PNG ends with
    # its IEND chunk and that chunk's fixed CRC.
    iend = bytes.fromhex("49454e44ae426082")
    probe = [source, "-resize", "50%"]
    limited_out, unlimited_out = temp + "/limited.png", temp + "/unlimited.png"
    limited = subprocess.run([bindir + "/convert", *probe, limited_out], capture_output=True)
    limited_whole = os.path.exists(limited_out) and open(limited_out, "rb").read().endswith(iend)
    assert limited.returncode != 0 or not limited_whole, "the size limit must cut the write"
    unlimited = subprocess.run(["/usr/bin/convert", *probe, unlimited_out], capture_output=True)
    assert unlimited.returncode == 0, unlimited.stderr
    assert open(unlimited_out, "rb").read().endswith(iend), "the unlimited resize is whole"
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

    # ImageMagick 7's exact refusal, on any host: a resize that exits 0 after
    # writing only part of its PNG. A status check alone replaced the original.
    open(bindir + "/convert", "w").write(
        '#!/bin/sh\n/usr/bin/head -c 64 -- "$SOURCE_PNG" > "$4"\nexit 0\n'
    )
    os.chmod(bindir + "/convert", 0o700)
    open(out, "wb").close()
    os.remove(out)
    result = subprocess.run(
        ["/bin/sh", "-c", script, "sh", out, "64", "full"], env=env, capture_output=True
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout.decode().strip() == "ergopti-unscaled"
    assert open(out, "rb").read() == png, (
        "a truncated resize reported as success must not replace the original"
    )
    assert not os.path.exists(out + ".scaled.png"), "the truncated resize must be removed"
    print("PASS a truncated resize that exits 0 keeps the original PNG")
