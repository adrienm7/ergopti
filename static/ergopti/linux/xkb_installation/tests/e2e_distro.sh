#!/usr/bin/env bash

# ==============================================================================
# End-to-end installation of the Ergopti XKB layout on a real distribution.
#
# Meant to run as root inside a fresh container of the distribution under test
# (see .github/workflows/linux-layout.yml). It does what a user does, with the
# distribution's own libxkbcommon, xkeyboard-config, compilers and Python:
#
#   1. runs the installer test suites with the distribution's python3;
#   2. creates an unprivileged user with passwordless sudo (or doas), which is
#      the situation of a desktop user typing the documented command;
#   3. installs the layout as that user through the piped entry point
#      (`cat install.sh | env BRANCH=... bash`) against the real system tree,
#      lets the detector choose the method and checks it against the
#      expectation for this distribution;
#   4. proves the result with the distribution's compilers, independently of
#      the installer's own verification: the custom type is bound to the probe
#      key alone and next to another layout, and Ctrl has its own level;
#   5. optionally replays the exact state of issue #84 (generation-2 leftovers,
#      fish, a wlroots compositor) and a GNOME session on a private D-Bus bus
#      with a real dconf;
#   6. uninstalls and requires the system tree to be byte-for-byte what it was;
#   7. repeats the cycle with the other method where it applies, and requires
#      a forced clean install to be refused where libxkbcommon is too old.
#
# Usage: e2e_distro.sh --expect-method clean|legacy|any [--replay-issue-84]
#                      [--gnome-dbus] [--use-fish] [--privilege sudo|doas]
#                      [--python python3.11] [--check-python-floor]
# ==============================================================================

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
INSTALLER_DIR=$(dirname "$SCRIPT_DIR")
LINUX_DIR=$(dirname "$INSTALLER_DIR")
REPO_ROOT=$(cd -- "$LINUX_DIR/../../.." && pwd)

VERSION="v2_2_1"
LEGACY_VARIANT="Ergopti_v2_2_1"
TYPE_NAME="ERGOPTI_SEVEN_LEVEL"
USER_NAME="ergopti"
USER_HOME="/home/$USER_NAME"
SYSTEM_ROOT="/usr/share/X11/xkb"
EXTENSIONS_ROOT="/usr/share/xkeyboard-config.d"
PACKAGE_DIR="$EXTENSIONS_ROOT/ergopti"
HTTP_PORT=8765

EXPECT_METHOD="any"
REPLAY_ISSUE_84=false
GNOME_DBUS=false
USE_FISH=false
PRIVILEGE="sudo"
PYTHON_BIN="python3"
CHECK_PYTHON_FLOOR=false

while [ $# -gt 0 ]; do
    case "$1" in
        --expect-method) EXPECT_METHOD="$2"; shift 2 ;;
        --replay-issue-84) REPLAY_ISSUE_84=true; shift ;;
        --gnome-dbus) GNOME_DBUS=true; shift ;;
        --use-fish) USE_FISH=true; shift ;;
        --privilege) PRIVILEGE="$2"; shift 2 ;;
        --python) PYTHON_BIN="$2"; shift 2 ;;
        --check-python-floor) CHECK_PYTHON_FLOOR=true; shift ;;
        *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done
case "$EXPECT_METHOD" in clean | legacy | any) ;; *) printf 'bad --expect-method\n' >&2; exit 2 ;; esac

WORK=$(mktemp -d /tmp/ergopti-e2e.XXXXXX)
chmod 755 "$WORK"
BARE_REPO="$WORK/ergopti.git"
HTTP_PID=""

cleanup() {
    if [ -n "$HTTP_PID" ]; then kill "$HTTP_PID" 2>/dev/null || true; fi
}
trap cleanup EXIT

