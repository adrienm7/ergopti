#!/usr/bin/env bash

set -euo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
INSTALLER_DIR=$(dirname "$TEST_DIR")
LINUX_DIR=$(dirname "$INSTALLER_DIR")
TMP_ROOT=$(mktemp -d -t ergopti-install-entrypoint.XXXXXX)

cleanup() {
    rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

FAKE_BIN="$TMP_ROOT/bin"
ISOLATED_EXTERNAL_BIN="$TMP_ROOT/external-bin"
mkdir -p "$FAKE_BIN" "$ISOLATED_EXTERNAL_BIN" "$TMP_ROOT/home"
export ISOLATED_EXTERNAL_BIN
cat > "$FAKE_BIN/fzf" <<'EOF'
#!/bin/sh
printf 'called\n' >> "$FZF_MARKER"
exit 97
EOF
cat > "$FAKE_BIN/sudo" <<'EOF'
#!/bin/sh
command_path=$(command -v "$1") || exit 127
shift
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
chmod +x "$FAKE_BIN/fzf" "$FAKE_BIN/sudo" "$FAKE_BIN/gsettings"
# Reachable from the privileged PATH too, so an activation attempted as root is
# observed and fails the test instead of quietly finding no gsettings at all.
cp "$FAKE_BIN/gsettings" "$ISOLATED_EXTERNAL_BIN/gsettings"

run_debian_detector() {
    local detector_bin="$TMP_ROOT/detector-bin"
    mkdir -p "$detector_bin"
    cat > "$detector_bin/pkg-config" <<'EOF'
#!/bin/sh
exit 1
EOF
    cat > "$detector_bin/dpkg-query" <<'EOF'
#!/bin/sh
case "$*" in
    *libxkbcommon0) printf '1.13.1-1\n' ;;
    *xkeyboard-config) printf '2.45.0-1\n' ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$detector_bin/pkg-config" "$detector_bin/dpkg-query"
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
    if ! env \
        HOME="$TMP_ROOT/home" \
        FZF_MARKER="$sandbox/fzf-called" \
        GSETTINGS_LOG="$sandbox/gsettings.log" \
        GSETTINGS_STATE="$sandbox/gsettings.state" \
        GSETTINGS_ELEVATED_MARKER="$sandbox/gsettings-elevated" \
        XDG_CURRENT_DESKTOP="GNOME" \
        XDG_SESSION_TYPE="x11" \
        PATH="$FAKE_BIN:$PATH" \
        ERGOPTI_XKB_EXTENSIONS_ROOT="$sandbox/extensions" \
        ERGOPTI_XKB_SYSTEM_ROOT="$sandbox/system" \
        ERGOPTI_XKB_CACHE_DIR="$sandbox/cache" \
        ERGOPTI_XKB_USER_HOME="$sandbox/home" \
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
    # An X11 session without a layout manager is told how to persist the layout.
    grep -q 'Installation terminée' "$output"

    if ! env \
        HOME="$TMP_ROOT/home" \
        GSETTINGS_LOG="$sandbox/gsettings.log" \
        GSETTINGS_STATE="$sandbox/gsettings.state" \
        GSETTINGS_ELEVATED_MARKER="$sandbox/gsettings-elevated" \
        PATH="$FAKE_BIN:$PATH" \
        ERGOPTI_XKB_EXTENSIONS_ROOT="$sandbox/extensions" \
        ERGOPTI_XKB_SYSTEM_ROOT="$sandbox/system" \
        ERGOPTI_XKB_CACHE_DIR="$sandbox/cache" \
        ERGOPTI_XKB_USER_HOME="$sandbox/home" \
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
    if ! env \
        HOME="$TMP_ROOT/home" \
        FZF_MARKER="$sandbox/fzf-called" \
        GSETTINGS_LOG="$sandbox/gsettings.log" \
        GSETTINGS_STATE="$sandbox/gsettings.state" \
        GSETTINGS_ELEVATED_MARKER="$sandbox/gsettings-elevated" \
        XDG_CURRENT_DESKTOP="GNOME" \
        XDG_SESSION_TYPE="wayland" \
        PATH="$FAKE_BIN:$PATH" \
        ERGOPTI_XKB_EXTENSIONS_ROOT="$sandbox/extensions" \
        ERGOPTI_XKB_SYSTEM_ROOT="$sandbox/system" \
        ERGOPTI_XKB_CACHE_DIR="$sandbox/cache" \
        ERGOPTI_XKB_USER_HOME="$sandbox/home" \
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
        bash "$INSTALLER_DIR/install.sh" --uninstall --yes > "$output" 2>&1; then
        printf 'uninstall without owned artifacts unexpectedly succeeded\n' >&2
        return 1
    fi
    grep -q -- '--uninstall requiert --installation-method clean|legacy' "$output"
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
        bash "$downloaded" --uninstall --yes \
            > "$sandbox/output.log" 2>&1; then
        cat "$sandbox/output.log" >&2
        return 1
    fi
    test ! -e "$sandbox/extensions/ergopti"

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
        bash "$downloaded" --uninstall --yes > "$ambiguous_root/output.log" 2>&1; then
        printf 'ambiguous uninstall unexpectedly succeeded\n' >&2
        return 1
    fi
    grep -q -- '--uninstall requiert --installation-method clean|legacy' \
        "$ambiguous_root/output.log"
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
        bash "$downloaded" --uninstall --yes \
            > "$sandbox/noop-output.log" 2>&1; then
        printf 'empty uninstall unexpectedly reported success\n' >&2
        return 1
    fi
    grep -q -- '--uninstall requiert --installation-method clean|legacy' \
        "$sandbox/noop-output.log"
    ! grep -q 'Désinstallation terminée' "$sandbox/noop-output.log"
}

run_debian_detector
run_non_interactive_install
run_non_interactive_legacy_install
run_uninstall_without_artifacts_fails
run_downloaded_uninstall
printf 'install entrypoint tests: OK\n'
