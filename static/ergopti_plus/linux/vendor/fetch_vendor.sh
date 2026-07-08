#!/usr/bin/env bash
# static/ergopti_plus/linux/vendor/fetch_vendor.sh
#
# Downloads third-party Lua libraries into the vendor/ directory so the
# Linux driver and its test suite can run without a system-wide LuaRocks tree.
#
# Usage:
#   bash vendor/fetch_vendor.sh               # fetch all deps
#   bash vendor/fetch_vendor.sh --dry-run     # print what would be fetched
#   bash vendor/fetch_vendor.sh --only <name> # fetch a single dependency
#
# Dependencies:
#   - luarocks (>= 3.x) — used to fetch and unpack the rocks.
#   - curl or wget      — fallback for environments without luarocks.
#
# After running this script, the vendor/ tree contains:
#
#   vendor/
#     luv/          lua-luv (libuv bindings: event loop, timers, async I/O)
#     lfs/          luafilesystem (stat(), directory iteration)
#     posix/        luaposix (signals, process control)
#     lgi/          lgi (GObject introspection: GTK, WebKit2GTK, D-Bus)
#     http/         lua-http (async HTTP/1.1 + HTTP/2 client)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
VENDOR_DIR="${SCRIPT_DIR}"

DRY_RUN=false
ONLY=""

# --------------------------------------------------
# Argument parsing
# --------------------------------------------------
while [[ $# -gt 0 ]]; do
	case "$1" in
		--dry-run) DRY_RUN=true; shift ;;
		--only)    ONLY="$2"; shift 2 ;;
		--help|-h)
			cat << 'HELP'
Usage: bash vendor/fetch_vendor.sh [OPTIONS]

Options:
  --dry-run       Print what would be fetched without writing anything.
  --only <name>   Fetch only the named dependency (luv, lfs, posix, lgi, http).
  --help          Show this message.
HELP
			exit 0
			;;
		*) echo "Unknown option: $1" >&2; exit 1 ;;
	esac
done

# --------------------------------------------------
# Dependency catalogue
# --------------------------------------------------
# Each entry:
#   name       short name for --only
#   rock       luarocks package name
#   version    minimum version pin
#   dest       sub-directory under vendor/
#   reason     why the driver needs it
#   apt_pkg    Debian/Ubuntu package (for system-wide install alternative)
#   dnf_pkg    Fedora package
#   pacman_pkg Arch package
declare -A DEPS

DEPS[luv]="\
rock=luv
version=1.44.2-1
dest=luv
reason=libuv event loop + async timers + non-blocking pipe I/O (event_loop, timer_scheduler, http_client)
apt_pkg=lua-luv
dnf_pkg=lua-luv
pacman_pkg=lua-luv"

DEPS[lfs]="\
rock=luafilesystem
version=1.8.0-1
dest=lfs
reason=stat() + directory iteration (file_system adapter, test runner)
apt_pkg=lua-filesystem
dnf_pkg=lua-filesystem
pacman_pkg=lua-filesystem"

DEPS[posix]="\
rock=luaposix
version=36.2.1-1
dest=posix
reason=POSIX signals for graceful shutdown + SIGHUP reload (daemon signal handlers)
apt_pkg=lua-posix
dnf_pkg=lua-posix
pacman_pkg=lua-posix"

DEPS[lgi]="\
rock=lgi
version=0.9.2-5
dest=lgi
reason=GObject introspection — GTK windows, WebKit2GTK webviews, GDBus tray SNI
apt_pkg=lua-lgi
dnf_pkg=lua-lgi
pacman_pkg=lua-lgi"

DEPS[http]="\
rock=http
version=0.4-1
dest=http
reason=Async HTTP/1.1 + HTTP/2 client (http_client adapter, Ollama communication)
apt_pkg=lua-http
dnf_pkg=lua-http
pacman_pkg=lua-http"

# --------------------------------------------------
# Helpers
# --------------------------------------------------

_dep_field() {
	local dep="$1"
	local field="$2"
	local entry="${DEPS[$dep]}"
	# Extract field=value from the multi-line entry.
	echo "$entry" | while IFS='=' read -r k v; do
		[[ "$k" == "$field" ]] && echo "$v" && break
	done
}

