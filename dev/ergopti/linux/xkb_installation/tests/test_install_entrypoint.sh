#!/usr/bin/env bash

# ==============================================================================
# Exercises the real shell entry point (install.sh) in isolated filesystems.
#
# Every scenario runs the actual script against temporary XKB roots through the
# ERGOPTI_XKB_* overrides, with stand-ins for the tools the script drives
# (sudo, fzf, gsettings, xkbcli, xkbcomp). The stand-ins are stateful where the
# script reads back what it wrote, because a fake that always answers the same
# thing hides exactly the silent failure of issue #84. The real compilers are
# covered by test_xkb_toolchain.py and by the distribution matrix.
# ==============================================================================

# -E propagates the ERR trap into the scenario functions: most assertions here
# are bare `grep -q` over a log file, so without the trap errexit aborts the
# whole suite with an exit code and not a single line of output — a CI failure
# nobody can read.
set -Eeuo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
INSTALLER_DIR=$(dirname "$TEST_DIR")
LINUX_DIR=$(dirname "$INSTALLER_DIR")
TMP_ROOT=$(mktemp -d -t ergopti-install-entrypoint.XXXXXX)

cleanup() {
    rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT
trap 'printf "install entrypoint tests: FAILED at %s:%s -> %s\n" \
    "${BASH_SOURCE[0]##*/}" "$LINENO" "$BASH_COMMAND" >&2' ERR

FAKE_BIN="$TMP_ROOT/bin"
ISOLATED_EXTERNAL_BIN="$TMP_ROOT/external-bin"
mkdir -p "$FAKE_BIN" "$ISOLATED_EXTERNAL_BIN" "$TMP_ROOT/home"
export ISOLATED_EXTERNAL_BIN
cat > "$FAKE_BIN/fzf" <<'EOF'
#!/bin/sh
printf 'called\n' >> "$FZF_MARKER"
exit 97
EOF
# SUDO_PLANT_LOCKED_DIR reproduces what a real privileged run leaves behind:
# root-owned files inside the user's temporary checkout that the user cannot
# delete afterwards (bytecode caches, in the field).
cat > "$FAKE_BIN/sudo" <<'EOF'
#!/bin/sh
command_path=$(command -v "$1") || exit 127
shift
if [ "${SUDO_PLANT_LOCKED_DIR:-}" = 1 ]; then
    for directory in "${TMPDIR:-/tmp}"/ergopti-install.*; do
        [ -d "$directory" ] || continue
        mkdir -p "$directory/locked"
        : > "$directory/locked/keep"
        chmod 555 "$directory/locked"
    done
fi
ERGOPTI_TEST_ELEVATED=1 PATH="$ISOLATED_EXTERNAL_BIN" exec "$command_path" "$@"
EOF
# Stateful on purpose: the installer reads the value back after writing it, so
# a fake that always returns the empty list would hide a write that never
# sticks — the exact silent failure of issue #84.
cat > "$FAKE_BIN/gsettings" <<'EOF'
#!/bin/sh
if [ "${ERGOPTI_TEST_ELEVATED:-}" = 1 ]; then
    printf 'elevated\n' >> "$GSETTINGS_ELEVATED_MARKER"
    printf 'desktop activation ran with elevated privileges\n' >&2
    exit 98
fi
printf '%s\n' "$*" >> "$GSETTINGS_LOG"
case "$1" in
    get)
        if [ -s "$GSETTINGS_STATE" ]; then
            cat "$GSETTINGS_STATE"
        else
            printf '@a(ss) []\n'
        fi
        ;;
    set)
        shift 3
        printf '%s\n' "$1" > "$GSETTINGS_STATE"
        ;;
esac
EOF
# Stand-ins for the compilers: they dump the keymap named by FAKE_KEYMAP, so a
# scenario can hand the entry point a working layout or the dead one of
# issue #84 and observe how the script reacts. They use shell builtins only:
# under the fake sudo the PATH holds nothing but this directory.
cat > "$FAKE_BIN/xkbcli" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${XKBCLI_LOG:-/dev/null}"
case "$1" in
    --version) printf '1.13.1\n' ;;
    compile-keymap) while IFS= read -r line; do printf '%s\n' "$line"; done < "$FAKE_KEYMAP" ;;
    list) printf -- "- layout: 'ergopti'\n" ;;
    *) exit 1 ;;
