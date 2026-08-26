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
#   - every activation step reports success or failure instead of hiding it.
#
# Usage:
#   bash install.sh [--installation-method clean|legacy] [--ansi] [--uninstall]
# ==============================================================================

set -euo pipefail

REPO_URL="https://github.com/adrienm7/ergopti.git"
TARGET_DIR="static/ergopti/linux"
INSTALLER_REL_PATH="xkb_installation"
SCRIPT_NAME_LEGACY="xkb_files_installer_legacy.py"
SCRIPT_NAME_CLEAN="xkb_files_installer_clean.py"

DEFAULT_BRANCH="main"
SELECTED_BRANCH="${BRANCH:-$DEFAULT_BRANCH}"
FORCE_INSTALLATION_METHOD=""
WANT_UNINSTALL=false
WANT_ANSI=false
WANT_YES=false
SELECTED_VERSION_ARG=""
SELECTED_VARIANT_ARG=""
UNINSTALL_METHOD_REQUIRED_MESSAGE="--uninstall requiert --installation-method clean|legacy"

RED=$(printf '\033[31m')
GREEN=$(printf '\033[32m')
YELLOW=$(printf '\033[33m')
BLUE=$(printf '\033[34m')
BOLD=$(printf '\033[1m')
NO_COLOR=$(printf '\033[0m')

LOG_INDENT=""

unset FZF_DEFAULT_OPTS || true

usage_error() {
    printf "${RED}❌ %s${NO_COLOR}\n" "$1" >&2
    echo "Usage : $0 [--installation-method clean|legacy] [--version v2_2_1]" \
        "[--variant ergopti|ergopti_plus] [--ansi] [--uninstall] [--yes]" >&2
    exit 1
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

has_legacy_installation() {
    local system_root="$1"
    local target
    for target in \
            "$system_root/symbols/fr" \
            "$system_root/types/extra" \
            "$system_root/rules/evdev.lst" \
            "$system_root/rules/evdev.xml"; do
        if [ -f "$target" ] && grep -qi 'ergopti' "$target" \
                && has_numbered_backup "$target"; then
            return 0
        fi
    done
    return 1
}

has_clean_installation() {
    local extensions_root="$1"
    local system_root="$2"
    local user_home="$3"
    local component

    if [ -d "$extensions_root/ergopti" ]; then
        return 0
    fi
    for component in symbols types; do
        if [ -d "$system_root/$component" ] \
                && find "$system_root/$component" -maxdepth 1 \
                    \( -type f -o -type l \) -iname '*ergopti*' -print -quit \
                    2>/dev/null | grep -q .; then
            return 0
        fi
    done
    if [ -f "$system_root/rules/evdev" ] \
            && grep -i 'ergopti' "$system_root/rules/evdev" | grep -q '='; then
        return 0
    fi
    if [ -n "$user_home" ] && [ -f "$user_home/.XCompose" ] \
            && grep -qFx '# Ergopti managed XCompose' "$user_home/.XCompose"; then
        return 0
    fi
    return 1
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

    if [ "$clean_found" = true ] && [ "$legacy_found" = true ]; then
        usage_error "$UNINSTALL_METHOD_REQUIRED_MESSAGE"
    fi
    if [ "$clean_found" != true ] && [ "$legacy_found" != true ]; then
        usage_error "$UNINSTALL_METHOD_REQUIRED_MESSAGE"
    fi
    if [ "$clean_found" = true ]; then
        FORCE_INSTALLATION_METHOD="clean"
    else
        FORCE_INSTALLATION_METHOD="legacy"
    fi
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --installation-method)
            FORCE_INSTALLATION_METHOD="$2"
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
if [ "$WANT_YES" = true ] && [ "$WANT_UNINSTALL" != true ] \
        && { [ -z "$SELECTED_VERSION_ARG" ] || [ -z "$SELECTED_VARIANT_ARG" ]; }; then
    usage_error "--yes requiert --version et --variant"
fi
if [[ ! "$SELECTED_BRANCH" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]]; then
    usage_error "Branche invalide : $SELECTED_BRANCH"
fi
case "$SELECTED_BRANCH" in
    *..* | */ | *//*) usage_error "Branche invalide : $SELECTED_BRANCH" ;;
esac

if [ "$WANT_YES" != true ] && [ ! -t 1 ]; then
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
            && find "$LOCAL_DRIVERS_ROOT" -maxdepth 1 -type d -name 'v*' -print -quit \
                | grep -q .; then
        IS_LOCAL=true
    fi
fi

TEMP_DIR=$(mktemp -d -t ergopti-install.XXXXXX)

cleanup() {
    local exit_code=$?
    tput cnorm >/dev/null 2>&1 || true
    if [ -n "${TEMP_DIR:-}" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
    exit "$exit_code"
}
trap cleanup EXIT INT TERM

printf "${BOLD}Ergopti — installeur de la disposition clavier Linux${NO_COLOR}\n"

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------

log_section "Vérification des dépendances"

if ! command -v git >/dev/null 2>&1 && [ -f /etc/os-release ]; then
    printf "${LOG_INDENT}Git non trouvé. Tentative d'installation automatique...\n"
    . /etc/os-release
    case ${ID:-} in
        fedora) sudo dnf install -y git ;;
        debian | ubuntu | linuxmint | pop) sudo apt-get update && sudo apt-get install -y git ;;
        arch | manjaro | endeavouros) sudo pacman -S --noconfirm git ;;
        solus) sudo eopkg it -y git ;;
        opensuse*) sudo zypper install -y git ;;
    esac
