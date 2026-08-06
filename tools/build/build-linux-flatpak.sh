#!/usr/bin/env bash
# tools/build/build-linux-flatpak.sh
#
# Assembles a Flatpak of the Ergopti+ Linux driver from the build/linux/ driver
# bundle. It generates, under build/linux/flatpak/:
#   - org.ergopti.Ergopti.yml                 the flatpak-builder manifest
#   - payload/lib/ergopti/                    the driver tree, with the shared
#                                             tree staged as its _shared child
#   - payload/bin/ergopti                     the LUA_PATH wrapper
#   - payload/share/applications/*.desktop    the desktop entry
#   - payload/share/icons/.../*.svg           a placeholder icon
#   - payload/share/metainfo/*.metainfo.xml   the AppStream metadata
# and, when flatpak-builder and flatpak are both installed, the single-file
# bundle build/linux/ergopti-<version>.flatpak (via `flatpak build-bundle`).
#
# LUAJIT IS BUILT, NOT BORROWED. org.freedesktop.Platform does not ship LuaJIT,
# and the daemon is a LuaJIT program, so the manifest carries a luajit module
# that compiles it from upstream into /app. The manifest asserts /app/bin/luajit
# exists at the end of the build rather than discovering it is missing at the
# user's first launch.
#
# ---------------------------------------------------------------------------
# WHY THIS FLATPAK ASKS FOR --device=all, AND WHAT IT STILL CANNOT DO
# ---------------------------------------------------------------------------
# The daemon is an input driver. It READS /dev/input/event* to see keystrokes
# and WRITES /dev/uinput to inject the replacements. The Flatpak sandbox denies
# both by default and there is no narrower permission that grants them:
# --device=input exposes /dev/input only, and /dev/uinput is not under that
# tree, so injection — half the driver — would still fail. --device=all is the
# only permission that covers both, and it is broad: it exposes every device
# node in /dev, not the two this daemon needs. That is the honest cost of
# shipping an input daemon as a Flatpak, and it is stated here rather than
# buried in a manifest line.
#
# A FLATPAK INSTALL IS NOT SELF-SUFFICIENT. --device=all lifts the SANDBOX
# restriction; it cannot lift the HOST one. /dev/input/event* is root:input and
# unreadable by a normal user, and /dev/uinput does not exist at all until the
# uinput module is loaded. The sandbox cannot grant access to a device node the
# user could not open on the host either. So a Flatpak install ALSO needs the
# udev rule, the /etc/modules-load.d entry and the "input" + "uinput" group
# membership that static/ergopti_plus/linux/install.sh sets up:
#
#     bash install.sh --setup-perms      # on the HOST, once, then log out
#
# A user who installs only the Flatpak and skips that step gets a daemon that
# starts, logs one line and captures nothing. This is the single most likely
# support question about this package.
#
# FURTHER SANDBOX LIMITS, STATED RATHER THAN HIDDEN:
#   - Helper binaries the driver shells out to (xclip, wl-clipboard, xdotool,
#     yad, kanata) are host programs and are not in the runtime. Features that
#     depend on them degrade until each is added as a module here. Deliberately
#     NOT worked around with --talk-name=org.freedesktop.Flatpak: spawning on
#     the host is a sandbox escape, not a packaging fix.
#   - Same for shared libraries loaded through FFI at runtime: the tray dlopens
#     libayatana-appindicator, which the freedesktop runtime does not carry, so
#     the icon and menu stay absent until that library is added as a module too.
#   - kanata remaps at the host level and runs as its own service; it stays a
#     host install and is not part of this bundle.
#   - Flatpak points XDG_CONFIG_HOME and XDG_DATA_HOME at ~/.var/app/<app-id>/,
#     and infra/config_paths.lua honours both. The Flatpak therefore keeps its
#     own config and data there and does NOT read an existing ~/.config/ergopti
#     left by a .deb, .rpm or install.sh install.
#   - Autostart is not the desktop entry's job here: a Flatpak autostarts via
#     the Background portal or a user-created ~/.config/autostart entry.
#
# Usage:
#   bash tools/build/build-linux-flatpak.sh
#     (stage the manifest and payload, then build the .flatpak bundle)
#
#   bash tools/build/build-linux-flatpak.sh --skip-flatpak
#     (stage and validate the structure only — needs no flatpak toolchain)

