#!/bin/bash

# ======================================================
# ======================================================
# ======================================================
# ======= Ergopti XKB layout installation script =======
# ======================================================
# ======================================================
# ======================================================

# Single-file installer for Ergopti.
# Handles downloading, interactive selection (via fzf) and installation execution.

set -euo pipefail
# -e: Exit immediately if a command exits with a non-zero status
# -u: Treat unset variables as an error
# -o pipefail: Return value of a pipeline is the status of the last command to exit with a non-zero status





# ======================================
# ======= CONFIGURATION & COLORS =======
# ======================================

REPO_URL="https://github.com/adrienm7/ergopti.git"
TARGET_DIR="static/drivers/linux"
# Relative path to installer scripts inside the downloaded structure
INSTALLER_REL_PATH="xkb_installation"
# Script names
SCRIPT_NAME_LEGACY="xkb_files_installer_legacy.py"
SCRIPT_NAME_CLEAN="xkb_files_installer_clean.py"

# Branch configuration
DEFAULT_BRANCH="main"
# Allow override via env var, otherwise use default
SELECTED_BRANCH="${BRANCH:-$DEFAULT_BRANCH}"

# ANSI Colors
RED=$(printf '\033[31m')
GREEN=$(printf '\033[32m')
YELLOW=$(printf '\033[33m')
BLUE=$(printf '\033[34m')
BOLD=$(printf '\033[1m')
NO_COLOR=$(printf '\033[0m')

# Global indentation
LOG_INDENT=""

# Ignore user FZF configuration to ensure UI consistency
unset FZF_DEFAULT_OPTS





# ================================
# ======= HELPER FUNCTIONS =======
# ================================

log_section() {
    LOG_INDENT=""
    printf "\n${BOLD}${BLUE}%s...${NO_COLOR}\n" "$1"
    LOG_INDENT="   "
}

# Run a command with hierarchical logging
# Usage: run_step "Action Description" "Success Message" cmd arg1...
run_step() {
    local action_desc="$1"
    local success_msg="$2"
    shift 2
    printf "${LOG_INDENT}%s...\n" "$action_desc"
    local output
    if output=$("$@" 2>&1); then
        printf "${LOG_INDENT}   ${GREEN}✅ %s${NO_COLOR}\n" "$success_msg"
    else
        printf "${LOG_INDENT}   ${RED}❌ Échec de l’opération${NO_COLOR}\n"
        printf "${LOG_INDENT}   ${RED}Détails de l’erreur :${NO_COLOR}\n" >&2
        echo "$output" | sed "s/^/${LOG_INDENT}      /" >&2
        exit 1
    fi
}

# Helper to retry commands with a timeout (fixes hanging network/builds)
# Usage: run_with_retry <max_attempts> <timeout_sec> <command> [args...]
run_with_retry() {
    local max_attempts=$1
    local timeout_sec=$2
    shift 2
    local count=1
    while [ $count -le "$max_attempts" ]; do
        if timeout "$timeout_sec" "$@"; then return 0; fi
        if [ $count -lt "$max_attempts" ]; then
            printf "${LOG_INDENT}      ${YELLOW}⚠️  Trop long ou échec (Essai $count/$max_attempts). Nouvelle tentative...${NO_COLOR}\n" >&2
            sleep 2
            count=$((count + 1))
        else return 1; fi
    done
}

# Wrapper for FZF to enforce consistent style
run_fzf() {
    fzf --height=12 --layout=reverse --border --inline-info "$@"
}





# =================================
# ======= ENVIRONMENT SETUP =======
# =================================

if [ ! -t 1 ]; then
    printf "%s❌ Erreur: terminal interactif requis.%s\n" "${RED}" "${NO_COLOR}" >&2
    exit 1
fi

# Determine if running locally (file exists) or via pipe/curl
IS_LOCAL=false
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    IS_LOCAL=true
fi

# Create a secure temporary directory
# -d: Create a directory instead of a file
# -t: Use system temp path (/tmp) with the given name template (XXXXXX ensures uniqueness)
    TEMP_DIR=$(mktemp -d -t ergopti-install.XXXXXX)

