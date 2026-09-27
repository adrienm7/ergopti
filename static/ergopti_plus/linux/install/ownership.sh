#!/usr/bin/env bash
# static/ergopti_plus/linux/install/ownership.sh
#
# Records only files supplied by the installer, never pre-existing user files.
# SHA-256 lets uninstall retain a shipped file that the user later modified.

set -euo pipefail
[ "$#" -eq 3 ] || { echo 'Expected driver source, shared source and installation root.' >&2; exit 64; }
DRIVER_SOURCE="$1"
SHARED_SOURCE="$2"
INSTALL_ROOT="$3"
[ -f "$DRIVER_SOURCE/ergopti_hotstrings.lua" ] && [ -f "$SHARED_SOURCE/data/locales/en.json" ] \
	&& [ -d "$INSTALL_ROOT" ] || { echo 'Invalid ownership source or destination.' >&2; exit 1; }
manifest="$(mktemp "$INSTALL_ROOT/.ergopti-owned-files.XXXXXX")"
trap 'rm -f -- "$manifest"' EXIT
for tree in linux _shared; do
	source="$DRIVER_SOURCE"
	if [ "$tree" = _shared ]; then source="$SHARED_SOURCE"; fi
	find "$source" -type f -exec sha256sum -- {} + | while read -r digest file; do
		[[ "$digest" =~ ^[0-9a-f]{64}$ ]] || { echo 'Payload filename cannot be represented safely.' >&2; exit 1; }
		relative="$tree/${file#"$source/"}"
		case "$relative" in
			*$'\n'*|*$'\t'*|*\\*) echo 'Payload filename cannot be represented safely.' >&2; exit 1 ;;
		esac
		printf '%s\t%s\n' "$digest" "$relative" >> "$manifest"
	done
done
mv -- "$manifest" "$INSTALL_ROOT/.ergopti-owned-files"
