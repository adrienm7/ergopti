#!/usr/bin/env bash
# install/native_source_build.sh
# Source-only compiler prerequisites shared by the installer and CI checkout lane.

native_source_build_required() {
	local driver="$1"
	local repository
	repository="$(cd "${driver}/../../.." && pwd -P)" || return 1
	[ "$driver" = "${repository}/static/ergopti_plus/linux" ]
}

native_source_build_packages() {
	# Void's meta package selects musl-devel or glibc-devel for its target libc.
	case "$1" in
		apt) printf '%s\n' gcc libc6-dev linux-libc-dev ;;
		dnf) printf '%s\n' gcc glibc-devel kernel-headers ;;
		zypper) printf '%s\n' gcc glibc-devel linux-glibc-devel ;;
		pacman) printf '%s\n' gcc glibc linux-api-headers ;;
		xbps) printf '%s\n' gcc base-devel kernel-libc-headers ;;
		apk) printf '%s\n' gcc musl-dev linux-headers ;;
		*) return 1 ;;
	esac
}

native_source_compile_probe() {
	local source="$1"
	local compiler="${CC:-cc}"
	local name
	for name in archive_publication.c archive_publication.h; do
		[ -f "${source}/${name}" ] && [ ! -L "${source}/${name}" ] || return 1
	done
	command -v "$compiler" >/dev/null 2>&1 || return 1
	# Parse every real source include; a compiler path alone proves no libc SDK.
	"$compiler" -std=c11 -O2 -fPIC -Wall -Wextra -Werror -fsyntax-only \
		-I "$source" "${source}/archive_publication.c" >/dev/null 2>&1
}

native_source_ensure_prerequisites() {
	local source="$1"
	local manager="$2"
	local install_package="$3"
	local packages
	local package
	local name
	for name in archive_publication.c archive_publication.h; do
		[ -f "${source}/${name}" ] && [ ! -L "${source}/${name}" ] || return 1
	done
	if native_source_compile_probe "$source"; then return 0; fi
	packages="$(native_source_build_packages "$manager")" || return 1
	while IFS= read -r package; do
		"$install_package" "$manager" "$package" || return 1
	done <<< "$packages"
	if ! native_source_compile_probe "$source"; then
		echo "source-build-toolchain-unavailable" >&2
		return 1
	fi
}
