#!/bin/bash

# ==================================================
# ==================================================
# ==================================================
# ======= XKB installation method detector =========
# ==================================================
# ==================================================
# ==================================================

# Probe for libxkbcommon version to decide installation method.
# Exit 0 = Clean method (User path)
# Exit 1 = Legacy method (System path)

set -euo pipefail
# -e: Exit immediately if a command exits with a non-zero status
# -u: Treat unset variables as an error
# -o pipefail: Return value of a pipeline is the status of the last command to exit with a non-zero status

# --- NEW: Environment setup to see the compiled version immediately ---
export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/usr/local/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"
export LD_LIBRARY_PATH="/usr/local/lib:/usr/local/lib64:${LD_LIBRARY_PATH:-}"



# ======================================
# ======= CONFIGURATION & COLORS =======
# ======================================

# Minimum required version for Clean method
MIN_VER="1.13.0"

# ANSI Colors
RED=$(printf '\033[31m')
GREEN=$(printf '\033[32m')
YELLOW=$(printf '\033[33m')
BLUE=$(printf '\033[34m')
BOLD=$(printf '\033[1m')
NO_COLOR=$(printf '\033[0m')





# ===========================================
# ======= HELPER: VERSION COMPARISON ========
# ===========================================

# Compare two versions (v1 >= v2)
# Returns 0 (True) if v1 >= v2, 1 (False) otherwise.
version_ge() {
    local v1=$1
    local v2=$2
    
    # Split version strings into arrays by dot
    IFS='.' read -r -a a <<< "$v1"
    IFS='.' read -r -a b <<< "$v2"
    
    # Fill missing patch version with 0 (e.g. "1.13" -> "1.13.0")
    [ -z "${a[2]}" ] && a[2]=0
    [ -z "${b[2]}" ] && b[2]=0

    # Compare Major
    if (( ${a[0]} > ${b[0]} )); then return 0; fi
    if (( ${a[0]} < ${b[0]} )); then return 1; fi

    # Compare Minor
    if (( ${a[1]} > ${b[1]} )); then return 0; fi
    if (( ${a[1]} < ${b[1]} )); then return 1; fi

    # Compare Patch
    if (( ${a[2]} >= ${b[2]} )); then return 0; fi
    
    return 1
}





# ===========================================
# ======= HELPER: GET SYSTEM VERSION ========
# ===========================================

# Extract clean version string (X.Y or X.Y.Z) from text
extract_version() {
    echo "$1" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 || true
}

get_system_lib_version() {
    # List of commands to try in order
    local cmds=(
        "pkg-config --modversion xkbcommon"
        "pkg-config --modversion xkbcommon-x11"
        "dpkg-query -W -f=\${Version} libxkbcommon0"
        "rpm -q --queryformat '%{VERSION}' libxkbcommon"
    )

    for cmd_str in "${cmds[@]}"; do
        local bin_name=$(echo "$cmd_str" | awk '{print $1}')
        
        if command -v "$bin_name" >/dev/null 2>&1; then
            local output
            # Run command, capture stdout, silence stderr
            output=$(eval "$cmd_str" 2>/dev/null) || true
            
            if [ -n "$output" ]; then
                local parsed=$(extract_version "$output")
                if [ -n "$parsed" ]; then
                    echo "$parsed"
                    return 0
                fi
            fi
        fi
    done
    
    return 1
}





# ===========================================
# ======= HELPER: UPDATE ATTEMPT ============
# ===========================================

