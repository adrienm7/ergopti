#!/usr/bin/env bash
# static/ergopti_plus/linux/install.sh
#
# Standalone installer for the Ergopti hotstring expansion daemon.
#
# Designed for users who prefer not to use a package manager (.deb/.rpm).
# Installs to the XDG user directories (~/.local/) so no root is required
# for the files themselves, only for the dependency installation step.
#
# Usage:
#   bash install.sh [--no-service] [--prefix <dir>]
#
# Options:
#   --no-service    Skip systemd user service creation
#   --prefix <dir>  Override base install path (default: ~/.local)

set -euo pipefail


# ======================================
# ======================================
# ======= 1/ Configuration =======
# ======================================
# ======================================

PREFIX="${HOME}/.local"
INSTALL_SERVICE=true
# Skips every package-manager call. The path for a distribution this script has
# no arm for, and for anyone who prefers to install dependencies themselves —
# previously such a machine got a hard abort with the list of packages and no
# way to continue.
SKIP_DEPS=false
# Runs only the privileged part: the uinput udev rule, the two groups and the
# module load. Separated so a user can review exactly what needs root, and so it
# can be re-run after a kernel update without reinstalling the driver.
SETUP_PERMS_ONLY=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# This script runs from TWO layouts, and assuming one of them was a bug:
#
#   CHECKOUT  static/ergopti_plus/linux/install.sh — the script sits INSIDE the
#             driver, and _shared is its parent's child.
#   TARBALL   <unpacked>/install.sh — build-linux-driver.sh copies it to the
#             bundle ROOT, beside linux/ and _shared/.
#
# It only ever computed the checkout's shape, so on the release tarball — the
# download the notes send every distribution the .deb and .rpm do not cover —
# SRC_SHARED pointed one level above the unpack directory and the install died
# with "cp: cannot stat '.../_shared/.'". Probing is what tells them apart;
# counting levels cannot.
if [ -d "${SCRIPT_DIR}/linux" ] && [ -d "${SCRIPT_DIR}/_shared" ]; then
	SRC_DRIVER="${SCRIPT_DIR}/linux"
	DRIVERS_ROOT="${SCRIPT_DIR}"
else
	SRC_DRIVER="${SCRIPT_DIR}"
	DRIVERS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
fi

ERGOPTI_VERSION="$(
	node -p "require('$(cd "${SCRIPT_DIR}/../../.." && pwd -P)/package.json').version" 2>/dev/null \
	|| echo "dev"
)"


# ================================
# ================================
# ======= 2/ Argument Parse =======
# ================================
# ================================

while [[ $# -gt 0 ]]; do
	case "$1" in
		--no-service)
			INSTALL_SERVICE=false
			shift
			;;
		--no-deps)
			SKIP_DEPS=true
			shift
			;;
		--setup-perms)
			SETUP_PERMS_ONLY=true
			shift
			;;
		--prefix)
			PREFIX="$2"
			shift 2
			;;
		--help|-h)
			cat << 'HELP'
Utilisation : bash install.sh [OPTIONS]

Options :
  --no-service      Ne crée pas le service systemd utilisateur
  --no-deps         N'installe aucune dépendance (à votre charge)
  --setup-perms     Configure uniquement les permissions (udev, groupes, module)
  --prefix <dir>    Répertoire de base (défaut : ~/.local)
  --help            Affiche ce message d'aide
HELP
			exit 0
			;;
		*)
			echo "Option inconnue : $1" >&2
			exit 1
			;;
	esac
done

LIB_DIR="${PREFIX}/lib/ergopti"
BIN_DIR="${PREFIX}/bin"
CONFIG_DIR="${HOME}/.config/ergopti/hotstrings"
SYSTEMD_DIR="${HOME}/.config/systemd/user"

# Single source of truth for the shared-tree location, both the repo source and
# the install destination. A future rename of the _shared/ tree only needs editing these
# two lines (and they must stay in sync with the daemon's runtime resolution in
# ergopti_hotstrings.lua, which expects the installed dir to be a sibling).
SRC_SHARED="${DRIVERS_ROOT}/_shared"
DEST_SHARED="${LIB_DIR}/_shared"


# ====================================
# ====================================
# ======= 3/ Distro Detection =======
# ====================================
# ====================================

# Ordered from most to least specific. zypper before dnf because openSUSE ships
# both on some images, and xbps before apk for the same reason on Void.
_has_manager() {
	# /sbin and /usr/sbin too: Alpine keeps apk in /sbin, which an ordinary
	# user's PATH does not include there, so `command -v apk` alone answered
	# "unknown" and the installer refused every dependency on Alpine.
	command -v "$1" >/dev/null 2>&1 || [ -x "/sbin/$1" ] || [ -x "/usr/sbin/$1" ]
}

_detect_pkg_manager() {
	if _has_manager apt-get; then
		echo "apt"
	elif _has_manager zypper; then
		echo "zypper"
	elif _has_manager dnf; then
		echo "dnf"
	elif _has_manager pacman; then
		echo "pacman"
	elif _has_manager xbps-install; then
		echo "xbps"
	elif _has_manager apk; then
		echo "apk"
	else
		echo "unknown"
	fi
}

# ==========================================
# ==========================================
# ======= 4b/ Input permissions ============
# ==========================================
# ==========================================

# The daemon reads /dev/input/eventN and writes /dev/uinput. Neither is
# accessible to a normal user by default, and the failure is silent in the worst
# way: the daemon starts, logs one line, and never expands anything.
#
# TWO GROUPS, NOT uaccess. systemd's own udev guidance forbids tagging
# /dev/input with uaccess — "unprivileged raw keyboard access would make
# keylogging trivial" — and it is right: the seat ACL logind grants for cameras
# and GPUs is deliberately NOT granted for input. So membership is explicit and
# the user is told what it means.
#
# THE static_node OPTION IS NOT OPTIONAL. /dev/uinput does not exist until the
# module is loaded, so a rule without it applies to nothing on a fresh boot and
# the permissions appear not to have been set at all.

_setup_permissions() {
	echo ""
	echo "=== Permissions d'entrée (nécessite sudo) ==="
	echo ""
	echo "  ⚠  AVERTISSEMENT DE SÉCURITÉ"
	echo "     Appartenir au groupe « input » permet de lire TOUTES les frappes"
	echo "     clavier de la session, y compris les mots de passe saisis dans"
	echo "     n'importe quelle application. C'est ce qu'exige un moteur de"
	echo "     hotstrings, et c'est ce que font keyd et xremap."
	echo ""

	local target_uid
	target_uid="${SUDO_UID:-$(id -u)}"
	if [ "$(id -u)" = 0 ]; then
		bash "${SRC_DRIVER}/install/setup_permissions.sh" --user "$target_uid"
	elif command -v sudo >/dev/null 2>&1; then
		sudo bash "${SRC_DRIVER}/install/setup_permissions.sh" --user "$target_uid"
	else
		pkexec /bin/bash "${SRC_DRIVER}/install/setup_permissions.sh" --user "$target_uid"
	fi
	echo ""
	echo "  ⚠  Déconnectez-vous et reconnectez-vous pour que les groupes"
	echo "     prennent effet — l'appartenance à un groupe n'est lue qu'à"
	echo "     l'ouverture de session."
}

