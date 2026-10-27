#!/usr/bin/env bash
# tools/test/prepare-linux-distro-unit.sh
# Inside a distribution container prepared by .github/linux-install-matrix.json,
# create the ordinary installation user, give it a private copy of the source
# checkout, build native test dependencies for the distribution's own LuaJIT,
# then run one suite of the unchanged module groups as that user: "unit" is
# every group of tests/support/module_groups.lua but the integration group (the
# Unit stage's distribution rows), "integration" that group alone (the
# Integration stage's). tools/test/run-linux-distro-unit.sh starts the
# container and calls this script as root.

set -euo pipefail

distro="${1:?distribution is required}"
source_root="${2:?source checkout is required}"
suite="${3:?suite is required: unit or integration}"
test -f "$source_root/static/ergopti_plus/linux/tests/run.lua"
case "$suite" in
	unit|integration) ;;
	*) echo 'Unsupported distribution suite.' >&2; exit 1 ;;
esac
case "$distro" in
	debian) apt-get install -y --no-install-recommends luajit python3 ca-certificates git gcc libc6-dev make cmake pkg-config libluajit-5.1-dev libuv1-dev libglib2.0-0t64 sqlite3 openssl curl ;;
	fedora) dnf install -y luajit python3 ca-certificates git gcc make cmake pkgconf-pkg-config luajit-devel libuv-devel glib2 sqlite openssl curl ;;
	arch) pacman -Sy --noconfirm luajit python ca-certificates git gcc make cmake pkgconf libuv glib2 sqlite openssl curl ;;
	alpine) apk add --no-cache luajit python3 ca-certificates git build-base cmake pkgconf luajit-dev libuv-dev glib sqlite openssl tzdata curl ;;
	opensuse) zypper --non-interactive install luajit python3 ca-certificates git gcc make cmake pkg-config luajit-devel libuv-devel libglib-2_0-0 sqlite3 openssl curl ;;
	*) echo 'Unsupported mandatory unit distribution.' >&2; exit 1 ;;
esac

interpreter="$(command -v luajit)"
test -x "$interpreter"
test -x /usr/bin/python3
# Native reset fixtures use the real CLI; refuse before starting any group.
sqlite="$(command -v sqlite3)"
test -x "$sqlite"
"$sqlite" --version
# The GNOME proxy check decodes gsettings output with the native GLib.
"$interpreter" -e 'require("ffi").load("libglib-2.0.so.0")'
# At-rest metrics encryption, declared by install.sh, derives its key with the
# openssl CLI from the machine id and encrypts through native libcrypto 3. A
# container is not a booted system and has no machine id, so it gets one.
command -v openssl >/dev/null
"$interpreter" -e 'require("ffi").load("libcrypto.so.3")'
if [ ! -s /etc/machine-id ]; then
	od -An -tx1 -N16 /dev/urandom | tr -d ' \n' > /etc/machine-id
	printf '\n' >> /etc/machine-id
fi
grep -Eqx '[0-9a-f]{32}' /etc/machine-id
# The capture calendar fixture replays a real DST day with TZ=Europe/Paris;
# Alpine ships no zone data by default and would silently compute UTC.
test -f /usr/share/zoneinfo/Europe/Paris

# Root bypasses the suite's real unreadable-file permission premise, so the
# suite runs as the same ordinary user the archive installation lot creates.
if command -v useradd >/dev/null 2>&1; then
	useradd -m -d /tmp/ergopti-home -s /bin/bash ergopti-ci
else
	adduser -D -h /tmp/ergopti-home -s /bin/bash ergopti-ci
fi
test "$(id -u ergopti-ci)" -ge 1000
install -d -m 0750 /etc/sudoers.d
printf '%s\n' 'ergopti-ci ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ergopti-ci
chmod 0440 /etc/sudoers.d/ergopti-ci

# Keep the mounted checkout untouched and give the installation user a private
# writable source tree, including every original test and shared file.
unit_root="$(mktemp -d /tmp/ergopti-distro-source.XXXXXXXX)"
trap 'rm -rf -- "$unit_root"' EXIT
cp -a "$source_root/." "$unit_root/"
chown -R ergopti-ci:ergopti-ci "$unit_root"
cd "$unit_root/static/ergopti_plus/linux"