step() { printf '\n\033[1;34m== %s ==\033[0m\n' "$1"; }
ok() { printf '   \033[32mok\033[0m %s\n' "$1"; }
die() { printf '\033[31m!! %s\033[0m\n' "$1" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Host facts
# ---------------------------------------------------------------------------

step "Distribution under test"
# Read in a subshell: os-release also defines VERSION, NAME and ID, which
# would otherwise clobber this script's own variables.
# shellcheck disable=SC1091
PRETTY_NAME=$(. /etc/os-release 2>/dev/null && printf '%s (ID=%s ID_LIKE=%s)' "${PRETTY_NAME:-?}" "${ID:-?}" "${ID_LIKE:--}")
printf '   %s\n' "${PRETTY_NAME:-unknown distribution}"
printf '   python: %s\n' "$("$PYTHON_BIN" --version 2>&1)"
printf '   xkbcli: %s\n' "$(have xkbcli && xkbcli --version || echo absent)"
printf '   xkbcomp: %s\n' "$(have xkbcomp && xkbcomp -version 2>&1 | head -1 || echo absent)"
printf '   %s -> %s\n' "$SYSTEM_ROOT" "$(readlink -f "$SYSTEM_ROOT")"
[ -f "$SYSTEM_ROOT/types/extra" ] || die "xkeyboard-config is not installed ($SYSTEM_ROOT/types/extra missing)"
if have git; then git config --global --add safe.directory '*'; fi

# ---------------------------------------------------------------------------
# 1. An unprivileged user, a local mirror of the repository
# ---------------------------------------------------------------------------

step "Unprivileged user with $PRIVILEGE"
if ! id "$USER_NAME" >/dev/null 2>&1; then
    if have useradd; then
        useradd -m -s /bin/bash "$USER_NAME"
    elif have adduser; then
        adduser -D -s /bin/bash "$USER_NAME"
    else
        die "no useradd/adduser available"
    fi
fi
mkdir -p "$USER_HOME"
chown "$USER_NAME" "$USER_HOME"
case "$PRIVILEGE" in
    sudo)
        have sudo || die "sudo is not installed"
        mkdir -p /etc/sudoers.d
        printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$USER_NAME" > /etc/sudoers.d/ergopti-e2e
        chmod 0440 /etc/sudoers.d/ergopti-e2e
        ;;
    doas)
        have doas || die "doas is not installed"
        mkdir -p /etc/doas.d
        printf 'permit nopass %s\n' "$USER_NAME" > /etc/doas.d/ergopti-e2e.conf
        [ -f /etc/doas.conf ] || printf 'permit nopass %s\n' "$USER_NAME" > /etc/doas.conf
        ;;
    *) die "bad --privilege" ;;
esac

# The piped entry point fetches the installer from GitHub; a bare mirror of
# this checkout stands in for it so the run needs no network. The mirror is
# seeded from the tracked files rather than pushed from HEAD: the CI checkout
# is shallow and detached, a mirror pushed from it inherits that boundary, and
# git 2.25 (Ubuntu 20.04) cannot fetch --depth 1 from a shallow repository --
# it re-forks upload-pack until the container runs out of processes, which
# surfaces as hundreds of "the remote end hung up unexpectedly".
SEED_REPO="$WORK/mirror-seed"
mkdir -p "$SEED_REPO"
# git rather than tar: the openSUSE images ship no tar at all. A scratch
# index keeps this exactly HEAD, whatever the real index holds.
MIRROR_INDEX="$WORK/mirror.index"
GIT_INDEX_FILE="$MIRROR_INDEX" git -C "$REPO_ROOT" read-tree HEAD
GIT_INDEX_FILE="$MIRROR_INDEX" git -C "$REPO_ROOT" \
    checkout-index -a -f --prefix="$SEED_REPO/"
rm -f "$MIRROR_INDEX"
git init --quiet --bare "$BARE_REPO"
git -C "$SEED_REPO" init --quiet
git -C "$SEED_REPO" config user.email e2e@example.invalid
git -C "$SEED_REPO" config user.name e2e
# -f as well: a file that is tracked upstream but matches a .gitignore
# pattern would otherwise be dropped from the mirror.
git -C "$SEED_REPO" add -A -f
git -C "$SEED_REPO" commit --quiet -m "mirror of the commit under test"
git -C "$SEED_REPO" push --quiet "$BARE_REPO" HEAD:refs/heads/dev
git -C "$BARE_REPO" symbolic-ref HEAD refs/heads/dev
# The oldest git in the matrix cannot serve a shallow mirror, and what it
# produces then is a fork storm rather than a readable message: refuse one.
[ "$(git -C "$BARE_REPO" rev-parse --is-shallow-repository)" = false ] \
    || die "the mirror is shallow: git 2.25 cannot fetch --depth 1 from it"