if $SETUP_PERMS_ONLY; then
	_setup_permissions
	exit 0
fi

# ===========================================
# ===========================================
# ======= 4/ Dependency Verification =======
# ===========================================
# ===========================================

# APT alternatives are selected from actual local metadata in declared order.
# A failed/malformed observation never grants repair or falls through to an
# arbitrary package. Installing a provider still requires the native re-probe.
_available_apt_runtime_package() {
	local package_name metadata label value rest candidate count
	for package_name in "$@"; do
		if ! metadata="$(LC_ALL=C apt-cache policy -- "$package_name")"; then return 1; fi
		candidate=""
		count=0
		while read -r label value rest; do
			if [ "$label" = "Candidate:" ]; then
				count=$((count + 1))
				[ -z "$rest" ] || return 1
				candidate="$value"
			fi
		done <<< "$metadata"
		if [ "$count" = 0 ] && [ -z "$metadata" ]; then continue; fi
		[ "$count" = 1 ] || return 1
		[ "$candidate" = "(none)" ] && continue
		[[ "$candidate" =~ ^[0-9][A-Za-z0-9.+:~_-]*$ ]] || return 1
		printf '%s\n' "$package_name"
		return 0
	done
	return 1
}

_archive_digest_runtime_available() {
	luajit "${SRC_DRIVER}/platform/network/digest_probe.lua" "$SRC_DRIVER" >/dev/null 2>&1
}

_ensure_archive_digest_runtime() {
	if _archive_digest_runtime_available; then return 0; fi
	[ -n "${ARCHIVE_DIGEST_SONAME:-}" ] || return 1
	local manager package_name
	manager="$(_detect_pkg_manager)"
	# The generated Lua projection supplies this SONAME to the native probe;
	# package selection remains in the generator's owned repair table.
	if ! package_name="$(_required_dependency_package "$manager" "$ARCHIVE_DIGEST_SONAME")"; then
		return 1
	fi
	if ! _install_required_package "$manager" "$package_name"; then return 1; fi
	_archive_digest_runtime_available
}

_required_dependency_package() {
	local pkg_mgr="$1"
	local capability="$2"
	case "${pkg_mgr}:${capability}" in
		# BEGIN GENERATED LINUX NATIVE PACKAGES
		apt:libxkbcommon.so.0) echo "libxkbcommon0" ;;
		apt:libxkbcommon-x11.so.0) echo "libxkbcommon-x11-0" ;;
		apt:libX11.so.6) echo "libx11-6" ;;
		apt:libX11-xcb.so.1) echo "libx11-xcb1" ;;
		dnf:libxkbcommon.so.0) echo "libxkbcommon" ;;
		dnf:libxkbcommon-x11.so.0) echo "libxkbcommon-x11" ;;
		dnf:libX11.so.6) echo "libX11" ;;
		dnf:libX11-xcb.so.1) echo "libX11-xcb" ;;
		zypper:libxkbcommon.so.0) echo "libxkbcommon0" ;;
		zypper:libxkbcommon-x11.so.0) echo "libxkbcommon-x11-0" ;;
		zypper:libX11.so.6) echo "libX11-6" ;;
		zypper:libX11-xcb.so.1) echo "libX11-xcb1" ;;
		pacman:libxkbcommon.so.0) echo "libxkbcommon" ;;
		pacman:libxkbcommon-x11.so.0) echo "libxkbcommon-x11" ;;
		pacman:libX11.so.6) echo "libx11" ;;
		pacman:libX11-xcb.so.1) echo "libx11" ;;
		xbps:libxkbcommon.so.0) echo "libxkbcommon" ;;
		xbps:libxkbcommon-x11.so.0) echo "libxkbcommon-x11" ;;
		xbps:libX11.so.6) echo "libX11" ;;
		xbps:libX11-xcb.so.1) echo "libX11" ;;
		apk:libxkbcommon.so.0) echo "libxkbcommon" ;;
		apk:libxkbcommon-x11.so.0) echo "libxkbcommon-x11" ;;
		apk:libX11.so.6) echo "libx11" ;;
		apk:libX11-xcb.so.1) echo "libx11" ;;
		apt:curl) echo "curl" ;;
		dnf:curl) echo "curl" ;;
		zypper:curl) echo "curl" ;;
		pacman:curl) echo "curl" ;;
		xbps:curl) echo "curl" ;;
		apk:curl) echo "curl" ;;
		apt:libcrypto.so.3) _available_apt_runtime_package libssl3t64 libssl3 ;;
		# END GENERATED LINUX NATIVE PACKAGES
		apt:luajit) echo "luajit" ;;
		dnf:luajit) echo "luajit" ;;
		zypper:luajit) echo "luajit" ;;
		pacman:luajit) echo "luajit" ;;
		xbps:luajit) echo "LuaJIT" ;;
		apk:luajit) echo "luajit" ;;
		apt:notify-send) echo "libnotify-bin" ;;
		dnf:notify-send) echo "libnotify" ;;
		zypper:notify-send) echo "libnotify-tools" ;;
		pacman:notify-send) echo "libnotify" ;;
		xbps:notify-send) echo "libnotify" ;;
		apk:notify-send) echo "libnotify" ;;
		apt:sha256sum) echo "coreutils" ;;
		dnf:sha256sum) echo "coreutils" ;;
		zypper:sha256sum) echo "coreutils" ;;
		pacman:sha256sum) echo "coreutils" ;;
		xbps:sha256sum) echo "coreutils" ;;
		apk:sha256sum) echo "coreutils" ;;
		apt:xkbcli) echo "libxkbcommon-tools" ;;
		dnf:xkbcli) echo "libxkbcommon-utils" ;;
		zypper:xkbcli) echo "libxkbcommon-tools" ;;
		pacman:xkbcli) echo "libxkbcommon" ;;
		xbps:xkbcli) echo "libxkbcommon-tools" ;;
		apk:xkbcli) echo "xkbcli" ;;
		apt:libatspi.so.0) echo "at-spi2-core" ;;
		dnf:libatspi.so.0) echo "at-spi2-core" ;;
		zypper:libatspi.so.0) echo "at-spi2-core" ;;
		pacman:libatspi.so.0) echo "at-spi2-core" ;;
		xbps:libatspi.so.0) echo "at-spi2-core" ;;
		apk:libatspi.so.0) echo "at-spi2-core" ;;
		# Typing metrics: the keylogger writes and the metrics windows read
		# through the sqlite3 CLI; without it both fall back to nothing useful.
		apt:sqlite3) echo "sqlite3" ;;
		dnf:sqlite3) echo "sqlite" ;;
		zypper:sqlite3) echo "sqlite3" ;;
		pacman:sqlite3) echo "sqlite" ;;
		xbps:sqlite3) echo "sqlite" ;;
		apk:sqlite3) echo "sqlite" ;;
		# The tray's dialogs: every prompt (a delay, a link, an API key) and
		# every confirmation is a zenity window. KDE and minimal images lack it.
		apt:zenity) echo "zenity" ;;
		dnf:zenity) echo "zenity" ;;
		zypper:zenity) echo "zenity" ;;
		pacman:zenity) echo "zenity" ;;
		xbps:zenity) echo "zenity" ;;
		apk:zenity) echo "zenity" ;;
		# The tray icon. platform/tray/appindicator.lua binds this library
		# through FFI; without it --tray has nothing to host the icon in.
		apt:tray) echo "libayatana-appindicator3-1" ;;
		dnf:tray) echo "libayatana-appindicator-gtk3" ;;
		zypper:tray) echo "libayatana-appindicator3-1" ;;
		pacman:tray) echo "libayatana-appindicator" ;;
		xbps:tray) echo "libayatana-appindicator" ;;
		apk:tray) echo "libayatana-appindicator" ;;
		# The WebKit2GTK typelib the tray's windows (settings, editor,
		# metrics, onboarding) are drawn with through lgi.
		apt:webkit) echo "gir1.2-webkit2-4.1" ;;
		dnf:webkit) echo "webkit2gtk4.1" ;;
		zypper:webkit) echo "typelib-1_0-WebKit2-4_1" ;;
		pacman:webkit) echo "webkit2gtk-4.1" ;;
		xbps:webkit) echo "libwebkit2gtk41" ;;
		apk:webkit) echo "webkit2gtk-4.1" ;;
		# GNOME Shell hosts no tray icon on its own: an SNI host extension must be
		# enabled. Ubuntu ships and enables its own; the others do not.
		apt:gnome-tray) echo "gnome-shell-extension-appindicator" ;;
		dnf:gnome-tray) echo "gnome-shell-extension-appindicator" ;;
		zypper:gnome-tray) echo "gnome-shell-extension-appindicator" ;;
		pacman:gnome-tray) echo "gnome-shell-extension-appindicator" ;;
		xbps:gnome-tray) echo "gnome-shell-extension-appindicator" ;;
		apk:gnome-tray) echo "gnome-shell-extension-appindicator" ;;
		*) return 1 ;;
	esac
}

