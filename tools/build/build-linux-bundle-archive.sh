#!/usr/bin/env bash
# tools/build/build-linux-bundle-archive.sh
#
# Packs the installable Linux tarball install.sh runs from: linux/, _shared/,
# bin/ and install.sh, plus the private runtime prefix the AppImage stages on
# the oldest supported LTS (stage-linux-private-runtime.sh) at linux/runtime
# with its environment at linux/network-runtime-env.sh. Inside the driver
# tree, the installer's copy and its ownership manifest carry the runtime with
# the driver, so uninstall and rollback need no second list (owned runtimes,
# PIN: the source installs run the same LuaJIT, luv, luafilesystem, luaposix,
# curl, sqlite3, openssl and zstd as every package).
#
# The build directory itself is left untouched: the .deb, .rpm and AppImage
# copy build/linux/linux whole and stage the runtime themselves.
#
# Usage:
#   bash tools/build/build-linux-bundle-archive.sh <asset file name>
#     Writes $ERGOPTI_LINUX_BUILD_DIR/<asset> and its .sha256.

set -euo pipefail

if [ "$#" -ne 1 ] || [[ "$1" == */* ]] || [ -z "$1" ]; then
	echo "Usage: $0 <asset file name>" >&2
	exit 2
fi
ASSET="$1"
case "$ASSET" in
	.|..|linux|_shared|bin|install.sh|AppDir)
		echo "[ERR] Bundle asset name collides with a build input: $ASSET" >&2
		exit 2 ;;
esac
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IFS= read -r -d '' PROJECT_ROOT < <(cd -- "$SCRIPT_DIR/../.." && printf '%s\0' "$PWD")
BUILD_DIR="${ERGOPTI_LINUX_BUILD_DIR:-$PROJECT_ROOT/build/linux}"
case "$BUILD_DIR" in
	/?*) ;;
	*) echo "[ERR] ERGOPTI_LINUX_BUILD_DIR must be an absolute path, got '$BUILD_DIR'" >&2; exit 1 ;;
esac
for output in "$BUILD_DIR/$ASSET" "$BUILD_DIR/$ASSET.sha256"; do
	if [ -L "$output" ] || { [ -e "$output" ] && [ ! -f "$output" ]; }; then
		echo "[ERR] Bundle output is not a direct regular file: $output" >&2
		exit 1
	fi
done

bash "$SCRIPT_DIR/write_build_stamp.sh" verify "$BUILD_DIR/_shared"
STAGE="$(mktemp -d "$BUILD_DIR/.bundle-archive.XXXXXX")"
trap 'rm -rf -- "$STAGE"' EXIT
for entry in linux _shared bin install.sh; do
	cp -a "$BUILD_DIR/$entry" "$STAGE/$entry"
done
bash "$SCRIPT_DIR/stage-linux-private-runtime.sh" "$BUILD_DIR/AppDir" "$STAGE/linux/runtime" "$STAGE/linux"
install -m 644 "$BUILD_DIR/AppDir/usr/lib/ergopti/network-runtime-env.sh" "$STAGE/linux/network-runtime-env.sh"

# Build both artifacts in the private stage. Replacing an existing output by
# rename avoids truncating a different user file hardlinked to that output.
tar -czf "$STAGE/$ASSET" -C "$STAGE" linux _shared bin install.sh
(cd "$STAGE" && sha256sum -- "$ASSET" > "$ASSET.sha256" && sha256sum --check -- "$ASSET.sha256")
mv -T -- "$STAGE/$ASSET" "$BUILD_DIR/$ASSET"
mv -T -- "$STAGE/$ASSET.sha256" "$BUILD_DIR/$ASSET.sha256"
echo "Bundle contents:"
tar -tzf "$BUILD_DIR/$ASSET" | sed -n '1,20p'
echo "... $(tar -tzf "$BUILD_DIR/$ASSET" | wc -l) entries"
