#!/bin/bash

# ==============================================================================
# Ergopti XKB layout installation script.
#
# Single-file installer: downloads the selected layout version from this
# repository, offers an interactive selection (version, variant) through fzf,
# then runs the appropriate Python installer (clean or legacy).
#
# Simplifications compared to the historical script:
#   - two variants only: Ergopti and Ergopti+ (the "Ergopti++" files stay in
#     the repository but are no longer installable: they saturate XCompose);
#   - the custom types file is always installed: without it the Shift layer
#     and the AltGr layers cannot work (issue #84);
#   - `--uninstall` removes a previously installed layout;
#   - every activation step reports success or failure instead of hiding it,
#     and a layout that does not verify stops the script with a non-zero code;
#   - privileged file writes go through sudo (or doas, or run directly as
#     root) while desktop activation always runs as the invoking user;
#   - `--diagnose` prints a report of the host, the session, the XKB tooling
#     and the installed layouts, without privileges, for bug reports;
#   - the whole run is copied to a log file whose path is printed first.
#
# Usage:
#   bash install.sh [--installation-method clean|legacy] [--version vX_Y_Z]
#                   [--variant ergopti|ergopti_plus] [--ansi] [--yes]
#                   [--uninstall] [--diagnose] [--help]
#   PYTHON=python3.11 bash install.sh    # another interpreter (>= 3.8)
# ==============================================================================

set -euo pipefail

REPO_URL="https://github.com/adrienm7/ergopti.git"
TARGET_DIR="static/ergopti/linux"
INSTALLER_REL_PATH="xkb_installation"
SCRIPT_NAME_LEGACY="xkb_files_installer_legacy.py"
SCRIPT_NAME_CLEAN="xkb_files_installer_clean.py"
SCRIPT_NAME_DIAGNOSE="xkb_diagnose.py"

# Oldest interpreter the Python installers support (dataclasses, f-strings,
# Path.unlink(missing_ok)). RHEL 8 and openSUSE Leap 15 default to 3.6.
MIN_PYTHON_MAJOR=3
MIN_PYTHON_MINOR=8
PYTHON_BIN="${PYTHON:-python3}"

DEFAULT_BRANCH="main"
SELECTED_BRANCH="${BRANCH:-$DEFAULT_BRANCH}"
FORCE_INSTALLATION_METHOD=""
WANT_UNINSTALL=false
WANT_DIAGNOSE=false
WANT_ANSI=false
WANT_YES=false
SELECTED_VERSION_ARG=""
SELECTED_VARIANT_ARG=""
UNINSTALL_METHOD_REQUIRED_MESSAGE="--uninstall requiert --installation-method clean|legacy"

# Every line printed by this script and its children is also appended here,
# so a bug report can carry the complete run instead of a paraphrase.
LOG_FILE="${ERGOPTI_INSTALL_LOG:-${TMPDIR:-/tmp}/ergopti-install.log}"
LOG_TEE_PID=""
# Overridable so the test-suite can simulate another distribution.
OS_RELEASE_FILE="${ERGOPTI_OS_RELEASE_FILE:-/etc/os-release}"

RED=$(printf '\033[31m')
GREEN=$(printf '\033[32m')
YELLOW=$(printf '\033[33m')
BLUE=$(printf '\033[34m')
BOLD=$(printf '\033[1m')
NO_COLOR=$(printf '\033[0m')

LOG_INDENT=""

unset FZF_DEFAULT_OPTS || true

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

usage() {
    cat <<USAGE
Usage : bash install.sh [options]

  --installation-method clean|legacy   force la méthode (sinon détection)
  --version vX_Y_Z                     version de la disposition (ex. v2_2_1)
  --variant ergopti|ergopti_plus       variante
  --ansi                               clavier physique ANSI
  --yes                                aucune question (requiert --version et --variant)
  --uninstall                          retire une installation existante
  --diagnose                           rapport de diagnostic (sans droits root)
  --help                               cette aide

Variables : BRANCH=dev (branche du dépôt), PYTHON=python3.11 (interpréteur >= ${MIN_PYTHON_MAJOR}.${MIN_PYTHON_MINOR}),
            ERGOPTI_INSTALL_LOG=/chemin/journal.log
USAGE
}

usage_error() {
    printf "${RED}❌ %s${NO_COLOR}\n" "$1" >&2
    usage >&2
    exit 1
}

# fail <message> [hint] [exit code]
fail() {
    printf "${RED}❌ %s${NO_COLOR}\n" "$1" >&2
    if [ -n "${2:-}" ]; then
        printf "   %s\n" "$2" >&2
    fi
    if [ -n "$LOG_FILE" ]; then
        printf "   Journal complet : %s\n" "$LOG_FILE" >&2
    fi
    exit "${3:-1}"
}

warn() {
    printf "${LOG_INDENT}${YELLOW}⚠️  %s${NO_COLOR}\n" "$1"
}

info() {
    printf "${LOG_INDENT}ℹ️  %s\n" "$1"
}

log_section() {
    LOG_INDENT=""
    printf "\n${BOLD}${BLUE}%s...${NO_COLOR}\n" "$1"
    LOG_INDENT="   "
}

run_step() {
    local action_desc="$1"
    local success_msg="$2"
    shift 2
    printf "${LOG_INDENT}%s...\n" "$action_desc"
    local output
    if output=$("$@" 2>&1); then
        printf "${LOG_INDENT}   ${GREEN}✅ %s${NO_COLOR}\n" "$success_msg"
    else
        printf "${LOG_INDENT}   ${RED}❌ Échec de l'opération${NO_COLOR}\n" >&2
        printf "${LOG_INDENT}   ${RED}Détails de l'erreur :${NO_COLOR}\n" >&2
        echo "$output" | sed "s/^/${LOG_INDENT}      /" >&2
        if [ -n "$LOG_FILE" ]; then
            printf "${LOG_INDENT}   Journal complet : %s\n" "$LOG_FILE" >&2
        fi
        exit 1
    fi
}

