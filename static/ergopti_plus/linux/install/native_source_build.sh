#!/usr/bin/env bash
# install/native_source_build.sh
# Read-only source capability admission; package policy belongs to the shared catalogue.

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
