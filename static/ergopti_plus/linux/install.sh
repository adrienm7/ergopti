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

# Script's own directory — the linux driver root.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# The drivers root is one level above the linux driver.
DRIVERS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"

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
		--prefix)
			PREFIX="$2"
			shift 2
			;;
		--help|-h)
			cat << 'HELP'
Utilisation : bash install.sh [OPTIONS]

Options :
  --no-service      Ne crée pas le service systemd utilisateur
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
# the install destination. A shared/ -> _shared/ rename only needs editing these
# two lines (and they must stay in sync with the daemon's runtime resolution in
# ergopti_hotstrings.lua, which expects the installed dir to be a sibling).
SRC_SHARED="${DRIVERS_ROOT}/shared"
DEST_SHARED="${LIB_DIR}/shared"


# ====================================
# ====================================
# ======= 3/ Distro Detection =======
# ====================================
# ====================================

_detect_pkg_manager() {
	if command -v apt-get >/dev/null 2>&1; then
		echo "apt"
	elif command -v dnf >/dev/null 2>&1; then
		echo "dnf"
	elif command -v pacman >/dev/null 2>&1; then
		echo "pacman"
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
		dnf)
			sudo dnf install -y "$@"
			;;
		pacman)
			sudo pacman -Sy --noconfirm "$@"
			;;
		*)
			echo "Erreur : impossible de détecter le gestionnaire de paquets." >&2
			echo "  Installez manuellement : $*" >&2
			return 1
			;;
	esac
}


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
		pacman)  sudo pacman -Sy --noconfirm "$pkg_pacman" ;;
		*)
			echo "Erreur : installez manuellement '${cmd}'." >&2
			return 1
			;;
	esac
}

echo ""
echo "=== Ergopti ${ERGOPTI_VERSION} — vérification des dépendances ==="
_check_or_install luajit    luajit          luajit          luajit
_check_or_install ydotool   ydotool         ydotool         ydotool
_check_or_install notify-send libnotify-bin libnotify       libnotify


# =================================
# =================================
# ======= 5/ Kanata Install =======
# =================================
# =================================

# Kanata releases page — fetch the latest amd64 binary if kanata is absent
KANATA_RELEASE_URL="https://github.com/jtroo/kanata/releases/latest/download/kanata"

_install_kanata() {
	if command -v kanata >/dev/null 2>&1; then
		echo "  ✔  kanata — déjà installé"
		return 0
	fi
	echo "  →  kanata manquant — téléchargement du binaire…"
	local dest="${BIN_DIR}/kanata"
	install -d "${BIN_DIR}"
	if command -v curl >/dev/null 2>&1; then
		curl --silent --location --output "${dest}" "${KANATA_RELEASE_URL}"
	elif command -v wget >/dev/null 2>&1; then
		wget --quiet --output-document "${dest}" "${KANATA_RELEASE_URL}"
	else
		echo "Erreur : ni curl ni wget disponible — installez kanata manuellement." >&2
		return 1
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

# Copy driver Lua sources.
cp -r "${SCRIPT_DIR}/." "${LIB_DIR}/linux/"
cp -r "${SRC_SHARED}/." "${DEST_SHARED}/"

# Copy default hotstring TOMLs so the user has something to start with.
# We do NOT overwrite existing user config to preserve customisations.
for toml in "${SRC_SHARED}/hotstrings/"*.toml; do
	[[ "$(basename "${toml}")" == _* ]] && continue
	category="$(basename "${toml}" .toml)"
	dest="${CONFIG_DIR}/${category}.toml"
	if [ ! -f "${dest}" ]; then
		install -m 0644 "${toml}" "${dest}"
		echo "  →  config par défaut : ${dest}"
	else
		echo "  ✔  config existante conservée : ${dest}"
	fi
done

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


# ============================================================
# ============================================================
# ======= 7/ Kanata Config Symlink & Systemd Service =======
# ============================================================
# ============================================================

KANATA_CONFIG_DIR="${HOME}/.config/kanata"
# Kanata layout lives in the shared kanata/ folder one level above this driver.
KANATA_SRC="${SCRIPT_DIR}/../kanata/kanata.kbd"

echo ""
echo "=== Configuration de kanata ==="

install -d "${KANATA_CONFIG_DIR}"

if [ -f "${KANATA_SRC}" ]; then
	ln -sf "$(realpath "${KANATA_SRC}")" "${KANATA_CONFIG_DIR}/ergopti.kbd"
	echo "  ✔  lien symbolique kanata : ${KANATA_CONFIG_DIR}/ergopti.kbd"
else
	echo "  Avertissement : fichier kanata source introuvable — lien ignoré." >&2
fi


# ========================================
# ========================================
# ======= 9/ Systemd Service Setup =======
# ========================================
# ========================================

if $INSTALL_SERVICE; then
	echo ""
	echo "=== Création des services systemd utilisateur ==="

	install -d "${SYSTEMD_DIR}"

	# ergopti-hotstrings daemon (ydotool/Lua path)
	cat > "${SYSTEMD_DIR}/ergopti-hotstrings.service" << SERVICE
[Unit]
Description=Ergopti hotstring expansion daemon
After=graphical-session.target

[Service]
Type=simple
ExecStart=${BIN_DIR}/ergopti-hotstrings
Restart=on-failure
RestartSec=3s
Environment=DISPLAY=:0

[Install]
WantedBy=graphical-session.target
SERVICE

	systemctl --user daemon-reload

	systemctl --user enable  ergopti-hotstrings.service
	systemctl --user restart ergopti-hotstrings.service

	echo "  ✔  service ergopti-hotstrings activé et démarré"
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