_install_required_package() {
	local pkg_mgr="$1"
	local package_name="$2"
	case "${pkg_mgr}" in
		apt)     sudo apt-get install -y "${package_name}" ;;
		dnf)     sudo dnf install -y "${package_name}" ;;
		zypper)  sudo zypper --non-interactive install "${package_name}" ;;
		pacman)  sudo pacman -Sy --noconfirm "${package_name}" ;;
		xbps)    sudo xbps-install -Sy "${package_name}" ;;
		apk)     sudo apk add "${package_name}" ;;
		*) return 1 ;;
	esac
}

_check_or_install() {
	local cmd="$1"

	if command -v "$cmd" >/dev/null 2>&1; then
		echo "  ✔  ${cmd} — déjà installé"
		return 0
	fi

	local pkg_mgr
	local package_name
	pkg_mgr="$(_detect_pkg_manager)"
	if ! package_name="$(_required_dependency_package "${pkg_mgr}" "${cmd}")"; then
		echo "  ✗  Aucun paquet ${pkg_mgr} déclaré pour la dépendance '${cmd}'." >&2
		echo "     Installez-la manuellement, puis relancez avec --no-deps." >&2
		return 1
	fi

	echo "  →  ${cmd} manquant — installation de ${package_name}…"
	_install_required_package "${pkg_mgr}" "${package_name}"
	if ! command -v "$cmd" >/dev/null 2>&1; then
		echo "  ✗  ${package_name} a été installé, mais '${cmd}' reste introuvable." >&2
		return 1
	fi
	echo "  ✔  ${cmd} — capacité vérifiée"
}

_check_or_install_library() {
	local soname="$1"
	if luajit -e "local ffi=require('ffi'); ffi.load('${soname}')" >/dev/null 2>&1; then
		echo "  ✔  ${soname} — déjà installé"
		return 0
	fi
	local pkg_mgr
	local package_name
	pkg_mgr="$(_detect_pkg_manager)"
	if ! package_name="$(_required_dependency_package "${pkg_mgr}" "${soname}")"; then
		echo "  ✗  Aucun paquet ${pkg_mgr} déclaré pour la bibliothèque '${soname}'." >&2
		return 1
	fi
	echo "  →  ${soname} manquant — installation de ${package_name}…"
	_install_required_package "${pkg_mgr}" "${package_name}"
	if ! luajit -e "local ffi=require('ffi'); ffi.load('${soname}')" >/dev/null 2>&1; then
		echo "  ✗  ${package_name} a été installé, mais '${soname}' reste indisponible." >&2
		return 1
	fi
	echo "  ✔  ${soname} — capacité vérifiée"
}

_native_output_ordinary_directory() {
	local directory="$1"
	if [ -L "$directory" ] || { [ -e "$directory" ] && [ ! -d "$directory" ]; }; then
		echo "Native archive bin parent unavailable" >&2
		return 1
	fi
}

_native_output_bin_parents() {
	# This namespace belongs to installed source-build output, never an ad hoc
	# checkout artifact or an unreviewed release input.
	if [ -e "${SRC_DRIVER}/native_modules" ] || [ -L "${SRC_DRIVER}/native_modules" ]; then
		echo "Unreviewed source native module directory" >&2
		return 1
	fi
	_native_output_ordinary_directory "${SRC_DRIVER}/bin" \
		&& _native_output_ordinary_directory "${LIB_DIR}/linux" \
		&& _native_output_ordinary_directory "${LIB_DIR}/linux/bin" \
		&& _native_output_ordinary_directory "${SRC_DRIVER}/native_modules" \
		&& _native_output_ordinary_directory "${LIB_DIR}/linux/native_modules"
}

# BEGIN GENERATED LINUX ARCHIVE DIGEST
ARCHIVE_DIGEST_SONAME="libcrypto.so.3"
# END GENERATED LINUX ARCHIVE DIGEST

