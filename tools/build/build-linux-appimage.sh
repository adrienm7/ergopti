#!/usr/bin/env bash
# tools/build/build-linux-appimage.sh
#
# Assembles an AppImage of the Ergopti+ Linux driver from the build/linux/
# bundle produced by build-linux-driver.sh. Sibling of build-linux-deb.sh and
# build-linux-rpm.sh: same bundle in, a different installable artifact out.
#
# It produces exactly two things:
#   1. build/linux/AppDir/                            — the staged AppDir:
#        AppDir/AppRun                                  entry point
#        AppDir/ergopti.desktop                         desktop entry
#        AppDir/ergopti.png                             application icon
#        AppDir/usr/bin/ergopti                         launcher, forwards to AppRun
#        AppDir/usr/bin/luajit                          required bundled runtime
#        AppDir/usr/lib/ergopti/                        driver tree, flat
#        AppDir/usr/lib/ergopti/_shared/                shared tree, as a child
#   2. build/linux/Ergopti-<version>-x86_64.AppImage  — only when appimagetool is
#      on PATH. Without it the AppDir is left staged and the manual packaging
#      command is printed. Actual native staging requires Linux x86_64.
#
# LuaJIT, luv, curl, native GIO modules, schemas and their linked ELF closure
# are bundled from trusted build-host packages. The recipient supplies glibc
# and certificate trust; this remains a similar-vintage Linux package rather
# than universal binary compatibility. Missing components refuse packaging.
# Native admission does not prove physical input, PAC or desktop settings.
#
# The shared tree is staged as a CHILD of the driver root
# (usr/lib/ergopti/_shared), matching build-linux-deb.sh and build-linux-rpm.sh.
# Three packagers agreeing on one layout is worth more than each being clever.
#
# Usage:
#   bash tools/build/build-linux-appimage.sh
#     (stage the AppDir, then package it with appimagetool)
#
#   bash tools/build/build-linux-appimage.sh --skip-appimage
#     (stage and validate the AppDir only — never invokes appimagetool)

set -euo pipefail

# Parsed up front and strictly: a mistyped flag that is silently ignored turns a
# "validated" build into a build that validated nothing. The sibling packagers
# read their skip flag positionally and late, so `--skip-de` reaches dpkg-deb.
SKIP_APPIMAGE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-appimage) SKIP_APPIMAGE=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/build/linux"
APPDIR="$BUILD_DIR/AppDir"
APPDIR_LIB="$APPDIR/usr/lib/ergopti"
PACKAGE_NAME="ergopti"
# Extract version from package.json (e.g. "3.0.0") or fall back to "0.1.0"
VERSION=$(node -e "try { process.stdout.write(require('$PROJECT_ROOT/package.json').version) } catch(e) { process.stdout.write('0.1.0') }" 2>/dev/null || echo "0.1.0")
ARCH="x86_64"
APPIMAGE_FILE="$BUILD_DIR/Ergopti-${VERSION}-${ARCH}.AppImage"

echo "=== ergopti AppImage packager ==="
echo "Package: $PACKAGE_NAME $VERSION ($ARCH)"
echo ""

# ----------------------------------------------------------------------
# 1. Ensure the driver bundle exists
# ----------------------------------------------------------------------
if [ ! -d "$BUILD_DIR" ] || [ ! -f "$BUILD_DIR/linux/ergopti_hotstrings.lua" ]; then
  echo "[ERR] Driver bundle not found at $BUILD_DIR"
  echo "      Run 'bash tools/build/build-linux-driver.sh' first."
  exit 1
fi

# Counted over the two bundle trees, not over build/linux as a whole: the AppDir
# is staged inside build/linux and is not yet removed at this point, so a whole
# directory count doubles on the second run and reports a bundle that grew.
echo "[OK] Driver bundle found: $(find "$BUILD_DIR/linux" "$BUILD_DIR/_shared" -type f | wc -l) files"

