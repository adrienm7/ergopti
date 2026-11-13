#!/usr/bin/env bash
# tools/build/owned_runtime_install_acceptance.sh

# ==============================================================================
# MODULE: Owned runtime install acceptance (hosted Mac)
# DESCRIPTION:
# Runs the first install of a signed owned-runtime artifact on a hosted macOS
# runner exactly as the launcher's --request-owned-runtime-install role does
# behind the administrator prompt, with sudo instead of the prompt (a hosted
# runner has passwordless sudo and no console user to answer a dialog): the
# installer helper is copied root-owned into a fresh UUID stage, its code
# signature is verified there, and its one --owned-install-first transaction
# runs. It then proves what the helper claims: the closed success line, the
# runtime files, both LaunchDaemons loaded, pqrs' driver package installed and
# the stage retired.
#
# USAGE:
#   bash tools/build/owned_runtime_install_acceptance.sh <artifact.tar.gz>
#
# A hosted runner cannot approve the DriverKit extension, so the driver stays
# unapproved and no typing goes through the runtime; that is the real-Mac
# acceptance (WP9).
# ==============================================================================

set -euo pipefail

fail() { printf '::error::owned runtime install acceptance: %s\n' "$*" >&2; exit 1; }
log() { printf '[owned-install-acceptance] %s\n' "$*"; }

[ "$#" -eq 1 ] || fail "expected one argument: the artifact archive"
[ "$(uname -s)" = Darwin ] || fail "a Mac is required"
archive="$1"
[ -f "$archive" ] || fail "no archive at $archive"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../static/ergopti_plus/_shared/core/text/data/identifiers.sh
. "$REPO_ROOT/static/ergopti_plus/_shared/core/text/data/identifiers.sh"
CORE="$ERGOPTI_SERVICE_LABEL_MACOS_CORE"
VHID="$ERGOPTI_SERVICE_LABEL_MACOS_VIRTUAL_HID"
PARENT="/Library/Application Support/ErgoptiPlus"
DAEMON="/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app"
EXPECTED="OWNED_RUNTIME_INSTALL|1|files-published-services-observed-staging-retired"

work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/owned-install.XXXXXX")"
tar -xzf "$archive" -C "$work"
helper="$work/ErgoptiPlus-Runtime-Installer.app"
[ -d "$helper" ] || fail "the archive holds no ErgoptiPlus-Runtime-Installer.app"
codesign --verify --strict --deep --verbose=2 "$helper"

for label in "$CORE" "$VHID"; do
	if sudo launchctl print "system/$label" > /dev/null 2>&1; then fail "$label is already loaded before the install"; fi
done
had_driver=no
[ -e "$DAEMON" ] && had_driver=yes
log "pqrs daemon installed before the install: $had_driver"

# The launcher's role installs pqrs' pinned package in the same administrator
# shell when no driver is installed (OwnedRuntimeInstallMainOperation
# driverProgram): download it as the Lua fetch does, then check it as root.
manifest="$REPO_ROOT/static/ergopti_plus/macos/vendor/remap-runtime/manifest.json"
pin() { plutil -extract "virtual_hid_device.$1" raw -o - "$manifest"; }
if [ "$had_driver" = no ]; then
	package="$work/$(pin file_name)"
	curl -L --fail --silent --show-error --proto =https --output "$package" "$(pin source_url)"
	[ "$(shasum -a 256 "$package" | cut -d' ' -f1)" = "$(pin sha256)" ] || fail "the driver package is not the pinned one"
	sudo /bin/sh -c '
		set -eu
		signature=$(/usr/sbin/pkgutil --check-signature "$1")
		printf "%s\n" "$signature" | /usr/bin/grep -q "^ *Status: signed by a developer certificate issued by Apple"
		printf "%s\n" "$signature" | /usr/bin/grep -Eq "^ *1\. Developer ID Installer: .*\($2\)$"
		/usr/sbin/installer -pkg "$1" -target / >/dev/null
	' sh "$package" "$(pin team_identifier)"
	[ -e "$DAEMON" ] || fail "pqrs' package installed no daemon program"
fi

# The same staging as OwnedVirtualHIDDaemonReportMainOperation.stagedHelperProgram.
stage_dir="$PARENT/.runtime-installer-$(uuidgen)"
stage="$stage_dir/Helper.app"
sudo /bin/sh -c '
	set -eu
	[ -d "$1" ] || /bin/mkdir -m 0755 "$1"
	/bin/mkdir -m 0700 "$2"
	/usr/bin/ditto --noqtn --noacl --noextattr --norsrc "$3" "$4"
	/usr/sbin/chown -R root:wheel "$2"; /bin/chmod -RN "$2"; /bin/chmod -R go-w "$2"
	/usr/bin/codesign --verify --strict --all-architectures --deep "$4"
' sh "$PARENT" "$stage_dir" "$helper" "$stage"

status=0
line="$(sudo /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin "$stage/Contents/MacOS/ErgoptiPlus-Runtime-Installer" --owned-install-first)" || status=$?
log "helper exit $status, answer: $line"

diagnose() {
	sudo launchctl print "system/$CORE" 2>&1 | head -40 || true
	sudo launchctl print "system/$VHID" 2>&1 | head -40 || true
	sudo ls -la "$PARENT" /Library/LaunchDaemons 2>&1 || true
	sudo tail -40 /var/log/install.log 2>&1 || true
}
[ "$status" -eq 0 ] && [ "$line" = "$EXPECTED" ] || { diagnose; fail "the helper answered '$line' (exit $status), expected '$EXPECTED'"; }

for path in "$PARENT/Runtime/ErgoptiPlus-Remap-Core.app" "$PARENT/Runtime/ErgoptiPlus-Remap-Console.app" \
	"$PARENT/Runtime/bin/ergoptiplus_remap_cli" "/Library/LaunchDaemons/$CORE.plist" "/Library/LaunchDaemons/$VHID.plist" "$DAEMON"; do
	sudo test -e "$path" || { diagnose; fail "missing after the install: $path"; }
done
for label in "$CORE" "$VHID"; do
	sudo launchctl print "system/$label" > /dev/null || { diagnose; fail "$label is not loaded after the install"; }
done
plutil -extract Label raw -o - "/Library/LaunchDaemons/$VHID.plist" | grep -qx "$VHID" || fail "the VirtualHIDDevice job has another label"
for journal in .runtime-install-journal .runtime-service-journal .runtime-vhid-service-journal; do
	if sudo test -e "$PARENT/$journal"; then diagnose; fail "the transaction left its ledger $journal"; fi
done
if sudo test -e "$stage_dir/Helper.app"; then fail "the helper did not retire its stage"; fi
log "installed: runtime files, $CORE and $VHID loaded, pqrs daemon present (before: $had_driver), stage retired"