# BEGIN GENERATED LINUX NETWORK PROVIDERS
_network_runtime_packages() {
	case "$1" in
		apt) echo "glib-networking gsettings-desktop-schemas lua-luv" ;;
		dnf) return 1 ;;
		zypper) echo "glib-networking gsettings-desktop-schemas luajit-luv" ;;
		pacman) echo "glib-networking gsettings-desktop-schemas lua51-luv" ;;
		xbps) return 1 ;;
		apk) echo "glib-networking gsettings-desktop-schemas lua5.1-luv" ;;
		*) return 1 ;;
	esac
}
# END GENERATED LINUX NETWORK PROVIDERS

# BEGIN GENERATED LINUX SOURCE NETWORK BUILD
_network_source_build_packages() {
	case "$1" in
		apt) return 1 ;;
		dnf) echo "git gcc glibc-devel make cmake pkgconf-pkg-config luajit-devel glib-networking gsettings-desktop-schemas dconf" ;;
		zypper) return 1 ;;
		pacman) return 1 ;;
		xbps) return 1 ;;
		apk) return 1 ;;
		*) return 1 ;;
	esac
}
NATIVE_LUV_SOURCE_URL="https://github.com/luvit/luv.git"
NATIVE_LUV_SOURCE_REVISION="26e62e49b0230891ece45a78cc1f63c074e60020"
NATIVE_LUV_CMAKE_OPTIONS=("-DLUA_BUILD_TYPE=System" "-DWITH_LUA_ENGINE=LuaJIT" "-DBUILD_MODULE=ON" "-DBUILD_SHARED_LIBS=OFF" "-DBUILD_STATIC_LIBS=OFF" "-DWITH_SHARED_LIBUV=OFF")
# END GENERATED LINUX SOURCE NETWORK BUILD

NATIVE_LUV_STAGE=""
_prepare_source_network_runtime() {
	local repository manager packages package_name builder
	repository="$(cd "${SRC_DRIVER}/../../.." && pwd -P)"
	if [ "$SRC_DRIVER" != "${repository}/static/ergopti_plus/linux" ]; then return 0; fi
	if _network_runtime_available; then return 0; fi
	manager="$(_detect_pkg_manager)"
	# No bootstrap entry means normal package-based repair still owns admission.
	if ! packages="$(_network_source_build_packages "$manager")"; then return 0; fi
	_native_output_bin_parents || return 1
	builder="${SRC_DRIVER}/install/build_native_luv.sh"
	[ -f "$builder" ] && [ ! -L "$builder" ] || return 1
	for package_name in $packages; do
		_install_required_package "$manager" "$package_name" || return 1
	done
	NATIVE_LUV_STAGE="$(mktemp -d)"
	if ! bash "$builder" "$NATIVE_LUV_STAGE" "$NATIVE_LUV_SOURCE_URL" \
		"$NATIVE_LUV_SOURCE_REVISION" "${NATIVE_LUV_CMAKE_OPTIONS[@]}"; then
		echo "Source network build refused; stage retained: $NATIVE_LUV_STAGE" >&2
		return 1
	fi
	[ -f "$NATIVE_LUV_STAGE/luv.so" ] && [ ! -L "$NATIVE_LUV_STAGE/luv.so" ] || return 1
	export LUA_CPATH="$NATIVE_LUV_STAGE/?.so;${LUA_CPATH:-;;}"
	_network_runtime_available || return 1
}

# Read-only native admission shares the lookup child's ABI and resolver factory.
# A loadable GLib alone cannot replace an installed proxy module or LuaJIT luv.
_network_runtime_available() {
	luajit "${SRC_DRIVER}/platform/network/runtime_probe.lua" "${SRC_SHARED}" >/dev/null 2>&1
}

_ensure_network_runtime() {
	if _network_runtime_available; then return 0; fi
	local manager
	local packages
	manager="$(_detect_pkg_manager)"
	if ! packages="$(_network_runtime_packages "${manager}")"; then
		echo "proxy-backend-unavailable: no verified ${manager} runtime provider; install the documented prerequisites." >&2
		return 1
	fi
	local package_name
	for package_name in ${packages}; do
		if ! _install_required_package "${manager}" "${package_name}"; then return 1; fi
	done
	if ! _network_runtime_available; then
		echo "proxy-backend-unavailable: installed packages did not provide the required native runtime." >&2
		return 1
	fi
}

if $SKIP_DEPS; then
	echo ""
	echo "=== Dépendances ignorées (--no-deps) ==="
else
echo ""
echo "=== Ergopti ${ERGOPTI_VERSION} — vérification des dépendances ==="
# ydotool is deliberately absent from this list. The daemon writes to
# /dev/uinput itself; ydotool assumed a US layout, needed a root daemon, and
# forked once per event, which is what made the keyboard grab unaffordable.
_check_or_install luajit
_check_or_install notify-send
_check_or_install zenity
_check_or_install sqlite3
_check_or_install sha256sum
# The live keymap shared by capture and injection. The daemon now fails closed
# without libxkbcommon state, while the injector falls back to the clipboard if
# its inverse table cannot cover a character.
_check_or_install xkbcli
# Secure-field detection calls libatspi through LuaJIT FFI. Treating it as an
# optional desktop convenience makes the privacy filter fail closed forever.
_check_or_install_library libatspi.so.0
# BEGIN GENERATED LINUX NATIVE CAPABILITIES
_check_or_install_library libxkbcommon.so.0
_check_or_install_library libxkbcommon-x11.so.0
_check_or_install_library libX11.so.6
_check_or_install_library libX11-xcb.so.1
_check_or_install curl
# END GENERATED LINUX NATIVE CAPABILITIES

# The desktop half: the tray icon and the windows it opens. Best effort rather
# than fatal, because a headless machine or a server needs neither and must
# still get working hotstrings — but VERIFIED, and said out loud when it
# fails, because "the icon never appeared" is otherwise indistinguishable from
# a daemon that did not start. Neither was installed at all before: the README
# told users to find the tray package themselves, so the first run of a fresh
# install showed no icon on every distribution.
_ensure_desktop_backend() {
	local capability="$1"
	local label="$2"
	local probe="$3"
	if luajit -e "${probe}" >/dev/null 2>&1; then
		echo "  ✔  ${label} — déjà installé"
		return 0
	fi
	local pkg_mgr
	local package_name
	pkg_mgr="$(_detect_pkg_manager)"
	if ! package_name="$(_required_dependency_package "${pkg_mgr}" "${capability}")"; then
		echo "  ⚠  ${label} : aucun paquet ${pkg_mgr} connu — à installer manuellement." >&2
		return 0
	fi
	echo "  →  ${label} manquant — installation de ${package_name}…"
	_install_required_package "${pkg_mgr}" "${package_name}" || true
	if luajit -e "${probe}" >/dev/null 2>&1; then
		echo "  ✔  ${label} — capacité vérifiée"
	else
		echo "  ⚠  ${label} indisponible après installation de ${package_name}." >&2
	fi
}

