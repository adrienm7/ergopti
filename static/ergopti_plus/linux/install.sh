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
_detect_pkg_manager() {
	if command -v apt-get >/dev/null 2>&1; then
		echo "apt"
	elif command -v zypper >/dev/null 2>&1; then
		echo "zypper"
	elif command -v dnf >/dev/null 2>&1; then
		echo "dnf"
	elif command -v pacman >/dev/null 2>&1; then
		echo "pacman"
	elif command -v xbps-install >/dev/null 2>&1; then
		echo "xbps"
	elif command -v apk >/dev/null 2>&1; then
		echo "apk"
	else
		echo "unknown"
	fi
}

_install_pkg() {
	local pkg_mgr
	pkg_mgr=$(_detect_pkg_manager)

	case "$pkg_mgr" in
		apt)
			sudo apt-get update -qq
			sudo apt-get install -y "$@"
			;;
		dnf)     sudo dnf install -y "$@" ;;
		zypper)  sudo zypper --non-interactive install "$@" ;;
		pacman)  sudo pacman -Sy --noconfirm "$@" ;;
		xbps)    sudo xbps-install -Sy "$@" ;;
		apk)     sudo apk add "$@" ;;
		*)
			# Not an abort. A distribution this script has no arm for still has a
			# working driver — it only lacks the convenience of installing the
			# dependencies for the user. Aborting here made every such machine
			# uninstallable for the sake of a package list it just printed.
			echo "  ⚠  Gestionnaire de paquets inconnu — installez manuellement : $*" >&2
			echo "     Puis relancez avec --no-deps." >&2
			return 0
			;;
	esac
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

UDEV_RULE_PATH="/etc/udev/rules.d/99-ergopti-uinput.rules"
MODULES_LOAD_PATH="/etc/modules-load.d/ergopti-uinput.conf"

_setup_permissions() {
	echo ""
	echo "=== Permissions d'entrée (nécessite sudo) ==="
	echo ""
	echo "  ⚠  AVERTISSEMENT DE SÉCURITÉ"
	echo "     Appartenir au groupe « input » permet de lire TOUTES les frappes"
	echo "     clavier de la session, y compris les mots de passe saisis dans"
	echo "     n'importe quelle application. C'est ce qu'exige un moteur de"
	echo "     hotstrings, et c'est ce que font kanata, keyd et xremap."
	echo ""

	if ! command -v sudo >/dev/null 2>&1; then
		echo "  ⚠  sudo introuvable — configurez les permissions manuellement :" >&2
		echo "     groupes 'input' et 'uinput', règle udev, chargement du module." >&2
		return 0
	fi

	# The uinput group is ours to create; input already exists on every distro
	# that ships udev, but creating it is harmless and covers the ones that do not.
	sudo groupadd -f uinput 2>/dev/null || true
	sudo groupadd -f input  2>/dev/null || true

	# `id -un` rather than $USER. This script runs under `set -u`, and $USER is set
	# by a login shell — not by a container, a systemd unit, a cron job or
	# `su -c`. Fedora and Arch containers proved it: the installer aborted here
	# with "USER: unbound variable" after having already copied every file, so the
	# user was left with a half-installed driver and a shell error. `id -un` asks
	# the kernel, which always answers.
	local target_user
	target_user="$(id -un)"
	sudo usermod -aG input  "${target_user}"
	sudo usermod -aG uinput "${target_user}"
	echo "  ✔  ${target_user} ajouté aux groupes input et uinput"

	# The directory is created first, and its absence is not fatal. A Fedora
	# container aborted here — no udev installed, so /etc/udev/rules.d does not
	# exist — after the files were already copied and the groups already changed.
	# A missing udev is a real configuration (minimal images, some immutable
	# systems): the rule simply has nothing to configure there, and saying so beats
	# stopping halfway.
	if ! sudo install -d "$(dirname "${UDEV_RULE_PATH}")" 2>/dev/null; then
		echo "  ⚠  $(dirname "${UDEV_RULE_PATH}") introuvable — pas d'udev sur ce système."
		echo "     /dev/uinput devra être rendu accessible autrement."
		return 0
	fi

	sudo tee "${UDEV_RULE_PATH}" >/dev/null << 'UDEV_EOF'
# Ergopti — write access to /dev/uinput for the uinput group.
#
# static_node is what makes this work on a fresh boot: /dev/uinput does not
# exist until the module is loaded, so a rule without it matches nothing and the
# permissions look as though they were never applied.
#
# uaccess is deliberately NOT used here or on /dev/input: systemd's udev
# guidance forbids it for input devices, because an unprivileged process able to
# read raw keyboard events can keylog every application on the seat.
KERNEL=="uinput", MODE="0660", GROUP="uinput", OPTIONS+="static_node=uinput"
UDEV_EOF
	echo "  ✔  règle udev : ${UDEV_RULE_PATH}"

	sudo install -d "$(dirname "${MODULES_LOAD_PATH}")" 2>/dev/null || true
	sudo tee "${MODULES_LOAD_PATH}" >/dev/null << 'MODULES_EOF'
# Ergopti — load the uinput module at boot so /dev/uinput exists before the
# user session (and therefore before the daemon) starts.
uinput
MODULES_EOF
	echo "  ✔  chargement du module : ${MODULES_LOAD_PATH}"

	# Now, so the current session does not have to reboot to test.
	sudo modprobe uinput 2>/dev/null || true
	sudo udevadm control --reload-rules 2>/dev/null || true
	sudo udevadm trigger 2>/dev/null || true

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

_check_or_install() {
	local cmd="$1"
	local pkg_apt="$2"
	local pkg_dnf="${3:-$2}"
	local pkg_pacman="${4:-$2}"

	if command -v "$cmd" >/dev/null 2>&1; then
		echo "  ✔  ${cmd} — déjà installé"
		return 0
	fi

	echo "  →  ${cmd} manquant — installation en cours…"
	local pkg_mgr
	pkg_mgr=$(_detect_pkg_manager)

	case "$pkg_mgr" in
		apt)     sudo apt-get install -y "$pkg_apt" ;;
		dnf)     sudo dnf install -y "$pkg_dnf" ;;
		zypper)  sudo zypper --non-interactive install "$pkg_dnf" ;;
		pacman)  sudo pacman -Sy --noconfirm "$pkg_pacman" ;;
		xbps)    sudo xbps-install -Sy "$pkg_pacman" ;;
		apk)     sudo apk add "$pkg_pacman" ;;
		*)
			echo "  ⚠  Installez manuellement '${cmd}'." >&2
			return 0
			;;
	esac
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
_check_or_install luajit    luajit          luajit          luajit
_check_or_install notify-send libnotify-bin libnotify       libnotify
# The live keymap shared by capture and injection. The daemon now fails closed
# without libxkbcommon state, while the injector falls back to the clipboard if
# its inverse table cannot cover a character.
_check_or_install xkbcli    libxkbcommon-tools libxkbcommon-utils libxkbcommon