run_with_retry() {
    local max_attempts=$1 timeout_sec=$2
    shift 2
    local count=1
    while [ "$count" -le "$max_attempts" ]; do
        if timeout "$timeout_sec" "$@"; then return 0; fi
        if [ "$count" -lt "$max_attempts" ]; then
            printf "${LOG_INDENT}      ${YELLOW}⚠️  Trop long ou échec (essai $count/$max_attempts). Nouvelle tentative...${NO_COLOR}\n" >&2
            sleep 2
            count=$((count + 1))
        else
            return 1
        fi
    done
}

run_fzf() {
    fzf --height=12 --layout=reverse --border --inline-info "$@"
}

# confirm <question>: yes in --yes mode, otherwise asks on the terminal.
# stdin may be the script itself (curl | bash), so the answer is read from
# /dev/tty; without a terminal the answer is no.
confirm() {
    if [ "$WANT_YES" = true ]; then
        return 0
    fi
    local answer=""
    if [ -r /dev/tty ] && [ -w /dev/tty ]; then
        printf "%s [O/n] " "$1" > /dev/tty
        read -r answer < /dev/tty || answer="n"
    else
        return 1
    fi
    case "${answer,,}" in
        "" | o | oui | y | yes) return 0 ;;
        *) return 1 ;;
    esac
}

# An unexpected failure under `set -e` used to end the script without a word.
on_unexpected_error() {
    local code=$1 line=$2 command=$3
    printf "\n${RED}❌ L'installeur s'est arrêté (code %s) à la ligne %s : %s${NO_COLOR}\n" \
        "$code" "$line" "$command" >&2
    if [ -n "$LOG_FILE" ]; then
        printf "   Journal complet : %s\n" "$LOG_FILE" >&2
    fi
    printf "   Diagnostic : relancez ce script avec --diagnose et joignez sa sortie au rapport de bug.\n" >&2
}
set -E
trap 'on_unexpected_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

# ---------------------------------------------------------------------------
# Privileges and packages
# ---------------------------------------------------------------------------

# Privileged file writes only. Desktop activation must never go through
# here: dconf and D-Bus belong to the user's session (issue #84).
as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    elif command -v doas >/dev/null 2>&1; then
        doas "$@"
    else
        fail "Ni sudo ni doas n'est disponible : relancez ce script en root."
    fi
}

os_field() {
    (
        # shellcheck disable=SC1090
        [ -r "$OS_RELEASE_FILE" ] && . "$OS_RELEASE_FILE" 2>/dev/null
        eval "printf '%s' \"\${$1:-}\""
    )
}

pkg_family() {
    local token
    for token in $(os_field ID) $(os_field ID_LIKE); do
        case "$token" in
            debian | ubuntu) echo apt; return ;;
            fedora | rhel | centos) echo dnf; return ;;
            arch) echo pacman; return ;;
            suse | opensuse*) echo zypper; return ;;
            alpine) echo apk; return ;;
            void) echo xbps; return ;;
        esac
    done
    echo unknown
}

pkg_install() {
    case "$(pkg_family)" in
        apt) as_root apt-get install -y "$@" || { as_root apt-get update && as_root apt-get install -y "$@"; } ;;
        dnf) as_root dnf install -y "$@" ;;
        pacman) as_root pacman -S --noconfirm --needed "$@" ;;
        zypper) as_root zypper --non-interactive install "$@" ;;
        apk) as_root apk add "$@" ;;
        xbps) as_root xbps-install -y "$@" ;;
        *) return 1 ;;
    esac
}

xkbcli_package() {
    case "$(pkg_family)" in
        apt | zypper | apk) echo libxkbcommon-tools ;;
        dnf) echo libxkbcommon-utils ;;
        pacman | xbps) echo libxkbcommon ;;
        *) echo "" ;;
    esac
}

xkbcomp_package() {
    case "$(pkg_family)" in
        apt) echo x11-xkb-utils ;;
        dnf) echo xorg-x11-xkb-utils ;;
        pacman) echo xorg-xkbcomp ;;
        zypper | apk | xbps) echo xkbcomp ;;
        *) echo "" ;;
    esac
}

# ---------------------------------------------------------------------------
# Host checks
# ---------------------------------------------------------------------------

check_host() {
    case "$(os_field ID)" in
        nixos)
            fail "NixOS détecté : /usr/share n'y est pas modifiable, cet installeur ne s'applique pas." \
                "Déclarez la disposition dans votre configuration NixOS (services.xserver.xkb.extraLayouts) à partir des fichiers .xkb et xkb_types.txt du dépôt."
            ;;
        guix)
            fail "Guix System détecté : /usr/share n'y est pas modifiable, cet installeur ne s'applique pas." \
                "Déclarez la disposition dans votre configuration Guix à partir des fichiers .xkb et xkb_types.txt du dépôt."
            ;;
    esac
    if [ -r /proc/mounts ] \
            && awk '$2 == "/usr" || $2 == "/" { print $4 }' /proc/mounts | grep -Eq '(^|,)ro(,|$)'; then
        warn "/usr semble monté en lecture seule (distribution immuable ?) : l'installation échouera probablement."
    fi
}