# The icon exists once the library does; on GNOME it is only SHOWN when an
# extension hosts StatusNotifierItems. Without one the daemon registers its
# icon, the bus accepts it, and nothing appears — on Fedora and Debian GNOME,
# i.e. every GNOME that is not Ubuntu's. Enabling takes effect at the next
# login, which the input groups already require.
GNOME_TRAY_EXTENSION="appindicatorsupport@rgcjonas.gmail.com"
_ensure_gnome_tray_host() {
	case "${XDG_CURRENT_DESKTOP:-}" in
		*GNOME*|*gnome*) ;;
		*) return 0 ;;
	esac
	if ! command -v gnome-extensions >/dev/null 2>&1; then
		echo "  ⚠  GNOME sans gnome-extensions — activez une extension AppIndicator pour voir l'icône." >&2
		return 0
	fi
	if gnome-extensions list --enabled 2>/dev/null | grep -qi "appindicator"; then
		echo "  ✔  extension GNOME AppIndicator — déjà active"
		return 0
	fi
	local pkg_mgr
	local package_name
	pkg_mgr="$(_detect_pkg_manager)"
	if ! gnome-extensions list 2>/dev/null | grep -qx "${GNOME_TRAY_EXTENSION}" \
		&& package_name="$(_required_dependency_package "${pkg_mgr}" gnome-tray)"; then
		echo "  →  extension GNOME AppIndicator manquante — installation de ${package_name}…"
		_install_required_package "${pkg_mgr}" "${package_name}" || true
	fi
	if gnome-extensions enable "${GNOME_TRAY_EXTENSION}" 2>/dev/null; then
		echo "  ✔  extension GNOME AppIndicator activée"
		return 0
	fi
	# A package installed during this session is unknown to the running shell,
	# which then refuses to enable it. The setting it reads at the next login is
	# written instead, merged into the user's list rather than replacing it.
	local enabled
	enabled="$(gsettings get org.gnome.shell enabled-extensions 2>/dev/null || true)"
	case "${enabled}" in
		*"'${GNOME_TRAY_EXTENSION}'"*) ;;
		"@as []"|"[]"|"") enabled="['${GNOME_TRAY_EXTENSION}']" ;;
		*) enabled="${enabled%]}, '${GNOME_TRAY_EXTENSION}']" ;;
	esac
	if gsettings set org.gnome.shell enabled-extensions "${enabled}" 2>/dev/null; then
		echo "  ✔  extension GNOME AppIndicator activée (effective à la prochaine connexion)"
	else
		echo "  ⚠  Impossible d'activer l'extension AppIndicator — sans elle, GNOME n'affiche pas l'icône." >&2
	fi
}

echo ""
echo "=== Icône de la barre système et fenêtres ==="
_ensure_gnome_tray_host
_ensure_desktop_backend tray "icône de la barre système (libayatana-appindicator)" \
	"local ffi=require('ffi'); for _, n in ipairs({'libayatana-appindicator3.so.1','libappindicator3.so.1'}) do if pcall(ffi.load, n) then os.exit(0) end end; os.exit(1)"

# Networking requires LuaJIT luv and a supported GIO proxy resolver. The other
# Lua modules below remain optional for webviews, filesystem and signal features.
echo ""
echo "=== Dépendances Lua optionnelles (event loop, timers, webviews, signaux) ==="

# Each module must be loadable by LUAJIT, which speaks the Lua 5.1 ABI. The
# generic names this list used (lua-lgi, lua-posix…) are Lua 5.4 builds on
# Fedora, Arch, openSUSE and Alpine: installed successfully and invisible to
# luajit, so the windows never opened there. Worse, a name the archive does not
# carry (lua-http on Arch, lua-filesystem on openSUSE) failed under set -e and
# aborted the install before a single driver file was copied.
#
# So: a list of candidates per manager, the 5.1/LuaJIT build first; each one is
# tried until luajit can require the optional module; missing optional packages
# are not fatal. Networking uses the mandatory canonical provider path instead.
_lua_module_installed() {
	luajit -e "require('$1')" >/dev/null 2>&1
}

_lua_module_candidates() {
	case "$1:$2" in
		apt:luv)      echo "lua-luv" ;;
		apt:lfs)      echo "lua-filesystem" ;;
		apt:posix)    echo "lua-posix" ;;
		apt:lgi)      echo "lua-lgi" ;;
		dnf:luv)      echo "luajit2.1-luv lua5.1-luv compat-lua-luv" ;;
		dnf:lfs)      echo "lua5.1-filesystem compat-lua-filesystem luajit2.1-filesystem" ;;
		dnf:posix)    echo "lua5.1-posix compat-lua-posix luajit2.1-posix" ;;
		dnf:lgi)      echo "lua5.1-lgi compat-lua-lgi luajit2.1-lgi" ;;
		zypper:luv)   echo "luajit-luv lua51-luv" ;;
		zypper:lfs)   echo "luajit-luafilesystem lua51-luafilesystem" ;;
		zypper:posix) echo "luajit-luaposix lua51-luaposix" ;;
		zypper:lgi)   echo "luajit-lgi lua51-lgi" ;;
		pacman:luv)   echo "lua51-luv luajit-luv" ;;
		pacman:lfs)   echo "lua51-filesystem" ;;
		pacman:posix) echo "lua51-posix" ;;
		pacman:lgi)   echo "lua51-lgi" ;;
		xbps:luv)     echo "lua51-luv" ;;
		xbps:lfs)     echo "lua51-luafilesystem" ;;
		xbps:posix)   echo "lua51-luaposix" ;;
		xbps:lgi)     echo "lua51-lgi" ;;
		apk:luv)      echo "lua5.1-luv" ;;
		apk:lfs)      echo "lua5.1-filesystem" ;;
		apk:posix)    echo "lua5.1-posix" ;;
		apk:lgi)      echo "lua5.1-lgi" ;;
		*) return 1 ;;
	esac
}