esac
EOF
cat > "$FAKE_BIN/xkbcomp" <<'EOF'
#!/bin/sh
case "$1" in
    -version) printf 'xkbcomp 1.4.7\n' >&2 ;;
    *) while IFS= read -r line; do printf '%s\n' "$line"; done < "$FAKE_KEYMAP" ;;
esac
EOF
chmod +x "$FAKE_BIN/fzf" "$FAKE_BIN/sudo" "$FAKE_BIN/gsettings" "$FAKE_BIN/xkbcli" "$FAKE_BIN/xkbcomp"
# Reachable from the privileged PATH too, so an activation attempted as root is
# observed and fails the test instead of quietly finding no gsettings at all.
cp "$FAKE_BIN/gsettings" "$ISOLATED_EXTERNAL_BIN/gsettings"
cp "$FAKE_BIN/xkbcli" "$FAKE_BIN/xkbcomp" "$ISOLATED_EXTERNAL_BIN/"

GOOD_KEYMAP="$TMP_ROOT/good.xkb"
DEAD_KEYMAP="$TMP_ROOT/dead.xkb"
cat > "$GOOD_KEYMAP" <<'EOF'
xkb_keymap {
xkb_types "complete" {
	type "ERGOPTI_SEVEN_LEVEL" {
		modifiers= Shift+Lock+Control+Mod4+Alt+LevelThree;
		map[Shift]= 3;
		map[Control]= 5;
		preserve[Control]= Control;
	};
};
xkb_symbols "pc+ergopti+inet(evdev)" {
	key <AD01>               {
		type= "ERGOPTI_SEVEN_LEVEL",
		symbols[1]= [ egrave, Egrave, Egrave, egrave, z, grave, doublelowquotemark ]
	};
};
};
EOF
cat > "$DEAD_KEYMAP" <<'EOF'
xkb_keymap {
xkb_types "complete" { };
xkb_symbols "pc+ergopti+inet(evdev)" {
	key <AD01>               {
		type= "ONE_LEVEL",
		symbols[1]= [ egrave ]
	};
};
};
EOF
export FAKE_KEYMAP="$GOOD_KEYMAP"

run_debian_detector() {
    local detector_bin="$TMP_ROOT/detector-bin"
    mkdir -p "$detector_bin"
    # The detector stops at the first probe that answers, so any probe binary
    # the host happens to ship decides the method instead of the scenario: a
    # runner with libxkbcommon-tools answers `xkbcli --version` with its own
    # 1.6, and the whole Debian scenario silently becomes a legacy one. Stub
    # the entire probe surface, read from the detector itself so that a probe
    # added there later cannot re-open the leak without a stub.
    local probes probe
    probes=$(grep -oE 'probe_version [a-z0-9-]+' \
        "$INSTALLER_DIR/detect_installation_method.sh" | awk '{ print $2 }' | sort -u)
    # A renamed helper would produce an empty list and silently restore the
    # leak this stubbing exists to close.
    if ! grep -qx 'xkbcli' <<< "$probes"; then
        printf 'no probe list read from the detector: %s\n' "$probes" >&2
        return 1
    fi
    while read -r probe; do
        printf '#!/bin/sh\nexit 1\n' > "$detector_bin/$probe"
    done <<< "$probes"
    # Debian and Ubuntu name the data package xkb-data: the detector asks for
    # that name, so the stand-in must answer that name and not the upstream
    # one. Answering the wrong name left the version to be deduced from
    # /usr/share/xkeyboard-config-2, that is, from the host again.
    cat > "$detector_bin/dpkg-query" <<'EOF'
#!/bin/sh
case "$*" in
    *libxkbcommon0) printf '1.13.1-1\n' ;;
    *xkb-data) printf '2.45.0-1\n' ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$detector_bin"/*
    local output
    output=$(XDG_SESSION_TYPE=wayland PATH="$detector_bin:/usr/bin:/bin" \
        bash "$INSTALLER_DIR/detect_installation_method.sh")
    grep -qx 'METHOD=clean' <<< "$output"
    # Same versions under Xorg: the X server compiles with xkbcomp from the
    # legacy tree and never sees extension directories.
    output=$(XDG_SESSION_TYPE=x11 PATH="$detector_bin:/usr/bin:/bin" \
        bash "$INSTALLER_DIR/detect_installation_method.sh" || true)
    grep -qx 'METHOD=legacy' <<< "$output"
    grep -q 'X11' <<< "$output"
    # No session information at all (SSH, console) must not pick a method
    # that only Wayland can see.
    output=$(env -u XDG_SESSION_TYPE -u WAYLAND_DISPLAY -u DISPLAY PATH="$detector_bin:/usr/bin:/bin" \
        bash "$INSTALLER_DIR/detect_installation_method.sh" || true)
    grep -qx 'METHOD=legacy' <<< "$output"
}