check_python() {
    if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
        fail "Interpréteur Python introuvable : $PYTHON_BIN" \
            "Installez python3 (apt/dnf/pacman/zypper/apk), ou indiquez-en un : PYTHON=python3.11 bash install.sh"
    fi
    local version
    version=$("$PYTHON_BIN" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null || true)
    if [ -z "$version" ]; then
        fail "Impossible d'interroger $PYTHON_BIN ($(command -v "$PYTHON_BIN"))."
    fi
    if ! "$PYTHON_BIN" -c "import sys; sys.exit(0 if sys.version_info >= ($MIN_PYTHON_MAJOR, $MIN_PYTHON_MINOR) else 1)"; then
        fail "Python $version trouvé ($(command -v "$PYTHON_BIN")) : l'installeur requiert Python >= $MIN_PYTHON_MAJOR.$MIN_PYTHON_MINOR." \
            "Installez une version plus récente (paquet python3.11 ou python311 selon la distribution) puis relancez avec PYTHON=python3.11."
    fi
    printf "${LOG_INDENT}${GREEN}✅ Python %s (%s)${NO_COLOR}\n" "$version" "$(command -v "$PYTHON_BIN")"
}

# Without a compiler the installer cannot prove the layout works, which is how
# issue #84 shipped. Offer the distribution's package when one is known.
ensure_xkb_compiler() {
    local method="$1" wanted=""
    if command -v xkbcli >/dev/null 2>&1; then
        printf "${LOG_INDENT}${GREEN}✅ xkbcli disponible : la disposition sera vérifiée par libxkbcommon${NO_COLOR}\n"
        return 0
    fi
    if [ "$method" = legacy ] && command -v xkbcomp >/dev/null 2>&1; then
        printf "${LOG_INDENT}${GREEN}✅ xkbcomp disponible : la disposition sera vérifiée par le compilateur de Xorg${NO_COLOR}\n"
        return 0
    fi
    wanted=$(xkbcli_package)
    if [ "$method" = legacy ] && [ -z "$wanted" ]; then
        wanted=$(xkbcomp_package)
    fi
    warn "Aucun compilateur XKB (xkbcli) n'est installé : sans lui, l'installeur ne peut pas prouver que la disposition fonctionne."
    if [ -z "$wanted" ]; then
        info "Gestionnaire de paquets inconnu : la disposition sera installée sans vérification."
        return 0
    fi
    if confirm "${LOG_INDENT}Installer le paquet $wanted maintenant ?"; then
        if pkg_install "$wanted"; then
            printf "${LOG_INDENT}${GREEN}✅ %s installé${NO_COLOR}\n" "$wanted"
        else
            warn "Installation de $wanted échouée : la disposition sera installée sans vérification."
        fi
    else
        info "Sans vérification ; installez $wanted pour l'obtenir."
    fi
}

# ---------------------------------------------------------------------------
# Detection of an existing installation (uninstall)
# ---------------------------------------------------------------------------

has_numbered_backup() {
    local target backup suffix
    for target in "$@"; do
        for backup in "$target".*; do
            [ -e "$backup" ] || continue
            suffix="${backup#"$target".}"
            if [[ "$suffix" =~ ^[0-9]+$ ]]; then
                return 0
            fi
        done
    done
    return 1
}

LEGACY_EVIDENCE=""
CLEAN_EVIDENCE=""

has_legacy_installation() {
    local system_root="$1"
    local target found=1
    for target in \
            "$system_root/symbols/fr" \
            "$system_root/types/extra" \
            "$system_root/rules/evdev.lst" \
            "$system_root/rules/evdev.xml"; do
        if [ -f "$target" ] && grep -qi 'ergopti' "$target" \
                && has_numbered_backup "$target"; then
            LEGACY_EVIDENCE="${LEGACY_EVIDENCE}${LEGACY_EVIDENCE:+, }$target (+ sauvegarde)"
            found=0
        fi
    done
    return "$found"
}

has_clean_installation() {
    local extensions_root="$1"
    local system_root="$2"
    local user_home="$3"
    local component found=1

    if [ -d "$extensions_root/ergopti" ]; then
        CLEAN_EVIDENCE="$extensions_root/ergopti"
        found=0
    fi
    for component in symbols types; do
        if [ -d "$system_root/$component" ] \
                && find "$system_root/$component" -maxdepth 1 \
                    \( -type f -o -type l \) -iname '*ergopti*' -print 2>/dev/null \
                    | grep -q .; then
            CLEAN_EVIDENCE="${CLEAN_EVIDENCE}${CLEAN_EVIDENCE:+, }$system_root/$component/*ergopti* (lien hérité)"
            found=0
        fi
    done
    if [ -f "$system_root/rules/evdev" ] \
            && grep -i 'ergopti' "$system_root/rules/evdev" | grep -q '='; then
        CLEAN_EVIDENCE="${CLEAN_EVIDENCE}${CLEAN_EVIDENCE:+, }$system_root/rules/evdev (règle héritée)"
        found=0
    fi
    if [ -n "$user_home" ] && [ -f "$user_home/.XCompose" ] \
            && grep -qFx '# Ergopti managed XCompose' "$user_home/.XCompose"; then
        CLEAN_EVIDENCE="${CLEAN_EVIDENCE}${CLEAN_EVIDENCE:+, }$user_home/.XCompose (inclusion)"
        found=0
    fi
    return "$found"
}