_install_lua_module() {
	local mod="$1"
	local label="$2"
	if _lua_module_installed "${mod}"; then
		echo "  ✔  ${mod} (${label}) — déjà installé"
		return 0
	fi
	local pkg_mgr
	local candidates
	pkg_mgr="$(_detect_pkg_manager)"
	if ! candidates="$(_lua_module_candidates "${pkg_mgr}" "${mod}")"; then
		echo "  ⚠  ${mod} (${label}) : aucun paquet ${pkg_mgr} connu pour LuaJIT." >&2
		return 0
	fi
	local package_name
	for package_name in ${candidates}; do
		echo "  →  ${mod} manquant — essai du paquet ${package_name}…"
		_install_required_package "${pkg_mgr}" "${package_name}" >/dev/null 2>&1 || true
		if _lua_module_installed "${mod}"; then
			echo "  ✔  ${mod} (${label}) — capacité vérifiée"
			return 0
		fi
	done
	echo "  ⚠  ${mod} (${label}) indisponible pour LuaJIT — fonction dégradée." >&2
}

# Networking owns luv as a required native ABI, after any repair attempt.
_prepare_source_network_runtime
_ensure_network_runtime
if ! _ensure_archive_digest_runtime; then
	echo "archive-digest-unavailable: retained-FD updates require an actual OpenSSL3 runtime; capability remains unavailable." >&2
fi
_install_lua_module lfs   "système de fichiers"
_install_lua_module posix "signaux SIGTERM/SIGHUP"
_install_lua_module lgi   "fenêtres WebKit, compteur de vitesse"

echo "  → Les dépendances Lua optionnelles sont installées si disponibles."

# After lgi, which is how the windows reach WebKit: the typelib is useless to a
# luajit that cannot load lgi, and the probe needs both. lgi.core loads the
# typelib WITHOUT initialising GTK: `lgi.WebKit2` would call gtk_init, which
# fails with no display — i.e. during every install over SSH or from a TTY.
_ensure_desktop_backend webkit "fenêtres de configuration (WebKit2GTK)" \
	"local core=require('lgi.core'); os.exit(core.gi.require('WebKit2') and 0 or 1)"
fi


# =================================
# =================================
# ======= 5/ File Installation =======
# =================================
# =================================

echo ""
echo "=== Installation des fichiers ==="

# The layout registry travels below the installed driver. Resolved before the
# first copy: a source without it must stop here, not after replacing an
# installation whose Ergopti hotstrings it would then drop.
# shellcheck source=install/layout_registry.sh
source "${SRC_DRIVER}/install/layout_registry.sh"
SRC_REGISTRY="$(layout_registry_source "${SRC_DRIVER}" "${DRIVERS_ROOT}")"

# Source installations compile before replacing the current installation.
# Release bundles carry their target-built helper; absent binaries are refused,
# never rebuilt from an unrelated checkout or borrowed from a system location.
# Native helper admission never follows a foreign bin directory. The existing
# selected source/installation namespace remains the ownership premise; these
# checks do not claim hostile same-UID race isolation or atomic directory leases.
# Refuse before compiling, migrating configuration, copying files or replacing
# the existing generated-helper ownership manifest.
# BEGIN GENERATED LINUX ARCHIVE BUILD PACKAGES
_native_output_build_packages() {
	case "$1" in
		apt) echo "gcc libc6-dev" ;;
		dnf) echo "gcc glibc-devel" ;;
		zypper) echo "gcc glibc-devel" ;;
		pacman) echo "gcc glibc" ;;
		xbps) return 1 ;;
		apk) echo "gcc musl-dev linux-headers" ;;
		*) return 1 ;;
	esac
}
# END GENERATED LINUX ARCHIVE BUILD PACKAGES

# Only checkout installs compile this backend. Binary release recipients do
# not acquire a compiler, and --no-deps leaves the complete toolchain to its
# caller. The canonical builder still verifies compilation and publication.
_ensure_native_output_toolchain() {
	if $SKIP_DEPS; then return 0; fi
	local manager packages package_name
	manager="$(_detect_pkg_manager)"
	if ! packages="$(_native_output_build_packages "$manager")"; then
		echo "Native archive build prerequisites unavailable; install a C compiler and libc headers, then use --no-deps" >&2
		return 1
	fi
	for package_name in $packages; do
		_install_required_package "$manager" "$package_name" || return 1
	done
}

_native_output_bin_parents || exit 1
command -v tar >/dev/null || { echo "Native payload copy requires tar" >&2; exit 1; }
NATIVE_OUTPUT_STAGE=""
NATIVE_OUTPUT_SOURCE="${SRC_DRIVER}/bin/libergopti_archive_publication.so"
NATIVE_OUTPUT_REPO="$(cd "${SRC_DRIVER}/../../.." && pwd -P)"
if [ "$SRC_DRIVER" = "${NATIVE_OUTPUT_REPO}/static/ergopti_plus/linux" ]; then
	NATIVE_OUTPUT_BUILD="${NATIVE_OUTPUT_REPO}/tools/build/build-linux-native-output.sh"
	[ -f "$NATIVE_OUTPUT_BUILD" ] && [ ! -L "$NATIVE_OUTPUT_BUILD" ] || {
		echo "Canonical native archive build helper unavailable" >&2
		exit 1
	}
	_ensure_native_output_toolchain || exit 1
	NATIVE_OUTPUT_STAGE="$(mktemp -d)"
	# A failed/uncertain compiler leaves its private stage for explicit cleanup;
	# no recursive trap can erase an unobserved compiler descendant's resources.
	if ! bash "$NATIVE_OUTPUT_BUILD" --source-directory "${SRC_DRIVER}/native/archive_output" \
		--output-directory "$NATIVE_OUTPUT_STAGE"; then
		echo "Native archive build refused; stage retained: $NATIVE_OUTPUT_STAGE" >&2
		exit 1
	fi
	NATIVE_OUTPUT_SOURCE="${NATIVE_OUTPUT_STAGE}/libergopti_archive_publication.so"
fi
[ -f "$NATIVE_OUTPUT_SOURCE" ] && [ ! -L "$NATIVE_OUTPUT_SOURCE" ] || {
	echo "Target native archive backend unavailable" >&2
	exit 1
}

# Create destination directories.
install -d "${LIB_DIR}/linux"
install -d "${DEST_SHARED}"
install -d "${BIN_DIR}"
install -d "${CONFIG_DIR}"

# The pre-v2 standalone installer copied complete canonical packs into the user
# override directory. Classify those copies against the still-installed OLD
# bundle before replacing it: intact generated seeds leave the active namespace,
# while any byte the user changed makes the file an explicit retained override.
# shellcheck source=install/canonical_packs.sh
source "${SRC_DRIVER}/install/canonical_packs.sh"
migrate_canonical_packs \
	"${SRC_SHARED}/modules/hotstrings" \
	"${DEST_SHARED}/modules/hotstrings" \
	"${CONFIG_DIR}"