chown -R "$USER_NAME" "$BARE_REPO"
# The redirection has to live in the user's own git configuration:
# GIT_CONFIG_COUNT is only honoured from git 2.31, so on Ubuntu 20.04's 2.25
# it was ignored and the piped entry point fetched github.com for real,
# exactly what the bare mirror above exists to avoid. GIT_ALLOW_PROTOCOL
# makes a redirection that failed to apply an error rather than a silent
# network round trip.
{
    printf '[url "file://%s"]\n' "$BARE_REPO"
    printf '\tinsteadOf = https://github.com/adrienm7/ergopti.git\n'
} > "$USER_HOME/.gitconfig"
chown "$USER_NAME" "$USER_HOME/.gitconfig"
GIT_REDIRECT=(GIT_ALLOW_PROTOCOL=file)

# run_as_user VAR=value ... -- command args
run_as_user() {
    local -a assignments=()
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do
        assignments+=("$1")
        shift
    done
    shift
    if have runuser; then
        runuser -u "$USER_NAME" -- env HOME="$USER_HOME" PYTHON="$PYTHON_BIN" "${assignments[@]}" "$@"
    else
        su "$USER_NAME" -c "$(printf '%q ' env HOME="$USER_HOME" PYTHON="$PYTHON_BIN" "${assignments[@]}" "$@")"
    fi
}

snapshot() {
    (cd "$SYSTEM_ROOT/" && find -L . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) > "$1"
}

# ---------------------------------------------------------------------------
# 2. Test suites with the distribution's interpreter, as the user
# ---------------------------------------------------------------------------
# The suites simulate a desktop user; run as root they would exercise the
# privilege-drop paths instead of the ones a user reaches.

step "Installer test suites with $PYTHON_BIN"
run_as_user -- "$PYTHON_BIN" "$SCRIPT_DIR/run_all_tests.py" > "$WORK/unit.log" 2>&1 || { tail -40 "$WORK/unit.log"; die "unit suite failed"; }
tail -3 "$WORK/unit.log"
run_as_user -- bash "$SCRIPT_DIR/test_install_entrypoint.sh" > "$WORK/entrypoint.log" 2>&1 || { tail -40 "$WORK/entrypoint.log"; die "entrypoint suite failed"; }
tail -1 "$WORK/entrypoint.log"

# ---------------------------------------------------------------------------
# Independent verification with the distribution's own compilers
# ---------------------------------------------------------------------------

# assert_keymap_usable <keymap text> <group> <label>
assert_keymap_usable() {
    local keymap="$1" group="$2" label="$3" block typeblock
    grep -q "type \"$TYPE_NAME\"" <<< "$keymap" || die "$label: the $TYPE_NAME type is not in the keymap"
    block=$(awk '/key <AD01>/ { flag = 1 } flag { print } flag && /};/ { exit }' <<< "$keymap")
    [ -n "$block" ] || die "$label: key <AD01> is missing, the symbols never loaded"
    grep -Eq "type(\[(Group)?${group}\])?= \"$TYPE_NAME\"" <<< "$block" \
        || die "$label: <AD01> is not bound to $TYPE_NAME (issue #84):"$'\n'"$block"
    grep -Eq "symbols\[(Group)?${group}\]= \[ *egrave, +Egrave, +Egrave, +egrave, +z, +grave, +doublelowquotemark \]" <<< "$block" \
        || die "$label: <AD01> does not carry its seven levels:"$'\n'"$block"
    typeblock=$(awk -v t="type \"$TYPE_NAME\"" 'index($0, t) { flag = 1 } flag { print } flag && /};/ { exit }' <<< "$keymap")
    grep -Eq 'map\[Shift\]= *(Level)?3;' <<< "$typeblock" || die "$label: Shift does not select level 3"
    grep -Eq 'map\[Control\]= *(Level)?5;' <<< "$typeblock" || die "$label: Ctrl does not select level 5"
    grep -Eq 'preserve\[Control\]= *Control;' <<< "$typeblock" || die "$label: Ctrl is not preserved"
    ok "$label: <AD01> on $TYPE_NAME, Shift -> 3, Ctrl -> 5 (z) preserved"
}

