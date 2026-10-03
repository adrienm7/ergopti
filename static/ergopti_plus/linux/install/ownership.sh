#!/usr/bin/env bash
# static/ergopti_plus/linux/install/ownership.sh
#
# Records only files supplied by the installer, never pre-existing user files.
# SHA-256 lets uninstall retain a shipped file that the user later modified.
# The optional fourth and fifth arguments name a tree the installer copied from
# outside the driver source and where it landed below the installation root: the
# layout registry of a checkout install (install/layout_registry.sh). Its files
# are the installer's too. Self-contained, because the updater runs the previous
# installation's copy of this script against a new payload.

set -euo pipefail
[ "$#" -eq 3 ] || [ "$#" -eq 5 ] || {
	echo 'Expected driver source, shared source, installation root, then optionally an extra source and its installed path.' >&2
	exit 64
}
DRIVER_SOURCE="$1"
SHARED_SOURCE="$2"
INSTALL_ROOT="$3"
EXTRA_SOURCE="${4:-}"
EXTRA_PREFIX="${5:-}"
[ -f "$DRIVER_SOURCE/ergopti_hotstrings.lua" ] && [ -f "$SHARED_SOURCE/data/locales/en.json" ] \
	&& [ -d "$INSTALL_ROOT" ] || { echo 'Invalid ownership source or destination.' >&2; exit 1; }
if [ "$#" -eq 5 ]; then
	# Only below the driver tree, which is all uninstall.sh accepts, and never
	# outside it.
	case "/$EXTRA_PREFIX/" in
		/linux/*/) ;;
		*) echo 'Invalid extra ownership path.' >&2; exit 1 ;;
	esac
	case "/$EXTRA_PREFIX/" in
		*/../*|*/./*|*//*|*\\*) echo 'Invalid extra ownership path.' >&2; exit 1 ;;
	esac
	[ -d "$EXTRA_SOURCE" ] || { echo 'Invalid extra ownership source.' >&2; exit 1; }
fi
manifest="$(mktemp "$INSTALL_ROOT/.ergopti-owned-files.XXXXXX")"
trap 'rm -f -- "$manifest"' EXIT
trees=(linux _shared)
if [ -n "$EXTRA_PREFIX" ]; then trees+=(extra); fi
for tree in "${trees[@]}"; do
	case "$tree" in
		linux) source="$DRIVER_SOURCE"; prefix=linux ;;
		_shared) source="$SHARED_SOURCE"; prefix=_shared ;;
		extra) source="$EXTRA_SOURCE"; prefix="$EXTRA_PREFIX" ;;
	esac
	find "$source" -type f -exec sha256sum -- {} + | while read -r digest file; do
		[[ "$digest" =~ ^[0-9a-f]{64}$ ]] || { echo 'Payload filename cannot be represented safely.' >&2; exit 1; }
		# GNU checksum output marks binary inputs with '*'; it is not a path byte.
		file="${file#\*}"
		relative="$prefix/${file#"$source/"}"
		case "$relative" in
			*$'\n'*|*$'\t'*|*\\*) echo 'Payload filename cannot be represented safely.' >&2; exit 1 ;;
		esac
		printf '%s\t%s\n' "$digest" "$relative" >> "$manifest"
	done
done
launcher="$INSTALL_ROOT/bin/ergopti-hotstrings"
if [ -f "$launcher" ]; then
	digest="$(sha256sum -- "$launcher")"
	printf '%s\tbin/ergopti-hotstrings\n' "${digest%% *}" >> "$manifest"
fi
mv -- "$manifest" "$INSTALL_ROOT/.ergopti-owned-files"
