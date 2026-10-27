#!/usr/bin/env bash
# static/ergopti_plus/linux/install/start_at_login.sh
#
# User-owned startup choice. Disabling affects future sessions only; the current
# daemon must remain alive while its menu reports the result.

set -euo pipefail
DRIVER_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$DRIVER_ROOT/install/desktop_entry.sh"
source "$DRIVER_ROOT/install/config_home.sh"
ergopti_resolve_config_home CONFIG_ROOT
ACTION="${1:-status}"
case "$ACTION" in status|enable|disable) ;; *) exit 64 ;; esac

if [ "$DRIVER_ROOT" = /usr/lib/ergopti ]; then
	DESKTOP_NAME=ergopti.desktop
	LAUNCHER=/usr/bin/ergopti
elif [[ "$DRIVER_ROOT" = */lib/ergopti/linux ]]; then
	DESKTOP_NAME=ergopti-hotstrings.desktop
	LAUNCHER="${DRIVER_ROOT%/lib/ergopti/linux}/bin/ergopti-hotstrings"
else
	echo 'Automatic startup requires an installed application.' >&2
	exit 78
fi
DESKTOP_FILE="$CONFIG_ROOT/autostart/$DESKTOP_NAME"

if [ "$ACTION" = status ]; then
	# Report a real conflicting command without acquiring it for replacement.
	if [ -f "$DESKTOP_FILE" ] && ! grep -Fxq "Exec=$LAUNCHER --tray" "$DESKTOP_FILE" \
		&& ! grep -Fxq "Exec=$LAUNCHER --session-start --tray" "$DESKTOP_FILE" \
		&& ! grep -Fxq "$(ergopti_desktop_exec "$LAUNCHER")" "$DESKTOP_FILE"; then
		printf 'other\n'
		exit 0
	fi
	if [ -f "$DESKTOP_FILE" ] && grep -Eq '^(Hidden=true|X-GNOME-Autostart-enabled=false)$' "$DESKTOP_FILE"; then
		printf 'disabled\n'
	elif systemctl --user is-enabled --quiet ergopti-hotstrings.service 2>/dev/null; then
		printf 'enabled\n'
	elif [ -f "$DESKTOP_FILE" ] || [ -f "/etc/xdg/autostart/$DESKTOP_NAME" ]; then
		printf 'enabled\n'
	else
		printf 'disabled\n'
	fi
	exit 0
fi

# Operator records remain language-independent data. The menu renders its
# existing localized failure, while an installer terminal retains code/path
# evidence without a second catalogue or a new untranslated sentence.
startup_record() {
	local record="[startup] code=$1 role=$2"
	printf '%s path=%q\n' "$record" "$3" >&2
}

if { [ -e "$DESKTOP_FILE" ] || [ -L "$DESKTOP_FILE" ]; } \
	&& { [ -L "$DESKTOP_FILE" ] || [ ! -f "$DESKTOP_FILE" ]; }; then
	startup_record invalid-source desktop "$DESKTOP_FILE"
	exit 78
fi
if [ -f "$DESKTOP_FILE" ] && ! grep -Fxq "Exec=$LAUNCHER --tray" "$DESKTOP_FILE" \
	&& ! grep -Fxq "Exec=$LAUNCHER --session-start --tray" "$DESKTOP_FILE" \
	&& ! grep -Fxq "$(ergopti_desktop_exec "$LAUNCHER")" "$DESKTOP_FILE"; then
	echo 'The startup entry belongs to another command.' >&2
	exit 78
fi

# Admit the receipt before changing startup or its service. A linked or special
# source cannot authorize publishing a preference that removal cannot own.
manifest="$DRIVER_ROOT/../.ergopti-owned-files"
receipt_present=false
if [ -e "$manifest" ] || [ -L "$manifest" ]; then
	[ ! -L "$manifest" ] && [ -f "$manifest" ] \
		|| { startup_record invalid-source receipt "$manifest"; exit 78; }
	receipt_present=true
fi

install -d -m 700 "$CONFIG_ROOT/autostart"
desktop_tmp= receipt_tmp= desktop_previous= receipt_previous=
desktop_published=false
receipt_published=false
committed=false

