#!/usr/bin/env bash
# tools/test/build-linux-distro-lua54.sh
# Build the real stock interpreter and native luv needed by dual-ABI tests.
set -euo pipefail
source_root="${1:?source checkout required}"
destination="${2:?fresh native dependency directory required}"
luv_source="${3:?verified luv checkout required}"
stock_interpreter=/usr/bin/lua5.4
# The ephemeral distribution root must not replace an incumbent executable.
if [ -e "$stock_interpreter" ] || [ -L "$stock_interpreter" ]; then
    printf '%s\n' 'Stock Lua interpreter destination already exists.' >&2
    exit 1
fi
pin_reader="$source_root/tools/build/read-native-source-pin.py"
version="$(python3 "$pin_reader" lua54 version)"
url="$(python3 "$pin_reader" lua54 url)"
digest="$(python3 "$pin_reader" lua54 sha256)"
luv_revision="$(python3 "$pin_reader" luv revision)"
test "$(git -C "$luv_source" rev-parse HEAD)" = "$luv_revision"
git -C "$luv_source" fsck --strict
mkdir -m 0755 "$destination"
mkdir -m 0755 "$destination/bin" "$destination/modules"
curl --fail --silent --show-error --location --max-time 120 "$url" -o "$destination/lua.tar.gz"
printf '%s  %s\n' "$digest" "$destination/lua.tar.gz" | sha256sum --check
# This archive is admitted before extraction; build the original Linux target,
# whose exported Lua symbols bind the extension to this exact interpreter.
tar -xzf "$destination/lua.tar.gz" -C "$destination"
lua_source="$destination/lua-$version"
make -C "$lua_source" -j2 linux
install -m 0755 "$lua_source/src/lua" "$destination/bin/lua5.4"
cmake -S "$luv_source" -B "$destination/luv-build" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DWITH_LUA_ENGINE=Lua -DLUA_BUILD_TYPE=System \
    -DLUA_INCLUDE_DIR="$lua_source/src" -DLUA_LIBRARY="$lua_source/src/liblua.a" \
    -DWITH_SHARED_LIBUV=ON -DBUILD_MODULE=ON -DBUILD_STATIC_LIBS=OFF -DBUILD_SHARED_LIBS=OFF
cmake --build "$destination/luv-build" --parallel 2
install -m 0644 "$destination/luv-build/luv.so" "$destination/modules/luv.so"
python3 - "$destination/bin/lua5.4" "$destination/modules/luv.so" "$lua_source/src/lua" <<'PY_ELF'
from pathlib import Path
import sys
assert Path(sys.argv[1]).read_bytes() == Path(sys.argv[3]).read_bytes()
for name in sys.argv[1:3]:
    path = Path(name)
    assert path.is_file() and not path.is_symlink()
    with path.open("rb") as stream:
        assert stream.read(4) == b"\x7fELF", "A genuine native ELF is required"
PY_ELF
# Use the genuine interpreter's own compiled module site. The canonical suite
# launcher stays unchanged, and sudo needs no extra environment-preservation rule.
stock_module="$(env -u LUA_CPATH -u LUA_CPATH_5_4 "$destination/bin/lua5.4" -e '
local site = assert(package.cpath:match("^([^;]+)"))
assert(site:match("^/[^?]*lua/5%.4/%?%.so$"), "A canonical stock ABI module site is required")
print((site:gsub("%?", "luv")))
')"
if [ -e "$stock_module" ] || [ -L "$stock_module" ]; then
    printf '%s\n' 'Stock Lua native module destination already exists.' >&2
    exit 1
fi
mkdir -p "$(dirname "$stock_module")"
install -m 0644 "$destination/modules/luv.so" "$stock_module"
install -m 0755 "$destination/bin/lua5.4" "$stock_interpreter"
env -u LUA_CPATH -u LUA_CPATH_5_4 "$stock_interpreter" -e '
assert(_VERSION == "Lua 5.4" and jit == nil)
local uv = require("luv")
assert(debug.getinfo(uv.fs_stat, "S").what == "C")
assert(uv.fs_stat(".").type == "directory")
print("Native stock Lua 5.4 and luv prerequisite admitted through standard discovery")
'
python3 - "$destination/bin/lua5.4" "$stock_interpreter" "$destination/modules/luv.so" "$stock_module" <<'PY_IDENTICAL'
from pathlib import Path
import sys
assert Path(sys.argv[1]).read_bytes() == Path(sys.argv[2]).read_bytes()
assert Path(sys.argv[3]).read_bytes() == Path(sys.argv[4]).read_bytes()
PY_IDENTICAL
sha256sum "$stock_interpreter" "$stock_module"