set -euo pipefail

SKIP_FLATPAK=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-flatpak) SKIP_FLATPAK=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"
BUILD_DIR="$PROJECT_ROOT/build/linux"
FLATPAK_DIR="$BUILD_DIR/flatpak"
PAYLOAD_DIR="$FLATPAK_DIR/payload"
REPO_DIR="$FLATPAK_DIR/repo"
BUILDER_DIR="$FLATPAK_DIR/build"
PACKAGE_NAME="ergopti"
# Extract version from package.json (e.g. "3.0.0") or fall back to "0.1.0"
VERSION=$(node -e "try { process.stdout.write(require('$PROJECT_ROOT/package.json').version) } catch(e) { process.stdout.write('0.1.0') }" 2>/dev/null || echo "0.1.0")
# The bundle branch. Flatpak needs one to address the ref in the local repo, and
# `stable` is what the manifest declares as its default-branch.
BRANCH="stable"
FLATPAK_FILE="$BUILD_DIR/${PACKAGE_NAME}-${VERSION}.flatpak"

echo "=== ergopti Flatpak packager ==="
echo "Package: $PACKAGE_NAME $VERSION (branch $BRANCH)"
echo ""

# ----------------------------------------------------------------------
# 1. Ensure the driver bundle exists
# ----------------------------------------------------------------------
if [ ! -d "$BUILD_DIR" ] || [ ! -f "$BUILD_DIR/linux/ergopti_hotstrings.lua" ]; then
  echo "[ERR] Driver bundle not found at $BUILD_DIR"
  echo "      Run 'bash tools/build/build-linux-driver.sh' first."
  exit 1
fi

echo "[OK] Driver bundle found: $(find "$BUILD_DIR/linux" -type f | wc -l) files"

# ----------------------------------------------------------------------
# 2. Create the flatpak staging tree
# ----------------------------------------------------------------------
rm -rf "$FLATPAK_DIR"
mkdir -p "$PAYLOAD_DIR/lib/ergopti"
mkdir -p "$PAYLOAD_DIR/bin"
mkdir -p "$PAYLOAD_DIR/share/applications"
mkdir -p "$PAYLOAD_DIR/share/icons/hicolor/scalable/apps"
mkdir -p "$PAYLOAD_DIR/share/metainfo"

# ----------------------------------------------------------------------
# 3. The flatpak-builder manifest
# ----------------------------------------------------------------------
# The manifest is the single source of truth for the app id: the shell reads it
# back below instead of declaring its own copy, so the two cannot drift.
MANIFEST_FILE="$FLATPAK_DIR/org.ergopti.Ergopti.yml"

cat > "$MANIFEST_FILE" << 'MANIFEST_EOF'
# Generated by tools/build/build-linux-flatpak.sh — do not edit by hand.
app-id: org.ergopti.Ergopti
default-branch: stable

# Pinned deliberately: the runtime version decides which glib, GTK and libc the
# daemon and its D-Bus tooling see, and a floating version turns an unrelated
# runtime release into an Ergopti bug report.
runtime: org.freedesktop.Platform
runtime-version: '24.08'
sdk: org.freedesktop.Sdk

command: ergopti