# verify_with_xkbcli <layouts> <variants> <group of the Ergopti layout>
verify_with_xkbcli() {
    have xkbcli || return 0
    local keymap
    keymap=$(xkbcli compile-keymap --rules evdev --model pc105 --layout "$1" --variant "$2" 2> "$WORK/xkbcli.err") \
        || { cat "$WORK/xkbcli.err"; die "xkbcli cannot compile $1 ($2)"; }
    assert_keymap_usable "$keymap" "$3" "libxkbcommon $1"
}

# verify_with_xkbcomp <symbols include> <types include> [include dir]
verify_with_xkbcomp() {
    have xkbcomp || return 0
    local probe="$WORK/probe.xkb" keymap
    printf 'xkb_keymap {\n\txkb_keycodes { include "evdev+aliases(qwerty)" };\n\txkb_types { include "%s" };\n\txkb_compat { include "complete" };\n\txkb_symbols { include "%s" };\n\txkb_geometry { include "pc(pc105)" };\n};\n' "$2" "$1" > "$probe"
    if [ -n "${3:-}" ]; then
        keymap=$(xkbcomp "-I$3" -xkb "$probe" - 2> "$WORK/xkbcomp.err") || { cat "$WORK/xkbcomp.err"; die "xkbcomp rejected $1"; }
    else
        keymap=$(xkbcomp -xkb "$probe" - 2> "$WORK/xkbcomp.err") || { cat "$WORK/xkbcomp.err"; die "xkbcomp rejected $1"; }
    fi
    assert_keymap_usable "$keymap" 1 "xkbcomp $1"
}

# verify_registry clean|legacy
verify_registry() {
    have xkbcli || return 0
    local listing
    listing=$(xkbcli list 2>/dev/null || true)
    if [ -z "$listing" ]; then
        printf '   xkbcli list unavailable on this version, registry not checked\n'
        return 0
    fi
    case "$1" in
        clean) grep -q "layout: 'ergopti'" <<< "$listing" || die "registry: the ergopti layout is not listed by libxkbregistry" ;;
        legacy) grep -q "variant: '$LEGACY_VARIANT'" <<< "$listing" || die "registry: the $LEGACY_VARIANT variant is not listed" ;;
    esac
    ok "registry lists the $1 layout"
}

verify_method() {
    case "$1" in
        clean)
            [ -f "$PACKAGE_DIR/symbols/ergopti" ] || die "package not installed in $PACKAGE_DIR"
            [ -f "$PACKAGE_DIR/rules/evdev.post" ] || die "rules/evdev.post missing"
            grep -q 'layout\[2\]' "$PACKAGE_DIR/rules/evdev.post" || die "evdev.post lacks the indexed rules"
            [ "$(stat -c %a "$PACKAGE_DIR/symbols/ergopti")" = "644" ] || die "package file is not world-readable"
            verify_with_xkbcli ergopti "" 1
            verify_with_xkbcli ergopti,us "," 1
            verify_with_xkbcli us,ergopti "," 2
            verify_with_xkbcomp "pc+ergopti+inet(evdev)" "complete+ergopti" "$PACKAGE_DIR"
            verify_registry clean
            ;;
        legacy)
            grep -q "xkb_symbols \"$LEGACY_VARIANT\"" "$SYSTEM_ROOT/symbols/fr" || die "symbols/fr lacks the section"
            grep -q "type \"$TYPE_NAME\"" "$SYSTEM_ROOT/types/extra" || die "types/extra lacks the type"
            [ -f "$SYSTEM_ROOT/types/extra.1" ] || die "no backup of types/extra"
            verify_with_xkbcli fr "$LEGACY_VARIANT" 1
            verify_with_xkbcli fr,us "$LEGACY_VARIANT," 1
            verify_with_xkbcli us,fr ",$LEGACY_VARIANT" 2
            verify_with_xkbcomp "pc+fr($LEGACY_VARIANT)+inet(evdev)" "complete"
            verify_registry legacy
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Installer runs
# ---------------------------------------------------------------------------

