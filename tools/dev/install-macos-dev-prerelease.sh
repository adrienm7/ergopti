#!/usr/bin/env bash
# tools/dev/install-macos-dev-prerelease.sh

# ==============================================================================
# MODULE: macOS signed dev prerelease installer (field reports)
# DESCRIPTION:
# Installs or updates /Applications/ErgoptiPlus.app from the newest signed dev
# prerelease on GitHub, verified, then quits the running copy and opens the new
# one with this clone as its field-run root, so
# tools/dev/collect-macos-field-report.sh --installed can drive every field
# check with no click.
#
# USAGE:
#   bash tools/dev/install-macos-dev-prerelease.sh
#
# Verification: the archive's size and SHA-256 must match the release's own
# macos-publication.json, and the unpacked app must pass a strict deep code
# signature check whose designated requirement names the certificate leaf the
# owned runtime manifest pins (the CI certificate). Anything else refuses and
# changes nothing. It never writes a system preference. When this account
# cannot write /Applications (a managed Mac), it asks for the administrator
# password once, before anything is quit or replaced, and copies with sudo.
# ==============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && printf '%s.' "$PWD")"
REPO_ROOT="${REPO_ROOT%.}"
# shellcheck source=../../static/ergopti_plus/_shared/data/identifiers.sh
. "$REPO_ROOT/static/ergopti_plus/_shared/data/identifiers.sh"

fail() { printf '[dev-prerelease] REFUSED: %s\n' "$*" >&2; exit 1; }
log() { printf '[dev-prerelease] %s\n' "$*"; }

[ "$(uname -s)" = Darwin ] || fail "a Mac is required."
APP="/Applications/$ERGOPTI_APP_BUNDLE"
# The repository comes from the updater defaults, the one source of every GitHub link.
DEFAULTS="$REPO_ROOT/static/ergopti_plus/_shared/modules/updater/defaults.json"
repository="$(/usr/bin/python3 -c 'import json,sys; g=json.load(open(sys.argv[1]))["github"]; print(g["owner"] + "/" + g["repo"])' "$DEFAULTS")" \
	|| fail "the updater defaults name no GitHub repository."
ARCHIVE="$ERGOPTI_APP_BUNDLE.zip"
# Git and the download links, not the REST API: behind a company proxy the shared
# address exhausts the API's anonymous quota (a 403 in a field report).
REMOTE="https://${ERGOPTI_HOST_GITHUB}/$repository"
MANIFEST="$REPO_ROOT/static/ergopti_plus/macos/vendor/remap-runtime/manifest.json"
as_admin=
work="$(mktemp -d "${TMPDIR:-/tmp}/ergopti-dev-prerelease.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# The newest dev prerelease tag (vX.Y.Z-dev.N, and v0.0.0-dev.N before
# 2026-11-08), and its two macOS assets. The counter runs across both cores,
# so the newest tag is the one with the highest N.
tags="$(git ls-remote --tags --refs "$REMOTE.git" 'v*-dev.*')" || fail "GitHub's tags could not be read."
tag="$(printf '%s\n' "$tags" | sed -n 's|.*refs/tags/\(v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*-dev\.[0-9][0-9]*\)$|\1|p' \
	| awk -F'-dev[.]' '{ print $2, $0 }' | sort -n | tail -n 1 | cut -d' ' -f2)"
[ -n "$tag" ] || fail "no dev prerelease is published."
publication_url="$REMOTE/releases/download/$tag/macos-publication.json"
archive_url="$REMOTE/releases/download/$tag/$ARCHIVE"
log "Newest signed dev prerelease: $tag."

installed="$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist" 2>/dev/null || true)"
if [ "v$installed" = "$tag" ] && [ "${ERGOPTI_REINSTALL:-0}" != 1 ]; then
	log "$APP is already $tag."
else
	curl -fsSL --proto =https "$publication_url" -o "$work/publication.json" || fail "$tag publishes no macos-publication.json."
	# A company proxy cut the 27 MB archive at 56% (curl 18, field report
	# 2026-11-05): each retry resumes where the transfer stopped; the size and
	# SHA-256 checks below still admit only the published archive.
	curl -fL --proto =https --progress-bar --retry 6 --retry-delay 5 --retry-all-errors -C - \
		"$archive_url" -o "$work/app.zip" || fail "the macOS archive could not be downloaded."
	expected="$(/usr/bin/python3 -c 'import json,sys
for a in json.load(open(sys.argv[1]))["archives"]:
    if a["name"] == sys.argv[2]: print(a["size"], a["sha256"])' "$work/publication.json" "$ARCHIVE")" \
		|| fail "macos-publication.json names no $ARCHIVE."
	read -r size sha256 <<<"$expected"
	[ "$(stat -f %z "$work/app.zip")" = "$size" ] || fail "the archive is not the size the release publishes."
	[ "$(shasum -a 256 "$work/app.zip" | cut -d' ' -f1)" = "$sha256" ] || fail "the archive is not the one the release publishes."
	ditto -x -k "$work/app.zip" "$work/unpacked" || fail "the archive could not be unpacked."
	new="$work/unpacked/$ERGOPTI_APP_BUNDLE"
	[ -d "$new" ] || fail "the archive holds no $ERGOPTI_APP_BUNDLE."
	codesign --verify --deep --strict "$new" || fail "the downloaded app's signature does not verify."
	leaf="$(/usr/bin/python3 -c 'import json,re,sys