finish-args:
  # THE BROAD ONE, AND THE REASON IT IS NOT NEGOTIABLE.
  # The daemon reads /dev/input/event* (evdev) and writes /dev/uinput to inject
  # keystrokes. --device=input covers /dev/input only; /dev/uinput sits outside
  # that tree, so with anything narrower the daemon can observe and never type.
  # --device=all is the only permission that grants both, and it exposes all of
  # /dev — a real cost, accepted here because an input daemon cannot work
  # without raw device access. See the header of the generating script.
  - --device=all
  # Display server: Wayland when there is one, X11 otherwise. --share=ipc is
  # what makes the X11 fallback usable rather than merely present.
  - --socket=wayland
  - --socket=fallback-x11
  - --share=ipc
  # The session bus carries both halves of the user-facing surface: the tray
  # owns a StatusNotifierItem name on it and hands its menu to the panel's
  # StatusNotifierWatcher, and notifications go to org.freedesktop.Notifications.
  # This is full session-bus access, which is broader than a pair of name
  # policies would be; libayatana-appindicator picks a fresh
  # org.kde.StatusNotifierItem-<pid>-<n> name per instance, so an --own-name
  # filter would have to be a wildcard anyway.
  - --socket=session-bus
  # The LLM features talk to a local Ollama on 127.0.0.1. A sandbox without
  # --share=network gets its own network namespace, where the host's loopback
  # is not the app's loopback and every request fails to connect.
  - --share=network

cleanup:
  - /include
  - /lib/pkgconfig
  - /share/man
  - '*.a'
  - '*.la'

modules:
  # org.freedesktop.Platform does not ship LuaJIT, and the daemon is a LuaJIT
  # program — so it is built here rather than assumed. Upstream's v2.1 branch is
  # the maintained line; a release build should pin `commit:` instead of
  # `branch:` so the bundle is reproducible.
  - name: luajit
    buildsystem: simple
    build-commands:
      - make amalg PREFIX=/app
      - make install PREFIX=/app
      # `make install` installs luajit-<version> and symlinks `luajit` to it.
      # The wrapper execs the unversioned name, so assert it here: a missing
      # symlink must fail the build, not the user's first launch.
      - test -x /app/bin/luajit
    sources:
      - type: git
        url: https://github.com/LuaJIT/LuaJIT.git
        branch: v2.1

  # The driver payload, staged by the generating script. `type: dir` copies the
  # CONTENTS of payload/ into the build directory, so these paths are relative
  # to that: lib/, bin/, share/.
  - name: ergopti
    buildsystem: simple
    build-commands:
      - install -d /app/lib/ergopti
      # The shared tree is staged as a CHILD of the driver root (/app/lib/ergopti/_shared),
      # matching what build-linux-deb.sh installs under /usr/lib/ergopti.
      - cp -r lib/ergopti/. /app/lib/ergopti/
      - install -Dm755 bin/ergopti /app/bin/ergopti
      - install -Dm644 share/applications/org.ergopti.Ergopti.desktop /app/share/applications/org.ergopti.Ergopti.desktop
      - install -Dm644 share/icons/hicolor/scalable/apps/org.ergopti.Ergopti.svg /app/share/icons/hicolor/scalable/apps/org.ergopti.Ergopti.svg
      - install -Dm644 share/metainfo/org.ergopti.Ergopti.metainfo.xml /app/share/metainfo/org.ergopti.Ergopti.metainfo.xml
      # The entry point the wrapper execs must actually be in the image; a
      # payload that staged an empty tree would otherwise produce a bundle that
      # installs cleanly and dies on launch.
      - test -f /app/lib/ergopti/ergopti_hotstrings.lua
    sources:
      - type: dir
        path: payload
MANIFEST_EOF

# Read the id back out of the generated manifest — see above: one source, and a
# typo in it must stop the build here rather than produce a bundle whose desktop
# file and icon are exported under a name nothing references.
APP_ID=$(sed -n 's/^app-id: *//p' "$MANIFEST_FILE" | head -1)
if [ -z "$APP_ID" ]; then
  echo "[ERR] Generated manifest declares no app-id: $MANIFEST_FILE"
  exit 1
fi
echo "  Manifest: $MANIFEST_FILE ($APP_ID)"

# ----------------------------------------------------------------------
# 4. Stage the driver payload
# ----------------------------------------------------------------------
# No '2>/dev/null || true' anywhere below. A staging copy that swallows its own
# failure is how a packager ships an empty package and still exits 0.
echo "Staging driver payload..."
cp -r "$BUILD_DIR/linux/." "$PAYLOAD_DIR/lib/ergopti/"