# Distribution packages often target Lua 5.4. Build the existing vendor versions
# against this interpreter's headers, without replacing the interpreter itself.
# Official release commits are immutable source pins; Git verifies their objects.
native_root="$(mktemp -d /tmp/ergopti-distro-native.XXXXXXXX)"
trap 'rm -rf -- "$native_root" "$unit_root"' EXIT
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

# These unchanged fixtures create files in the driver root and its tests directory.
# Only these two directory owners change; checked-out source files and modes remain intact.
unit_driver="$(pwd -P)"
test -f "$unit_driver/tests/run.lua"
chown ergopti-ci "$unit_driver" "$unit_driver/tests"

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
-- Native GVariant fixtures require the base GLib ABI, not a desktop session.
local glib = ffi.load(require("_generated.native_runtime").network_runtime.libraries.glib)
ffi.cdef("void *g_variant_new_string(const char *string); void g_variant_unref(void *value);")
local variant = glib.g_variant_new_string("native-unit-admission")
assert(variant ~= nil)
glib.g_variant_unref(variant)
print(jit.version)
'
sudo -H -u ergopti-ci env -u SUDO_UID -u SUDO_GID -u SUDO_USER \
	/usr/bin/python3 -c 'import os; assert(os.geteuid() != 0)'
sudo -H -u ergopti-ci env -u SUDO_UID -u SUDO_GID -u SUDO_USER \
	/usr/bin/python3 -c '
import os
from pathlib import Path
import tempfile
assert(os.geteuid() != 0)
working = Path.cwd()
for directory in (working, working / "tests"):
    assert(directory.stat().st_uid == os.geteuid())
    with tempfile.TemporaryFile(dir=directory) as receipt:
        assert(receipt.write(b"ordinary fixture write") == 22)
        receipt.seek(0)
        assert(receipt.read() == b"ordinary fixture write")
assert(Path.cwd() == working)
print("Native ordinary-user fixture writes: 2 directories admitted")
'
# The suite's module groups of tests/support/module_groups.lua run at once, each with
# a private TMPDIR and HOME: the whole suite in one process held every archive
# cell for about four minutes. A shared HOME let one group's writes to the
# user's ~/.config/ergopti_plus reach another group's fixture that proves its
# parent bootstrap stays untouched. openSUSE's sudo session adds pam_env's
# XDG_*_HOME defaults (aaa_base xdg.conf) from the ACCOUNT home, which outrank
# HOME, so they are removed too or every group shares one ~/.config again.
# Logs print whole, in group order, under one header each, so the workflow
# diagnostic still reads one runner summary per group.
mapfile -t all_groups < <("$interpreter" -e 'for _, group in ipairs(dofile("tests/support/module_groups.lua").GROUPS) do print(group.name) end')
unit_groups=()
for unit_group in "${all_groups[@]}"; do
	case "$suite/$unit_group" in
		unit/integration) ;;
		unit/*|integration/integration) unit_groups+=("$unit_group") ;;
	esac
done
test "${#unit_groups[@]}" -gt 0
unit_logs="$(mktemp -d "$native_root/logs.XXXXXXXX")"
unit_pids=()
for unit_group in "${unit_groups[@]}"; do
	group_tmp="$(mktemp -d "$native_root/unit-$unit_group.XXXXXXXX")"
	group_home="$(mktemp -d "$native_root/home-$unit_group.XXXXXXXX")"
	chown ergopti-ci "$group_tmp" "$group_home"
	sudo -H -u ergopti-ci env -u SUDO_UID -u SUDO_GID -u SUDO_USER \
		-u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_CACHE_HOME -u XDG_STATE_HOME \
		LUA_CPATH="$native_root/modules/?.so;;" TMPDIR="$group_tmp" HOME="$group_home" "$interpreter" tests/run.lua --module="$unit_group" \
		>"$unit_logs/$unit_group.log" 2>&1 &
	unit_pids+=("$!")
done
unit_status=0
for index in "${!unit_groups[@]}"; do
	group_status=0
	wait "${unit_pids[$index]}" || group_status=$?
	if [ "$unit_status" -eq 0 ]; then unit_status="$group_status"; fi
	printf 'distro-unit-group %s\n' "${unit_groups[$index]}"
	cat "$unit_logs/${unit_groups[$index]}.log"
done
exit "$unit_status"
