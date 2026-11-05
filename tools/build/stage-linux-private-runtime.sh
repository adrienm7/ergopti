#!/usr/bin/env bash
# tools/build/stage-linux-private-runtime.sh
#
# Copies the private runtime prefix the AppImage stages (stage-linux-network-
# runtime.py, built on the oldest supported LTS) into another package's tree,
# so every format runs the same pinned LuaJIT, luv, luafilesystem, luaposix,
# curl, sqlite3, openssl and zstd instead of the host's (owned runtimes, PIN;
# docs/design/owned-runtimes.md section 6.4).
#
# The prefix holds bin/, lib/ (the ELF closure, Lua C modules and GIO modules)
# and share/ (Lua packages and the GSettings schemas). The driver tree under
# usr/lib/ergopti is not part of it: each packager installs that itself.
# network-runtime-env.sh is the one owner of how the prefix reaches the
# daemon; the copy is admitted by sourcing it, which refuses a missing part.
#
# Usage:
#   bash tools/build/stage-linux-private-runtime.sh <AppDir> <destination prefix> <installed driver root>
#     The destination must not exist yet. The installed driver root is the
#     path the package installs the driver at, for the admission's arguments.

set -euo pipefail

if [ "$#" -ne 3 ] || [[ "$1" != /* ]] || [[ "$2" != /* ]] || [[ "$3" != /* ]]; then
	echo "Usage: $0 <absolute AppDir> <absolute destination prefix> <absolute installed driver root>" >&2
	exit 2
fi
APPDIR="$1"
DESTINATION="$2"
SOURCE="$APPDIR/usr"

for directory in "$SOURCE" "$SOURCE/bin" "$SOURCE/lib" "$SOURCE/share"; do
	if [ ! -d "$directory" ] || [ -L "$directory" ]; then
		echo "[ERR] Private runtime source directory is not a direct directory: $directory" >&2
		exit 1
	fi
done
if [ ! -x "$SOURCE/bin/luajit" ] || [ ! -f "$SOURCE/lib/ergopti/network-runtime-env.sh" ]; then
	echo "[ERR] No staged private runtime in $APPDIR: run tools/build/build-linux-appimage.sh first." >&2
	exit 1
fi
if [ -e "$DESTINATION" ] || [ -L "$DESTINATION" ]; then
	echo "[ERR] $DESTINATION already exists; the private runtime is staged into a fresh path." >&2
	exit 1
fi

mkdir -p "$DESTINATION/lib"
cp -a "$SOURCE/bin" "$DESTINATION/bin"
cp -a "$SOURCE/share" "$DESTINATION/share"
# Everything under lib except the driver tree, which is the packager's.
for entry in "$SOURCE/lib"/* "$SOURCE/lib"/.[!.]* "$SOURCE/lib"/..?*; do
	[ -e "$entry" ] || [ -L "$entry" ] || continue
	[ "$(basename -- "$entry")" = ergopti ] && continue
	cp -a "$entry" "$DESTINATION/lib/"
done
# The launcher scripts are the packager's; only the runtime's programs stay.
rm -f "$DESTINATION/bin/ergopti"

# Admission must not succeed only because a symlink reaches a build-host file.
# Preserve normal internal aliases, but require every link to resolve inside the
# copied prefix, where it will remain valid after the package is installed.
IFS= read -r -d '' COPIED_PREFIX < <(CDPATH= cd -Pe -- "$DESTINATION" && printf '%s\0' "$PWD")
{
	# A process substitution's EOF does not acknowledge its producer. Retain
	# this PID before per-link queries replace $! and require its actual status.
	LINK_SCAN_PID=$!
	while IFS= read -r -d '' link; do
		if ! IFS= read -r -d '' literal_target < <(readlink -z -- "$link"); then
			echo "[ERR] Private runtime link cannot be read: $link" >&2
			exit 1
		fi
		case "$literal_target" in
			/*) echo "[ERR] Private runtime contains a nonrelocatable absolute link: $link" >&2; exit 1 ;;
		esac
		if ! IFS= read -r -d '' target < <(readlink -ze -- "$link"); then
			echo "[ERR] Private runtime contains an unresolved link: $link" >&2
			exit 1
		fi
		case "$target" in
			"$COPIED_PREFIX"|"$COPIED_PREFIX"/*) ;;
			*) echo "[ERR] Private runtime link leaves the copied prefix: $link" >&2; exit 1 ;;
		esac
	done
	if ! wait "$LINK_SCAN_PID"; then
		echo '[ERR] Private runtime link inventory could not be completed.' >&2
		exit 1
	fi
} < <(find "$DESTINATION" -type l -print0)

# Admission through the environment the installed launcher sources: every part
# it requires must be in the copy.
bash -c 'set -euo pipefail; source "$1" "$2" "$3" >/dev/null' private-runtime-admission \
	"$SOURCE/lib/ergopti/network-runtime-env.sh" "$DESTINATION" "$3" || {
	echo "[ERR] The private runtime copied to $DESTINATION is incomplete." >&2
	exit 1
}
echo "  Private runtime: $(find "$DESTINATION" -type f | wc -l) files in $DESTINATION"