# Two file renames are not a hard-kill transaction. On an observed publication
# or service failure, restore the previous owned bytes and retain recovery
# copies if restoration itself is refused.
finish_startup() {
	local status=$? rollback_failed=false temporary recovery_recorded=false
	trap - EXIT
	if ! "$committed"; then
		if "$desktop_published"; then
			if [ -n "$desktop_previous" ]; then
				if mv -f -- "$desktop_previous" "$DESKTOP_FILE"; then desktop_previous=; else rollback_failed=true; fi
			elif ! rm -f -- "$DESKTOP_FILE"; then rollback_failed=true; fi
		fi
		if "$receipt_published"; then
			if mv -f -- "$receipt_previous" "$manifest"; then receipt_previous=; else rollback_failed=true; fi
		fi
	fi
	if "$rollback_failed"; then
		for temporary in "$desktop_previous" "$receipt_previous"; do
			if [ -n "$temporary" ]; then
				startup_record rollback-failed recovery "$temporary"
				recovery_recorded=true
			fi
		done
		if ! "$recovery_recorded"; then startup_record rollback-failed desktop "$DESKTOP_FILE"; fi
		status=1
	else
		for temporary in "$desktop_tmp" "$receipt_tmp" "$desktop_previous" "$receipt_previous"; do
			if [ -n "$temporary" ] && ! rm -f -- "$temporary"; then
				startup_record cleanup-failed temporary "$temporary"
				status=1
			fi
		done
	fi
	exit "$status"
}
trap finish_startup EXIT

desktop_tmp="$(mktemp "$DESKTOP_FILE.XXXXXX")"
if [ -f "$DESKTOP_FILE" ]; then
	desktop_previous="$(mktemp "$DESKTOP_FILE.previous.XXXXXX")"
	cp -p -- "$DESKTOP_FILE" "$desktop_previous"
	cp -p -- "$desktop_previous" "$desktop_tmp"
fi
hidden=false
if [ "$ACTION" = disable ]; then hidden=true; fi
cat > "$desktop_tmp" <<EOF
[Desktop Entry]
Type=Application
Name=Ergopti
$(ergopti_desktop_exec "$LAUNCHER")
Terminal=false
Hidden=$hidden
X-Ergopti-Startup=true
EOF
# Standalone removal follows content receipts, including startup changes made
# by this menu. Stage its exact new digest before either file is published.
if "$receipt_present"; then
	receipt_previous="$(mktemp "$manifest.previous.XXXXXX")"
	cp -p -- "$manifest" "$receipt_previous"
	receipt_tmp="$(mktemp "$manifest.XXXXXX")"
	cp -p -- "$receipt_previous" "$receipt_tmp"
	while IFS=$'\t' read -r digest relative; do
		if [ "$relative" != @autostart ]; then printf '%s\t%s\n' "$digest" "$relative"; fi
	done < "$receipt_previous" > "$receipt_tmp"
	digest="$(sha256sum < "$desktop_tmp")"
	printf '%s\t@autostart\n' "${digest%% *}" >> "$receipt_tmp"
	mv -f -- "$receipt_tmp" "$manifest"
	receipt_published=true
fi
mv -f -- "$desktop_tmp" "$DESKTOP_FILE"
desktop_published=true

# XDG is the session entry point on every desktop. Only a complete publication
# can authorize changing the unit; a refusal restores both file snapshots.
if command -v systemctl >/dev/null 2>&1; then
	# list-unit-files works without a user bus; a failed query remains an error.
	# A filtered query exits 1 for a missing unit on systemd 257, so select from
	# the complete successful inventory instead of filtering the native query.
	unit_files="$(systemctl --user --no-pager --no-legend list-unit-files)"
	unit_present=false
	while read -r unit_name unit_metadata; do
		if [ "$unit_name" = ergopti-hotstrings.service ]; then unit_present=true; break; fi
	done <<< "$unit_files"
	if "$unit_present"; then systemctl --user --no-reload disable ergopti-hotstrings.service; fi
fi
committed=true