infer_uninstall_method() {
    local extensions_root="${ERGOPTI_XKB_EXTENSIONS_ROOT:-/usr/share/xkeyboard-config.d}"
    local system_root="${ERGOPTI_XKB_SYSTEM_ROOT:-/usr/share/X11/xkb}"
    local user_home="${ERGOPTI_XKB_USER_HOME:-${HOME:-}}"
    local clean_found=false
    local legacy_found=false

    if has_clean_installation "$extensions_root" "$system_root" "$user_home"; then
        clean_found=true
    fi

    if has_legacy_installation "$system_root"; then
        legacy_found=true
    fi

    printf "${LOG_INDENT}Artefacts Clean  : %s\n" "${CLEAN_EVIDENCE:-aucun}"
    printf "${LOG_INDENT}Artefacts Legacy : %s\n" "${LEGACY_EVIDENCE:-aucun}"
    if [ "$clean_found" = true ] && [ "$legacy_found" = true ]; then
        usage_error "$UNINSTALL_METHOD_REQUIRED_MESSAGE (les deux méthodes ont laissé des fichiers)"
    fi
    if [ "$clean_found" != true ] && [ "$legacy_found" != true ]; then
        usage_error "$UNINSTALL_METHOD_REQUIRED_MESSAGE (aucune installation Ergopti détectée)"
    fi
    if [ "$clean_found" = true ]; then
        FORCE_INSTALLATION_METHOD="clean"
    else
        FORCE_INSTALLATION_METHOD="legacy"
    fi
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case $1 in
        --installation-method)
            FORCE_INSTALLATION_METHOD="${2:-}"
            if [[ "$FORCE_INSTALLATION_METHOD" != "clean" && "$FORCE_INSTALLATION_METHOD" != "legacy" ]]; then
                usage_error "--installation-method doit être 'clean' ou 'legacy'"
            fi
            shift 2
            ;;
        --version)
            [ -n "${2:-}" ] || usage_error "--version requiert une valeur (ex. v2_2_1)"
            SELECTED_VERSION_ARG="$2"
            shift 2
            ;;
        --variant)
            [ -n "${2:-}" ] || usage_error "--variant requiert une valeur"
            SELECTED_VARIANT_ARG="$2"
            shift 2
            ;;
        --ansi)
            WANT_ANSI=true
            shift
            ;;
        --yes)
            WANT_YES=true
            shift
            ;;
        --uninstall)
            WANT_UNINSTALL=true
            shift
            ;;
        --diagnose)
            WANT_DIAGNOSE=true
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            usage_error "Option inconnue : $1"
            ;;
    esac
done

if [[ -n "$SELECTED_VERSION_ARG" ]]; then
    [[ "$SELECTED_VERSION_ARG" =~ ^v[0-9._]+$ ]] || usage_error "Version invalide : $SELECTED_VERSION_ARG"
    SELECTED_VERSION_ARG="${SELECTED_VERSION_ARG//./_}"
fi
case "$SELECTED_VARIANT_ARG" in
    "") ;;
    ergopti | ergopti_plus) ;;
    *) usage_error "Variante invalide : $SELECTED_VARIANT_ARG (ergopti|ergopti_plus)" ;;
esac
if [ "$WANT_YES" = true ] && [ "$WANT_UNINSTALL" != true ] && [ "$WANT_DIAGNOSE" != true ] \
        && { [ -z "$SELECTED_VERSION_ARG" ] || [ -z "$SELECTED_VARIANT_ARG" ]; }; then
    usage_error "--yes requiert --version et --variant"
fi
if [[ ! "$SELECTED_BRANCH" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]]; then
    usage_error "Branche invalide : $SELECTED_BRANCH"
fi
case "$SELECTED_BRANCH" in
    *..* | */ | *//*) usage_error "Branche invalide : $SELECTED_BRANCH" ;;
esac

if [ "$WANT_YES" != true ] && [ "$WANT_DIAGNOSE" != true ] && [ ! -t 1 ]; then
    printf "%s❌ Erreur : terminal interactif requis.%s\n" "${RED}" "${NO_COLOR}" >&2
    echo "(Si vous voyez ce message mais aucun bandeau d'accueil, le téléchargement du script a probablement échoué.)" >&2
    exit 1
fi

IS_LOCAL=false
SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
    LOCAL_DRIVERS_ROOT=$(dirname "$SCRIPT_DIR")
    if [ -f "$SCRIPT_DIR/detect_installation_method.sh" ] \
            && find "$LOCAL_DRIVERS_ROOT" -maxdepth 1 -type d -name 'v*' -print 2>/dev/null \
                | grep -q .; then
        IS_LOCAL=true
    fi
fi

TEMP_DIR=$(mktemp -d -t ergopti-install.XXXXXX)

