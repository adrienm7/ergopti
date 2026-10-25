#!/usr/bin/env bash
# static/ergopti_plus/linux/install/ownership.sh
#
# Records only files supplied by the installer, never pre-existing user files.
# SHA-256 lets uninstall retain a shipped file that the user later modified.
# The optional fourth and fifth arguments name a tree the installer copied from
# outside the driver source and where it landed below the installation root: the
# layout registry of a checkout install (install/layout_registry.sh). Its files
# are the installer's too. The helper and its canonical schema travel together:
# the updater runs the previous installation's owner against a new payload.

set -euo pipefail
ownership_directory="$(cd -- "$(dirname -- "$0")" && pwd -P)"
# Canonical receipt constants are also read by the native rollback verifier.
source "$ownership_directory/ownership_schema.sh"

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
[ "$#" -eq 3 ] || [ "$#" -eq 5 ] || {
	echo 'Expected driver source, shared source, installation root, then optionally an extra source and its installed path.' >&2
	exit 64
}
DRIVER_SOURCE="$1"
SHARED_SOURCE="$2"
INSTALL_ROOT="$3"
EXTRA_SOURCE="${4:-}"
EXTRA_PREFIX="${5:-}"
[ -f "$DRIVER_SOURCE/$OWNERSHIP_DRIVER_SENTINEL" ] && [ -f "$SHARED_SOURCE/$OWNERSHIP_SHARED_SENTINEL" ] \
	&& [ -d "$INSTALL_ROOT" ] || { echo 'Invalid ownership source or destination.' >&2; exit 1; }
if [ "$#" -eq 5 ]; then
	# Only below the driver tree, which is all uninstall.sh accepts, and never
	# outside it.
	case "/$EXTRA_PREFIX/" in
		/"$OWNERSHIP_DRIVER_TREE"/*/) ;;
		*) echo 'Invalid extra ownership path.' >&2; exit 1 ;;
	esac
	case "/$EXTRA_PREFIX/" in
		*/../*|*/./*|*//*|*\\*) echo 'Invalid extra ownership path.' >&2; exit 1 ;;
	esac
	[ -d "$EXTRA_SOURCE" ] || { echo 'Invalid extra ownership source.' >&2; exit 1; }
fi
manifest="$(mktemp "$INSTALL_ROOT/$OWNERSHIP_MANIFEST.XXXXXX")"
trap 'rm -f -- "$manifest"' EXIT
trees=("$OWNERSHIP_DRIVER_TREE" "$OWNERSHIP_SHARED_TREE")
if [ -n "$EXTRA_PREFIX" ]; then trees+=(extra); fi
for tree in "${trees[@]}"; do
	case "$tree" in
		"$OWNERSHIP_DRIVER_TREE") source="$DRIVER_SOURCE"; prefix="$OWNERSHIP_DRIVER_TREE" ;;
		"$OWNERSHIP_SHARED_TREE") source="$SHARED_SOURCE"; prefix="$OWNERSHIP_SHARED_TREE" ;;
		extra) source="$EXTRA_SOURCE"; prefix="$EXTRA_PREFIX" ;;
	esac
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
mv -- "$manifest" "$INSTALL_ROOT/$OWNERSHIP_MANIFEST"