# Copy driver Lua sources. SRC_DRIVER, not SCRIPT_DIR: from the release tarball
# this script sits BESIDE the driver rather than inside it, so SCRIPT_DIR would
# nest linux/, _shared/ and bin/ inside LIB_DIR/linux/.
# Exclude the canonical generated backend from the source copy. Checkout-local
# fixture .so bytes can never be staged even briefly; only the freshly compiled
# output (or release-bundle artifact) below supplies this exact destination.
NATIVE_LUV_RETAINED_DIGEST=""
if [ -z "$NATIVE_LUV_STAGE" ] && [ -f "${LIB_DIR}/.ergopti-owned-files" ] \
	&& [ ! -L "${LIB_DIR}/.ergopti-owned-files" ] \
	&& [ -f "${LIB_DIR}/linux/native_modules/luv.so" ] \
	&& [ ! -L "${LIB_DIR}/linux/native_modules/luv.so" ]; then
	NATIVE_LUV_EXISTING_DIGEST="$(sha256sum -- "${LIB_DIR}/linux/native_modules/luv.so")"
	while IFS=$'\t' read -r prior_digest prior_relative; do
		if [ "$prior_relative" = "linux/native_modules/luv.so" ] \
			&& [ "$prior_digest" = "${NATIVE_LUV_EXISTING_DIGEST%% *}" ]; then
			NATIVE_LUV_RETAINED_DIGEST="$prior_digest"
		fi
	done < "${LIB_DIR}/.ergopti-owned-files"
fi
tar -C "$SRC_DRIVER" --exclude='./bin/libergopti_archive_publication.so' -cf - . \
	| tar -C "${LIB_DIR}/linux" -xf -
# Re-read after the payload/native directory operations; a payload bin alias
# must not become write authority for the target helper.
_native_output_bin_parents || exit 1
install -d "${LIB_DIR}/linux/bin"
_native_output_bin_parents || exit 1
[ -d "${LIB_DIR}/linux/bin" ] || exit 1
install -m 755 "$NATIVE_OUTPUT_SOURCE" "${LIB_DIR}/linux/bin/libergopti_archive_publication.so"
if [ -n "$NATIVE_LUV_STAGE" ]; then
	_native_output_bin_parents || exit 1
	install -d "${LIB_DIR}/linux/native_modules"
	_native_output_bin_parents || exit 1
	NATIVE_LUV_PUBLICATION="$(mktemp "${LIB_DIR}/linux/native_modules/.luv.XXXXXX")"
	install -m 755 "$NATIVE_LUV_STAGE/luv.so" "$NATIVE_LUV_PUBLICATION"
	mv -T -- "$NATIVE_LUV_PUBLICATION" "${LIB_DIR}/linux/native_modules/luv.so"
fi
cp -r "${SRC_SHARED}/." "${DEST_SHARED}/"
install_layout_registry "${SRC_REGISTRY}" "${LIB_DIR}/linux"
install -d "${LIB_DIR}/bin"
install -m 755 "${SRC_DRIVER}/install/standalone_launcher.sh" "${LIB_DIR}/bin/ergopti-hotstrings"
# A registry copied from the checkout is the installer's too, so uninstall.sh
# removes it with the driver.
if [ -n "${SRC_REGISTRY}" ]; then
	bash "${SRC_DRIVER}/install/ownership.sh" "${SRC_DRIVER}" "${SRC_SHARED}" "${LIB_DIR}" \
		"${SRC_REGISTRY}" "linux/${LAYOUT_REGISTRY_FOLDER}"
else
	bash "${SRC_DRIVER}/install/ownership.sh" "${SRC_DRIVER}" "${SRC_SHARED}" "${LIB_DIR}"
fi

if [ -n "$NATIVE_OUTPUT_STAGE" ] || [ -n "$NATIVE_LUV_RETAINED_DIGEST" ]; then
	# This generated checkout artifact is outside the input source tree, so its
	# actual installed bytes need their own canonical ownership entry.
	NATIVE_OUTPUT_DIGEST="$(sha256sum -- "${LIB_DIR}/linux/bin/libergopti_archive_publication.so")"
	NATIVE_OUTPUT_MANIFEST="$(mktemp "${LIB_DIR}/.ergopti-owned-native.XXXXXX")"
	while IFS=$'\t' read -r native_digest native_relative; do
		[ "$native_relative" = "linux/bin/libergopti_archive_publication.so" ] && continue
		[ "$native_relative" = "linux/native_modules/luv.so" ] && continue
		printf '%s\t%s\n' "$native_digest" "$native_relative" >> "$NATIVE_OUTPUT_MANIFEST"
	done < "${LIB_DIR}/.ergopti-owned-files"
	printf '%s\tlinux/bin/libergopti_archive_publication.so\n' "${NATIVE_OUTPUT_DIGEST%% *}" \
		>> "$NATIVE_OUTPUT_MANIFEST"
	if [ -n "$NATIVE_LUV_STAGE" ] || [ -n "$NATIVE_LUV_RETAINED_DIGEST" ]; then
		NATIVE_LUV_DIGEST="$(sha256sum -- "${LIB_DIR}/linux/native_modules/luv.so")"
		printf '%s\tlinux/native_modules/luv.so\n' "${NATIVE_LUV_DIGEST%% *}" >> "$NATIVE_OUTPUT_MANIFEST"
	fi
	mv -- "$NATIVE_OUTPUT_MANIFEST" "${LIB_DIR}/.ergopti-owned-files"
	if [ -n "$NATIVE_OUTPUT_STAGE" ]; then
		rm -f -- "${NATIVE_OUTPUT_STAGE}/libergopti_archive_publication.so"
		rmdir -- "$NATIVE_OUTPUT_STAGE"
	fi
fi

if [ -n "$NATIVE_LUV_STAGE" ]; then
	# Keep the authenticated source/build evidence; no recursive cleanup assumes
	# retirement of compiler descendants solely from the installer's own exit.
	echo "Source network build evidence retained: $NATIVE_LUV_STAGE"
fi

# Create the wrapper script in ~/.local/bin/ that points to the installed libs.
cat > "${BIN_DIR}/ergopti-hotstrings" << WRAPPER
#!/usr/bin/env bash
# Auto-généré par install.sh — ne pas éditer manuellement.
set -euo pipefail
INSTALL_ROOT=$(printf '%q' "${LIB_DIR}")
exec bash "\${INSTALL_ROOT}/bin/ergopti-hotstrings" "\$@"
WRAPPER
chmod +x "${BIN_DIR}/ergopti-hotstrings"
echo "  ✔  lanceur : ${BIN_DIR}/ergopti-hotstrings"


# The permissions the daemon cannot start without. Run as part of a normal
# install, not only behind --setup-perms: an installer that leaves the driver
# unable to read the keyboard has not installed anything, and the failure is
# silent — the daemon starts, logs one line, and expands nothing.
_setup_permissions