write_legacy_fixture() {
    local system="$1"
    mkdir -p "$system/symbols" "$system/types" "$system/rules"
    cat > "$system/symbols/fr" <<'EOF'
partial default alphanumeric_keys
xkb_symbols "basic" {
    include "latin"
    name[Group1]="French";
};
EOF
    cat > "$system/types/extra" <<'EOF'
default partial xkb_types "default" {
    virtual_modifiers LevelThree;

    type "FOUR_LEVEL_X" {
        modifiers = Shift + LevelThree;
        map[Shift] = Level2;
    };
};
EOF
    cat > "$system/rules/evdev.lst" <<'EOF'
! model
  pc105           Generic 105-key PC

! layout
  fr              French

! variant
  oss             fr: French (alt.)

! option
EOF
    cat > "$system/rules/evdev.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<xkbConfigRegistry version="1.1">
  <layoutList>
    <layout>
      <configItem><name>fr</name><description>French</description></configItem>
      <variantList>
        <variant><configItem><name>oss</name><description>French (alt.)</description></configItem></variant>
      </variantList>
    </layout>
  </layoutList>
</xkbConfigRegistry>
EOF
}

# sandbox_env <sandbox> <extra env assignments...>: the environment every
# scenario hands to the entry point.
sandbox_env() {
    local sandbox="$1"
    shift
    env \
        HOME="$TMP_ROOT/home" \
        FZF_MARKER="$sandbox/fzf-called" \
        GSETTINGS_LOG="$sandbox/gsettings.log" \
        GSETTINGS_STATE="$sandbox/gsettings.state" \
        GSETTINGS_ELEVATED_MARKER="$sandbox/gsettings-elevated" \
        XKBCLI_LOG="$sandbox/xkbcli.log" \
        ERGOPTI_INSTALL_LOG="$sandbox/install.log" \
        PATH="$FAKE_BIN:$PATH" \
        ERGOPTI_XKB_EXTENSIONS_ROOT="$sandbox/extensions" \
        ERGOPTI_XKB_SYSTEM_ROOT="$sandbox/system" \
        ERGOPTI_XKB_CACHE_DIR="$sandbox/cache" \
        ERGOPTI_XKB_USER_HOME="$sandbox/home" \
        "$@"
}