cleanup() {
    # Capture exit code to preserve it
    local exit_code=$?
    
    # Safety: Ensure cursor is visible if script crashes during download
    tput cnorm >/dev/null 2>&1 || true
    
    # Safety check: ensure variable is set/not empty AND directory exists
    # "${TEMP_DIR:-}" prevents 'unbound variable' error if TEMP_DIR was never set
    if [ -n "${TEMP_DIR:-}" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
    
    exit "$exit_code"
}

# Run cleanup before any EXIT (normal end) or signals (Ctrl+C, termination)
trap cleanup EXIT INT TERM





# ================================
# ======= DEPENDENCY CHECK =======
# ================================

log_section "Vérification des dépendances"

# Install git if missing
if ! command -v git >/dev/null 2>&1 && [ -f /etc/os-release ]; then
    printf "${LOG_INDENT}Git non trouvé. Tentative d'installation automatique...\n"
    . /etc/os-release
    case $ID in
        fedora) sudo dnf install -y git ;;
        debian|ubuntu|linuxmint|pop) sudo apt-get update && sudo apt-get install -y git ;;
        arch|manjaro|endeavouros) sudo pacman -S --noconfirm git ;;
        solus) sudo eopkg it -y git ;;
        opensuse*) sudo zypper install -y git ;;
    esac
fi

for cmd in git python3 curl; do
    run_step "Vérification de $cmd" "$cmd disponible" command -v "$cmd"
done





# ==============================
# ======= FZF MANAGEMENT =======
# ==============================

log_section "Vérification de la disponibilité de fzf"
if ! command -v fzf >/dev/null 2>&1; then
    printf "${LOG_INDENT}${YELLOW}⚠️  Fzf non trouvé. Lancement de l’installation locale...${NO_COLOR}\n"
    LOG_INDENT="${LOG_INDENT}   " # Add indentation dynamically (add 3 spaces)
    
    run_step "Téléchargement de fzf" "Code source récupéré" \
        run_with_retry 3 20 git clone --depth 1 https://github.com/junegunn/fzf.git "$TEMP_DIR/fzf"
    run_step "Compilation de fzf" "Binaire généré et prêt" \
        run_with_retry 3 60 "$TEMP_DIR/fzf/install" --bin --no-update-rc --no-key-bindings --no-completion
    
    LOG_INDENT="${LOG_INDENT%   }" # Remove indentation dynamically (remove last 3 spaces)
    export PATH="$TEMP_DIR/fzf/bin:$PATH"
else
    printf "${LOG_INDENT}${GREEN}✅ Fzf est déjà installé sur le système${NO_COLOR}\n"
fi





# ==============================================
# ======= SOURCE PREPARATION (METADATA) ========
# ==============================================

if [ "$IS_LOCAL" = true ]; then
    log_section "Mode local détecté"
    # Resolve script location
    SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
    # Drivers root is the parent folder of the script (linux/)
    DRIVERS_ROOT="$(dirname "$SCRIPT_DIR")"
    printf "${LOG_INDENT}Analyse des fichiers locaux dans : ${BOLD}$DRIVERS_ROOT${NO_COLOR}\n"

else
    # --- REMOTE MODE: FETCH METADATA ONLY ---
    log_section "Connexion au dépôt distant ($SELECTED_BRANCH)"
    REPO_DIR="$TEMP_DIR/repo"

    printf "${LOG_INDENT}Initialisation du dépôt...\n"
    # 1. Initialize empty repo
    git init "$REPO_DIR" >/dev/null 2>&1
    cd "$REPO_DIR"
    git remote add origin "$REPO_URL" >/dev/null 2>&1

    # 2. Fetch only metadata (blobless clone) - Very Fast
    run_step "Récupération de la liste des fichiers" "Métadonnées synchronisées" \
        git fetch --depth 1 --filter=blob:none origin "$SELECTED_BRANCH"
        
    DRIVERS_ROOT="$REPO_DIR/$TARGET_DIR"
fi





# ============================================
# ======= 1. RELEASE SELECTION ===============
# ============================================

