#!/usr/bin/env bash
# tools/dev/run-linux-dev.sh

# ==============================================================================
# MODULE: Linux developer daemon runner
# DESCRIPTION:
# Runs the Linux daemon from this clone (static/ergopti_plus/linux) through the
# same entry point the packages start, install/launch.sh, with the tray: the
# same input-permission request, session lock, native archive backend, luv,
# config folder (~/.config/ergopti, paths.toml) and AI runtimes. A saved .lua of
# the driver or of _shared/lua restarts the daemon (infra/dev_source.lua); the
# tray's Reload does it on demand. The updater is off: a checkout is a source
# run (infra/installation.lua).
#
# USAGE:
#   bash tools/dev/run-linux-dev.sh [daemon options]   e.g. --verbose
#
# The installed user unit is stopped first: two daemons would both grab the
# keyboard. Start it again with: systemctl --user start ergopti-hotstrings
# A Reload runs this script again, detached, once the old daemon has exited.
# ==============================================================================

set -euo pipefail

# Command substitution removes trailing LF bytes, even when they belong to a
# directory name. Capture a sentinel and remove only that final byte afterward.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && printf '%s.' "$(pwd -P)")"
REPO_ROOT="${REPO_ROOT%.}"
# shellcheck source=../../static/ergopti_plus/_shared/data/identifiers.sh
. "$REPO_ROOT/static/ergopti_plus/_shared/data/identifiers.sh"
DRIVER_ROOT="$REPO_ROOT/static/ergopti_plus/linux"
NATIVE_SOURCE="$DRIVER_ROOT/native/archive_output"
NATIVE_LIBRARY="$DRIVER_ROOT/bin/libergopti_archive_publication.so"
UNIT="ergopti-hotstrings.service"

fail() { printf '[linux-dev] ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[linux-dev] %s\n' "$*"; }

[ "$(uname -s)" = Linux ] || fail "The developer daemon runs on Linux only."
[ -f "$DRIVER_ROOT/ergopti_hotstrings.lua" ] || fail "No driver at $DRIVER_ROOT/ergopti_hotstrings.lua."
command -v luajit >/dev/null 2>&1 || fail "luajit is missing; install it (apt install luajit, dnf install luajit, pacman -S luajit)."
luajit -e 'require("luv")' >/dev/null 2>&1 \
	|| fail "LuaJIT luv is missing; install it (apt install lua-luv, zypper install luajit-luv, pacman -S lua51-luv)."

# The installed daemon holds the session lock and the keyboard grab.
if command -v systemctl >/dev/null 2>&1 && systemctl --user is-active --quiet "$UNIT" 2>/dev/null; then
	log "Stopping the installed $UNIT (start it again with: systemctl --user start ergopti-hotstrings)."
	systemctl --user stop "$UNIT"
fi

# The packages ship the native archive backend next to the wrapper; a clone has
# only its C source. Rebuild it whenever a source is newer than the library.
native_stale=false
if [ ! -f "$NATIVE_LIBRARY" ]; then
	native_stale=true
else
	for source in "$NATIVE_SOURCE"/archive_publication.c "$NATIVE_SOURCE"/archive_publication.h; do
		[ "$source" -nt "$NATIVE_LIBRARY" ] && native_stale=true
	done
fi
if [ "$native_stale" = true ]; then
	log "Building the native archive backend into $NATIVE_LIBRARY..."
	stage="$(mktemp -d)"
	if ! bash "$REPO_ROOT/tools/build/build-linux-native-output.sh" \
		--source-directory "$NATIVE_SOURCE" --output-directory "$stage"; then
		rm -rf "$stage"
		fail "The native archive backend did not build (a C compiler and libc headers are required)."
	fi
	mv -f "$stage/libergopti_archive_publication.so" "$NATIVE_LIBRARY"
	rm -rf "$stage"
fi

export LUA_PATH="$DRIVER_ROOT/?.lua;$DRIVER_ROOT/?/init.lua;$REPO_ROOT/static/ergopti_plus/_shared/lua/?.lua;$REPO_ROOT/static/ergopti_plus/_shared/lua/?/init.lua;;"
export "$ERGOPTI_DEV_SOURCE_ENVIRONMENT=$REPO_ROOT"
log "Starting the daemon from $DRIVER_ROOT (developer source mode)."
log "A saved .lua reloads it; the tray's Reload does it on demand."
# --service: this script is the startup owner, as the standalone launcher is;
# without it launch.sh hands a --tray start to the installed systemd unit.
# A Reload relays the daemon's own arguments, which already hold --tray.
tray=--tray
for argument in "$@"; do [ "$argument" != --tray ] || tray=; done
exec bash "$DRIVER_ROOT/install/launch.sh" --service ${tray:+"$tray"} "$@"
