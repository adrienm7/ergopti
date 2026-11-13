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
# Installed updaters released before the structure move probe the old shared
# layout; only the tarball self-updates, so only it carries the probes.
bash "$SCRIPT_DIR/add-linux-legacy-update-probes.sh" "$STAGE"

# Build both artifacts in the private stage. Replacing an existing output by
# rename avoids truncating a different user file hardlinked to that output.
tar -czf "$STAGE/$ASSET" -C "$STAGE" linux _shared bin install.sh
(cd "$STAGE" && sha256sum -- "$ASSET" > "$ASSET.sha256" && sha256sum --check -- "$ASSET.sha256")
# Retain exact prior inodes so a failed second rename can restore both outputs
# without changing their contents, permissions or other hard links.
BACKUP="$(mktemp -d "$BUILD_DIR/.bundle-rollback.XXXXXX")"
retain_backup=false
cleanup_bundle() {
	local status=$?
	trap - EXIT
	if "$retain_backup"; then
		echo "[ERR] Bundle recovery files retained at $BACKUP" >&2
	else
		rm -rf -- "$BACKUP" || status=1
	fi
	rm -rf -- "$STAGE" || status=1
	exit "$status"
}
trap cleanup_bundle EXIT
for part in archive checksum; do
	if [ "$part" = archive ]; then name="$ASSET"; else name="$ASSET.sha256"; fi
	ln -- "$STAGE/$name" "$BACKUP/new-$part"
	if [ -e "$BUILD_DIR/$name" ]; then ln -- "$BUILD_DIR/$name" "$BACKUP/old-$part"; fi
done
# Hash and stat observations are captured before publication: the retained
# hard link alone shares writes with the published file and proves no bytes.
# These observations do not serialize an unrelated concurrent writer.
bundle_output_evidence() {
	local file="$1" before after digest size
	[ -f "$file" ] && [ ! -L "$file" ] || return 1
	before="$(stat -c '%d:%i:%f:%u:%g:%s:%y' -- "$file")" || return 1
	size="$(stat -c '%s' -- "$file")" || return 1
	# Bound the read to the observed size plus one byte, and never wait for a
	# substituted FIFO or follow a substituted final symlink during open.
	[[ "$size" =~ ^[0-9]{1,18}$ ]] || return 1
	digest="$(set -o pipefail; dd if="$file" bs=65536 count="$((10#$size + 1))" iflag=nonblock,nofollow,count_bytes status=none | sha256sum)" || return 1
	after="$(stat -c '%d:%i:%f:%u:%g:%s:%y' -- "$file")" || return 1
	[ "$before" = "$after" ] && [ -f "$file" ] && [ ! -L "$file" ] || return 1
	printf '%s\n%s\n' "$after" "$digest"
}
new_archive_evidence="$(bundle_output_evidence "$BACKUP/new-archive")"
new_checksum_evidence="$(bundle_output_evidence "$BACKUP/new-checksum")"
rollback_bundle_part() {
	local part="$1" target="$BUILD_DIR/$2" observed expected
	if [ "$part" = archive ]; then expected="$new_archive_evidence"; else expected="$new_checksum_evidence"; fi
	# Only undo our own rename. An intervening writer keeps its file and the
	# retained backup is reported for manual recovery.
	if [ ! -L "$target" ] && [ "$target" -ef "$BACKUP/new-$part" ]; then
		observed="$(bundle_output_evidence "$target")" || return 1
		[ "$observed" = "$expected" ] || return 1
		if [ -e "$BACKUP/old-$part" ]; then
			mv -T -- "$BACKUP/old-$part" "$target"
		else
			rm -f -- "$target"
		fi
	elif [ ! -L "$target" ] && [ -e "$BACKUP/old-$part" ] && [ "$target" -ef "$BACKUP/old-$part" ]; then
		return 0
	elif [ ! -e "$BACKUP/old-$part" ] && [ ! -e "$target" ] && [ ! -L "$target" ]; then
		return 0
	else
		return 1
	fi
}
if ! mv -T -- "$STAGE/$ASSET" "$BUILD_DIR/$ASSET" \
	|| ! mv -T -- "$STAGE/$ASSET.sha256" "$BUILD_DIR/$ASSET.sha256"; then
	rollback_bundle_part archive "$ASSET" || retain_backup=true
	rollback_bundle_part checksum "$ASSET.sha256" || retain_backup=true
	exit 1
fi
echo "Bundle contents:"
tar -tzf "$BUILD_DIR/$ASSET" | sed -n '1,20p'
echo "... $(tar -tzf "$BUILD_DIR/$ASSET" | wc -l) entries"