run_non_interactive_legacy_install() {
    local sandbox="$TMP_ROOT/legacy-install"
    local local_linux="$sandbox/local tree/linux"
    local output="$sandbox/output.log"
    mkdir -p "$sandbox/extensions" "$sandbox/home"
    write_legacy_fixture "$sandbox/system"
    cp "$sandbox/system/types/extra" "$sandbox/pristine-extra"
    printf "[('xkb', 'us')]\n" > "$sandbox/gsettings.state"
    mkdir -p "$(dirname "$local_linux")"
    cp -R "$LINUX_DIR" "$local_linux"
    if ! sandbox_env "$sandbox" \
        XDG_CURRENT_DESKTOP="GNOME" \
        XDG_SESSION_TYPE="x11" \
        bash "$local_linux/xkb_installation/install.sh" \
            --installation-method legacy \
            --version v2_2_1 \
            --variant ergopti \
            --yes > "$output" 2>&1; then
        cat "$output" >&2
        return 1
    fi
    test ! -e "$sandbox/fzf-called"
    # The type block sits inside the xkb_types section: it precedes the final
    # closing brace and the section count is unchanged.
    local extra="$sandbox/system/types/extra"
    grep -q 'type "ERGOPTI_SEVEN_LEVEL"' "$extra"
    test "$(grep -c 'xkb_types' "$extra")" -eq 1
    test "$(grep -n 'type "ERGOPTI_SEVEN_LEVEL"' "$extra" | cut -d: -f1)" -lt "$(grep -n '^};' "$extra" | tail -1 | cut -d: -f1)"
    cmp -s "$sandbox/pristine-extra" "$extra.1"
    grep -q 'xkb_symbols "Ergopti_v2_2_1"' "$sandbox/system/symbols/fr"
    grep -q '<name>Ergopti_v2_2_1</name>' "$sandbox/system/rules/evdev.xml"
    # Desktop activation uses the fr+variant spelling, first in the list, and
    # never runs with elevated privileges.
    grep -qx "\[('xkb', 'fr+Ergopti_v2_2_1'), ('xkb', 'us')\]" "$sandbox/gsettings.state"
    test ! -e "$sandbox/gsettings-elevated"
    grep -q 'valeur confirmée' "$output"
    # Both compilers were asked to prove the patched tree, with the variant.
    grep -q 'Keymap vérifiée par libxkbcommon' "$output"
    grep -q 'Keymap vérifiée par xkbcomp' "$output"
    grep -q -- '--variant Ergopti_v2_2_1' "$sandbox/xkbcli.log"
    grep -q 'Installation terminée' "$output"
    grep -q 'Disposition  : fr+Ergopti_v2_2_1' "$output"
    # The complete run is also in the log file named at the start.
    grep -q "Journal de cette exécution : $sandbox/install.log" "$output"
    grep -q 'Installation terminée' "$sandbox/install.log"

    if ! sandbox_env "$sandbox" \
        bash "$local_linux/xkb_installation/install.sh" \
            --installation-method legacy --uninstall --yes > "$sandbox/uninstall.log" 2>&1; then
        cat "$sandbox/uninstall.log" >&2
        return 1
    fi
    cmp -s "$sandbox/pristine-extra" "$extra"
    ! grep -q 'Ergopti_v2_2_1' "$sandbox/system/symbols/fr"
    grep -qx "\[('xkb', 'us')\]" "$sandbox/gsettings.state"
    test ! -e "$sandbox/gsettings-elevated"
}

run_non_interactive_install() {
    local sandbox="$TMP_ROOT/non-interactive"
    local local_linux="$sandbox/local tree/linux"
    local output="$sandbox/output.log"
    mkdir -p "$sandbox/system/symbols" "$sandbox/system/rules" "$sandbox/extensions"
    # Seed an existing layout so the ordering rule is observable: starting from
    # an empty list, appending and prepending produce the same value.
    printf "[('xkb', 'us')]\n" > "$sandbox/gsettings.state"
    mkdir -p "$(dirname "$local_linux")"
    cp -R "$LINUX_DIR" "$local_linux"
    : > "$sandbox/system/rules/evdev"
    if ! sandbox_env "$sandbox" \
        XDG_CURRENT_DESKTOP="GNOME" \
        XDG_SESSION_TYPE="wayland" \
        bash "$local_linux/xkb_installation/install.sh" \
            --installation-method clean \
            --version v2_2_1 \
            --variant ergopti \
            --yes > "$output" 2>&1; then
        cat "$output" >&2
        return 1
    fi
    test ! -e "$sandbox/fzf-called"
    test -f "$sandbox/extensions/ergopti/symbols/ergopti"
    grep -q '^get org.gnome.desktop.input-sources sources$' "$sandbox/gsettings.log"
    grep -q '^set org.gnome.desktop.input-sources sources' "$sandbox/gsettings.log"
    # The layout must end up first: GNOME types with the first source listed.
    grep -qx "\[('xkb', 'ergopti'), ('xkb', 'us')\]" "$sandbox/gsettings.state"
    # The privileged half must never touch the session: dconf and D-Bus belong
    # to the user, so a root write silently changes nothing (issue #84).
    test ! -e "$sandbox/gsettings-elevated"
    # The value is read back after the write, so a no-op write cannot pass.
    test "$(grep -c '^get org.gnome.desktop.input-sources sources$' "$sandbox/gsettings.log")" -ge 2
    grep -q 'valeur confirmée' "$output"
    # The staged package and the installed one were both compiled, alone and
    # next to another layout, before the script claimed success.
    grep -q -- '--layout ergopti,us' "$sandbox/xkbcli.log"
    grep -q -- '--layout us,ergopti' "$sandbox/xkbcli.log"
    grep -q 'Keymap vérifiée par libxkbcommon' "$output"
    grep -q 'Disposition activée' "$output"
    grep -q 'Installation terminée' "$output"
}

