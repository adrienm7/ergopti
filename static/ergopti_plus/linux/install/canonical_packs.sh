#!/usr/bin/env bash
# static/ergopti_plus/linux/install/canonical_packs.sh

# Migrates the standalone installer's legacy canonical-pack seeds before the
# installed shared tree is replaced. The old installed bundle is the only
# trustworthy baseline for distinguishing an untouched generated seed from a
# deliberate user override.

CANONICAL_PACK_MIGRATION_MARKER=".ergopti-canonical-packs-v2"
CANONICAL_PACK_BACKUP_DIR=".ergopti-migrations/canonical-seeds"

# Reports whether two files hold the same bytes. sha256sum ships in coreutils,
# which every supported image carries; cmp needs diffutils, which minimal Arch,
# Fedora and openSUSE images lack.
# @param $1 First file.
# @param $2 Second file.
same_bytes() {
	local left right
	left="$(sha256sum < "$1")" || return 2
	right="$(sha256sum < "$2")" || return 2
	[ "${left}" = "${right}" ]
}

# Admits the exact completion record without unbounded reads. NONBLOCK and
# NOFOLLOW prevent a replaced FIFO or symlink from hanging the installer; the
# surrounding metadata observations refuse observed source changes. They do not
# serialize writers outside this installer.
canonical_pack_marker_valid() {
	local marker="$1" before after digest expected
	[ -f "$marker" ] && [ ! -L "$marker" ] || return 1
	before="$(stat -c '%d:%i:%f:%s:%y:%z' -- "$marker")" || return 1
	digest="$(set -o pipefail; dd if="$marker" bs=3 count=1 iflag=nonblock,nofollow status=none | sha256sum)" || return 1
	after="$(stat -c '%d:%i:%f:%s:%y:%z' -- "$marker")" || return 1
	[ "$before" = "$after" ] && [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
	expected="$(printf '2\n' | sha256sum)" || return 1
	[ "$digest" = "$expected" ]
}

# Removes legacy seeds from the active override namespace while retaining their
# exact bytes outside the recursive *.toml loader. Modified files stay active.
# A marker makes this a one-time legacy transition: later user overrides are
# never reclassified merely because they happen to equal an installed pack.
# @param $1 New bundled canonical-pack directory.
# @param $2 Previously installed canonical-pack directory.
# @param $3 User hotstring configuration directory.
migrate_canonical_packs() {
	local source_dir="$1"
	local installed_dir="$2"
	local config_dir="$3"
	local marker="${config_dir}/${CANONICAL_PACK_MIGRATION_MARKER}"
	local backup_dir="${config_dir}/${CANONICAL_PACK_BACKUP_DIR}"
	local source_pack name user_pack installed_pack backup marker_tmp
	local index
	local -a user_packs=() backups=() backup_present=()

	if [ -e "${marker}" ] || [ -L "${marker}" ]; then
		if ! canonical_pack_marker_valid "$marker"; then
			printf '[install] code=invalid-canonical-pack-marker\n' >&2
			return 1
		fi
		return 0
	fi

	install -d "${config_dir}" "${backup_dir}"
	# The previously installed packs count as much as the new ones: a pack the
	# new bundle no longer carries (SFB reduction and rolls moved into the
	# Ergopti layout extension) must not leave its intact seed behind as an
	# override that hides the pack's new source.
	declare -A seen=()
	for source_pack in "${source_dir}"/*.toml "${installed_dir}"/*.toml; do
		[ -e "${source_pack}" ] || continue
		name="$(basename "${source_pack}")"
		[[ "${name}" == _* ]] && continue
		[ -z "${seen[${name}]:-}" ] || continue
		seen["${name}"]=1

		user_pack="${config_dir}/${name}"
		installed_pack="${installed_dir}/${name}"
		# A link is a user-selected reference, not an installer-created seed;
		# moving it would also change the meaning of a relative link target.
		[ -f "${user_pack}" ] && [ ! -L "${user_pack}" ] || continue
		[ -f "${installed_pack}" ] && [ ! -L "${installed_pack}" ] || continue
		# Status 1 means the bytes differ: a user override stays active. Any other
		# status is an unreadable pack, which must abort the migration.
		if same_bytes "${user_pack}" "${installed_pack}"; then
			:
		else
			[ "$?" -eq 1 ] || return 1
			continue
		fi

		# The suffix deliberately does not end in .toml: Loader.find_toml_files()
		# scans recursively, so a normal TOML backup would remain an active pack.
		backup="${backup_dir}/${name}.legacy-seed"
		if [ -e "${backup}" ] || [ -L "${backup}" ]; then
			[ -f "${backup}" ] && [ ! -L "${backup}" ] || return 1
			same_bytes "${user_pack}" "${backup}" || return 1
			backup_present+=(true)
		else
			backup_present+=(false)
		fi
		user_packs+=("${user_pack}")
		backups+=("${backup}")
	done

	# Admit every existing backup before moving the first seed. A conflict in a
	# later category must not leave an otherwise untouched migration half-applied.
	for index in "${!user_packs[@]}"; do
		if "${backup_present[$index]}"; then
			rm -f -- "${user_packs[$index]}"
		else
			mv -- "${user_packs[$index]}" "${backups[$index]}"
		fi
	done

	# A PID-derived name can already hold a user's file or an interrupted
	# attempt after PID reuse. Allocate a new sibling instead of truncating it.
	marker_tmp="$(mktemp "${marker}.tmp.XXXXXX")" || return 1
	if ! printf '%s\n' "2" > "${marker_tmp}" \
		|| ! chmod 0644 "${marker_tmp}" \
		|| ! mv -T -- "${marker_tmp}" "${marker}"; then
		rm -f -- "${marker_tmp}" || return 1
		return 1
	fi
}