cleanup() {
    local exit_code=$?
    # Nothing in here may change the exit code or trigger the error trap: a
    # failed cleanup after a successful installation must not read as a
    # failed installation.
    set +e
    trap - ERR
    tput cnorm >/dev/null 2>&1 || true
    if [ -n "${TEMP_DIR:-}" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR" 2>/dev/null || true
    fi
    if [ -n "$LOG_TEE_PID" ]; then
        # Give the copy to the log file its last lines before the prompt
        # comes back; on a bash too old to wait on a process substitution
        # the lines still land, only slightly later.
        exec 1>&3 2>&4
        wait "$LOG_TEE_PID" 2>/dev/null || true
    fi
    exit "$exit_code"
}
trap cleanup EXIT INT TERM

start_log() {
    if : > "$LOG_FILE" 2>/dev/null; then
        exec 3>&1 4>&2
        exec > >(tee -a "$LOG_FILE") 2>&1
        LOG_TEE_PID=$!
        printf "Journal de cette exécution : %s (à joindre à tout rapport de bug)\n" "$LOG_FILE"
    else
        printf "%s⚠️  Journal désactivé : impossible d'écrire dans %s%s\n" "$YELLOW" "$LOG_FILE" "$NO_COLOR"
        LOG_FILE=""
    fi
}

printf "${BOLD}Ergopti — installeur de la disposition clavier Linux${NO_COLOR}\n"
start_log
printf "Commande : install.sh"
if [ "$WANT_DIAGNOSE" = true ]; then printf " --diagnose"; fi
if [ "$WANT_UNINSTALL" = true ]; then printf " --uninstall"; fi
if [ -n "$FORCE_INSTALLATION_METHOD" ]; then printf " --installation-method %s" "$FORCE_INSTALLATION_METHOD"; fi
printf " (branche %s)\n" "$SELECTED_BRANCH"

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------

log_section "Vérification des dépendances"

check_host

if ! command -v git >/dev/null 2>&1; then
    printf "${LOG_INDENT}Git non trouvé. Tentative d'installation automatique...\n"
    pkg_install git || warn "Installation automatique de git impossible : installez-le puis relancez."
fi

run_step "Vérification de git" "git disponible" command -v git
check_python

if [ "$WANT_UNINSTALL" != true ] && [ "$WANT_YES" != true ] && [ "$WANT_DIAGNOSE" != true ]; then
    log_section "Vérification de la disponibilité de fzf"
    if ! command -v fzf >/dev/null 2>&1; then
        printf "${LOG_INDENT}${YELLOW}⚠️  Fzf non trouvé. Lancement de l'installation locale de fzf...${NO_COLOR}\n"
        LOG_INDENT="${LOG_INDENT}   "
        run_step "Téléchargement de fzf" "Code source récupéré" \
            run_with_retry 3 20 git clone --depth 1 https://github.com/junegunn/fzf.git "$TEMP_DIR/fzf"
        run_step "Compilation de fzf" "Binaire généré et prêt" \
            run_with_retry 3 60 "$TEMP_DIR/fzf/install" --bin --no-update-rc --no-key-bindings --no-completion
        LOG_INDENT="${LOG_INDENT%   }"
        export PATH="$TEMP_DIR/fzf/bin:$PATH"
    else
        printf "${LOG_INDENT}${GREEN}✅ Fzf est déjà installé sur le système${NO_COLOR}\n"
    fi
fi

# ---------------------------------------------------------------------------
# Source preparation
# ---------------------------------------------------------------------------

if [ "$IS_LOCAL" = true ]; then
    log_section "Mode local détecté"
    DRIVERS_ROOT="$(dirname "$SCRIPT_DIR")"
    printf "${LOG_INDENT}Analyse des fichiers locaux dans : ${BOLD}$DRIVERS_ROOT${NO_COLOR}\n"
else
    log_section "Connexion au dépôt distant ($SELECTED_BRANCH)"
    REPO_DIR="$TEMP_DIR/repo"
    git init "$REPO_DIR" >/dev/null 2>&1
    cd "$REPO_DIR"
    git remote add origin "$REPO_URL" >/dev/null 2>&1
    run_step "Récupération de la liste des fichiers" "Métadonnées synchronisées" \
        git fetch --depth 1 --filter=blob:none origin "$SELECTED_BRANCH"
    git config core.sparseCheckout true
    printf '%s\n' "$TARGET_DIR/$INSTALLER_REL_PATH" > .git/info/sparse-checkout
    run_step "Téléchargement de l'installeur" "Installeur récupéré" \
        git checkout "$SELECTED_BRANCH"
    DRIVERS_ROOT="$REPO_DIR/$TARGET_DIR"
fi

INSTALLER_SCRIPTS_DIR="$DRIVERS_ROOT/$INSTALLER_REL_PATH"

# ---------------------------------------------------------------------------
# Diagnostic shortcut (no privileges, nothing modified)
# ---------------------------------------------------------------------------

if [ "$WANT_DIAGNOSE" = true ]; then
    log_section "Diagnostic"
    LOG_INDENT=""
    "$PYTHON_BIN" -B "$INSTALLER_SCRIPTS_DIR/$SCRIPT_NAME_DIAGNOSE"
    if [ -n "$LOG_FILE" ]; then
        printf "\nRapport également enregistré dans %s\n" "$LOG_FILE"
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# Uninstall shortcut
# ---------------------------------------------------------------------------

if [ "$WANT_UNINSTALL" = true ]; then
    log_section "Désinstallation"
    if [ -z "$FORCE_INSTALLATION_METHOD" ]; then
        infer_uninstall_method
    fi
    # The desktop entries live in the user's dconf and Plasma config, which
    # the privileged process cannot reach: drop them from this shell first.
    # -B everywhere: the privileged run must not litter the user's temporary
    # checkout with root-owned bytecode the user cannot delete afterwards.
    if [ "$FORCE_INSTALLATION_METHOD" = "legacy" ]; then
        "$PYTHON_BIN" -B "$INSTALLER_SCRIPTS_DIR/xkb_files_installer_legacy.py" --deactivate-only || true
        run_step "Retrait de l'installation Legacy" "Installation Legacy retirée" \
            as_root "$PYTHON_BIN" -B "$INSTALLER_SCRIPTS_DIR/xkb_files_installer_legacy.py" \
                --uninstall --skip-activation
    elif [ "$FORCE_INSTALLATION_METHOD" = "clean" ]; then
        "$PYTHON_BIN" -B "$INSTALLER_SCRIPTS_DIR/xkb_files_installer_clean.py" --deactivate-only || true
        run_step "Retrait du paquet Clean" "Paquet Clean retiré" \
            as_root "$PYTHON_BIN" -B "$INSTALLER_SCRIPTS_DIR/xkb_files_installer_clean.py" \
                --uninstall --skip-activation
    else
        usage_error "Méthode de désinstallation absente ou invalide"
    fi
    printf "\n${GREEN}Désinstallation terminée. Redémarrez la session pour retrouver votre disposition précédente.${NO_COLOR}\n"
    exit 0
fi

# ---------------------------------------------------------------------------
# Version selection
# ---------------------------------------------------------------------------

printf "\n${LOG_INDENT}${BOLD}Sélection de la version${NO_COLOR}\n"

# Newest first. GNU sort knows -V; busybox may not, hence the numeric fallback
# on the vX_Y_Z form.
sort_versions_desc() {
    if printf '1\n' | sort -V >/dev/null 2>&1; then
        sort -rV
    else
        sed 's/^v//; s/_/ /g' | sort -k1,1nr -k2,2nr -k3,3nr | sed 's/ /_/g; s/^/v/'
    fi
}

if [ "$IS_LOCAL" = true ]; then
    mapfile -t RELEASES < <(find "$DRIVERS_ROOT" -maxdepth 1 -type d -name "v*" | sed 's|.*/||' | sort_versions_desc)
else
    mapfile -t RELEASES < <(git ls-tree -d --name-only "origin/$SELECTED_BRANCH:$TARGET_DIR" | grep "^v" | sort_versions_desc)
fi

if [ ${#RELEASES[@]} -eq 0 ]; then
    fail "Aucune version trouvée dans la branche $SELECTED_BRANCH."
fi

if [ -n "$SELECTED_VERSION_ARG" ]; then
    VERSION_FOUND=false
    for r in "${RELEASES[@]}"; do
        if [ "$(basename "$r")" = "$SELECTED_VERSION_ARG" ]; then
            VERSION_FOUND=true
            break
        fi
    done
    if [ "$VERSION_FOUND" = false ]; then
        printf "${LOG_INDENT}${RED}❌ Version inconnue sur $SELECTED_BRANCH : $SELECTED_VERSION_ARG${NO_COLOR}\n" >&2
        echo "Versions disponibles :" >&2
        for r in "${RELEASES[@]}"; do echo "  $(basename "$r")" >&2; done
        exit 1
    fi
    SELECTED_NAME="$SELECTED_VERSION_ARG"
else
    RELEASE_LIST=""
    for r in "${RELEASES[@]}"; do
        raw_name=$(basename "$r")
        RELEASE_LIST="${RELEASE_LIST}${raw_name//_/.}\n"
    done

    SELECTED_NAME=$(printf "%b" "$RELEASE_LIST" | run_fzf --prompt="Version > " --header="Sélectionnez la version du layout (Entrée = plus récente en haut)" || true)
    if [ -z "$SELECTED_NAME" ]; then
        printf "\nAnnulé.\n"
        exit 0
    fi
fi
REAL_NAME="${SELECTED_NAME//./_}"
printf "${LOG_INDENT}${GREEN}➡️  Version choisie : $SELECTED_NAME${NO_COLOR}\n"

# ---------------------------------------------------------------------------
# Variant analysis (before downloading content)
# ---------------------------------------------------------------------------

if [ "$IS_LOCAL" = true ]; then
    TARGET_PATH="$DRIVERS_ROOT/$REAL_NAME"
    FILE_LIST=$(find "$TARGET_PATH" -maxdepth 1 -type f | sed 's|.*/||')
else
    REMOTE_PATH="$TARGET_DIR/$REAL_NAME"
    FILE_LIST=$(git ls-tree --name-only "origin/$SELECTED_BRANCH:$REMOTE_PATH")
fi

printf "\n${LOG_INDENT}${BOLD}Configuration de l'installation${NO_COLOR}\n"

HAS_PLUS=false
HAS_STANDARD=false
while IFS= read -r file; do
    filename=$(basename "$file")
    filename_lower="${filename,,}"
    [[ "$filename_lower" != *.xkb ]] && continue
    case "$filename_lower" in
        *_plus_plus*) : ;; # Ergopti++ n'est plus proposé à l'installation
        *_plus*) HAS_PLUS=true ;;
        *_ansi*) : ;;
        *) HAS_STANDARD=true ;;
    esac