run_cleanup_failure_is_not_fatal() {
    # A successful installation used to end with exit code 1 when the
    # temporary checkout could not be removed: the privileged run had left
    # root-owned bytecode in it, `rm -rf` failed inside the EXIT trap and
    # `set -e` turned that into the script's status, after the success banner.
    local sandbox="$TMP_ROOT/cleanup-failure"
    local local_linux="$sandbox/local tree/linux"
    local output="$sandbox/output.log"
    mkdir -p "$sandbox/system/symbols" "$sandbox/system/rules" "$sandbox/extensions" "$sandbox/home" "$sandbox/tmp"
    mkdir -p "$(dirname "$local_linux")"
    cp -R "$LINUX_DIR" "$local_linux"
    # The checkout being copied may carry caches from earlier local runs.
    rm -rf "$local_linux/xkb_installation/__pycache__"
    local status=0
    sandbox_env "$sandbox" \
        TMPDIR="$sandbox/tmp" \
        SUDO_PLANT_LOCKED_DIR=1 \
        XDG_CURRENT_DESKTOP="GNOME" \
        XDG_SESSION_TYPE="wayland" \
        bash "$local_linux/xkb_installation/install.sh" \
            --installation-method clean \
            --version v2_2_1 \
            --variant ergopti \
            --yes > "$output" 2>&1 || status=$?
    chmod -R u+w "$sandbox/tmp"
    if [ "$status" -ne 0 ]; then
        printf 'a failed temporary cleanup changed the exit code to %s\n' "$status" >&2
        cat "$output" >&2
        return 1
    fi
    grep -q 'Installation terminée' "$output"
    ! grep -q "L'installeur s'est arrêté" "$output"
    # The privileged interpreter must not write bytecode into the user's
    # checkout in the first place.
    test ! -e "$local_linux/xkb_installation/__pycache__"
}

run_dead_layout_is_refused() {
    # The exact keymap of issue #84 (probe key on ONE_LEVEL) must stop the
    # script before anything is committed, with a non-zero code and the hint.
    local sandbox="$TMP_ROOT/dead-layout"
    local local_linux="$sandbox/local tree/linux"
    local output="$sandbox/output.log"
    mkdir -p "$sandbox/system/symbols" "$sandbox/system/rules" "$sandbox/extensions" "$sandbox/home"
    mkdir -p "$(dirname "$local_linux")"
    cp -R "$LINUX_DIR" "$local_linux"
    local status=0
    sandbox_env "$sandbox" \
        FAKE_KEYMAP="$DEAD_KEYMAP" \
        XDG_CURRENT_DESKTOP="GNOME" \
        XDG_SESSION_TYPE="wayland" \
        bash "$local_linux/xkb_installation/install.sh" \
            --installation-method clean \
            --version v2_2_1 \
            --variant ergopti \
            --yes > "$output" 2>&1 || status=$?
    if [ "$status" -ne 4 ]; then
        printf 'a dead layout returned %s instead of 4\n' "$status" >&2
        cat "$output" >&2
        return 1
    fi
    test ! -e "$sandbox/extensions/ergopti"
    grep -q 'ONE_LEVEL' "$output"
    grep -q 'Commande :' "$output"
    grep -q -- '--diagnose' "$output"
    ! grep -q 'Installation terminée' "$output"
    ! grep -q '^set ' "$sandbox/gsettings.log" 2>/dev/null
}

run_diagnose_mode() {
    local sandbox="$TMP_ROOT/diagnose"
    local local_linux="$sandbox/local tree/linux"
    local output="$sandbox/output.log"
    mkdir -p "$sandbox/system/rules" "$sandbox/extensions/ergopti/symbols" "$sandbox/home"
    printf 'installed\n' > "$sandbox/extensions/ergopti/symbols/ergopti"
    mkdir -p "$(dirname "$local_linux")"
    cp -R "$LINUX_DIR" "$local_linux"
    # No terminal on stdout and no --yes: the diagnostic must still run, it is
    # what a user pipes into a file for a bug report.
    if ! sandbox_env "$sandbox" \
        XDG_CURRENT_DESKTOP="Hyprland" \
        XDG_SESSION_TYPE="wayland" \
        bash "$local_linux/xkb_installation/install.sh" --diagnose > "$output" 2>&1; then
        cat "$output" >&2
        return 1
    fi
    grep -q '=== Système ===' "$output"
    grep -q 'Bureau reconnu' "$output"
    grep -q 'compositor' "$output"
    grep -q 'Fin du diagnostic' "$output"
    grep -q 'Rapport également enregistré' "$output"
    grep -q 'Fin du diagnostic' "$sandbox/install.log"
    test ! -e "$sandbox/gsettings-elevated"
    ! grep -q 'Installation terminée' "$output"
}

