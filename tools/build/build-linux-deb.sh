# tools/build/build-linux-deb.sh
#
# Assembles a .deb package from the build/linux/ driver bundle.
# Requires dpkg-deb (Linux only). The script is runnable on any platform
# to validate structure, but dpkg-deb packaging requires Linux.
#
# Usage:
#   bash tools/build/build-linux-deb.sh              # full build + .deb
#   bash tools/build/build-linux-deb.sh --skip-deb   # structure only (cross-platform)

set -euo pipefail

SKIP_DEB=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-deb) SKIP_DEB=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if ! "$SKIP_DEB" && ! command -v dpkg-deb >/dev/null 2>&1; then
  echo "[ERR] dpkg-deb is required to build a .deb; use --skip-deb for staging only." >&2
  exit 69
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IFS= read -r -d '' PROJECT_ROOT < <(cd -- "$SCRIPT_DIR/../.." && printf '%s\0' "$PWD")
# The external hosts are declared once in _shared/data/identifiers.json.
# shellcheck source=../../static/ergopti_plus/_shared/data/identifiers.sh
. "$PROJECT_ROOT/static/ergopti_plus/_shared/data/identifiers.sh"
# A caller that runs several builds at once gives each its own output directory.
BUILD_DIR="${ERGOPTI_LINUX_BUILD_DIR:-$PROJECT_ROOT/build/linux}"
case "$BUILD_DIR" in
  /?*) ;;
  *) echo "[ERR] ERGOPTI_LINUX_BUILD_DIR must be an absolute path, got '$BUILD_DIR'" >&2; exit 1 ;;
esac
DEB_ROOT="$BUILD_DIR/deb"
PACKAGE_NAME="ergopti"
ARCH="amd64"

echo "=== ergopti .deb packager ==="
echo ""

# ----------------------------------------------------------------------
# 1. Ensure the driver bundle exists
# ----------------------------------------------------------------------
if [ ! -d "$BUILD_DIR" ] || [ ! -f "$BUILD_DIR/linux/ergopti_hotstrings.lua" ]; then
  echo "[ERR] Driver bundle not found at $BUILD_DIR"
  echo "      Run 'bash tools/build/build-linux-driver.sh' first."
  exit 1
fi

echo "[OK] Driver bundle found: $(find "$BUILD_DIR" -type f | wc -l) files"

# ----------------------------------------------------------------------
# 2. Create .deb directory structure
# ----------------------------------------------------------------------
rm -rf "$DEB_ROOT"
mkdir -p "$DEB_ROOT/DEBIAN"
mkdir -p "$DEB_ROOT/usr/lib/ergopti"
mkdir -p "$DEB_ROOT/usr/bin"
mkdir -p "$DEB_ROOT/usr/share/applications"
mkdir -p "$DEB_ROOT/usr/share/icons/hicolor/512x512/apps"
mkdir -p "$DEB_ROOT/etc/ergopti"
mkdir -p "$DEB_ROOT/usr/lib/systemd/user"

# ----------------------------------------------------------------------
# 3. Copy driver files
# ----------------------------------------------------------------------
echo "Copying driver files..."
# The whole driver tree, not a list of directories to remember. The list this
# replaced named *.lua, modules, adapters, infra, ui and vendor — so it silently
# dropped _generated (without which the daemon refuses to start) and platform
# (the remap and tap-hold engine), while vendor had already stopped existing in the
# bundle. Every line also ended in `2>/dev/null || true`, so none of that made a
# sound. Tests are the one thing a system package has no use for.
cp -r "$BUILD_DIR/linux/." "$DEB_ROOT/usr/lib/ergopti/"
rm -rf "$DEB_ROOT/usr/lib/ergopti/tests" "$DEB_ROOT/usr/lib/ergopti/__pycache__"

# The assembled bundle is the runtime closure. Copy it whole so newly shared
# roots such as tap_hold/ cannot disappear from only the system packages.
mkdir -p "$DEB_ROOT/usr/lib/ergopti/_shared"
cp -r "$BUILD_DIR/_shared/." "$DEB_ROOT/usr/lib/ergopti/_shared/"
# The stamp build-linux-driver.sh wrote is how the installed daemon names its
# commit; a package without it would report "unknown".
bash "$SCRIPT_DIR/write_build_stamp.sh" verify "$DEB_ROOT/usr/lib/ergopti/_shared"
VERSION=$(node "$SCRIPT_DIR/linux-package-version.cjs" deb "$DEB_ROOT/usr/lib/ergopti/_shared" "$PROJECT_ROOT/package.json")
DEB_FILE="$BUILD_DIR/${PACKAGE_NAME}_${VERSION}_${ARCH}.deb"
echo "Package: $PACKAGE_NAME $VERSION ($ARCH)"
install -D -m 644 "$BUILD_DIR/linux/install/99-ergopti-uinput.rules" "$DEB_ROOT/etc/udev/rules.d/99-ergopti-uinput.rules"
install -D -m 644 "$BUILD_DIR/linux/install/ergopti-uinput.conf" "$DEB_ROOT/etc/modules-load.d/ergopti-uinput.conf"