done <<< "$FILE_LIST"

VARIANTS_MENU=""
$HAS_STANDARD && VARIANTS_MENU="${VARIANTS_MENU}1. Ergopti (standard)\n"
$HAS_PLUS && VARIANTS_MENU="${VARIANTS_MENU}2. Ergopti+ (à utiliser avec Espanso)\n"

if [ -z "$VARIANTS_MENU" ]; then
    fail "Aucun fichier .xkb installable trouvé dans cette version."
fi

if [ -n "$SELECTED_VARIANT_ARG" ]; then
    VARIANT_AVAILABLE=false
    if [ "$SELECTED_VARIANT_ARG" = "ergopti_plus" ] && $HAS_PLUS; then
        VARIANT_AVAILABLE=true
        SELECTED_VARIANT_RAW="2. Ergopti+ (à utiliser avec Espanso)"
    elif [ "$SELECTED_VARIANT_ARG" = "ergopti" ] && $HAS_STANDARD; then
        VARIANT_AVAILABLE=true
        SELECTED_VARIANT_RAW="1. Ergopti (standard)"
    fi
    if [ "$VARIANT_AVAILABLE" = false ]; then
        fail "Variante indisponible dans cette version : $SELECTED_VARIANT_ARG"
    fi
else
    SELECTED_VARIANT_RAW=$(printf "%b" "$VARIANTS_MENU" | run_fzf --prompt="Variante > " --header="Sélectionnez la variante (Ergopti++ n'est plus proposé)" || true)
    if [ -z "$SELECTED_VARIANT_RAW" ]; then
        printf "\nAnnulé.\n"
        exit 0
    fi