run_python_floor_guard() {
    local sandbox="$TMP_ROOT/python-floor"
    local old_bin="$sandbox/old-python"
    local output="$sandbox/output.log"
    mkdir -p "$old_bin" "$sandbox/system/rules" "$sandbox/extensions" "$sandbox/home"
    cat > "$old_bin/python3" <<'EOF'
#!/bin/sh
case "$*" in
    *sys.exit*) exit 1 ;;
    *) printf '3.6.9\n' ;;
esac
EOF
    chmod +x "$old_bin/python3"
    local status=0
    sandbox_env "$sandbox" PATH="$old_bin:$FAKE_BIN:$PATH" PYTHON=python3 \
        bash "$INSTALLER_DIR/install.sh" --diagnose > "$output" 2>&1 || status=$?
    if [ "$status" -eq 0 ]; then
        printf 'an interpreter below the floor was accepted\n' >&2
        cat "$output" >&2
        return 1
    fi
    grep -q 'Python 3.6.9' "$output"
    grep -q 'requiert Python >= 3.8' "$output"
    grep -q 'PYTHON=python3.11' "$output"
    # The override names another interpreter and the same run then succeeds.
    if ! sandbox_env "$sandbox" PATH="$old_bin:$FAKE_BIN:$PATH" PYTHON="$(command -v python3)" \
        bash "$INSTALLER_DIR/install.sh" --diagnose > "$sandbox/override.log" 2>&1; then
        cat "$sandbox/override.log" >&2
        return 1
    fi
    grep -q 'Fin du diagnostic' "$sandbox/override.log"
}

run_unsupported_host_guard() {
    local sandbox="$TMP_ROOT/nixos"
    local output="$sandbox/output.log"
    mkdir -p "$sandbox/system/rules" "$sandbox/extensions" "$sandbox/home"
    printf 'ID=nixos\nPRETTY_NAME="NixOS 25.11"\n' > "$sandbox/os-release"
    local status=0
    sandbox_env "$sandbox" ERGOPTI_OS_RELEASE_FILE="$sandbox/os-release" \
        bash "$INSTALLER_DIR/install.sh" --yes --version v2_2_1 --variant ergopti \
        --installation-method clean > "$output" 2>&1 || status=$?
    if [ "$status" -eq 0 ]; then
        printf 'NixOS was not refused\n' >&2
        cat "$output" >&2
        return 1
    fi
    grep -q 'NixOS' "$output"
    grep -q 'extraLayouts' "$output"
    test ! -e "$sandbox/extensions/ergopti"
}

run_help() {
    local output="$TMP_ROOT/help.log"
    bash "$INSTALLER_DIR/install.sh" --help > "$output" 2>&1
    grep -q -- '--diagnose' "$output"
    grep -q 'PYTHON=' "$output"
}

run_uninstall_without_artifacts_fails() {
    local sandbox="$TMP_ROOT/no-install"
    local output="$sandbox/output.log"
    mkdir -p "$sandbox/extensions" "$sandbox/system/rules"
    printf 'stock rules\n' > "$sandbox/system/rules/evdev.lst"
    printf 'foreign backup\n' > "$sandbox/system/rules/evdev.lst.1"
    if env \
        ERGOPTI_XKB_EXTENSIONS_ROOT="$sandbox/extensions" \
        ERGOPTI_XKB_SYSTEM_ROOT="$sandbox/system" \
        ERGOPTI_XKB_USER_HOME="$sandbox/home" \
        ERGOPTI_INSTALL_LOG="$sandbox/install.log" \
        bash "$INSTALLER_DIR/install.sh" --uninstall --yes > "$output" 2>&1; then
        printf 'uninstall without owned artifacts unexpectedly succeeded\n' >&2
        return 1
    fi
    grep -q -- '--uninstall requiert --installation-method clean|legacy' "$output"
    grep -q 'Artefacts Clean  : aucun' "$output"
    ! grep -q 'command not found' "$output"
}