# The whole shared tree, not just _shared/lua: the keycode tables, hotstring
# packs, locales and the defaults the resolver fails fast on live in
# _shared/data and _shared/modules.
mkdir -p "$PAYLOAD_DIR/lib/ergopti/_shared"
cp -r "$BUILD_DIR/_shared/." "$PAYLOAD_DIR/lib/ergopti/_shared/"

echo "  $(find "$PAYLOAD_DIR/lib/ergopti" -type f | wc -l) files staged for /app/lib/ergopti/"

# ----------------------------------------------------------------------
# 5. Launcher wrapper
# ----------------------------------------------------------------------
cat > "$PAYLOAD_DIR/bin/ergopti" << 'WRAPPER_EOF'
#!/bin/bash
# ergopti launcher — delegates to the LuaJIT driver inside the Flatpak.
# LUA_PATH is what makes require("logger.shim") resolve; without it the daemon
# dies on its first require, before it can log anything useful.
set -euo pipefail
DRIVER_ROOT="/app/lib/ergopti"
SHARED_LUA="$DRIVER_ROOT/_shared/lua"
export LUA_PATH="$DRIVER_ROOT/?.lua;$DRIVER_ROOT/?/init.lua;$SHARED_LUA/?.lua;$SHARED_LUA/?/init.lua;;"
exec luajit /app/lib/ergopti/ergopti_hotstrings.lua "$@"
WRAPPER_EOF
chmod 755 "$PAYLOAD_DIR/bin/ergopti"
echo "  Wrapper: /app/bin/ergopti"

# ----------------------------------------------------------------------
# 6. Desktop entry
# ----------------------------------------------------------------------
# Flatpak only exports files named after the app id, hence the prefixed name.
DESKTOP_FILE="$PAYLOAD_DIR/share/applications/${APP_ID}.desktop"

# --tray for the same reason the packaged systemd units carry it: opts.tray
# defaults to false and the whole menu block is gated on it, so a launcher
# without it yields a daemon with no icon and no menu.
cat > "$DESKTOP_FILE" << 'DESKTOP_EOF'
[Desktop Entry]
Type=Application
Name=Ergopti
Comment=Ergonomic keyboard optimizer — hotstring engine + metrics
Exec=ergopti --tray
Icon=org.ergopti.Ergopti
Terminal=false
Categories=Utility;
DESKTOP_EOF
echo "  Desktop entry: $(basename "$DESKTOP_FILE")"

# ----------------------------------------------------------------------
# 7. Placeholder icon
# ----------------------------------------------------------------------
# SVG rather than the 1x1 PNG the .deb ships: an icon in hicolor/scalable is
# correct at every size, so a placeholder cannot be caught lying about its
# dimensions by AppStream. Replace with the real artwork before publishing.
ICON_FILE="$PAYLOAD_DIR/share/icons/hicolor/scalable/apps/${APP_ID}.svg"

cat > "$ICON_FILE" << 'ICON_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128" viewBox="0 0 128 128">
  <rect width="128" height="128" rx="24" fill="#1E1E2E"/>
  <text x="64" y="90" font-family="sans-serif" font-size="72" font-weight="bold"
        text-anchor="middle" fill="#89B4FA">E</text>
</svg>
ICON_EOF
echo "  Icon placeholder: $(basename "$ICON_FILE")"

# ----------------------------------------------------------------------
# 8. AppStream metadata
# ----------------------------------------------------------------------
# Carries no <releases> block on purpose: a generated date would make this file
# a function of WHEN the packager ran rather than of what it read.
METAINFO_FILE="$PAYLOAD_DIR/share/metainfo/${APP_ID}.metainfo.xml"