# Optional Lua libraries — the daemon degrades gracefully without them,
# but the full feature set (async event loop, webview rendering, tray SNI,
# signal handlers) requires these packages.
echo ""
echo "=== Dépendances Lua optionnelles (event loop, timers, webviews, signaux) ==="

# Probe each Lua module individually via luajit -e 'require("<name>")'.
# _check_or_install with 'lua' would only check the interpreter, not the lib.
_lua_module_installed() {
	local mod="$1"
	luajit -e "require('${mod}')" >/dev/null 2>&1
}

_install_lua_pkgs() {
	local mod="$1"
	local pkg_apt="$2"
	local pkg_dnf="$3"
	local pkg_pacman="$4"

	if _lua_module_installed "$mod"; then
		echo "  ✔  ${mod} (Lua module) — déjà installé"
		return 0
	fi

	echo "  →  ${mod} manquant — installation du paquet (${pkg_apt}/${pkg_dnf})…"
	local pkg_mgr
	pkg_mgr=$(_detect_pkg_manager)

	case "$pkg_mgr" in
		apt)     sudo apt-get install -y "$pkg_apt" ;;
		dnf)     sudo dnf install -y "$pkg_dnf" ;;
		zypper)  sudo zypper --non-interactive install "$pkg_dnf" ;;
		pacman)  sudo pacman -Sy --noconfirm "$pkg_pacman" ;;
		xbps)    sudo xbps-install -Sy "$pkg_pacman" ;;
		apk)     sudo apk add "$pkg_pacman" ;;
		*)
			echo "  ⚠  Gestionnaire de paquets inconnu — installez '${mod}' manuellement." >&2
			return 0
			;;
	esac
}

_install_lua_pkgs luv    lua-luv        lua-luv        lua-luv
_install_lua_pkgs lfs    lua-filesystem lua-filesystem lua-filesystem
_install_lua_pkgs posix  lua-posix      lua-posix      lua-posix
_install_lua_pkgs lgi    lua-lgi        lua-lgi        lua-lgi

# lua-http uses the module name 'http' (not 'http' which collides). Store as lua-http.
# Most distros ship lua-http; the module is require("http") at runtime.
_install_lua_pkgs http   lua-http       lua-http       lua-http

echo "  → Les dépendances Lua optionnelles sont installées si disponibles."
fi


# =================================
# =================================
# ======= 5/ Kanata Install =======
# =================================
# =================================