# ========================================
# ========================================
# ======= 6/ Systemd Service Setup =======
# ========================================
# ========================================

if $INSTALL_SERVICE; then
	echo ""
	echo "=== Création des services systemd utilisateur ==="
	AUTOSTART_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
	AUTOSTART_FILE="${AUTOSTART_DIR}/ergopti-hotstrings.desktop"
	STARTUP_OWNER="xdg"

	install -d "${SYSTEMD_DIR}"

	# THE unit, copied from the tree rather than re-declared here. This block used
	# to write its own copy — one of six across five files — and they disagreed on
	# the unit name, the ExecStart and the WantedBy, so a user who installed the
	# .deb and then ran this script ended up with two enabled daemons both
	# grabbing the keyboard.
	#
	# Only the ExecStart differs between install roots, so that one line is
	# rewritten and everything else is taken verbatim.
	source "${SRC_DRIVER}/install/desktop_entry.sh"
	SERVICE_EXEC="$(ergopti_systemd_exec "${BIN_DIR}/ergopti-hotstrings")"
	while IFS= read -r service_line || [ -n "$service_line" ]; do
		case "$service_line" in
			ExecStart=*) printf '%s\n' "$SERVICE_EXEC" ;;
			*) printf '%s\n' "$service_line" ;;
		esac
	done < "${SRC_DRIVER}/ergopti-hotstrings.service" > "${SYSTEMD_DIR}/ergopti-hotstrings.service"

	# Guarded, because systemd is not universal: Alpine runs OpenRC, Void runs
	# runit, and Gentoo may run either. Those systems get the XDG autostart entry
	# below instead, which every desktop environment honours regardless of init.
	# `command -v systemctl` is the wrong question, and an Arch container proved
	# it: the binary is there and the SESSION BUS is not, so every --user call
	# fails and the script aborted under `set -e` having already copied the files.
	# The same happens over SSH without a session, from a bare TTY, and inside any
	# container. What matters is whether a user bus can be reached, so ask that —
	# and treat "no" as "install the unit, enable it later", never as a failure:
	# the unit file is written above either way, and the XDG autostart entry below
	# starts the daemon on any desktop regardless of init.
	if [ -f "$AUTOSTART_FILE" ] && grep -Fxq 'X-Ergopti-Startup=true' "$AUTOSTART_FILE"; then
		# Updates preserve an explicit menu choice; installation is not consent
		# to re-enable a startup entry the user disabled.
		STARTUP_CHOICE="$(bash "$LIB_DIR/linux/install/start_at_login.sh" status)"
		case "$STARTUP_CHOICE" in
			enabled) bash "$LIB_DIR/linux/install/start_at_login.sh" enable ;;
			disabled) bash "$LIB_DIR/linux/install/start_at_login.sh" disable ;;
			*) echo 'The startup choice could not be read.' >&2; exit 1 ;;
		esac
		STARTUP_OWNER="user-choice"
	elif command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
		# Retire a previous non-systemd fallback before enabling the unit. Leaving
		# both files active starts two daemons at the next graphical login, and both
		# compete for the same evdev grab.
		rm -f -- "${AUTOSTART_FILE}"
		systemctl --user daemon-reload

		systemctl --user enable  ergopti-hotstrings.service
		systemctl --user restart ergopti-hotstrings.service
		STARTUP_OWNER="systemd"
		echo "  ✔  service ergopti-hotstrings activé et démarré"

	elif command -v systemctl >/dev/null 2>&1; then
		echo "  ⚠  systemd présent mais aucun bus utilisateur joignable (session absente)."
		if systemctl --user is-enabled ergopti-hotstrings.service >/dev/null 2>&1; then
			# Preserve an already-enabled owner and retire an older fallback.
			rm -f -- "${AUTOSTART_FILE}"
			STARTUP_OWNER="systemd"
			echo "     L'unité déjà activée reste l'unique propriétaire du démarrage."
		else
			echo "     L'unité est installée ; XDG assurera le démarrage à la prochaine session."
		fi
	else
		echo "  ⚠  systemd absent — utilisation du démarrage automatique XDG."
	fi

	# XDG is the sole owner only on hosts where systemd is absent.
	if [ "${STARTUP_OWNER}" = "xdg" ]; then
		install -d "${AUTOSTART_DIR}"
		cat > "${AUTOSTART_FILE}" << AUTOSTART
[Desktop Entry]
Type=Application
Name=Ergopti+
Comment=Expansion de texte et métriques clavier
$(ergopti_desktop_exec "${BIN_DIR}/ergopti-hotstrings")
Terminal=false
X-GNOME-Autostart-enabled=true
AUTOSTART
		echo "  ✔  démarrage automatique XDG : ${AUTOSTART_FILE}"
	fi
fi


# =======================================
# =======================================
# ======= 7/ Post-Install Summary =======
# =======================================
# =======================================

for kind in wrapper unit autostart; do
	case "$kind" in
		wrapper) owned="${BIN_DIR}/ergopti-hotstrings" ;;
		unit) owned="${SYSTEMD_DIR}/ergopti-hotstrings.service" ;;
		autostart) owned="${XDG_CONFIG_HOME:-$HOME/.config}/autostart/ergopti-hotstrings.desktop" ;;
	esac
	if [ "$kind" != wrapper ] && ! $INSTALL_SERVICE; then continue; fi
	if [ -f "$owned" ]; then
		# The startup-choice helper may already have recorded the new desktop.
		if grep -q $'\t@'"$kind"'$' "${LIB_DIR}/.ergopti-owned-files"; then continue; fi
		digest="$(sha256sum -- "$owned")"
		printf '%s\t@%s\n' "${digest%% *}" "$kind" >> "${LIB_DIR}/.ergopti-owned-files"
	fi
done

echo ""
echo "=== Installation terminée ==="
echo ""
echo "  Lanceur  : ${BIN_DIR}/ergopti-hotstrings"
echo "  Config   : ${CONFIG_DIR}/"
echo ""

# Warn if ~/.local/bin is not on PATH — a common pitfall on fresh systems.
if [[ ":${PATH}:" != *":${BIN_DIR}:"* ]]; then
	echo "Attention : ${BIN_DIR} n'est pas dans votre PATH."
	echo "  Ajoutez cette ligne à ~/.bashrc ou ~/.zshrc :"
	echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
	echo ""
fi

if $INSTALL_SERVICE; then
	echo "Le daemon tourne en arrière-plan. Pour vérifier son état :"
	echo "  systemctl --user status ergopti-hotstrings"
else
	echo "Pour démarrer le daemon manuellement :"
	echo "  ergopti-hotstrings"
fi
