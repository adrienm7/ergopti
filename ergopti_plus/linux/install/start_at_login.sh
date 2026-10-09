#!/usr/bin/env bash
# static/ergopti_plus/linux/install/start_at_login.sh
#
# User-owned startup choice. Disabling affects future sessions only; the current
# daemon must remain alive while its menu reports the result.

set -euo pipefail
DRIVER_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$DRIVER_ROOT/install/desktop_entry.sh"
CONFIG_ROOT="${XDG_CONFIG_HOME:-$HOME/.config}"
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

if [ -L "$DESKTOP_FILE" ]; then
	echo 'Refusing to replace a linked startup setting.' >&2
	exit 78
fi
if [ -f "$DESKTOP_FILE" ] && ! grep -Fxq "Exec=$LAUNCHER --tray" "$DESKTOP_FILE" \
	&& ! grep -Fxq "Exec=$LAUNCHER --session-start --tray" "$DESKTOP_FILE" \
	&& ! grep -Fxq "$(ergopti_desktop_exec "$LAUNCHER")" "$DESKTOP_FILE"; then
	echo 'The startup entry belongs to another command.' >&2
	exit 78
fi

# XDG is the session entry point on every desktop. It starts the packaged unit
# when systemd is available; no enabled unit may compete with the XDG choice.
if command -v systemctl >/dev/null 2>&1; then
	# Disabling is a filesystem operation. Avoid an unnecessary daemon reload,
	# which fails when installation runs outside a graphical user session.
	# A supported --no-service installation has no unit to disable. Listing unit
	# files also works without a user bus; a failed query must remain an error.
	unit_files="$(systemctl --user --no-pager --no-legend list-unit-files ergopti-hotstrings.service)"
	if [ -n "$unit_files" ]; then
		systemctl --user --no-reload disable ergopti-hotstrings.service
	fi
fi
install -d -m 700 "$CONFIG_ROOT/autostart"
desktop_tmp="$(mktemp "$DESKTOP_FILE.XXXXXX")"
receipt_tmp=""
trap 'rm -f -- "$desktop_tmp"; if [ -n "$receipt_tmp" ]; then rm -f -- "$receipt_tmp"; fi' EXIT
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
mv -f -- "$desktop_tmp" "$DESKTOP_FILE"

# Standalone removal follows content receipts, including startup changes made
# by this menu. Never claim an unrelated payload file while updating this row.
manifest="$DRIVER_ROOT/../.ergopti-owned-files"
if [ -f "$manifest" ]; then
	[ ! -L "$manifest" ] || { echo 'Linked ownership receipt refused.' >&2; exit 78; }
	receipt_tmp="$(mktemp "$manifest.XXXXXX")"
	while IFS=$'\t' read -r digest relative; do
		if [ "$relative" != @autostart ]; then printf '%s\t%s\n' "$digest" "$relative"; fi
	done < "$manifest" > "$receipt_tmp"
	digest="$(sha256sum -- "$DESKTOP_FILE")"
	printf '%s\t@autostart\n' "${digest%% *}" >> "$receipt_tmp"
	mv -f -- "$receipt_tmp" "$manifest"
fi