# The upstream release asset is architecture-specific, and the URL below used to
# hardcode the x86_64 one. On an ARM laptop or an ARM server that produced a
# downloaded file that was not an executable for this machine, chmod +x
# succeeded, and the failure only appeared later as "kanata does not start" —
# with a binary sitting in ~/.local/bin looking perfectly installed.
_kanata_asset() {
	case "$(uname -m)" in
		x86_64|amd64)  echo "kanata" ;;
		aarch64|arm64) echo "kanata_macos_arm64" ;;
		*)             echo "" ;;
	esac
}

_install_kanata() {
	if command -v kanata >/dev/null 2>&1; then
		echo "  ✔  kanata — déjà installé"
		return 0
	fi

	local asset
	asset="$(_kanata_asset)"
	if [ -z "${asset}" ]; then
		# Not fatal: kanata is the remap daemon, and the hotstring engine works
		# without it. Saying which architecture had no asset is the useful part.
		echo "  ⚠  Aucun binaire kanata pour $(uname -m) — installez-le manuellement." >&2
		echo "     Le moteur de hotstrings fonctionne sans kanata." >&2
		return 0
	fi

	local url="https://github.com/jtroo/kanata/releases/latest/download/${asset}"
	echo "  →  kanata manquant — téléchargement ($(uname -m))…"
	local dest="${BIN_DIR}/kanata"
	install -d "${BIN_DIR}"
	if command -v curl >/dev/null 2>&1; then
		curl --silent --location --fail --output "${dest}" "${url}" || {
			echo "  ⚠  Téléchargement de kanata échoué — installez-le manuellement." >&2
			rm -f "${dest}"
			return 0
		}
	elif command -v wget >/dev/null 2>&1; then
		wget --quiet --output-document "${dest}" "${url}" || {
			echo "  ⚠  Téléchargement de kanata échoué — installez-le manuellement." >&2
			rm -f "${dest}"
			return 0
		}
	else
		echo "  ⚠  Ni curl ni wget — installez kanata manuellement." >&2
		return 0
	fi

	# A "latest" download cannot be checksum-pinned without pinning the version
	# too, so the check that IS possible is the one done: refuse a file that is
	# not an executable for this machine. An HTML error page saved as a binary
	# and marked executable is the failure mode this catches.
	if command -v file >/dev/null 2>&1 && ! file -b "${dest}" | grep -qi "executable"; then
		echo "  ⚠  Le fichier téléchargé n'est pas un exécutable — kanata ignoré." >&2
		rm -f "${dest}"
		return 0
	fi

	chmod +x "${dest}"
	echo "  ✔  kanata installé dans ${dest}"
}

echo ""
echo "=== Installation de kanata ==="
_install_kanata


# =================================
# =================================
# ======= 6/ File Installation =======
# =================================
# =================================

echo ""
echo "=== Installation des fichiers ==="

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
cp -r "${SRC_DRIVER}/." "${LIB_DIR}/linux/"
cp -r "${SRC_SHARED}/." "${DEST_SHARED}/"

# Create the wrapper script in ~/.local/bin/ that points to the installed libs.
cat > "${BIN_DIR}/ergopti-hotstrings" << WRAPPER
#!/usr/bin/env bash
# Auto-généré par install.sh — ne pas éditer manuellement.
set -euo pipefail
DRIVER_ROOT="${LIB_DIR}/linux"
SHARED_LUA="${DEST_SHARED}/lua"
export LUA_PATH="\${DRIVER_ROOT}/?.lua;\${DRIVER_ROOT}/?/init.lua;\${SHARED_LUA}/?.lua;\${SHARED_LUA}/?/init.lua;;"
exec luajit "\${DRIVER_ROOT}/ergopti_hotstrings.lua" "\$@"
WRAPPER
chmod +x "${BIN_DIR}/ergopti-hotstrings"
echo "  ✔  lanceur : ${BIN_DIR}/ergopti-hotstrings"


# The permissions the daemon cannot start without. Run as part of a normal
# install, not only behind --setup-perms: an installer that leaves the driver
# unable to read the keyboard has not installed anything, and the failure is
# silent — the daemon starts, logs one line, and expands nothing.
_setup_permissions

# =======================================
# =======================================
# ======= 7/ Kanata Configuration =======
# =======================================
# =======================================

KANATA_CONFIG_DIR="${HOME}/.config/kanata"
# The layout ships in two shapes: flattened beside install.sh in the built
# package, and inside the driver tree in a source checkout. Probe both rather
# than assume one — the previous single path was correct only in a checkout.
KANATA_SRC=""
for _kanata_candidate in \
	"${SCRIPT_DIR}/kanata.kbd" \
	"${SCRIPT_DIR}/platform/remap/data/kanata.kbd" \
	"${SCRIPT_DIR}/linux/platform/remap/data/kanata.kbd"
do
	if [ -f "${_kanata_candidate}" ]; then
		KANATA_SRC="${_kanata_candidate}"
		break
	fi
done

echo ""
echo "=== Configuration de kanata ==="