run_downloaded_uninstall() {
    local sandbox="$TMP_ROOT/downloaded"
    local source_repo="$sandbox/source-repo"
    local downloaded="$sandbox/install.sh"
    mkdir -p "$source_repo/static/ergopti/linux"
    cp -R "$INSTALLER_DIR" "$source_repo/static/ergopti/linux/xkb_installation"
    git -C "$source_repo" init -q
    git -C "$source_repo" config user.email tests@example.invalid
    git -C "$source_repo" config user.name tests
    git -C "$source_repo" add .
    git -C "$source_repo" commit -qm fixture
    git -C "$source_repo" branch -M main
    cp "$INSTALLER_DIR/install.sh" "$downloaded"

    mkdir -p "$sandbox/extensions/ergopti/symbols" "$sandbox/system/rules"
    printf 'installed\n' > "$sandbox/extensions/ergopti/symbols/ergopti"
    : > "$sandbox/system/rules/evdev"

    local rewrite_key="url.file://$source_repo.insteadOf"
    if ! env \
        HOME="$TMP_ROOT/home" \
        FZF_MARKER="$sandbox/fzf-called" \
        PATH="$FAKE_BIN:$PATH" \
        BRANCH=main \
        GIT_CONFIG_COUNT=1 \
        GIT_CONFIG_KEY_0="$rewrite_key" \
        GIT_CONFIG_VALUE_0="https://github.com/adrienm7/ergopti.git" \
        ERGOPTI_XKB_EXTENSIONS_ROOT="$sandbox/extensions" \
        ERGOPTI_XKB_SYSTEM_ROOT="$sandbox/system" \
        ERGOPTI_XKB_CACHE_DIR="$sandbox/cache" \
        ERGOPTI_XKB_USER_HOME="$sandbox/home" \
        ERGOPTI_INSTALL_LOG="$sandbox/install.log" \
        bash "$downloaded" --uninstall --yes \
            > "$sandbox/output.log" 2>&1; then
        cat "$sandbox/output.log" >&2
        return 1
    fi
    test ! -e "$sandbox/extensions/ergopti"
    grep -q "Artefacts Clean  : $sandbox/extensions/ergopti" "$sandbox/output.log"

    local dispatch_bin="$sandbox/dispatch-bin"
    local sudo_log="$sandbox/sudo.log"
    mkdir -p "$dispatch_bin"
    cat > "$dispatch_bin/sudo" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$SUDO_LOG"
exit 0
EOF
    chmod +x "$dispatch_bin/sudo"

    local legacy_root="$sandbox/legacy"
    mkdir -p "$legacy_root/system/rules" "$legacy_root/extensions"
    printf 'ergopti\n' > "$legacy_root/system/rules/evdev.lst"
    printf 'stock rules\n' > "$legacy_root/system/rules/evdev.lst.1"
    env \
        HOME="$TMP_ROOT/home" \
        PATH="$dispatch_bin:$FAKE_BIN:$PATH" \
        SUDO_LOG="$sudo_log" \
        BRANCH=main \
        GIT_CONFIG_COUNT=1 \
        GIT_CONFIG_KEY_0="$rewrite_key" \
        GIT_CONFIG_VALUE_0="https://github.com/adrienm7/ergopti.git" \
        ERGOPTI_XKB_EXTENSIONS_ROOT="$legacy_root/extensions" \
        ERGOPTI_XKB_SYSTEM_ROOT="$legacy_root/system" \
        ERGOPTI_XKB_CACHE_DIR="$legacy_root/cache" \
        ERGOPTI_XKB_USER_HOME="$legacy_root/home" \
        ERGOPTI_INSTALL_LOG="$legacy_root/install.log" \
        bash "$downloaded" --uninstall --yes > "$legacy_root/output.log" 2>&1
    grep -q 'xkb_files_installer_legacy.py --uninstall' "$sudo_log"

    local clean_v1_root="$sandbox/clean-v1"
    : > "$sudo_log"
    mkdir -p "$clean_v1_root/system/rules" "$clean_v1_root/extensions"
    printf '  ergopti = +ergopti\n' > "$clean_v1_root/system/rules/evdev"
    env \
        HOME="$TMP_ROOT/home" \
        PATH="$dispatch_bin:$FAKE_BIN:$PATH" \
        SUDO_LOG="$sudo_log" \
        BRANCH=main \
        GIT_CONFIG_COUNT=1 \
        GIT_CONFIG_KEY_0="$rewrite_key" \
        GIT_CONFIG_VALUE_0="https://github.com/adrienm7/ergopti.git" \
        ERGOPTI_XKB_EXTENSIONS_ROOT="$clean_v1_root/extensions" \
        ERGOPTI_XKB_SYSTEM_ROOT="$clean_v1_root/system" \
        ERGOPTI_XKB_CACHE_DIR="$clean_v1_root/cache" \
        ERGOPTI_XKB_USER_HOME="$clean_v1_root/home" \
        ERGOPTI_INSTALL_LOG="$clean_v1_root/install.log" \
        bash "$downloaded" --uninstall --yes > "$clean_v1_root/output.log" 2>&1
    grep -q 'xkb_files_installer_clean.py --uninstall' "$sudo_log"

    local ambiguous_root="$sandbox/ambiguous"
    : > "$sudo_log"
    mkdir -p \
        "$ambiguous_root/extensions/ergopti/symbols" \
        "$ambiguous_root/system/rules"
    printf 'installed\n' > "$ambiguous_root/extensions/ergopti/symbols/ergopti"
    printf 'ergopti\n' > "$ambiguous_root/system/rules/evdev.lst"
    printf 'stock rules\n' > "$ambiguous_root/system/rules/evdev.lst.1"
    if env \
        HOME="$TMP_ROOT/home" \
        PATH="$dispatch_bin:$FAKE_BIN:$PATH" \
        SUDO_LOG="$sudo_log" \
        BRANCH=main \
        GIT_CONFIG_COUNT=1 \
        GIT_CONFIG_KEY_0="$rewrite_key" \
        GIT_CONFIG_VALUE_0="https://github.com/adrienm7/ergopti.git" \
        ERGOPTI_XKB_EXTENSIONS_ROOT="$ambiguous_root/extensions" \
        ERGOPTI_XKB_SYSTEM_ROOT="$ambiguous_root/system" \
        ERGOPTI_XKB_CACHE_DIR="$ambiguous_root/cache" \
        ERGOPTI_XKB_USER_HOME="$ambiguous_root/home" \
        ERGOPTI_INSTALL_LOG="$ambiguous_root/install.log" \
        bash "$downloaded" --uninstall --yes > "$ambiguous_root/output.log" 2>&1; then
        printf 'ambiguous uninstall unexpectedly succeeded\n' >&2
        return 1
    fi
    grep -q -- '--uninstall requiert --installation-method clean|legacy' \
        "$ambiguous_root/output.log"
    grep -q 'les deux méthodes' "$ambiguous_root/output.log"
    test ! -s "$sudo_log"

    if env \
        HOME="$TMP_ROOT/home" \
        PATH="$FAKE_BIN:$PATH" \
        BRANCH=main \
        GIT_CONFIG_COUNT=1 \
        GIT_CONFIG_KEY_0="$rewrite_key" \
        GIT_CONFIG_VALUE_0="https://github.com/adrienm7/ergopti.git" \
        ERGOPTI_XKB_EXTENSIONS_ROOT="$sandbox/extensions" \
        ERGOPTI_XKB_SYSTEM_ROOT="$sandbox/system" \
        ERGOPTI_XKB_CACHE_DIR="$sandbox/cache" \
        ERGOPTI_XKB_USER_HOME="$sandbox/home" \
        ERGOPTI_INSTALL_LOG="$sandbox/install.log" \
        bash "$downloaded" --uninstall --yes \
            > "$sandbox/noop-output.log" 2>&1; then
        printf 'empty uninstall unexpectedly reported success\n' >&2
        return 1
    fi
    grep -q -- '--uninstall requiert --installation-method clean|legacy' \
        "$sandbox/noop-output.log"
    ! grep -q 'Désinstallation terminée' "$sandbox/noop-output.log"
}

run_help
run_debian_detector
run_non_interactive_install
run_non_interactive_legacy_install
run_cleanup_failure_is_not_fatal
run_dead_layout_is_refused
run_diagnose_mode
run_python_floor_guard
run_unsupported_host_guard
run_uninstall_without_artifacts_fails
run_downloaded_uninstall
printf 'install entrypoint tests: OK\n'
