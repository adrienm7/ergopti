#!/usr/bin/env bash
# static/ergopti_plus/linux/install/ownership.sh
#
# Records only files supplied by the installer, never pre-existing user files.
# SHA-256 lets uninstall retain a shipped file that the user later modified.
# Each optional pair of arguments after the third names a tree the installer
# copied from outside the driver source and where it landed below the
# installation root: the layout registry (install/layout_registry.sh) and the
# XKB helpers (install/xkb_helpers.sh) of a checkout install. Their files are
# the installer's too. The helper and its canonical schema travel together:
# the updater runs the previous installation's owner against a new payload.

set -euo pipefail
ownership_directory="$(cd -- "$(dirname -- "$0")" && pwd -P)"
# Canonical receipt constants are also read by the native rollback verifier.
source "$ownership_directory/ownership_schema.sh"

# Refuses with one closed developer record and exits. This helper prints no
# prose: the installer and the updater that call it report the failure in the
# user's language, and the updater may run an earlier installation's copy of
# it, so it cannot depend on that copy's message catalogue.
# @param $1 Refusal code.
# @param $2 Exit status.
ownership_refuse() {
	local record="[ownership] code=$1"
	printf '%s\n' "$record" >&2
	exit "$2"
}

valid_owned_relative() {
	local relative="$1"
	case "$relative" in ''|*$'\n'*|*$'\r'*|*$'\t'*|*\\*) return 1 ;; esac
	case "/$relative/" in */../*|*/./*|*//*) return 1 ;; esac
	[[ "$relative" != */ ]] || return 1
	case "$relative" in
		"$OWNERSHIP_DRIVER_TREE"/*|"$OWNERSHIP_SHARED_TREE"/*|"$OWNERSHIP_LAUNCHER") return 0 ;;
	esac
	return 1
}
[ "$#" -ge 3 ] && [ $(( ($# - 3) % 2 )) -eq 0 ] || {
	ownership_refuse usage 64
}
DRIVER_SOURCE="$1"
SHARED_SOURCE="$2"
INSTALL_ROOT="$3"
shift 3
EXTRA_SOURCES=()
EXTRA_PREFIXES=()
[ -f "$DRIVER_SOURCE/$OWNERSHIP_DRIVER_SENTINEL" ] && [ -f "$SHARED_SOURCE/$OWNERSHIP_SHARED_SENTINEL" ] \
	&& [ -d "$INSTALL_ROOT" ] || ownership_refuse invalid_source 1
while [ "$#" -gt 0 ]; do
	# Only below the driver tree, which is all uninstall.sh accepts, and never
	# outside it.
	case "/$2/" in
		/"$OWNERSHIP_DRIVER_TREE"/*/) ;;
		*) ownership_refuse invalid_extra_path 1 ;;
	esac
	case "/$2/" in
		*/../*|*/./*|*//*|*\\*) ownership_refuse invalid_extra_path 1 ;;
	esac
	[ -d "$1" ] || ownership_refuse invalid_extra_source 1
	EXTRA_SOURCES+=("$1")
	EXTRA_PREFIXES+=("$2")
	shift 2
done
target="$INSTALL_ROOT/$OWNERSHIP_MANIFEST"
if [ -L "$target" ] || { [ -e "$target" ] && [ ! -f "$target" ]; }; then
	ownership_refuse invalid_destination 1
fi
manifest="$(mktemp "$INSTALL_ROOT/$OWNERSHIP_MANIFEST.XXXXXX")"
trap 'rm -f -- "$manifest"' EXIT
sources=("$DRIVER_SOURCE" "$SHARED_SOURCE" "${EXTRA_SOURCES[@]}")
prefixes=("$OWNERSHIP_DRIVER_TREE" "$OWNERSHIP_SHARED_TREE" "${EXTRA_PREFIXES[@]}")
for index in "${!sources[@]}"; do
	source="${sources[$index]}"
	prefix="${prefixes[$index]}"
	# Keep source paths as native bytes; checksum filename escaping must never
	# become either a digest marker or part of the installed relative name.
	find "$source" -type f -print0 | while IFS= read -r -d '' file; do
		digest="$(sha256sum < "$file")"
		digest="${digest%% *}"
		if ! [[ "$digest" =~ ^[0-9a-f]+$ ]] || [ "${#digest}" -ne "$OWNERSHIP_HEX_LENGTH" ]; then
			checksum_refusal="[ownership] code=invalid_checksum"
			printf '%s path=%q\n' "$checksum_refusal" "$file" >&2
			exit 1
		fi
		relative="$prefix/${file#"$source/"}"
		if ! valid_owned_relative "$relative"; then
			# The caller owns localized status; native path bytes stay in one
			# developer record instead of becoming untranslated UI prose.
			filename_refusal="[ownership] code=invalid_receipt"
			printf '%s path=%q\n' "$filename_refusal" "$file" >&2
			exit 1
		fi
		printf '%s\t%s\n' "$digest" "$relative" >> "$manifest"
	done
done
launcher="$INSTALL_ROOT/$OWNERSHIP_LAUNCHER"
if [ -f "$launcher" ]; then
	digest="$(sha256sum < "$launcher")"
	printf '%s\t%s\n' "${digest%% *}" "$OWNERSHIP_LAUNCHER" >> "$manifest"
fi
mv -T -- "$manifest" "$target"