# ----------------------------------------------------------------------
# 2. Create the AppDir skeleton
# ----------------------------------------------------------------------
rm -rf "$APPDIR"
mkdir -p "$APPDIR_LIB"
mkdir -p "$APPDIR_LIB/_shared"
mkdir -p "$APPDIR/usr/bin"

# ----------------------------------------------------------------------
# 3. Stage the driver payload
# ----------------------------------------------------------------------
echo "Copying driver files..."

# Whole-tree copies, with no error suppression. Enumerating subdirectories the
# way the .deb packager does needs a `|| true` on every line to survive the
# trees the builder excludes (vendor/), and that suffix is exactly what let the
# PKGBUILD ship a package with no driver in it. It also silently omits
# platform/, which carries the remap and tap-hold engine. One copy, allowed to fail.
cp -r "$BUILD_DIR/linux/." "$APPDIR_LIB/"
cp -r "$BUILD_DIR/_shared/." "$APPDIR_LIB/_shared/"
# The stamp build-linux-driver.sh wrote is how the mounted daemon names its
# commit; an image without it would report "unknown".
bash "$SCRIPT_DIR/write_build_stamp.sh" verify "$APPDIR_LIB/_shared"

# Proof the payload actually landed, rather than the assumption that it did.
# An AppImage that packages cleanly around a missing driver is the worst
# possible outcome: it installs, it launches, and it fails on the target.
REQUIRED_PAYLOAD=(
  "ergopti_hotstrings.lua"
  "modules/hotstrings/engine.lua"
  "infra/paths.lua"
  "adapters/tray_menu.lua"
  "ui/webkit_host.lua"
  "_shared/lua/hotstring_engine/init.lua"
  "_shared/lua/json.lua"
  "_shared/data/keycodes/evdev.json"
  "_shared/data/locales/fr.json"
  "_shared/modules/timings/constants.toml"
  "_shared/modules/llm/defaults.json"
)

MISSING=0
for payload in "${REQUIRED_PAYLOAD[@]}"; do
  if [ ! -f "$APPDIR_LIB/$payload" ]; then
    echo "  MISSING: usr/lib/ergopti/$payload"
    MISSING=$((MISSING + 1))
  fi
done

if [ "$MISSING" -gt 0 ]; then
  echo "[ERR] $MISSING required payload file(s) absent from the staged AppDir."
  echo "      Rebuild the bundle with 'bash tools/build/build-linux-driver.sh'."
  exit 1
fi

file_count=$(find "$APPDIR_LIB" -type f | wc -l)
echo "  $file_count files copied to usr/lib/ergopti/"
echo "  Payload check: all ${#REQUIRED_PAYLOAD[@]} required file(s) present"

# ----------------------------------------------------------------------
# 4. Stage and admit the actual native network runtime
# ----------------------------------------------------------------------
# Missing build-host prerequisites are a packaging failure. The same-vintage
# glibc restriction remains; copying an executable alone is not ELF closure.
python3 "$SCRIPT_DIR/stage-linux-network-runtime.py" \
  --appdir "$APPDIR" \
  --catalogue "$PROJECT_ROOT/static/ergopti_plus/_shared/data/linux_native_runtime.json" \
  --template "$SCRIPT_DIR/templates/linux-portable-runtime-env.sh"

# ----------------------------------------------------------------------
# 5. AppRun — the single entry point
# ----------------------------------------------------------------------
cat > "$APPDIR/AppRun" << 'APPRUN_EOF'
#!/bin/bash
# AppRun — entry point of the Ergopti AppImage.
# Resolves the driver root, LUA_PATH and the LuaJIT binary, then execs the
# driver. This is the ONLY place those three are decided; usr/bin/ergopti
# forwards here rather than deriving its own.
set -euo pipefail

# An AppImage is mounted at a fresh temporary path on every run, so nothing
# inside it may be resolved from an absolute /usr prefix the way the .deb
# wrapper can. HERE is that mount point.
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd -P)"