# install_piped <log name> [extra install.sh args]: the documented command,
# script on stdin, installer fetched through git (redirected to the mirror).
# The installer's own log file lands in the user's home: the work directory
# belongs to root and the user could not write there.
install_piped() {
    local name="$1" log="$WORK/$1.log"
    shift
    run_as_user BRANCH=dev "${GIT_REDIRECT[@]}" XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=Hyprland \
        ERGOPTI_INSTALL_LOG="$USER_HOME/ergopti-$name.log" \
        -- sh -c 'cat "$0" | bash -s -- "$@"' "$INSTALLER_DIR/install.sh" \
        --yes --version "$VERSION" --variant ergopti "$@" > "$log" 2>&1 || { cat "$log"; die "piped install failed ($name)"; }
    cat "$log"
}

# install_local <log name> [extra install.sh args]: the checkout's own
# install.sh in local mode.
install_local() {
    local name="$1" log="$WORK/$1.log"
    shift
    run_as_user XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=Hyprland ERGOPTI_INSTALL_LOG="$USER_HOME/ergopti-$name.log" \
        -- bash "$INSTALLER_DIR/install.sh" --yes --version "$VERSION" --variant ergopti "$@" > "$log" 2>&1 \
        || { cat "$log"; die "local install failed ($name)"; }
    cat "$log"
}

uninstall_local() {
    local log="$WORK/$1.log"
    run_as_user XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=Hyprland ERGOPTI_INSTALL_LOG="$USER_HOME/ergopti-$1.log" \
        -- bash "$INSTALLER_DIR/install.sh" --uninstall --yes > "$log" 2>&1 || { cat "$log"; die "uninstall failed ($1)"; }
    cat "$log"
}

method_from_log() {
    if grep -q 'Clean (extensions XKB)' "$1"; then echo clean; else echo legacy; fi
}

assert_common_output() {
    local log="$1"
    grep -q 'Installation terminée' "$log" || die "no completion line"
    grep -q 'hyprland.conf' "$log" || die "no Hyprland instructions for a Hyprland session"
    grep -q 'kb_layout = ' "$log" || die "no kb_layout snippet"
    grep -q 'Réglage GNOME ignoré' "$log" || die "GNOME setting was not skipped on a Hyprland session"
    if have xkbcli || have xkbcomp; then
        grep -q 'Keymap vérifiée' "$log" || die "the installer did not verify the keymap although a compiler exists"
    else
        grep -q 'sans vérification' "$log" || die "no warning about the missing compiler"
    fi
    ! grep -q 'Traceback' "$log" || die "a traceback leaked into the output"
}

assert_pristine() {
    snapshot "$WORK/after.sha"
    if ! diff -u "$WORK/before.sha" "$WORK/after.sha" > "$WORK/tree.diff"; then
        cat "$WORK/tree.diff"
        die "the system tree differs from its pristine state after uninstall"
    fi
    [ ! -e "$PACKAGE_DIR" ] || die "package directory still present after uninstall"
    [ ! -e "$SYSTEM_ROOT/types/extra.1" ] || die "legacy backup still present after uninstall"
    if [ -f "$USER_HOME/.XCompose" ]; then
        ! grep -q 'Ergopti' "$USER_HOME/.XCompose" || die "$USER_HOME/.XCompose still references Ergopti"
    fi
    ok "system tree byte-for-byte pristine"
}

# ---------------------------------------------------------------------------
# 3. Optional: the interpreter floor
# ---------------------------------------------------------------------------

if [ "$CHECK_PYTHON_FLOOR" = true ]; then
    step "Default python3 below the floor is refused with a hint"
    status=0
    run_as_user PYTHON=python3 -- bash "$INSTALLER_DIR/install.sh" --diagnose > "$WORK/floor.log" 2>&1 || status=$?
    [ "$status" -ne 0 ] || { cat "$WORK/floor.log"; die "an old python3 was accepted"; }
    grep -q 'requiert Python >= 3.8' "$WORK/floor.log" || { cat "$WORK/floor.log"; die "no floor message"; }
    ok "python3 $(python3 --version 2>&1 | cut -d' ' -f2) refused, PYTHON=$PYTHON_BIN documented"
fi

# ---------------------------------------------------------------------------
# 4. Optional: the state of issue #84 before the first run
# ---------------------------------------------------------------------------

step "Pristine snapshot of $SYSTEM_ROOT"
snapshot "$WORK/before.sha"
printf '   %s files\n' "$(wc -l < "$WORK/before.sha")"