printf "\n${LOG_INDENT}${BOLD}Sélection de la version${NO_COLOR}\n"

if [ "$IS_LOCAL" = true ]; then
    # Local: Find directories
    mapfile -t RELEASES < <(find "$DRIVERS_ROOT" -maxdepth 1 -type d -name "v*" | sort -rV)
else
    # Remote: List directories from the fetched tree without downloading files
    # Syntax: git ls-tree -d --name-only origin/branch:path/to/dir
    mapfile -t RELEASES < <(git ls-tree -d --name-only "origin/$SELECTED_BRANCH:$TARGET_DIR" | grep "^v" | sort -rV)
fi

if [ ${#RELEASES[@]} -eq 0 ]; then
    printf "${LOG_INDENT}${YELLOW}⚠️  Aucune version détectée. Utilisation de la racine.${NO_COLOR}\n"
    SELECTED_NAME=""
else
    # Build list for FZF
    RELEASE_LIST=""
    for r in "${RELEASES[@]}"; do
        # Replace underscore with dot for better UI
        raw_name=$(basename "$r")
        RELEASE_LIST="${RELEASE_LIST}${raw_name//_/.}\n"
    done
    
    # Select
    SELECTED_NAME=$(printf "%b" "$RELEASE_LIST" | run_fzf --prompt="Version > " --header="Sélectionnez la version du layout (Entrée = Plus récente)")
    if [ -z "$SELECTED_NAME" ]; then printf "\nAnnulé.\n"; exit 0; fi
fi

# Revert dot to underscore to find the directory/path
REAL_NAME="${SELECTED_NAME//./_}"
printf "${LOG_INDENT}${GREEN}➡️ Version choisie : ${SELECTED_NAME:-Racine}${NO_COLOR}\n"





# ============================================
# ======= 2. VARIANT & OPTIONS ANALYSIS ======
# ============================================

# To optimize download, we analyze variants *before* downloading the content.
# We need the list of files in the selected version folder.

if [ "$IS_LOCAL" = true ]; then
    # Local: just ls
    if [ -n "$REAL_NAME" ]; then
        TARGET_PATH="$DRIVERS_ROOT/$REAL_NAME"
    else
        TARGET_PATH="$DRIVERS_ROOT"
    fi
    FILE_LIST=$(find "$TARGET_PATH" -maxdepth 1 -name "*")
else
    # Remote: git ls-tree the specific folder
    if [ -n "$REAL_NAME" ]; then
        REMOTE_PATH="$TARGET_DIR/$REAL_NAME"
    else
        REMOTE_PATH="$TARGET_DIR"
    fi
    FILE_LIST=$(git ls-tree --name-only "origin/$SELECTED_BRANCH:$REMOTE_PATH")
fi

printf "\n${LOG_INDENT}${BOLD}Configuration de l'installation${NO_COLOR}\n"

# --- VARIANT DETECTION ---
HAS_NORMAL=false
HAS_PLUS=false
HAS_PLUS_PLUS=false

# We parse the file list (local or remote)
while IFS= read -r file; do
    filename=$(basename "$file")
    # Convert to lowercase for comparison
    filename_lower="${filename,,}"
    
    if [[ "$filename_lower" == *"ergopti"* ]]; then
        if [[ "$filename_lower" == *"_plus_plus.xkb" ]]; then
            HAS_PLUS_PLUS=true
        elif [[ "$filename_lower" == *"_plus.xkb" ]]; then
            HAS_PLUS=true
        else
            HAS_NORMAL=true
        fi
    fi
done <<< "$FILE_LIST"

VARIANTS_MENU=""
if $HAS_NORMAL; then VARIANTS_MENU="${VARIANTS_MENU}1. Ergopti (Standard)\n"; fi
if $HAS_PLUS; then VARIANTS_MENU="${VARIANTS_MENU}2. Ergopti+ (À utiliser avec Espanso)\n"; fi
if $HAS_PLUS_PLUS; then VARIANTS_MENU="${VARIANTS_MENU}3. Ergopti++ (Déconseillé, pour tests uniquement)\n"; fi

if [ -z "$VARIANTS_MENU" ]; then
    printf "${LOG_INDENT}${RED}❌ Erreur : Aucun fichier Ergopti .xkb trouvé dans cette version.${NO_COLOR}\n"
    exit 1
fi

SELECTED_VARIANT_RAW=$(printf "%b" "$VARIANTS_MENU" | run_fzf --prompt="Variante > " --header="Sélectionnez la variante")
if [ -z "$SELECTED_VARIANT_RAW" ]; then printf "\nAnnulé.\n"; exit 0; fi

# Map selection back to suffix
SUFFIX=""
case "$SELECTED_VARIANT_RAW" in
    *"Ergopti++"*) SUFFIX="_plus_plus" ;;
    *"Ergopti+"*)  SUFFIX="_plus" ;;
    *)             SUFFIX="" ;;
