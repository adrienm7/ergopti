#!/usr/bin/env bash
# static/ergopti_plus/linux/install/build_native_luv.sh
# Build the canonical pinned source against the recipient's actual LuaJIT.
# Source, compiler and Git stages remain retained on refusal or interruption.

set -euo pipefail
[ "$#" -ge 4 ] || { echo "Native luv source recipe required" >&2; exit 2; }
STAGE="$1"
SOURCE_URL="$2"
SOURCE_REVISION="$3"
shift 3
[[ "$STAGE" == /* && -d "$STAGE" && ! -L "$STAGE" ]] || exit 2
[[ "$SOURCE_URL" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git$ ]] || exit 2
[[ "$SOURCE_REVISION" =~ ^[0-9a-f]{40}$ ]] || exit 2
[[ "$(uname -s)" == Linux ]] || exit 2
SOURCE="$STAGE/source"
BUILD="$STAGE/build"
DESTINATION="$STAGE/luv.so"
[[ ! -e "$SOURCE" && ! -L "$SOURCE" && ! -e "$BUILD" && ! -L "$BUILD" \
	&& ! -e "$DESTINATION" && ! -L "$DESTINATION" ]] || exit 2

# The private clone must not inherit another checkout's repository namespace.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES

git init -q "$SOURCE"
git -C "$SOURCE" fetch --depth=1 "$SOURCE_URL" "$SOURCE_REVISION"
git -C "$SOURCE" checkout --detach FETCH_HEAD
[ "$(git -C "$SOURCE" rev-parse HEAD)" = "$SOURCE_REVISION" ]
git -C "$SOURCE" fsck --strict
git -C "$SOURCE" submodule update --init --depth=1 -- deps/libuv deps/lua-compat-5.3

# Use the distribution's genuine metadata, never a fabricated Lua header path.
INCLUDE_DIR="$(pkg-config --variable=includedir luajit)"
[[ "$INCLUDE_DIR" == /* && -f "$INCLUDE_DIR/lua.h" ]] || exit 1
cmake -S "$SOURCE" -B "$BUILD" -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
	-DLUAJIT_INCLUDE_DIR="$INCLUDE_DIR" "$@"
cmake --build "$BUILD" --parallel 2
[[ -f "$BUILD/luv.so" && ! -L "$BUILD/luv.so" ]] || exit 1
# Verify real C entry points through the same LuaJIT used by the installed app.
luajit - "$BUILD/luv.so" <<'LUA'
local uv = assert(package.loadlib(arg[1], "luaopen_luv"))()
assert(jit.os == "Linux" and _VERSION == "Lua 5.1")
assert(debug.getinfo(uv.fs_stat, "S").what == "C")
assert(uv.fs_stat(".").type == "directory")
assert(uv.loop_alive() == false)
LUA
install -m 755 "$BUILD/luv.so" "$DESTINATION"
echo "Native source LuaJIT networking module generated"