fi

case "$SELECTED_VARIANT_RAW" in
    *"+"*) SUFFIX="_plus" ;;
    *) SUFFIX="" ;;
esac
VARIANT_ID="ergopti_plus"
if [ "$SUFFIX" = "" ]; then
    VARIANT_ID="ergopti"
fi
printf "${LOG_INDENT}${GREEN}➡️  Variante : $SELECTED_VARIANT_RAW${NO_COLOR}\n"

# Physical form: ISO by default, ANSI behind the flag.
XKB_FILENAME=""
while IFS= read -r candidate; do
    candidate_lower="${candidate,,}"
    [[ "$candidate_lower" == *_ansi* && "$WANT_ANSI" = false ]] && continue
    [[ "$candidate_lower" == *_plus_plus* ]] && continue
    if [ "$WANT_ANSI" = true ]; then
        [[ "$candidate_lower" == *"${SUFFIX}_ansi.xkb" ]] && { XKB_FILENAME="$candidate"; break; }
    else
        [[ "$candidate_lower" == *"ergopti"*"$SUFFIX.xkb" ]] && { XKB_FILENAME="$candidate"; break; }
    fi
done <<< "$FILE_LIST"

if [ -z "$XKB_FILENAME" ]; then
    fail "Erreur interne : fichier de disposition introuvable pour cette variante/forme."
fi
XKB_FILENAME=$(basename "$XKB_FILENAME")
printf "${LOG_INDENT}${GREEN}➡️  Fichier : $XKB_FILENAME${NO_COLOR}\n"

# The full custom types file is always installed: it owns the Shift layer,
# CapsLock layer and AltGr layers (issue #84: without it Shift stays dead).
TYPES_FILENAME="xkb_types.txt"
if ! grep -qxF "$TYPES_FILENAME" <<< "$FILE_LIST"; then
    fail "Erreur interne : fichier de types introuvable ($TYPES_FILENAME)."
fi
printf "${LOG_INDENT}${GREEN}➡️  Types : $TYPES_FILENAME (toujours inclus, choix supprimé)${NO_COLOR}\n"

BASENAME="${XKB_FILENAME%.*}"
XCOMPOSE_FILENAME=""
while IFS= read -r candidate; do
    if [ "$(basename "$candidate")" = "${BASENAME}.XCompose" ]; then
        XCOMPOSE_FILENAME="$(basename "$candidate")"
        break
    fi
done <<< "$FILE_LIST"
if [ -n "$XCOMPOSE_FILENAME" ]; then
    printf "${LOG_INDENT}${GREEN}➡️  XCompose : inclus (automatique)${NO_COLOR}\n"
else
    printf "${LOG_INDENT}${YELLOW}➡️  XCompose : non trouvé pour ce fichier${NO_COLOR}\n"
fi

# ---------------------------------------------------------------------------
# Targeted download
# ---------------------------------------------------------------------------

if [ "$IS_LOCAL" = false ]; then
    log_section "Téléchargement ciblé"
    BASE_PATH="$TARGET_DIR/$REAL_NAME"
    git config core.sparseCheckout true
    {
        echo "$TARGET_DIR/$INSTALLER_REL_PATH"
        echo "$BASE_PATH/$XKB_FILENAME"
        echo "$BASE_PATH/$TYPES_FILENAME"
        [ -n "$XCOMPOSE_FILENAME" ] && echo "$BASE_PATH/$XCOMPOSE_FILENAME"
    } >>.git/info/sparse-checkout
    run_step "Téléchargement des fichiers" "Fichiers récupérés" \
        git checkout "$SELECTED_BRANCH"
    SELECTED_VERSION_DIR="$REPO_DIR/$BASE_PATH"
else
    SELECTED_VERSION_DIR="$DRIVERS_ROOT/$REAL_NAME"
fi

# ---------------------------------------------------------------------------
# Installer execution
# ---------------------------------------------------------------------------

log_section "Préparation de l'installation"

if [ -n "$FORCE_INSTALLATION_METHOD" ]; then
    if [ "$FORCE_INSTALLATION_METHOD" = "clean" ]; then
        INSTALLER_SCRIPT="$SCRIPT_NAME_CLEAN"
        INSTALLER_METHOD="Clean (extensions XKB) [forcée]"
    else
        INSTALLER_SCRIPT="$SCRIPT_NAME_LEGACY"
        INSTALLER_METHOD="Legacy (système) [forcée]"
    fi
    printf "${LOG_INDENT}${YELLOW}⚠️  Méthode forcée via argument : ${BOLD}$INSTALLER_METHOD${NO_COLOR}\n"
    if [ "$FORCE_INSTALLATION_METHOD" = "clean" ] && [ "${XDG_SESSION_TYPE:-}" = "x11" ]; then
        printf "${LOG_INDENT}${YELLOW}⚠️  Session X11 détectée : Xorg ignore les répertoires d'extensions XKB, la méthode Clean n'y sera pas visible.${NO_COLOR}\n"
    fi
elif [ -f "$INSTALLER_SCRIPTS_DIR/detect_installation_method.sh" ]; then
    DETECT_OUTPUT=$(bash "$INSTALLER_SCRIPTS_DIR/detect_installation_method.sh") || true
    printf "%s\n" "$DETECT_OUTPUT" | sed "s/^/${LOG_INDENT}/"
    if printf '%s' "$DETECT_OUTPUT" | grep -q "^METHOD=clean$"; then
        INSTALLER_SCRIPT="$SCRIPT_NAME_CLEAN"
        INSTALLER_METHOD="Clean (extensions XKB)"
    else
        INSTALLER_SCRIPT="$SCRIPT_NAME_LEGACY"
        INSTALLER_METHOD="Legacy (système)"
    fi