install -d "${KANATA_CONFIG_DIR}"

# A COPY, never a symlink. This used to link ~/.config/kanata/ergopti.kbd back at
# the tracked template, and the daemon's generator opens that same path for
# writing on every start — so the first restart followed the link and overwrote
# the source of truth in the install tree. The two writers then disagreed in the
# worst possible direction: the file the parity gate reads had been rewritten by
# the thing the gate exists to check.
#
# Copying also closes an ordering gap. The unit below is enabled and started
# before the daemon has ever run, so without a file already in place kanata would
# start pointing at nothing. The committed template is a complete, loadable
# config — its generated block is pinned byte for byte to what the generator
# emits — so the copy is correct on its own and the daemon merely refreshes it
# once the user has a tap-hold override worth applying.
if [ -f "${KANATA_SRC}" ]; then
	install -m 0644 "${KANATA_SRC}" "${KANATA_CONFIG_DIR}/ergopti.kbd"
	echo "  ✔  configuration kanata : ${KANATA_CONFIG_DIR}/ergopti.kbd"
else
	echo "  Avertissement : fichier kanata source introuvable — configuration ignorée." >&2
fi


# ========================================
# ========================================
# ======= 8/ Systemd Service Setup =======
# ========================================
# ========================================

if $INSTALL_SERVICE; then
	echo ""
	echo "=== Création des services systemd utilisateur ==="

	install -d "${SYSTEMD_DIR}"

	# THE unit, copied from the tree rather than re-declared here. This block used
	# to write its own copy — one of six across five files — and they disagreed on
	# the unit name, the ExecStart and the WantedBy, so a user who installed the
	# .deb and then ran this script ended up with two enabled daemons both
	# grabbing the keyboard.
	#
	# Only the ExecStart differs between install roots, so that one line is
	# rewritten and everything else is taken verbatim.
	sed "s|^ExecStart=.*|ExecStart=${BIN_DIR}/ergopti-hotstrings --tray|" \
		"${SRC_DRIVER}/ergopti-hotstrings.service" \
		> "${SYSTEMD_DIR}/ergopti-hotstrings.service"

	# kanata key-remapping daemon (tap-hold + layer switching)
	# Runs alongside ergopti-hotstrings; reads the generated .kbd from
	# ~/.config/kanata/ergopti.kbd (written by the kanata manager module).
	cat > "${SYSTEMD_DIR}/kanata.service" << KANATA_SERVICE
[Unit]
Description=Kanata key remapping daemon (Ergopti)
# Same session lifetime as the daemon that reads its output: a remap daemon
# still running after logout re-maps the login screen.
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=simple
ExecStart=${BIN_DIR}/kanata --quiet --cfg ${KANATA_CONFIG_DIR}/ergopti.kbd
Restart=on-failure
RestartSec=3s
Nice=-10

[Install]
WantedBy=graphical-session.target
KANATA_SERVICE

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
	if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
		systemctl --user daemon-reload

		systemctl --user enable  ergopti-hotstrings.service
		systemctl --user restart ergopti-hotstrings.service
		echo "  ✔  service ergopti-hotstrings activé et démarré"

		# Enable kanata if the binary was installed.
		if [ -x "${BIN_DIR}/kanata" ]; then
			systemctl --user enable  kanata.service
			systemctl --user restart kanata.service
			echo "  ✔  service kanata activé et démarré"
		else
			echo "  ⚠  kanata binaire absent — service créé mais non activé"
		fi
	elif command -v systemctl >/dev/null 2>&1; then
		echo "  ⚠  systemd présent mais aucun bus utilisateur joignable (session absente)."
		echo "     L'unité est installée. Dans une vraie session graphique, activez-la avec :"
		echo "       systemctl --user enable --now ergopti-hotstrings"
	else
		echo "  ⚠  systemd absent — utilisation du démarrage automatique XDG."
	fi

	# Written unconditionally. It is init-agnostic and every desktop environment
	# reads it, so it is the one autostart mechanism that works on all of them —
	# and on a systemd machine the unit takes precedence anyway because the
	# desktop starts the session before processing autostart entries.
	AUTOSTART_DIR="${HOME}/.config/autostart"
	install -d "${AUTOSTART_DIR}"
	cat > "${AUTOSTART_DIR}/ergopti-hotstrings.desktop" << AUTOSTART
[Desktop Entry]
Type=Application
Name=Ergopti+
Comment=Expansion de texte et métriques clavier
Exec=${BIN_DIR}/ergopti-hotstrings --tray
Terminal=false
X-GNOME-Autostart-enabled=true
AUTOSTART
	echo "  ✔  démarrage automatique XDG : ${AUTOSTART_DIR}/ergopti-hotstrings.desktop"
fi


# =========================================
# =========================================
# ======= 10/ Post-Install Summary =======
# =========================================
# =========================================

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