fi

for cmd in git python3; do
    run_step "Vérification de $cmd" "$cmd disponible" command -v "$cmd"
done

if [ "$WANT_UNINSTALL" != true ] && [ "$WANT_YES" != true ]; then
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

# ---------------------------------------------------------------------------
# Uninstall shortcut
# ---------------------------------------------------------------------------

if [ "$WANT_UNINSTALL" = true ]; then
    log_section "Désinstallation"
    INSTALLER_SCRIPTS_DIR="$DRIVERS_ROOT/$INSTALLER_REL_PATH"
    if [ -z "$FORCE_INSTALLATION_METHOD" ]; then
        infer_uninstall_method
    fi
    if [ "$FORCE_INSTALLATION_METHOD" = "legacy" ]; then
        run_step "Retrait de l'installation Legacy" "Installation Legacy retirée" \
            sudo python3 "$INSTALLER_SCRIPTS_DIR/xkb_files_installer_legacy.py" --uninstall
    elif [ "$FORCE_INSTALLATION_METHOD" = "clean" ]; then
        run_step "Retrait du paquet Clean" "Paquet Clean retiré" \
            sudo python3 "$INSTALLER_SCRIPTS_DIR/xkb_files_installer_clean.py" --uninstall
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

if [ "$IS_LOCAL" = true ]; then
    mapfile -t RELEASES < <(find "$DRIVERS_ROOT" -maxdepth 1 -type d -name "v*" | sort -rV)
else
    mapfile -t RELEASES < <(git ls-tree -d --name-only "origin/$SELECTED_BRANCH:$TARGET_DIR" | grep "^v" | sort -rV)
fi