else
    INSTALLER_SCRIPT="$SCRIPT_NAME_LEGACY"
    INSTALLER_METHOD="Legacy (système) [défaut]"
fi

INSTALLER_FULL_PATH="$INSTALLER_SCRIPTS_DIR/$INSTALLER_SCRIPT"
if [ ! -f "$INSTALLER_FULL_PATH" ]; then
    fail "Script d'installation introuvable : $INSTALLER_FULL_PATH"
fi

if [ "$INSTALLER_SCRIPT" = "$SCRIPT_NAME_CLEAN" ]; then
    ensure_xkb_compiler clean
else
    ensure_xkb_compiler legacy
fi

XKB_FULL_PATH=$(realpath "$SELECTED_VERSION_DIR/$XKB_FILENAME")
TYPES_FULL_PATH=$(realpath "$SELECTED_VERSION_DIR/$TYPES_FILENAME")

INSTALLER_ARGS=(--xkb "$XKB_FULL_PATH" --types "$TYPES_FULL_PATH")
if [ -n "$XCOMPOSE_FILENAME" ]; then
    INSTALLER_ARGS+=(--xcompose "$(realpath "$SELECTED_VERSION_DIR/$XCOMPOSE_FILENAME")")
fi

if [ "$INSTALLER_SCRIPT" = "$SCRIPT_NAME_CLEAN" ]; then
    INSTALLER_ARGS+=(--variant "$VARIANT_ID" --skip-activation)
else
    INSTALLER_ARGS+=(--skip-activation)
    if [ "$WANT_YES" = true ] && [ -n "$XCOMPOSE_FILENAME" ]; then
        INSTALLER_ARGS+=(--force-xcompose)
    fi
fi

# The legacy method registers the layout as a variant of the system `fr`
# layout, so the desktop identifier is `fr+<section name>` rather than the
# package name used by the clean method.
LEGACY_LAYOUT_ID=""
if [ "$INSTALLER_SCRIPT" = "$SCRIPT_NAME_LEGACY" ]; then
    LEGACY_SYMBOL_NAME=$(grep -m1 'xkb_symbols' "$XKB_FULL_PATH" | cut -d'"' -f2)
    if [ -z "$LEGACY_SYMBOL_NAME" ]; then
        fail "Erreur interne : section xkb_symbols illisible dans $XKB_FULL_PATH"
    fi
    LEGACY_LAYOUT_ID="fr+$LEGACY_SYMBOL_NAME"
    LAYOUT_ID_FOR_SUMMARY="$LEGACY_LAYOUT_ID"
    FILES_FOR_SUMMARY="${ERGOPTI_XKB_SYSTEM_ROOT:-/usr/share/X11/xkb} (symbols/fr, types/extra, rules/evdev.*, sauvegardes .1)"
else
    LAYOUT_ID_FOR_SUMMARY="ergopti"
    FILES_FOR_SUMMARY="${ERGOPTI_XKB_EXTENSIONS_ROOT:-/usr/share/xkeyboard-config.d}/ergopti"
fi

printf "${LOG_INDENT}Méthode d'installation : ${BOLD}$INSTALLER_METHOD${NO_COLOR}\n"

printf "${LOG_INDENT}Le script va maintenant demander les droits administrateur pour copier les fichiers.\n"
printf "\n🚀 Exécution de l'installeur...\n"
tput cnorm >/dev/null 2>&1 || true
if ! as_root "$PYTHON_BIN" -B "$INSTALLER_FULL_PATH" "${INSTALLER_ARGS[@]}"; then
    fail "L'installation des fichiers a échoué (voir les messages ci-dessus)." \
        "Relancez ce script avec --diagnose et joignez sa sortie au rapport de bug." 4
fi

# Desktop activation deliberately runs *outside* sudo: GNOME keeps the layout
# list in the user's dconf database, reached over the user's D-Bus session bus,
# so the privileged process would write into root's settings and change nothing
# visible (issue #84).
printf "\n🖥️  Activation dans votre session de bureau...\n"
if [ "$INSTALLER_SCRIPT" = "$SCRIPT_NAME_CLEAN" ]; then
    ACTIVATION_COMMAND=("$PYTHON_BIN" -B "$INSTALLER_FULL_PATH" --activate-only --variant "$VARIANT_ID")
else
    ACTIVATION_COMMAND=("$PYTHON_BIN" -B "$INSTALLER_FULL_PATH" --activate-only --layout-id "$LEGACY_LAYOUT_ID")
fi
if ! "${ACTIVATION_COMMAND[@]}"; then
    fail "La vérification ou l'activation de la disposition a échoué (voir les messages ci-dessus)." \
        "Les fichiers restent installés pour analyse. Relancez ce script avec --diagnose et joignez sa sortie au rapport de bug." 4
fi

printf "\n${GREEN}${BOLD}✨ Installation terminée.${NO_COLOR}\n"
printf "   Méthode      : %s\n" "$INSTALLER_METHOD"
printf "   Disposition  : %s\n" "$LAYOUT_ID_FOR_SUMMARY"
printf "   Fichiers     : %s\n" "$FILES_FOR_SUMMARY"
if [ -n "$LOG_FILE" ]; then
    printf "   Journal      : %s\n" "$LOG_FILE"
fi
printf "   Déconnectez-vous puis reconnectez-vous (ou redémarrez) pour que la session recharge la disposition.\n"
printf "   En cas de problème : relancez ce script avec --diagnose et joignez sa sortie au rapport de bug.\n"