print(re.search(r"certificate leaf = H\"([0-9a-f]{40})\"", json.load(open(sys.argv[1]))["capture"]["requirement"]).group(1))' "$MANIFEST")" \
		|| fail "the runtime manifest pins no certificate leaf."
	requirement="$(codesign -d -r- "$new" 2>&1)"
	printf '%s\n' "$requirement" | grep -q "identifier \"$ERGOPTI_BUNDLE_ID_LAUNCHER\"" \
		|| fail "the downloaded app is not $ERGOPTI_BUNDLE_ID_LAUNCHER."
	printf '%s\n' "$requirement" | grep -qi "certificate leaf = H\"$leaf\"" \
		|| fail "the downloaded app is not signed with the CI certificate the owned runtime trusts."
	log "Verified $tag: size, SHA-256 and the CI certificate."
	if [ ! -w /Applications ]; then
		log "/Applications is not writable by this account: macOS asks for the administrator password once."
		sudo -v || fail "the administrator password was refused; nothing was changed."
		as_admin=sudo
	fi
fi

# Quit the running copy the way its menu does, then the guardian launchd keeps alive.
if pgrep -f "/$ERGOPTI_APP_BUNDLE/Contents/" >/dev/null 2>&1; then
	log "Quitting the running $ERGOPTI_APP_NAME..."
	osascript -e "tell application id \"$ERGOPTI_BUNDLE_ID_LAUNCHER\" to quit" >/dev/null 2>&1 || true
	launchctl bootout "gui/$(id -u)/$ERGOPTI_SERVICE_LABEL_MACOS_REMAP_GUARDIAN" >/dev/null 2>&1 || true
	for _ in $(seq 1 20); do pgrep -f "/$ERGOPTI_APP_BUNDLE/Contents/" >/dev/null 2>&1 || break; sleep 1; done
	pgrep -f "/$ERGOPTI_APP_BUNDLE/Contents/" >/dev/null 2>&1 \
		&& fail "$ERGOPTI_APP_NAME did not quit within 20 s; quit it from its menu and run this again."
fi

if [ -n "${new:-}" ]; then
	$as_admin rm -rf "/Applications/.$ERGOPTI_APP_BUNDLE.new"
	$as_admin ditto "$new" "/Applications/.$ERGOPTI_APP_BUNDLE.new"
	$as_admin rm -rf "$APP"
	$as_admin mv "/Applications/.$ERGOPTI_APP_BUNDLE.new" "$APP"
	log "Installed $tag in $APP."
fi

# Another copy of the app (a local build) shares the bundle ids but not the
# certificate: System Settings then grants Accessibility to that copy, the boot
# finds itself untrusted and resets the entry, so the switch vanishes at every
# reload. Every other copy is unregistered from LaunchServices (its files stay)
# and stopped, leaving one code identity for the grant.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
others="$({
	mdfind "kMDItemCFBundleIdentifier == '$ERGOPTI_BUNDLE_ID_LAUNCHER'" 2>/dev/null || true
	"$LSREGISTER" -dump 2>/dev/null | awk -v id="$ERGOPTI_BUNDLE_ID_LAUNCHER" '
		/^-----/ { if (ident == id && path != "") print path; path = ""; ident = "" }
		/^path:/ { sub(/^path: */, ""); sub(/ \(0x[0-9a-f]+\)$/, ""); path = $0 }
		/^identifier:/ { sub(/^identifier: */, ""); ident = $0 }
		END { if (ident == id && path != "") print path }' || true
} | { grep '\.app$' || true; } | { grep -vxF "$APP" || true; } | sort -u)"
while IFS= read -r other; do
	[ -n "$other" ] || continue
	log "Another copy shares the app's identity: $other; unregistering it (its files stay)."
	pkill -f "^$other/Contents/" >/dev/null 2>&1 || true
	"$LSREGISTER" -u "$other" >/dev/null 2>&1 || true
	[ -d "$other/Contents/Frameworks/Hammerspoon.app" ] \
		&& { "$LSREGISTER" -u "$other/Contents/Frameworks/Hammerspoon.app" >/dev/null 2>&1 || true; }
done <<<"$others"
"$LSREGISTER" -f "$APP" || fail "LaunchServices refused to register $APP."
"$LSREGISTER" -f "$APP/Contents/Frameworks/Hammerspoon.app" \
	|| fail "LaunchServices refused to register the embedded Hammerspoon."

# The launcher hands this clone to its Lua only after proving it (fieldRunRoot in main.swift).
open --env "${ERGOPTI_FIELD_REPORT_ENVIRONMENT}=$REPO_ROOT" "$APP" || fail "$APP could not be opened."
log "Opened $APP with this clone as its field-run root."