try_update_lib() {
    echo
    printf "${YELLOW}⚠️  Votre version de libxkbcommon est ancienne ou introuvable.${NO_COLOR}\n"
    printf "   Une version plus récente (>= %s) permet une installation\n" "$MIN_VER"
    printf "   ${BOLD}plus propre${NO_COLOR} (dans votre dossier utilisateur sans toucher au système).\n"
    echo
    
    # --- 1. IMMUTABLE SYSTEM CHECK ---
    # Check for SteamOS or OSTree based systems (Silverblue, Kinoite, etc.)
    local is_immutable=false
    if [ -f /etc/os-release ]; then
        if grep -q "ID=steamos" /etc/os-release || grep -q "VARIANT_ID=silverblue" /etc/os-release || grep -q "ostree=" /proc/cmdline 2>/dev/null; then
            is_immutable=true
        fi
    fi

    if [ "$is_immutable" = true ]; then
        printf "   ${RED}Système immuable détecté (SteamOS / OSTree).${NO_COLOR}\n"
        printf "   La compilation système est impossible ou déconseillée.\n"
        printf "   Passage automatique en mode Legacy.\n"
        return 1
    fi

    # --- 2. PROMPT ---
    # Prompt user (Default Yes)
    read -p "   Voulez-vous télécharger et compiler la dernière version ? (O/n) " -n 1 -r
    echo
    
    # If input is n or N, we cancel. Anything else (including Enter) is Yes.
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        return 1
    fi

    printf "   ${BLUE}1. Installation des outils de compilation...${NO_COLOR}\n"

    # --- 3. EXECUTE UPDATE (SOURCE COMPILE) ---
    if [ -f /etc/os-release ]; then . /etc/os-release; fi
    local DISTRO=${ID:-unknown}

    case $DISTRO in
        fedora)
            sudo dnf install -y git meson ninja-build gcc gcc-c++ bison flex libxml2-devel libxkbcommon-devel wayland-devel wayland-protocols-devel libxcb-devel ;;
        arch|manjaro|endeavouros)
            sudo pacman -S --needed --noconfirm git meson ninja bison flex libxml2 wayland wayland-protocols gcc libxcb ;;
        solus)
            sudo eopkg it -c system.devel -y && sudo eopkg it -y libxml2-devel wayland-devel ;;
        debian|ubuntu|pop|linuxmint)
            sudo apt update && sudo apt install -y git meson ninja-build bison flex libxml2-dev libwayland-dev libxkbcommon-dev wayland-protocols g++ libxcb-xkb-dev libxcb1-dev ;;
        *)
            echo "Distro inconnue, tentative d'installation générique impossible." ;;
    esac

    printf "   ${BLUE}2. Compilation depuis les sources...${NO_COLOR}\n"

    local BUILD_DIR="xkb_build_temp"
    rm -rf "$BUILD_DIR"
    git clone https://github.com/xkbcommon/libxkbcommon.git "$BUILD_DIR" || return 1
    cd "$BUILD_DIR"

    # Last available tag logic
    local LATEST_TAG
    LATEST_TAG=$(git tag -l "xkbcommon-*" | sort -V | tail -n 1)
    [ -z "$LATEST_TAG" ] && LATEST_TAG=$(git tag -l | sort -V | tail -n 1)
    
    printf "   --> Version : ${BOLD}$LATEST_TAG${NO_COLOR}\n"
    git checkout "$LATEST_TAG"

    if meson setup build --prefix=/usr/local --libdir=lib -Denable-docs=false -Denable-wayland=true; then
        ninja -C build
        sudo ninja -C build install
        cd ..
        rm -rf "$BUILD_DIR"
        return 0
    else
        cd ..
        rm -rf "$BUILD_DIR"
        return 1
    fi
}





# =================================
# ======= MAIN LOGIC flow =========
# =================================

# 1. First check of the version
CURRENT_VER=$(get_system_lib_version || echo "")

if [ -n "$CURRENT_VER" ] && version_ge "$CURRENT_VER" "$MIN_VER"; then
    echo "✅ libxkbcommon $CURRENT_VER détectée (>= $MIN_VER)"
    echo "   ➡️ Installation 'Clean' sélectionnée."
    exit 0
fi

# 2. If we are here, version is too old or missing. Propose Update.
try_update_lib || true # Prevent script exit on "no" answer due to -e
UPDATE_STATUS=$?

if [ $UPDATE_STATUS -eq 0 ]; then
    # Re-check after update attempt
    CURRENT_VER=$(get_system_lib_version || echo "")
    
    if [ -n "$CURRENT_VER" ] && version_ge "$CURRENT_VER" "$MIN_VER"; then
        echo "✅ Mise à jour réussie : libxkbcommon $CURRENT_VER"
        echo "   ➡️ Installation 'Clean' sélectionnée."
        echo "   (Note: Ajoutez /usr/local/lib/pkgconfig à PKG_CONFIG_PATH dans votre .bashrc)"
        exit 0
    fi
fi

# 3. Final Fallback to Legacy
STATUS_MSG="non trouvée"
[ -n "$CURRENT_VER" ] && STATUS_MSG="version $CURRENT_VER"

echo "❌ libxkbcommon $STATUS_MSG (< $MIN_VER minimum requis)"
if [ $UPDATE_STATUS -eq 0 ]; then
    echo "   (Même après tentative, la version système reste insuffisante)"
fi
echo "   ➡️ Installation 'Legacy' (Système) sélectionnée."
exit 1
