#!/bin/bash

# ==============================================================================
# Installation method detector for the Ergopti XKB layout.
#
# Decides between the two installation methods:
#   exit 0 -> clean   (XKB extensions directories, libxkbcommon >= 1.13 and
#                      xkeyboard-config >= 2.45)
#   exit 1 -> legacy  (direct modification of the system XKB tree)
#
# The detector is strictly read-only: it never installs nor compiles anything.
# The previous behaviour of offering to build libxkbcommon into /usr/local was
# removed on purpose: a second library copy changes the registry paths seen by
# applications and produced hard-to-diagnose setups (issue #84 class).
# ==============================================================================

set -euo pipefail

MIN_XKBCOMMON="1.13.0"
MIN_XKEYBOARDCONFIG="2.45.0"

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
# Package probes (first hit wins). Arch relies on pacman, which the previous
# detector missed entirely, pushing Arch users towards a source build or the
# legacy path even on up-to-date systems.
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
    probe_version pkg-config pkg-config --modversion xkbcommon \
        || probe_version pacman pacman -Q libxkbcommon \
        || probe_version dpkg-query dpkg-query -W '-f=${Version}' libxkbcommon0 \
        || probe_version rpm rpm -q --queryformat '%{VERSION}' libxkbcommon
}

probe_xkeyboardconfig() {
    probe_version pkg-config pkg-config --modversion xkeyboard-config \
        || probe_version pacman pacman -Q xkeyboard-config \
        || probe_version dpkg-query dpkg-query -W '-f=${Version}' xkeyboard-config \
        || probe_version rpm rpm -q --queryformat '%{VERSION}' xkeyboard-config
}

# ---------------------------------------------------------------------------
# Main decision
# ---------------------------------------------------------------------------

LIB_VER=$(probe_libxkbcommon || true)
XKC_VER=$(probe_xkeyboardconfig || true)

echo "Version libxkbcommon      : ${LIB_VER:-<introuvable>}"
echo "Version xkeyboard-config  : ${XKC_VER:-<introuvable>}"

if [ -z "$LIB_VER" ] || [ -z "$XKC_VER" ]; then
    printf "%s\n" "${YELLOW}⚠️  Impossible de déterminer les versions → méthode Legacy.${NO_COLOR}"
    echo "METHOD=legacy"
    exit 1
fi

if version_ge "$LIB_VER" "$MIN_XKBCOMMON" && version_ge "$XKC_VER" "$MIN_XKEYBOARDCONFIG"; then
    echo "✅ Prérequis Clean réunis (libxkbcommon >= $MIN_XKBCOMMON et xkeyboard-config >= $MIN_XKEYBOARDCONFIG)"
    echo "METHOD=clean"
    exit 0
fi

printf "%s\n" "${YELLOW}ℹ️  Prérequis Clean non réunis (il faut libxkbcommon >= $MIN_XKBCOMMON et xkeyboard-config >= $MIN_XKEYBOARDCONFIG) → méthode Legacy.${NO_COLOR}"
echo "METHOD=legacy"
exit 1
