#!/bin/sh
set -eu

action=${1:-ensure}
case "$action" in
	ensure|verify|print-path) ;;
	*) echo "usage: bootstrap.sh [ensure|verify|print-path]" >&2; exit 64 ;;
esac

version=v0.43.0
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repository_root=$(CDPATH= cd -- "$script_dir/../.." && pwd -P)
cache_dir="$repository_root/.rtk"
cache_path="$cache_dir/path"
manifest_path="$script_dir/release.tsv"

is_rtk() {
	candidate=$1
	required_version=${2:-}
	[ -f "$candidate" ] && [ -x "$candidate" ] || return 1
	version_text=$("$candidate" --version 2>/dev/null | sed -n '1p') || return 1
	case "$version_text" in rtk\ *) ;; *) return 1 ;; esac
	[ -z "$required_version" ] || [ "$version_text" = "rtk ${required_version#v}" ] || return 1
	"$candidate" gain --help 2>&1 | grep -qi 'token savings'
}

cache_binary() {
	candidate=$1
	mkdir -p "$cache_dir"
	temporary="$cache_path.$$"
	printf '%s\n' "$candidate" > "$temporary"
	mv -f "$temporary" "$cache_path"
}

find_rtk() {
	if [ -f "$cache_path" ]; then
		IFS= read -r cached < "$cache_path" || true
		if [ -n "${cached:-}" ] && is_rtk "$cached" "$version"; then
			printf '%s\n' "$cached"
			return 0
		fi
	fi

	if command -v rtk >/dev/null 2>&1; then
		candidate=$(command -v rtk)
		if is_rtk "$candidate" "$version"; then
			cache_binary "$candidate"
			printf '%s\n' "$candidate"
			return 0
		fi
	fi

	data_home=${XDG_DATA_HOME:-"$HOME/.local/share"}
	installed="$data_home/rtk/$version/bin/rtk"
	if is_rtk "$installed" "$version"; then
		cache_binary "$installed"
		printf '%s\n' "$installed"
		return 0
	fi
	return 1
}

platform_row() {
	case $(uname -s) in
		Linux) platform=linux ;;
		Darwin) platform=darwin ;;
		*) echo "unsupported operating system for RTK $version" >&2; return 1 ;;
	esac
	case $(uname -m) in
		x86_64|amd64) architecture=x86_64 ;;
		aarch64|arm64) architecture=aarch64 ;;
		*) echo "unsupported architecture for RTK $version" >&2; return 1 ;;
	esac

	match_asset=
	match_sha=
	tab=$(printf '\t')
	while IFS="$tab" read -r row_version row_os row_arch row_asset row_sha; do
		[ "$row_version" = "$version" ] || continue
		[ "$row_os" = "$platform" ] || continue
		[ "$row_arch" = "$architecture" ] || continue
		[ -z "$match_asset" ] || { echo "duplicate RTK release row" >&2; return 1; }
		match_asset=$row_asset
		match_sha=$row_sha
	done < "$manifest_path"
	[ -n "$match_asset" ] || { echo "no RTK asset for $platform/$architecture" >&2; return 1; }
	printf '%s\n%s\n' "$match_asset" "$match_sha"
}

verify_hash() {
	archive=$1
	expected=$2
	if command -v sha256sum >/dev/null 2>&1; then
		actual=$(sha256sum "$archive" | sed 's/[[:space:]].*//')
	elif command -v shasum >/dev/null 2>&1; then
		actual=$(shasum -a 256 "$archive" | sed 's/[[:space:]].*//')
	else
		echo "sha256sum or shasum is required" >&2
		return 1
	fi
	[ "$actual" = "$expected" ] || { echo "RTK archive checksum mismatch" >&2; return 1; }
}

install_rtk() {
	[ -z "${CI:-}" ] || { echo "RTK installation is disabled in CI" >&2; return 3; }
	row=$(platform_row)
	asset=$(printf '%s\n' "$row" | sed -n '1p')
	checksum=$(printf '%s\n' "$row" | sed -n '2p')
	[ -n "$asset" ] && [ -n "$checksum" ] || { echo "invalid RTK release row" >&2; return 1; }

	data_home=${XDG_DATA_HOME:-"$HOME/.local/share"}
	version_dir="$data_home/rtk/$version/bin"
	destination="$version_dir/rtk"
	mkdir -p "$version_dir"
	lock="$version_dir/.install.lock"
	if ! mkdir "$lock" 2>/dev/null; then
		if is_rtk "$destination" "$version"; then printf '%s\n' "$destination"; return 0; fi
		echo "another RTK installation owns $lock" >&2
		return 1
	fi

	temporary=$(mktemp -d "${TMPDIR:-/tmp}/rtk.XXXXXXXX")
	trap 'rm -rf "$temporary" "$lock"' EXIT HUP INT TERM
	archive="$temporary/$asset"
	url="https://github.com/rtk-ai/rtk/releases/download/$version/$asset"
	if command -v curl >/dev/null 2>&1; then
		curl -fL --proto '=https' --tlsv1.2 -o "$archive" "$url"
	elif command -v wget >/dev/null 2>&1; then
		wget --https-only -O "$archive" "$url"
	else
		echo "curl or wget is required to install RTK" >&2
		return 1
	fi
	verify_hash "$archive" "$checksum"

	entries=$(tar -tzf "$archive")
	entry_count=$(printf '%s\n' "$entries" | grep -c . || true)
	[ "$entry_count" -eq 1 ] || { echo "RTK archive must contain one entry" >&2; return 1; }
	case "$entries" in rtk|./rtk) ;; *) echo "unsafe RTK archive entry: $entries" >&2; return 1 ;; esac
	tar -xzf "$archive" -C "$temporary"
	candidate="$temporary/${entries#./}"
	chmod 755 "$candidate"
	is_rtk "$candidate" "$version" || { echo "downloaded executable is not Rust Token Killer $version" >&2; return 1; }
	mv -f "$candidate" "$destination.tmp.$$"
	mv -f "$destination.tmp.$$" "$destination"
	rm -rf "$temporary" "$lock"
	trap - EXIT HUP INT TERM
	printf '%s\n' "$destination"
}

if resolved=$(find_rtk); then
	printf '%s\n' "$resolved"
	exit 0
fi

if [ "$action" = verify ]; then
	echo "Rust Token Killer is unavailable or is the wrong rtk package" >&2
	exit 3
fi

if [ -n "${CI:-}" ]; then
	exit 3
fi

resolved=$(install_rtk)
cache_binary "$resolved"
printf '%s\n' "$resolved"
