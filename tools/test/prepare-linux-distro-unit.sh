#!/usr/bin/env bash
# tools/test/prepare-linux-distro-unit.sh
# Build native test dependencies for the distribution's own LuaJIT, then run
# the unchanged suite as its existing ordinary installation user.

set -euo pipefail

distro="${1:?distribution is required}"
case "$distro" in
	debian) apt-get install -y --no-install-recommends luajit python3 ca-certificates git gcc make cmake pkg-config libluajit-5.1-dev libuv1-dev ;;
	fedora) dnf install -y luajit python3 ca-certificates git gcc make cmake pkgconf-pkg-config luajit-devel libuv-devel ;;
	arch) pacman -Sy --noconfirm luajit python ca-certificates git gcc make cmake pkgconf libuv ;;
	alpine) apk add --no-cache luajit python3 ca-certificates git build-base cmake pkgconf luajit-dev libuv-dev ;;
	opensuse) zypper --non-interactive install luajit python3 ca-certificates git gcc make cmake pkg-config luajit-devel libuv-devel ;;
	*) echo 'Unsupported mandatory unit distribution.' >&2; exit 1 ;;
esac

interpreter="$(command -v luajit)"
test -x "$interpreter"
test -x /usr/bin/python3
test "$(id -u ergopti-ci)" -ge 1000

# Distribution packages often target Lua 5.4. Build the existing vendor versions
# against this interpreter's headers, without replacing the interpreter itself.
# Official release commits are immutable source pins; Git verifies their objects.
native_root="$(mktemp -d /tmp/ergopti-distro-native.XXXXXXXX)"
trap 'rm -rf -- "$native_root"' EXIT
chmod 0755 "$native_root"
mkdir -m 0755 "$native_root/modules"

checkout_source() {
	local target="$1" repository="$2" revision="$3"
	git init -q "$target"
	git -C "$target" fetch --depth=1 "$repository" "$revision"
	git -C "$target" checkout --detach FETCH_HEAD
	test "$(git -C "$target" rev-parse HEAD)" = "$revision"
	git -C "$target" fsck --strict
}

checkout_source "$native_root/luv" https://github.com/luvit/luv.git ebc79ee5aa082f90e53f75f3f326dcea11e8478d
checkout_source "$native_root/lfs" https://github.com/lunarmodules/luafilesystem.git 7c6e1b013caec0602ca4796df3b1d7253a2dd258
git -C "$native_root/luv" submodule update --init --depth=1 -- deps/lua-compat-5.3

include_dir="$(pkg-config --variable=includedir luajit)"
test -f "$include_dir/lua.h"
cmake -S "$native_root/luv" -B "$native_root/luv-build" \
	-DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
	-DWITH_LUA_ENGINE=LuaJIT -DLUA_BUILD_TYPE=System \
	-DLUAJIT_INCLUDE_DIR="$include_dir" -DWITH_SHARED_LIBUV=ON \
	-DBUILD_MODULE=ON -DBUILD_STATIC_LIBS=OFF -DBUILD_SHARED_LIBS=OFF
cmake --build "$native_root/luv-build" --parallel 2
make -C "$native_root/lfs" lib LUA_INC="$(pkg-config --cflags-only-I luajit)"
install -m 0644 "$native_root/luv-build/luv.so" "$native_root/modules/luv.so"
install -m 0644 "$native_root/lfs/src/lfs.so" "$native_root/modules/lfs.so"

unit_tmp="$(mktemp -d "$native_root/unit.XXXXXXXX")"
chown ergopti-ci "$unit_tmp"

# Permission refusal must execute under the same real non-root UID as the suite.
# Requiring native C entry points also refuses missing or wrong-ABI libraries.
sudo -H -u ergopti-ci env -u SUDO_UID -u SUDO_GID -u SUDO_USER \
	LUA_CPATH="$native_root/modules/?.so;;" TMPDIR="$unit_tmp" "$interpreter" -e '
local ffi = require("ffi")
ffi.cdef("unsigned int getuid(void);")
assert(ffi.C.getuid() ~= 0)
assert(jit.os == "Linux" and _VERSION == "Lua 5.1")
local uv, lfs = require("luv"), require("lfs")
assert(debug.getinfo(uv.fs_stat, "S").what == "C")
assert(debug.getinfo(lfs.attributes, "S").what == "C")
assert(uv.fs_stat(".").type == "directory")
assert(lfs.attributes(".", "mode") == "directory")
print(jit.version)
'
sudo -H -u ergopti-ci env -u SUDO_UID -u SUDO_GID -u SUDO_USER \
	/usr/bin/python3 -c 'import os; assert(os.geteuid() != 0)'
sudo -H -u ergopti-ci env -u SUDO_UID -u SUDO_GID -u SUDO_USER \
	LUA_CPATH="$native_root/modules/?.so;;" TMPDIR="$unit_tmp" "$interpreter" tests/run.lua
