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

	if [ -f "${marker}" ]; then
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
		[ -f "${user_pack}" ] || continue
		[ -f "${installed_pack}" ] || continue
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
		if [ -e "${backup}" ]; then
			same_bytes "${user_pack}" "${backup}" || return 1
			rm -f -- "${user_pack}"
		else
			mv -- "${user_pack}" "${backup}"
		fi
	done

	marker_tmp="${marker}.tmp.$$"
	printf '%s\n' "2" > "${marker_tmp}"
	chmod 0644 "${marker_tmp}"
	mv -- "${marker_tmp}" "${marker}"
}