if [ ${#RELEASES[@]} -eq 0 ]; then
    printf "${LOG_INDENT}${RED}❌ Aucune version trouvée dans la branche $SELECTED_BRANCH.${NO_COLOR}\n" >&2
    exit 1
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

    SELECTED_NAME=$(printf "%b" "$RELEASE_LIST" | run_fzf --prompt="Version > " --header="Sélectionnez la version du layout (Entrée = plus récente en haut)")
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
    FILE_LIST=$(find "$TARGET_PATH" -maxdepth 1 -type f -printf '%f\n')
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
    printf "${LOG_INDENT}${RED}❌ Erreur : aucun fichier .xkb installable trouvé dans cette version.${NO_COLOR}\n" >&2
    exit 1
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
        printf "${LOG_INDENT}${RED}❌ Variante indisponible dans cette version : $SELECTED_VARIANT_ARG${NO_COLOR}\n" >&2
        exit 1
    fi
else
    SELECTED_VARIANT_RAW=$(printf "%b" "$VARIANTS_MENU" | run_fzf --prompt="Variante > " --header="Sélectionnez la variante (Ergopti++ n'est plus proposé)")
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
    printf "${RED}❌ Erreur interne : fichier de disposition introuvable pour cette variante/forme.${NO_COLOR}\n" >&2
    exit 1
fi
XKB_FILENAME=$(basename "$XKB_FILENAME")
printf "${LOG_INDENT}${GREEN}➡️  Fichier : $XKB_FILENAME${NO_COLOR}\n"

# The full custom types file is always installed: it owns the Shift layer,
# CapsLock layer and AltGr layers (issue #84: without it Shift stays dead).
TYPES_FILENAME="xkb_types.txt"
if ! grep -qxF "$TYPES_FILENAME" <<< "$FILE_LIST"; then
    printf "${RED}❌ Erreur interne : fichier de types introuvable ($TYPES_FILENAME).${NO_COLOR}\n" >&2
    exit 1
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

INSTALLER_SCRIPTS_DIR="$DRIVERS_ROOT/$INSTALLER_REL_PATH"

if [ -n "$FORCE_INSTALLATION_METHOD" ]; then
    if [ "$FORCE_INSTALLATION_METHOD" = "clean" ]; then
        INSTALLER_SCRIPT="$SCRIPT_NAME_CLEAN"
        INSTALLER_METHOD="Clean (extensions XKB) [forcée]"
    else
        INSTALLER_SCRIPT="$SCRIPT_NAME_LEGACY"
        INSTALLER_METHOD="Legacy (système) [forcée]"
    fi
    printf "${LOG_INDENT}${YELLOW}⚠️  Méthode forcée via argument : ${BOLD}$INSTALLER_METHOD${NO_COLOR}\n"
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
    printf "${LOG_INDENT}${RED}❌ Erreur : script d'installation introuvable : %s${NO_COLOR}\n" "$INSTALLER_FULL_PATH" >&2
    exit 1
fi

XKB_FULL_PATH=$(realpath "$SELECTED_VERSION_DIR/$XKB_FILENAME")
TYPES_FULL_PATH=$(realpath "$SELECTED_VERSION_DIR/$TYPES_FILENAME")

INSTALLER_ARGS=(--xkb "$XKB_FULL_PATH" --types "$TYPES_FULL_PATH")
if [ -n "$XCOMPOSE_FILENAME" ]; then
    INSTALLER_ARGS+=(--xcompose "$(realpath "$SELECTED_VERSION_DIR/$XCOMPOSE_FILENAME")")
fi

if [ "$INSTALLER_SCRIPT" = "$SCRIPT_NAME_CLEAN" ]; then
    INSTALLER_ARGS+=(--variant "$VARIANT_ID" --skip-activation)
elif [ "$WANT_YES" = true ] && [ -n "$XCOMPOSE_FILENAME" ]; then
    INSTALLER_ARGS+=(--force-xcompose)
fi

printf "${LOG_INDENT}Méthode d'installation : ${BOLD}$INSTALLER_METHOD${NO_COLOR}\n"

printf "${LOG_INDENT}Le script va maintenant demander les droits sudo pour copier les fichiers.\n"
printf "\n🚀 Exécution de l'installeur...\n"
tput cnorm >/dev/null 2>&1 || true
sudo python3 "$INSTALLER_FULL_PATH" "${INSTALLER_ARGS[@]}"
if [ "$INSTALLER_SCRIPT" = "$SCRIPT_NAME_CLEAN" ]; then
    python3 "$INSTALLER_FULL_PATH" --activate-only --variant "$VARIANT_ID"
fi
