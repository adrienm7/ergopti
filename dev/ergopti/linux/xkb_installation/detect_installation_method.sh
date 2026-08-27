#!/bin/bash

# ==============================================================================
# Installation method detector for the Ergopti XKB layout.
#
# Decides between the two installation methods:
#   exit 0 -> clean   (XKB extensions directories, libxkbcommon >= 1.13 and
#                      xkeyboard-config >= 2.45, Wayland session)
#   exit 1 -> legacy  (direct modification of the system XKB tree)
#
# The session type matters as much as the library versions: only libxkbcommon
# reads the extensions directories. Xorg compiles keymaps with its own xkbcomp
# from the legacy tree, so a clean install is invisible to an X11 session even
# on a fully up-to-date host. When the session type cannot be determined (SSH,
# console), the legacy method is chosen because it works everywhere.
#
# The detector is strictly read-only: it never installs nor compiles anything.
# The previous behaviour of offering to build libxkbcommon into /usr/local was
# removed on purpose: a second library copy changes the registry paths seen by
# applications and produced hard-to-diagnose setups (issue #84 class).
# ==============================================================================

set -euo pipefail

MIN_XKBCOMMON="1.13.0"
MIN_XKEYBOARDCONFIG="2.45.0"
# xkeyboard-config >= 2.45 installs its data in this versioned directory; the
# historical /usr/share/X11/xkb becomes a compatibility symlink to it.
VERSIONED_DATA_DIR="/usr/share/xkeyboard-config-2"

RED=$(printf '\033[31m')
GREEN=$(printf '\033[32m')
YELLOW=$(printf '\033[33m')
BOLD=$(printf '\033[1m')
NO_COLOR=$(printf '\033[0m')

# ---------------------------------------------------------------------------
# Version helpers
# ---------------------------------------------------------------------------

version_ge() {
    local v1=$1 v2=$2
    local -a a b
    IFS='.' read -r -a a <<< "$v1"
    IFS='.' read -r -a b <<< "$v2"
    for i in 0 1 2; do
        a[$i]=${a[$i]:-0}
        b[$i]=${b[$i]:-0}
    done
    if ((10#${a[0]} > 10#${b[0]})); then return 0; fi
    if ((10#${a[0]} < 10#${b[0]})); then return 1; fi
    if ((10#${a[1]} > 10#${b[1]})); then return 0; fi
    if ((10#${a[1]} < 10#${b[1]})); then return 1; fi
    ((10#${a[2]} >= 10#${b[2]}))
}

extract_version() {
    printf '%s' "$1" | grep -oE '[0-9]+(\.[0-9]+){1,2}' | head -n 1 || true
}

# ---------------------------------------------------------------------------
# Session detection
# ---------------------------------------------------------------------------

session_kind() {
    local declared="${XDG_SESSION_TYPE:-}"
    declared="${declared,,}"
    case "$declared" in
        wayland | x11)
            printf '%s' "$declared"
            return
            ;;
    esac
    if [ -n "${WAYLAND_DISPLAY:-}" ]; then
        printf 'wayland'
    elif [ -n "${DISPLAY:-}" ]; then
        printf 'x11'
    else
        printf 'unknown'
    fi
}

# ---------------------------------------------------------------------------
# Package probes (first hit wins). The library's own tool comes first because
# it is distribution-independent; the package managers cover hosts without it.
# Arch relies on pacman, which the previous detector missed entirely, pushing
# Arch users towards a source build or the legacy path even on up-to-date
# systems.
# ---------------------------------------------------------------------------

probe_version() {
    local bin=$1
    shift
    command -v "$bin" >/dev/null 2>&1 || return 1
    local output=""
    output=$("$@" 2>/dev/null) || return 1
    [ -n "$output" ] || return 1
    local version
    version=$(extract_version "$output")
    [ -n "$version" ] || return 1
    printf '%s' "$version"
}

probe_libxkbcommon() {
    probe_version xkbcli xkbcli --version \
        || probe_version pkg-config pkg-config --modversion xkbcommon \
        || probe_version pacman pacman -Q libxkbcommon \
        || probe_version dpkg-query dpkg-query -W '-f=${Version}' libxkbcommon0 \
        || probe_version rpm rpm -q --queryformat '%{VERSION}' libxkbcommon \
        || probe_version rpm rpm -q --queryformat '%{VERSION}' libxkbcommon0 \
        || probe_version apk apk list --installed libxkbcommon \
        || probe_version xbps-query xbps-query -p pkgver libxkbcommon
}

probe_xkeyboardconfig() {
    # Debian and Ubuntu package xkeyboard-config as xkb-data.
    probe_version pkg-config pkg-config --modversion xkeyboard-config \
        || probe_version pacman pacman -Q xkeyboard-config \
        || probe_version dpkg-query dpkg-query -W '-f=${Version}' xkb-data \
        || probe_version rpm rpm -q --queryformat '%{VERSION}' xkeyboard-config \
        || probe_version apk apk list --installed xkeyboard-config \
        || probe_version xbps-query xbps-query -p pkgver xkeyboard-config
}

# ---------------------------------------------------------------------------
# Main decision
# ---------------------------------------------------------------------------

SESSION=$(session_kind)
LIB_VER=$(probe_libxkbcommon || true)
XKC_VER=$(probe_xkeyboardconfig || true)
XKC_SOURCE="paquet"
if [ -z "$XKC_VER" ] && [ -d "$VERSIONED_DATA_DIR" ]; then
    # No package manager answered, but the versioned data directory only
    # exists since xkeyboard-config 2.45.
    XKC_VER="$MIN_XKEYBOARDCONFIG"
    XKC_SOURCE="déduit de $VERSIONED_DATA_DIR"
fi

echo "Session graphique          : $SESSION"
echo "Version libxkbcommon       : ${LIB_VER:-<introuvable>}"
echo "Version xkeyboard-config   : ${XKC_VER:-<introuvable>} ($XKC_SOURCE)"

case "$SESSION" in
    x11)
        printf "%s\n" "${YELLOW}ℹ️  Session X11 (Xorg) : le serveur X compile les dispositions avec xkbcomp, qui ignore les répertoires d'extensions XKB → méthode Legacy.${NO_COLOR}"
        echo "METHOD=legacy"
        exit 1
        ;;
    unknown)
        printf "%s\n" "${YELLOW}⚠️  Type de session indéterminé (ni Wayland ni X11 détecté) : la méthode Clean n'est visible que des sessions Wayland → méthode Legacy. Utilisez --installation-method clean si vous êtes sous Wayland.${NO_COLOR}"
        echo "METHOD=legacy"
        exit 1
        ;;
esac

if [ -z "$LIB_VER" ] || [ -z "$XKC_VER" ]; then
    printf "%s\n" "${YELLOW}⚠️  Impossible de déterminer les versions → méthode Legacy.${NO_COLOR}"
    echo "METHOD=legacy"
    exit 1
fi

if version_ge "$LIB_VER" "$MIN_XKBCOMMON" && version_ge "$XKC_VER" "$MIN_XKEYBOARDCONFIG"; then
    echo "✅ Prérequis Clean réunis (libxkbcommon >= $MIN_XKBCOMMON, xkeyboard-config >= $MIN_XKEYBOARDCONFIG, session Wayland)"
    echo "METHOD=clean"
    exit 0
fi

printf "%s\n" "${YELLOW}ℹ️  Prérequis Clean non réunis (il faut libxkbcommon >= $MIN_XKBCOMMON et xkeyboard-config >= $MIN_XKEYBOARDCONFIG) → méthode Legacy.${NO_COLOR}"
echo "METHOD=legacy"
exit 1