esac

# Resolve XKB filename from the list (Local or Remote)
if [ -z "$SUFFIX" ]; then
    XKB_FILENAME=$(echo "$FILE_LIST" | grep -i "ergopti" | grep -i ".xkb$" | grep -iv "_plus" | head -n 1)
else
    XKB_FILENAME=$(echo "$FILE_LIST" | grep -i "ergopti" | grep -i "${SUFFIX}.xkb$" | head -n 1)
fi
XKB_FILENAME=$(basename "$XKB_FILENAME") # Ensure we just have the filename

if [ -z "$XKB_FILENAME" ]; then printf "${RED}❌ Erreur interne : Fichier variante introuvable.${NO_COLOR}\n"; exit 1; fi

printf "${LOG_INDENT}${GREEN}➡️ Variante : $SELECTED_VARIANT_RAW${NO_COLOR}\n"

# --- XCOMPOSE DETECTION ---
BASENAME="${XKB_FILENAME%.*}" # Remove extension
XCOMPOSE_FILENAME=$(echo "$FILE_LIST" | grep -i "${BASENAME}.XCompose" | head -n 1)
XCOMPOSE_FILENAME=$(basename "$XCOMPOSE_FILENAME")

if [ -n "$XCOMPOSE_FILENAME" ]; then
    printf "${LOG_INDENT}${GREEN}➡️ XCompose : Inclus (automatique)${NO_COLOR}\n"
else
    printf "${LOG_INDENT}${YELLOW}➡️ XCompose : Non trouvé${NO_COLOR}\n"
fi

# --- TYPES SELECTION ---
TYPES_MENU="1. Sans Ctrl ZXCV sur voyelles accentuées (Recommandé)\n2. Complet (Standard)\n3. Aucun (Déconseillé, risque de générer des erreurs)"

TYPES_CHOICE_RAW=$(printf "%b" "$TYPES_MENU" | run_fzf --prompt="Types > " --header="Configuration du comportement des touches (Types)")
if [ -z "$TYPES_CHOICE_RAW" ]; then printf "\nAnnulé.\n"; exit 0; fi

TYPES_FILENAME=""
case "$TYPES_CHOICE_RAW" in
    "1."*) TYPES_FILENAME=$(echo "$FILE_LIST" | grep -i "xkb_types_without_ctrl.txt" | head -n 1) ;;
    "2."*) TYPES_FILENAME=$(echo "$FILE_LIST" | grep -i "xkb_types.txt" | head -n 1) ;;
    *)     TYPES_FILENAME="" ;;
esac
TYPES_FILENAME=$(basename "$TYPES_FILENAME")

if [ -n "$TYPES_FILENAME" ]; then
    printf "${LOG_INDENT}${GREEN}➡️ Types : $TYPES_FILENAME${NO_COLOR}\n"
else
    printf "${LOG_INDENT}${YELLOW}➡️ Types : Aucun${NO_COLOR}\n"
fi





# ============================================
# ======= 3. DOWNLOAD CONTENT (REMOTE) =======
# ============================================