if [ "$REPLAY_ISSUE_84" = true ]; then
    step "Planting the generation-2 leftovers reported in issue #84"
    mkdir -p "$PACKAGE_DIR/symbols"
    cp "$LINUX_DIR/$VERSION/$LEGACY_VARIANT.xkb" "$PACKAGE_DIR/symbols/$LEGACY_VARIANT"
    printf '\n! layout = types\n  %s = +%s\n' "$LEGACY_VARIANT" "$LEGACY_VARIANT" >> "$SYSTEM_ROOT/rules/evdev"
    ok "stale $PACKAGE_DIR/symbols/$LEGACY_VARIANT and rules/evdev line in place"
fi

# ---------------------------------------------------------------------------
# 5. The documented command, method chosen by the detector
# ---------------------------------------------------------------------------

step "Install through the documented command (detector chooses)"
if [ "$USE_FISH" = true ]; then
    have fish || die "fish is not installed"
    have curl || die "curl is not installed"
    "$PYTHON_BIN" -m http.server --bind 127.0.0.1 --directory "$REPO_ROOT" "$HTTP_PORT" > "$WORK/http.log" 2>&1 &
    HTTP_PID=$!
    sleep 2
    command="curl -fsSL \"http://127.0.0.1:$HTTP_PORT/static/ergopti/linux/xkb_installation/install.sh\" | env BRANCH=\"dev\" bash -s -- --yes --version $VERSION --variant ergopti"
    printf '   fish -c %s\n' "$command"
    run_as_user "${GIT_REDIRECT[@]}" XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=Hyprland SHELL=/usr/bin/fish \
        ERGOPTI_INSTALL_LOG="$USER_HOME/ergopti-fish.log" -- fish -c "$command" > "$WORK/first.log" 2>&1 \
        || { cat "$WORK/first.log"; die "install through fish failed"; }
    cat "$WORK/first.log"
else
    install_piped first
fi
ACTUAL_METHOD=$(method_from_log "$WORK/first.log")
printf '   method chosen: %s (expected: %s)\n' "$ACTUAL_METHOD" "$EXPECT_METHOD"
if [ "$EXPECT_METHOD" != any ] && [ "$ACTUAL_METHOD" != "$EXPECT_METHOD" ]; then
    die "the detector chose $ACTUAL_METHOD, expected $EXPECT_METHOD"
fi
assert_common_output "$WORK/first.log"
grep -q "Journal de cette exécution" "$WORK/first.log" || die "no log file announced"
verify_method "$ACTUAL_METHOD"
if [ "$REPLAY_ISSUE_84" = true ]; then
    [ ! -e "$PACKAGE_DIR/symbols/$LEGACY_VARIANT" ] || die "generation-2 symbols file survived the upgrade"
    ! grep -q "$LEGACY_VARIANT = +$LEGACY_VARIANT" "$SYSTEM_ROOT/rules/evdev" || die "generation-2 rule survived the upgrade"
    ok "generation-2 leftovers neutralised"
fi

step "Diagnostic report after the install"
run_as_user XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=Hyprland ERGOPTI_INSTALL_LOG="$WORK/diagnose-journal.log" \
    -- bash "$INSTALLER_DIR/install.sh" --diagnose > "$WORK/diagnose.log" 2>&1 || { cat "$WORK/diagnose.log"; die "diagnose failed"; }
grep -q 'Fin du diagnostic' "$WORK/diagnose.log" || die "diagnostic incomplete"
if have xkbcli || have xkbcomp; then
    grep -q 'verdict *: utilisable' "$WORK/diagnose.log" || { cat "$WORK/diagnose.log"; die "diagnostic does not find the layout usable"; }
fi
ok "diagnostic complete ($(wc -l < "$WORK/diagnose.log") lines)"

# ---------------------------------------------------------------------------
# 6. Optional: a GNOME session on a private bus with a real dconf
# ---------------------------------------------------------------------------