_fetch_rock() {
	local rock="$1"
	local version="$2"
	local dest="$3"

	if $DRY_RUN; then
		echo "  [dry-run] would fetch ${rock} ${version} → vendor/${dest}/"
		return 0
	fi

	echo "  → fetching ${rock} ${version} …"

	# Strategy 1: luarocks unpack (preferred — gives us the source tree directly).
	if command -v luarocks >/dev/null 2>&1; then
		local tmpdir
		tmpdir="$(mktemp -d)"
		(
			cd "$tmpdir"
			luarocks unpack "$rock" "$version" >/dev/null 2>&1 || true
			# The unpack creates a directory named <rock>-<version>.
			local src
			src="$(find . -maxdepth 1 -type d -name "${rock}*" | head -1)"
			if [[ -n "$src" && -d "$src" ]]; then
				rm -rf "${VENDOR_DIR}/${dest}"
				cp -r "$src" "${VENDOR_DIR}/${dest}"
				echo "  ✔  ${rock} ${version} → vendor/${dest}/ (luarocks)"
			else
				echo "  ⚠  luarocks unpack succeeded but source dir not found — falling back to system package."
				rm -rf "$tmpdir"
				return 1
			fi
		)
		rm -rf "$tmpdir"
		return 0
	fi

	# Strategy 2: download the .src.rock from luarocks.org and extract manually.
	local url="https://luarocks.org/repositories/rocks/${rock}/${version}/${rock}-${version}.src.rock"
	local tmpfile
	tmpfile="$(mktemp)"

	if command -v curl >/dev/null 2>&1; then
		curl --silent --location --output "$tmpfile" "$url"
	elif command -v wget >/dev/null 2>&1; then
		wget --quiet --output-document "$tmpfile" "$url"
	else
		echo "  ✗  Neither curl nor wget available — cannot fetch ${rock}."
		rm -f "$tmpfile"
		return 1
	fi

	# .src.rock files are .zip archives; the rock contents live inside.
	local tmpdir
	tmpdir="$(mktemp -d)"
	if command -v unzip >/dev/null 2>&1; then
		unzip -q "$tmpfile" -d "$tmpdir" 2>/dev/null || true
		local src
		src="$(find "$tmpdir" -maxdepth 1 -type d -name "${rock}*" | head -1)"
		if [[ -n "$src" && -d "$src" ]]; then
			rm -rf "${VENDOR_DIR}/${dest}"
			cp -r "$src" "${VENDOR_DIR}/${dest}"
			echo "  ✔  ${rock} ${version} → vendor/${dest}/ (download)"
		else
			echo "  ✗  Could not extract ${rock} from the .src.rock archive."
			rm -rf "$tmpdir" "$tmpfile"
			return 1
		fi
	else
		echo "  ✗  unzip not available — cannot extract ${rock} .src.rock."
		rm -rf "$tmpdir" "$tmpfile"
		return 1
	fi

	rm -rf "$tmpdir" "$tmpfile"
	return 0
}


# --------------------------------------------------
# Main
# --------------------------------------------------

echo ""
echo "=== Ergopti Linux — vendor dependency fetcher ==="
echo ""

if [[ -n "$ONLY" ]]; then
	if [[ -z "${DEPS[$ONLY]:-}" ]]; then
		echo "Error: unknown dependency '${ONLY}'. Known: luv, lfs, posix, lgi, http." >&2
		exit 1
	fi

	rock="$(_dep_field "$ONLY" rock)"
	version="$(_dep_field "$ONLY" version)"
	dest="$(_dep_field "$ONLY" dest)"
	echo "Fetching single dependency: ${ONLY} (${rock} ${version})"
	_fetch_rock "$rock" "$version" "$dest"
else
	for dep in luv lfs posix lgi http; do
		rock="$(_dep_field "$dep" rock)"
		version="$(_dep_field "$dep" version)"
		dest="$(_dep_field "$dep" dest)"

		echo "${dep} (${rock} ${version}):"
		_fetch_rock "$rock" "$version" "$dest"
		echo ""
	done
fi

echo "=== Done ==="
if $DRY_RUN; then
	echo ""
	echo "This was a dry run. Remove --dry-run to actually fetch the dependencies."
else
	echo ""
	echo "The Linux daemon and test suite can now require the vendored libraries."
	echo "Make sure vendor/ is on LUA_PATH (the daemon and test runner handle this)."
fi