if [ "$IS_LOCAL" = false ]; then
    log_section "Téléchargement ciblé"
    
    # Construct base path inside repo
    if [ -n "$REAL_NAME" ]; then
        BASE_PATH="$TARGET_DIR/$REAL_NAME"
    else
        BASE_PATH="$TARGET_DIR"
    fi
    
    git config core.sparseCheckout true
    
    # 1. Add Install Scripts (Recursively)
    echo "$TARGET_DIR/$INSTALLER_REL_PATH" >> .git/info/sparse-checkout
    
    # 2. Add ONLY selected files (File Sparse)
    echo "$BASE_PATH/$XKB_FILENAME" >> .git/info/sparse-checkout
    
    if [ -n "$XCOMPOSE_FILENAME" ]; then
        echo "$BASE_PATH/$XCOMPOSE_FILENAME" >> .git/info/sparse-checkout
    fi
    
    if [ -n "$TYPES_FILENAME" ]; then
        echo "$BASE_PATH/$TYPES_FILENAME" >> .git/info/sparse-checkout
    fi
    
    # 3. Checkout (Download ONLY these specific files)
    run_step "Téléchargement des fichiers" "Fichiers récupérés" \
        git checkout "$SELECTED_BRANCH"
        
    # Set paths for execution (Remote)
    SELECTED_VERSION_DIR="$REPO_DIR/$BASE_PATH"
    DRIVERS_ROOT="$REPO_DIR/$TARGET_DIR"
else
    # Set paths for execution (Local)
    if [ -n "$REAL_NAME" ]; then
        SELECTED_VERSION_DIR="$DRIVERS_ROOT/$REAL_NAME"
    else
        SELECTED_VERSION_DIR="$DRIVERS_ROOT"
    fi
fi





# ================================
# ======= EXECUTION PHASE ========
# ================================

log_section "Préparation de l'installation"

INSTALLER_SCRIPTS_DIR="$DRIVERS_ROOT/$INSTALLER_REL_PATH"

# Par défaut : Legacy
INSTALLER_SCRIPT="$SCRIPT_NAME_LEGACY"
INSTALLER_METHOD="Legacy (Système)"

# Tentative de détection de la méthode "Clean"
# On ne redirige PAS la sortie pour permettre les questions interactives (o/N)
if [ -f "$INSTALLER_SCRIPTS_DIR/detect_installation_method.sh" ]; then
    if bash "$INSTALLER_SCRIPTS_DIR/detect_installation_method.sh"; then
            INSTALLER_SCRIPT="$SCRIPT_NAME_CLEAN"
            INSTALLER_METHOD="Clean (Utilisateur/Ext)"
    fi
fi

INSTALLER_FULL_PATH="$INSTALLER_SCRIPTS_DIR/$INSTALLER_SCRIPT"
if [ ! -f "$INSTALLER_FULL_PATH" ]; then
     printf "${LOG_INDENT}${RED}❌ Erreur : Script d'installation introuvable : %s${NO_COLOR}\n" "$INSTALLER_FULL_PATH"
     exit 1
fi

# Build arguments using FULL PATHS
XKB_FULL_PATH=$(realpath "$SELECTED_VERSION_DIR/$XKB_FILENAME")

XCOMPOSE_ARG=""
if [ -n "$XCOMPOSE_FILENAME" ]; then
    XCOMPOSE_ARG="--xcompose $(realpath "$SELECTED_VERSION_DIR/$XCOMPOSE_FILENAME")"
fi

TYPES_ARG=""
if [ -n "$TYPES_FILENAME" ]; then
    TYPES_ARG="--types $(realpath "$SELECTED_VERSION_DIR/$TYPES_FILENAME")"
fi

printf "${LOG_INDENT}Méthode détectée : ${BOLD}$INSTALLER_METHOD${NO_COLOR}\n"
printf "${LOG_INDENT}Le script va maintenant demander les droits sudo pour copier les fichiers.\n"

CMD="python3 $INSTALLER_FULL_PATH --xkb $XKB_FULL_PATH $XCOMPOSE_ARG $TYPES_ARG"

printf "\n🚀 Exécution de l'installateur...\n"
tput cnorm >/dev/null 2>&1 || true

# Execute with sudo
sudo $CMD