DRIVER_ROOT="$HERE/usr/lib/ergopti"
SHARED_LUA="$DRIVER_ROOT/_shared/lua"
source "$DRIVER_ROOT/network-runtime-env.sh" "$HERE/usr" "$DRIVER_ROOT"
LUAJIT_BIN="$HERE/usr/bin/luajit"

# No arguments means a desktop launch, and the driver gates its whole tray and
# menu block on --tray. Without it the user gets a running daemon with no icon
# and no menu, and no way to tell it started at all.
if [ "$#" -eq 0 ]; then
  exec "$LUAJIT_BIN" "$DRIVER_ROOT/ergopti_hotstrings.lua" --tray
fi

exec "$LUAJIT_BIN" "$DRIVER_ROOT/ergopti_hotstrings.lua" "$@"
APPRUN_EOF
chmod 755 "$APPDIR/AppRun"
echo "  Entry point: AppRun"

# ----------------------------------------------------------------------
# 6. Launcher script
# ----------------------------------------------------------------------
cat > "$APPDIR/usr/bin/ergopti" << 'WRAPPER_EOF'
#!/bin/bash
# ergopti launcher — forwards to AppRun.
# Two entry points that each built their own LUA_PATH would drift apart, and the
# one nobody launches by hand is the one that would ship broken.
set -euo pipefail
BIN_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd -P)"
exec "$BIN_DIR/../../AppRun" "$@"
WRAPPER_EOF
chmod 755 "$APPDIR/usr/bin/ergopti"
echo "  Launcher: usr/bin/ergopti"

# ----------------------------------------------------------------------
# 7. Desktop entry
# ----------------------------------------------------------------------
# appimagetool refuses an AppDir without a top-level .desktop file, and matches
# its Icon key against the icon file sitting beside it.
cat > "$APPDIR/ergopti.desktop" << 'DESKTOP_EOF'
[Desktop Entry]
Type=Application
Name=Ergopti
Comment=Ergonomic keyboard optimizer — hotstring engine + metrics
Exec=ergopti
Icon=ergopti
Terminal=false
Categories=Utility;
X-GNOME-Autostart-enabled=true
DESKTOP_EOF
echo "  Desktop entry: ergopti.desktop"

# ----------------------------------------------------------------------
# 8. Application icon
# ----------------------------------------------------------------------
install -m 644 "$BUILD_DIR/_shared/assets/ergopti_tray.png" "$APPDIR/ergopti.png"

echo "  Application icon: ergopti.png"

# ----------------------------------------------------------------------
# 9. Build the AppImage (Linux only)
# ----------------------------------------------------------------------
if [ "$SKIP_APPIMAGE" = true ]; then
  echo ""
  echo "=== AppDir complete (--skip-appimage) ==="
  echo "AppDir: $APPDIR"
  echo "Files: $(find "$APPDIR" -type f | wc -l)"
  echo "To package: ARCH=$ARCH appimagetool $APPDIR $APPIMAGE_FILE"
  exit 0
fi

if ! command -v appimagetool &>/dev/null; then
  echo ""
  echo "=== AppDir complete (appimagetool not available) ==="
  echo "AppDir: $APPDIR"
  echo "Files: $(find "$APPDIR" -type f | wc -l)"
  echo "Run on Linux to package: ARCH=$ARCH appimagetool $APPDIR $APPIMAGE_FILE"
  exit 0
fi

echo ""
echo "Building AppImage..."
ARCH="$ARCH" appimagetool "$APPDIR" "$APPIMAGE_FILE"

if [ -f "$APPIMAGE_FILE" ]; then
  appimage_size=$(du -h "$APPIMAGE_FILE" | cut -f1)
  echo ""
  echo "=== AppImage built successfully ==="
  echo "Package: $APPIMAGE_FILE ($appimage_size)"
  echo ""
  echo "Run with: chmod +x $APPIMAGE_FILE && $APPIMAGE_FILE"
else
  echo "[ERR] appimagetool did not produce an AppImage file."
  exit 1
fi