# The private runtime the AppImage stages on the oldest supported LTS: LuaJIT,
# luv, luafilesystem, luaposix, curl, sqlite3, openssl and zstd run from here,
# never from a host package (owned runtimes, PIN).
bash "$SCRIPT_DIR/stage-linux-private-runtime.sh" "$BUILD_DIR/AppDir" "$DEB_ROOT/usr/lib/ergopti/runtime" /usr/lib/ergopti
install -m 644 "$BUILD_DIR/AppDir/usr/lib/ergopti/network-runtime-env.sh" "$DEB_ROOT/usr/lib/ergopti/network-runtime-env.sh"

file_count=$(find "$DEB_ROOT/usr/lib/ergopti" -type f | wc -l)
echo "  $file_count files copied to /usr/lib/ergopti/"

# ----------------------------------------------------------------------
# 4. Install wrapper script
# ----------------------------------------------------------------------
cat > "$DEB_ROOT/usr/bin/ergopti" << 'WRAPPER_EOF'
#!/bin/bash
# ergopti launcher — delegates to the LuaJIT driver.
# The package's private runtime decides LUA_PATH, LUA_CPATH and the programs
# the driver runs (network-runtime-env.sh, shared with the AppImage).
set -euo pipefail
DRIVER_ROOT="/usr/lib/ergopti"
source "$DRIVER_ROOT/network-runtime-env.sh" "$DRIVER_ROOT/runtime" "$DRIVER_ROOT"
exec bash "$DRIVER_ROOT/install/launch.sh" "$@"
WRAPPER_EOF
chmod 755 "$DEB_ROOT/usr/bin/ergopti"
echo "  Wrapper: /usr/bin/ergopti"

# ----------------------------------------------------------------------
# 5. Desktop entry (autostart)
# ----------------------------------------------------------------------
cat > "$DEB_ROOT/usr/share/applications/ergopti.desktop" << 'DESKTOP_EOF'
[Desktop Entry]
Type=Application
Name=Ergopti
Comment=Ergonomic keyboard optimizer — hotstring engine + metrics
Exec=ergopti --tray
Icon=ergopti
Terminal=false
Categories=Utility;
X-GNOME-Autostart-enabled=true
DESKTOP_EOF
mkdir -p "$DEB_ROOT/etc/xdg/autostart"
sed 's|^Exec=.*|Exec=ergopti --session-start --tray|' \
  "$DEB_ROOT/usr/share/applications/ergopti.desktop" \
  > "$DEB_ROOT/etc/xdg/autostart/ergopti.desktop"
echo "  Desktop entry: ergopti.desktop"

# ----------------------------------------------------------------------
# 6. Application icon
# ----------------------------------------------------------------------
install -m 644 "$BUILD_DIR/_shared/assets/ergopti_tray.png" "$DEB_ROOT/usr/share/icons/hicolor/512x512/apps/ergopti.png"

echo "  Application icon: ergopti.png"

# ----------------------------------------------------------------------
# 7. Default config template
# ----------------------------------------------------------------------
if [ -f "$BUILD_DIR/linux/_generated/config_template.toml" ]; then
  cp "$BUILD_DIR/linux/_generated/config_template.toml" \
     "$DEB_ROOT/etc/ergopti/config.toml"
else
  cat > "$DEB_ROOT/etc/ergopti/config.toml" << 'CONFIG_EOF'
# ergopti default configuration
# Edit this file to customize hotstrings, LLM settings, and metrics.

[general]
language = "fr"
driver   = "linux"

[llm]
port = 11434
model = "codellama"

[hotstrings]
enabled = true
CONFIG_EOF
fi
echo "  Config: /etc/ergopti/config.toml"

# ----------------------------------------------------------------------
# 8. systemd user service
# ----------------------------------------------------------------------
# ONE unit name across every packager. This file used to install
# ergopti-hotstrings.service while install.sh installed ergopti-hotstrings.service, so a
# user who did both ended up with two enabled units — both grabbing the keyboard.
sed 's|^ExecStart=.*|ExecStart=/usr/bin/ergopti --service --tray|' \
  "$BUILD_DIR/linux/ergopti-hotstrings.service" \
  > "$DEB_ROOT/usr/lib/systemd/user/ergopti-hotstrings.service"
echo "  systemd service: ergopti-hotstrings.service"

