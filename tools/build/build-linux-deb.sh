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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/build/linux"
DEB_ROOT="$BUILD_DIR/deb"
PACKAGE_NAME="ergopti"
# Extract version from package.json (e.g. "3.0.0") or fall back to "0.1.0"
VERSION=$(node -e "try { process.stdout.write(require('$PROJECT_ROOT/package.json').version) } catch(e) { process.stdout.write('0.1.0') }" 2>/dev/null || echo "0.1.0")
ARCH="amd64"
DEB_FILE="$BUILD_DIR/${PACKAGE_NAME}_${VERSION}_${ARCH}.deb"

echo "=== ergopti .deb packager ==="
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
install -D -m 644 "$BUILD_DIR/linux/install/99-ergopti-uinput.rules" "$DEB_ROOT/etc/udev/rules.d/99-ergopti-uinput.rules"
install -D -m 644 "$BUILD_DIR/linux/install/ergopti-uinput.conf" "$DEB_ROOT/etc/modules-load.d/ergopti-uinput.conf"

file_count=$(find "$DEB_ROOT/usr/lib/ergopti" -type f | wc -l)
echo "  $file_count files copied to /usr/lib/ergopti/"

# ----------------------------------------------------------------------
# 4. Install wrapper script
# ----------------------------------------------------------------------
cat > "$DEB_ROOT/usr/bin/ergopti" << 'WRAPPER_EOF'
#!/bin/bash
# ergopti launcher — delegates to the LuaJIT driver.
# Set LUA_PATH so all driver and shared modules resolve correctly.
DRIVER_ROOT="/usr/lib/ergopti"
SHARED_LUA="$DRIVER_ROOT/_shared/lua"
export LUA_PATH="$DRIVER_ROOT/?.lua;$DRIVER_ROOT/?/init.lua;$SHARED_LUA/?.lua;$SHARED_LUA/?/init.lua;;"
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
Depends: luajit (>= 2.1), xclip, libnotify-bin, curl, libxkbcommon0, libxkbcommon-tools, at-spi2-core, pkexec, kmod, udev, libayatana-appindicator3-1, zenity, login, passwd, util-linux, lua-lgi, gir1.2-webkit2-4.1, glib-networking, gsettings-desktop-schemas, lua-luv, libxkbcommon-x11-0, libx11-6, libx11-xcb1
Recommends: lua-luv, lua-filesystem, openssl, xdotool, wl-clipboard
Section: utils
Priority: optional
Homepage: https://github.com/adrienm7/ergopti
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

bash /usr/lib/ergopti/install/setup_permissions.sh --active-sessions
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

# ----------------------------------------------------------------------
# 10. Build the .deb (Linux only)
# ----------------------------------------------------------------------
if [ "${1:-}" = "--skip-deb" ]; then
  echo ""
  echo "=== Structure complete (--skip-deb) ==="
  echo "DEB root: $DEB_ROOT"
  echo "Files: $(find "$DEB_ROOT" -type f | wc -l)"
  echo "To package: dpkg-deb --build $DEB_ROOT $DEB_FILE"
  exit 0
fi

if ! command -v dpkg-deb &>/dev/null; then
  echo ""
  echo "=== Structure complete (dpkg-deb not available) ==="
  echo "DEB root: $DEB_ROOT"
  echo "Files: $(find "$DEB_ROOT" -type f | wc -l)"
  echo "Run on Linux to package: dpkg-deb --build $DEB_ROOT $DEB_FILE"
  exit 0
fi

echo ""
echo "Building .deb package..."
dpkg-deb --build "$DEB_ROOT" "$DEB_FILE"

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
