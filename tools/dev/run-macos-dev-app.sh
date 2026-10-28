#!/usr/bin/env bash
# tools/dev/run-macos-dev-app.sh

# ==============================================================================
# MODULE: macOS developer app runner
# DESCRIPTION:
# Builds ErgoptiPlus.app in developer source mode and opens it: its launcher
# runs the Lua of this clone (static/ergopti_plus/macos), so a saved .lua edit
# reloads the driver and the menu's Reload picks it up. A stock Hammerspoon can
# no longer run the driver (infra/instance_admission.lua), so this replaces
# the former ~/.hammerspoon bootstrap installer.
#
# USAGE:
#   bash tools/dev/run-macos-dev-app.sh             build, then open
#   bash tools/dev/run-macos-dev-app.sh --open-only open the developer app built before
#
# Rebuild after a change to the Swift launcher, a native helper or LuaSocket;
# a Lua or _shared edit needs no rebuild.
# ==============================================================================

set -euo pipefail

# Command substitution removes trailing LF bytes, even when they belong to a
# directory name. Capture a sentinel and remove only that final byte afterward.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && printf '%s.' "$PWD")"
REPO_ROOT="${REPO_ROOT%.}"
# shellcheck source=../../static/ergopti_plus/_shared/data/identifiers.sh
. "$REPO_ROOT/static/ergopti_plus/_shared/data/identifiers.sh"
APP_PATH="$REPO_ROOT/build/macos/$ERGOPTI_APP_BUNDLE"

fail() { printf '[macos-dev-app] ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[macos-dev-app] %s\n' "$*"; }

open_only=false
case "$#:${1:-}" in
	0:) ;;
	1:--open-only) open_only=true ;;
	*) fail "Expected no argument or --open-only." ;;
esac

[ "$(uname -s)" = Darwin ] || fail "The developer app is built and run on macOS only."
[ -f "$REPO_ROOT/static/ergopti_plus/macos/init.lua" ] \
	|| fail "No driver at $REPO_ROOT/static/ergopti_plus/macos/init.lua."

# Every process running a binary of an ErgoptiPlus bundle, installed or built
# here: the launcher, its embedded Hammerspoon and the remap guardian, which
# runs the launcher binary under the same process name.
ergopti_pids() {
	pgrep -f "/${ERGOPTI_APP_BUNDLE}/Contents/" 2>/dev/null || true
}

# The launcher prohibits a second instance: a running ErgoptiPlus would be
# activated instead and the developer app would exit at once. Quit it the way
# the menu does, then stop what is left. The guardian is a launchd agent with
# KeepAlive, so a plain kill only makes launchd start it again (Activity
# Monitor's Quit appears to do nothing); it is booted out first, and the next
# launch registers it again.
stop_running_ergopti() {
	local pids waited=0
	pids="$(ergopti_pids)"
	[ -n "$pids" ] || return 0
	log "Stopping the running $ERGOPTI_APP_NAME (pids: $(printf '%s' "$pids" | tr '\n' ' '))..."
	osascript -e "tell application id \"$ERGOPTI_BUNDLE_ID_LAUNCHER\" to quit" >/dev/null 2>&1 || true
	launchctl bootout "gui/$(id -u)/$ERGOPTI_SERVICE_LABEL_MACOS_REMAP_GUARDIAN" >/dev/null 2>&1 || true
	while [ -n "$(ergopti_pids)" ] && [ "$waited" -lt 10 ]; do sleep 1; waited=$((waited + 1)); done
	pids="$(ergopti_pids)"
	if [ -n "$pids" ]; then
		# shellcheck disable=SC2086 # one pid per word
		kill -TERM $pids 2>/dev/null || true
		waited=0
		while [ -n "$(ergopti_pids)" ] && [ "$waited" -lt 5 ]; do sleep 1; waited=$((waited + 1)); done
	fi
	pids="$(ergopti_pids)"
	if [ -n "$pids" ]; then
		# shellcheck disable=SC2086 # one pid per word
		kill -KILL $pids 2>/dev/null || true
		sleep 1
	fi
	pids="$(ergopti_pids)"
	if [ -n "$pids" ]; then
		ps -o pid=,command= -p "$(printf '%s' "$pids" | paste -sd, -)" >&2 || true
		fail "These $ERGOPTI_APP_NAME processes survived a quit, SIGTERM and SIGKILL (launchd restarts them); turn ErgoptiPlus off in System Settings > General > Login Items & Extensions, then run this again."
	fi
	log "No $ERGOPTI_APP_NAME process is left."
}
stop_running_ergopti

# The former bootstrap made a stock Hammerspoon load this clone; it now only
# shows a refusal there. Name the files, never delete user configuration.
for bootstrap in "$HOME/.hammerspoon/init.lua" "${XDG_CONFIG_HOME:-$HOME/.config}/hammerspoon/init.lua"; do
	if [ -f "$bootstrap" ] && grep -q "Ergopti+ dev bootstrap" "$bootstrap" 2>/dev/null; then
		log "WARNING: $bootstrap is a retired Ergopti+ dev bootstrap; delete it (and restore your backup) so a stock Hammerspoon stops showing the refusal."
	fi
done

if [ "$open_only" = false ]; then
	# The host slice alone: a two-slice launcher needs Xcode, and a developer app
	# runs only here. ERGOPTI_LAUNCHER_ARCHS=universal keeps both on an Xcode Mac.
	ERGOPTI_DEV_SOURCE=1 ERGOPTI_LAUNCHER_ARCHS="${ERGOPTI_LAUNCHER_ARCHS:-native}" \
		bash "$REPO_ROOT/tools/build/build_macos_app.sh"
fi
[ -d "$APP_PATH" ] || fail "No developer app at $APP_PATH; run without --open-only first."
recorded="$(plutil -extract "$ERGOPTI_DEV_SOURCE_PLIST_KEY" raw -o - "$APP_PATH/Contents/Info.plist" 2>/dev/null)" \
	|| fail "$APP_PATH is not a developer build; run without --open-only."
[ "$recorded" = "$REPO_ROOT" ] || fail "$APP_PATH runs the Lua of $recorded, not this clone; rebuild here."

open "$APP_PATH"
log "Opened $APP_PATH; its Lua runs from $REPO_ROOT/static/ergopti_plus/macos."
log "A saved .lua edit reloads the driver; the menu's Reload does it on demand."
log "Launcher trail: ~/Library/Logs/ergopti_plus/launcher.log (look for 'developer source mode')."