if [ "$GNOME_DBUS" = true ]; then
    step "GNOME activation on a private D-Bus session bus"
    if ! have dbus-run-session || ! have gsettings; then
        die "--gnome-dbus requires dbus-run-session and gsettings"
    fi
    gsettings list-schemas | grep -qx 'org.gnome.desktop.input-sources' || die "gsettings-desktop-schemas missing"
    mkdir -p /tmp/runtime-ergopti
    chown "$USER_NAME" /tmp/runtime-ergopti
    chmod 700 /tmp/runtime-ergopti
    if [ "$ACTUAL_METHOD" = clean ]; then
        installer="$INSTALLER_DIR/xkb_files_installer_clean.py"
        activate_args="--variant ergopti"
        layout_id="ergopti"
    else
        installer="$INSTALLER_DIR/xkb_files_installer_legacy.py"
        activate_args="--layout-id fr+$LEGACY_VARIANT"
        layout_id="fr+$LEGACY_VARIANT"
    fi
    cat > "$WORK/gnome-check.sh" <<'EOF'
set -euo pipefail
gsettings set org.gnome.desktop.input-sources sources "[('xkb', 'us')]"
"$PY" "$INSTALLER" --activate-only $ACTIVATE_ARGS
value=$(gsettings get org.gnome.desktop.input-sources sources)
printf 'sources after activation: %s\n' "$value"
case "$value" in
    "[('xkb', '$LAYOUT'), ('xkb', 'us')]") ;;
    *) printf 'the layout is not first, or us was dropped\n'; exit 1 ;;
esac
printf 'mru-sources: %s\n' "$(gsettings get org.gnome.desktop.input-sources mru-sources)"
"$PY" "$INSTALLER" --deactivate-only
value=$(gsettings get org.gnome.desktop.input-sources sources)
printf 'sources after deactivation: %s\n' "$value"
[ "$value" = "[('xkb', 'us')]" ] || { printf 'us was not preserved alone after deactivation\n'; exit 1; }
EOF
    chmod 644 "$WORK/gnome-check.sh"
    run_as_user XDG_RUNTIME_DIR=/tmp/runtime-ergopti XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=GNOME \
        PY="$PYTHON_BIN" INSTALLER="$installer" ACTIVATE_ARGS="$activate_args" LAYOUT="$layout_id" \
        -- dbus-run-session -- bash "$WORK/gnome-check.sh" > "$WORK/gnome.log" 2>&1 || { cat "$WORK/gnome.log"; die "GNOME activation failed"; }
    cat "$WORK/gnome.log"
    grep -q 'valeur confirmée' "$WORK/gnome.log" || die "the write was not read back"
    ok "gsettings holds $layout_id first, then us, and is clean after deactivation"
fi

# ---------------------------------------------------------------------------
# 7. Uninstall, then the other method
# ---------------------------------------------------------------------------

step "Uninstall ($ACTUAL_METHOD)"
uninstall_local uninstall-first
assert_pristine

if [ "$ACTUAL_METHOD" = clean ]; then
    step "Legacy method, forced (universal fallback)"
    install_local legacy --installation-method legacy
    assert_common_output "$WORK/legacy.log"
    grep -q "Disposition  : fr+$LEGACY_VARIANT" "$WORK/legacy.log" || die "legacy layout id not reported"
    verify_method legacy
    uninstall_local uninstall-legacy
    assert_pristine
else
    step "Clean method, forced on a host that cannot read it"
    status=0
    run_as_user XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=Hyprland ERGOPTI_INSTALL_LOG="$WORK/forced-clean-journal.log" \
        -- bash "$INSTALLER_DIR/install.sh" --yes --version "$VERSION" --variant ergopti --installation-method clean \
        > "$WORK/forced-clean.log" 2>&1 || status=$?
    cat "$WORK/forced-clean.log"
    if [ "$status" -eq 0 ]; then
        if have xkbcli && [ "$(xkbcli --version | cut -d. -f1-2 | tr -d .)" -ge 113 ] 2>/dev/null; then
            printf '   this host has a recent libxkbcommon under an X11-less session: clean accepted\n'
            uninstall_local uninstall-forced-clean
            assert_pristine
        else
            die "a forced clean install on an old libxkbcommon reported success"
        fi
    else
        grep -Eq 'requiert|ne compile pas|inutilisable' "$WORK/forced-clean.log" || die "the refusal does not explain itself"
        [ ! -e "$PACKAGE_DIR" ] || die "a refused clean install left a package behind"
        ok "forced clean refused with an explanation (exit $status), nothing left behind"
        assert_pristine
    fi
fi

step "Done: $PRETTY_NAME, detector chose $ACTUAL_METHOD"