cat > "$METAINFO_FILE" << 'METAINFO_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <id>org.ergopti.Ergopti</id>
  <name>Ergopti</name>
  <summary>Ergonomic keyboard optimizer with AI-powered hotstrings</summary>
  <metadata_license>CC0-1.0</metadata_license>
  <project_license>MIT</project_license>
  <developer_name>Ergopti Contributors</developer_name>
  <url type="homepage">https://github.com/adrienm7/ergopti</url>
  <launchable type="desktop-id">org.ergopti.Ergopti.desktop</launchable>
  <description>
    <p>
      Ergopti is a cross-platform keyboard optimizer: an intelligent hotstring
      engine, keystroke metrics, and AI-assisted text expansion. On Linux it
      runs as a user daemon that reads evdev and injects through uinput.
    </p>
    <p>
      This package requires full device access to work, because it reads
      /dev/input and writes /dev/uinput. It also needs the host udev rule and
      the input and uinput group membership that the project installer sets up
      with "install.sh --setup-perms" — without them the daemon starts but
      captures nothing.
    </p>
  </description>
</component>
METAINFO_EOF
echo "  AppStream: $(basename "$METAINFO_FILE")"

# ----------------------------------------------------------------------
# 9. The generated files must all name the same app
# ----------------------------------------------------------------------
# Three files spell the id in three syntaxes (YAML key, .desktop Icon=,
# AppStream <id>). A desktop file pointing at another id exports an icon nothing
# uses and a launcher the software centre cannot match to the app — a failure
# that is invisible until someone installs the bundle.
for generated in "$DESKTOP_FILE" "$METAINFO_FILE"; do
  if ! grep -q "$APP_ID" "$generated"; then
    echo "[ERR] $generated does not name $APP_ID — generated files disagree with the manifest."
    exit 1
  fi
done

# ----------------------------------------------------------------------
# 10. Build the bundle (needs the flatpak toolchain)
# ----------------------------------------------------------------------
echo ""
echo "Structure: $(find "$FLATPAK_DIR" -type f | wc -l) files under $FLATPAK_DIR"

print_manual_commands() {
  echo "To build on a Linux host with flatpak-builder:"
  echo "  flatpak install -y flathub org.freedesktop.Platform//24.08 org.freedesktop.Sdk//24.08"
  echo "  flatpak-builder --force-clean --disable-rofiles-fuse --repo=$REPO_DIR $BUILDER_DIR $MANIFEST_FILE"
  echo "  flatpak build-bundle $REPO_DIR $FLATPAK_FILE $APP_ID $BRANCH"
}

print_host_permission_warning() {
  echo ""
  echo "[!] --device=all lifts the SANDBOX restriction, not the HOST one."
  echo "    The user must still run 'bash install.sh --setup-perms' on the host"
  echo "    (udev rule + input/uinput groups) or the daemon captures nothing."
}

if [ "$SKIP_FLATPAK" = true ]; then
  echo ""
  echo "=== Structure complete (--skip-flatpak) ==="
  print_manual_commands
  print_host_permission_warning
  exit 0
fi

if ! command -v flatpak-builder &>/dev/null || ! command -v flatpak &>/dev/null; then
  echo ""
  echo "=== Structure complete (flatpak toolchain not available) ==="
  print_manual_commands
  print_host_permission_warning
  exit 0
fi

echo ""
echo "Building the Flatpak..."
# --disable-rofiles-fuse: CI containers and many sandboxes have no FUSE, and
# without this flag flatpak-builder aborts before it compiles anything.
flatpak-builder --force-clean --disable-rofiles-fuse \
  --repo="$REPO_DIR" "$BUILDER_DIR" "$MANIFEST_FILE"

rm -f "$FLATPAK_FILE"
flatpak build-bundle "$REPO_DIR" "$FLATPAK_FILE" "$APP_ID" "$BRANCH"

if [ ! -f "$FLATPAK_FILE" ]; then
  echo "[ERR] flatpak build-bundle did not produce a bundle file."
  exit 1
fi

bundle_size=$(du -h "$FLATPAK_FILE" | cut -f1)
echo ""
echo "=== Flatpak built successfully ==="
echo "Bundle: $FLATPAK_FILE ($bundle_size)"
echo ""
echo "Install with: flatpak install --user $FLATPAK_FILE"
echo "Run with:     flatpak run $APP_ID"
print_host_permission_warning