# ----------------------------------------------------------------------
# 9. DEBIAN control files
# ----------------------------------------------------------------------
cat > "$DEB_ROOT/DEBIAN/control" << CONTROL_EOF
Package: $PACKAGE_NAME
Version: $VERSION
Architecture: $ARCH
Maintainer: Ergopti Contributors <ergopti@example.com>
Depends: xclip, libnotify-bin, libxkbcommon0, libxkbcommon-tools, at-spi2-core, pkexec, kmod, udev, libayatana-appindicator3-1, login, passwd, util-linux, lua-lgi, gir1.2-webkit2-4.1, glib-networking, gsettings-desktop-schemas, xdg-utils, libsecret-tools, libxkbcommon-x11-0, libx11-6, libx11-xcb1
Recommends: xdotool, wmctrl, wl-clipboard
Section: utils
Priority: optional
Homepage: https://$ERGOPTI_HOST_GITHUB/adrienm7/ergopti
Description: Ergonomic keyboard optimizer with AI-powered hotstrings
 Ergopti is a cross-platform keyboard optimizer that provides an
 intelligent hotstring engine, keystroke metrics, and AI-assisted
 text expansion. It runs as a user daemon on Linux via systemd.
CONTROL_EOF
echo "  DEBIAN/control"
printf '%s\n' /etc/udev/rules.d/99-ergopti-uinput.rules /etc/modules-load.d/ergopti-uinput.conf > "$DEB_ROOT/DEBIAN/conffiles"

cat > "$DEB_ROOT/DEBIAN/postinst" << 'POSTINST_EOF'
#!/bin/bash
set -e

case "${1:-}" in
  configure) bash /usr/lib/ergopti/install/setup_permissions.sh --active-sessions ;;
esac
POSTINST_EOF
chmod 755 "$DEB_ROOT/DEBIAN/postinst"
echo "  DEBIAN/postinst"

cat > "$DEB_ROOT/DEBIAN/prerm" << 'PRERM_EOF'
#!/bin/bash
set -e

case "$1" in
  remove|deconfigure) bash /usr/lib/ergopti/install/stop_sessions.sh ;;
esac
PRERM_EOF
chmod 755 "$DEB_ROOT/DEBIAN/prerm"
echo "  DEBIAN/prerm"

# A private checkout or umask must not become the installed system payload's
# access policy. Normalize only the owned copy, preserving executable intent;
# source files and symlink targets outside this staging tree remain untouched.
chmod -R u=rwX,go=rX "$DEB_ROOT"

# ----------------------------------------------------------------------
# 10. Build the .deb (Linux only)
# ----------------------------------------------------------------------
print_packaging_command() {
  printf '%s dpkg-deb --root-owner-group --build %q %q\n' "$1" "$DEB_ROOT" "$DEB_FILE"
}

if [ "$SKIP_DEB" = true ]; then
  echo ""
  echo "=== Structure complete (--skip-deb) ==="
  echo "DEB root: $DEB_ROOT"
  echo "Files: $(find "$DEB_ROOT" -type f | wc -l)"
  print_packaging_command "To package:"
  exit 0
fi

echo ""
echo "Building .deb package..."
DEB_STAGE="$(mktemp -d "$BUILD_DIR/.ergopti-deb.XXXXXX")"
DEB_STAGE_FILE="$DEB_STAGE/${PACKAGE_NAME}_${VERSION}_${ARCH}.deb"
cleanup_deb_stage() {
  status=$?
  trap - EXIT
  if [ -e "$DEB_STAGE_FILE" ] || [ -L "$DEB_STAGE_FILE" ]; then
    rm -f -- "$DEB_STAGE_FILE" || status=1
  fi
  rmdir -- "$DEB_STAGE" || status=1
  exit "$status"
}
trap cleanup_deb_stage EXIT
dpkg-deb --root-owner-group --build "$DEB_ROOT" "$DEB_STAGE_FILE"
[ -f "$DEB_STAGE_FILE" ] && [ ! -L "$DEB_STAGE_FILE" ] && [ -s "$DEB_STAGE_FILE" ] || {
  echo "[ERR] dpkg-deb did not produce a nonempty package file." >&2
  exit 1
}
mv -T -- "$DEB_STAGE_FILE" "$DEB_FILE"

if [ -f "$DEB_FILE" ]; then
  deb_size=$(du -h "$DEB_FILE" | cut -f1)
  echo ""
  echo "=== .deb built successfully ==="
  echo "Package: $DEB_FILE ($deb_size)"
  echo ""
  echo "Install with: sudo dpkg -i $DEB_FILE"
  echo "Or:           sudo apt install $DEB_FILE"
else
  echo "[ERR] dpkg-deb did not produce a package file."
  exit 1
fi
