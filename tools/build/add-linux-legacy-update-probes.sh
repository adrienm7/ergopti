#!/usr/bin/env bash
# tools/build/add-linux-legacy-update-probes.sh
#
# Adds to a staged Linux tarball the paths that installed
# Linux updaters released before the structure move probe before they accept
# an update (decided by the coordinator on 2026-11-13, to review by the
# maintainer):
#
#   _shared/data/locales/en.json  a file: their infra/paths.lua
#                                 SHARED_PROBE_FILE and their
#                                 install/ownership_schema.sh
#                                 OWNERSHIP_SHARED_SENTINEL;
#   _shared/lua/                  a directory: v1.0.9's validate_candidate
#                                 requires the old shared Lua tree.
#
# The move put the locales under core/i18n/data/locales and the shared Lua
# modules at the shared root, so without these an installed v1.0.9 ...
# v1.0.10-dev.175 refused every newer tarball (« staged archive is missing the
# shared Lua tree ») and could never update again. The locale copy is
# generated from the moved file: no second tracked source exists.
#
# v1.0.9 also requires linux/infra/version.lua, which the structure plan
# moves later (linux/updater/engine/). That path is checked here, so the step
# that moves it fails this build until it adds its own probe below.
#
# Remove this step, its call in build-linux-bundle-archive.sh and its test
# once the first release whose updater finds a staged shared root by its
# build stamp (modules/updater/installer.lua staged_shared_root) has been out
# for one full release cycle (TODO.md « Legacy Linux updater probes »).
#
# Usage:
#   bash tools/build/add-linux-legacy-update-probes.sh <staged tarball root>

set -euo pipefail

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
	echo "Usage: $0 <staged tarball root>" >&2
	exit 2
fi
SHARED="$1/_shared"
DRIVER_VERSION="$1/linux/infra/version.lua"
SOURCE="$SHARED/core/i18n/data/locales/en.json"
LOCALE="$SHARED/data/locales/en.json"
LEGACY_LUA="$SHARED/lua"

if [ ! -f "$DRIVER_VERSION" ] || [ -L "$DRIVER_VERSION" ]; then
	echo "[ERR] Updaters before the structure move require $DRIVER_VERSION: add its probe here." >&2
	exit 1
fi
if [ ! -f "$SOURCE" ] || [ -L "$SOURCE" ]; then
	echo "[ERR] The moved English locale is missing: $SOURCE" >&2
	exit 1
fi
# A present path means the layout changed again: refuse instead of guessing.
for path in "$LOCALE" "$LEGACY_LUA"; do
	if [ -e "$path" ] || [ -L "$path" ]; then
		echo "[ERR] Legacy updater probe already exists: $path" >&2
		exit 1
	fi
done

mkdir -p -- "$(dirname -- "$LOCALE")"
cp -- "$SOURCE" "$LOCALE"
mkdir -- "$LEGACY_LUA"
printf '%s\n' \
	"Probe for Linux updaters released before the structure move; no module lives here." \
	> "$LEGACY_LUA/README.txt"
echo "Legacy updater probes added: data/locales/en.json, lua/"
