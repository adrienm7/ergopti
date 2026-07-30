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
mkdir -p "$DEB_ROOT/usr/share/icons/hicolor/128x128/apps"
mkdir -p "$DEB_ROOT/etc/ergopti"
mkdir -p "$DEB_ROOT/usr/lib/systemd/user"

# ----------------------------------------------------------------------
# 3. Copy driver files
# ----------------------------------------------------------------------
echo "Copying driver files..."
cp -r "$BUILD_DIR"/linux/*.lua "$DEB_ROOT/usr/lib/ergopti/" 2>/dev/null || true
cp -r "$BUILD_DIR"/linux/modules "$DEB_ROOT/usr/lib/ergopti/" 2>/dev/null || true
cp -r "$BUILD_DIR"/linux/adapters "$DEB_ROOT/usr/lib/ergopti/" 2>/dev/null || true
cp -r "$BUILD_DIR"/linux/lib "$DEB_ROOT/usr/lib/ergopti/" 2>/dev/null || true
cp -r "$BUILD_DIR"/linux/ui "$DEB_ROOT/usr/lib/ergopti/" 2>/dev/null || true
cp -r "$BUILD_DIR"/linux/vendor "$DEB_ROOT/usr/lib/ergopti/" 2>/dev/null || true

# Copy shared modules (from _shared/lua in the assembled bundle)
if [ -d "$BUILD_DIR/_shared/lua" ]; then
  mkdir -p "$DEB_ROOT/usr/lib/ergopti/_shared"
  cp -r "$BUILD_DIR/_shared/lua" "$DEB_ROOT/usr/lib/ergopti/_shared/"
fi

# Copy shared data files (locales, keycodes — needed at runtime)
if [ -d "$BUILD_DIR/_shared/data" ]; then
  mkdir -p "$DEB_ROOT/usr/lib/ergopti/_shared"
  cp -r "$BUILD_DIR/_shared/data" "$DEB_ROOT/usr/lib/ergopti/_shared/"
fi

# Copy shared modules config (timings/constants.toml, llm/defaults.json, etc.)
if [ -d "$BUILD_DIR/_shared/modules" ]; then
  mkdir -p "$DEB_ROOT/usr/lib/ergopti/_shared"
  cp -r "$BUILD_DIR/_shared/modules" "$DEB_ROOT/usr/lib/ergopti/_shared/"
fi

# Copy shared UI files (host_bridge.js, i18n.js — needed by webkit_host)
if [ -d "$BUILD_DIR/_shared/ui" ]; then
  mkdir -p "$DEB_ROOT/usr/lib/ergopti/_shared"
  cp -r "$BUILD_DIR/_shared/ui" "$DEB_ROOT/usr/lib/ergopti/_shared/"
fi

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
exec luajit /usr/lib/ergopti/ergopti_hotstrings.lua "$@"
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
Exec=ergopti
Icon=ergopti
Terminal=false
Categories=Utility;
X-GNOME-Autostart-enabled=true
DESKTOP_EOF
echo "  Desktop entry: ergopti.desktop"

# ----------------------------------------------------------------------
# 6. Placeholder icon
# ----------------------------------------------------------------------
# Generate a minimal 1x1 PNG as placeholder (valid PNG header)
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x02\x00\x00\x00\x90wS\xde\x00\x00\x00\x0cIDATx\x9cc\xf8\x0f\x00\x00\x01\x01\x00\x05\x18\xd8N\x00\x00\x00\x00IEND\xaeB`\x82' \
  > "$DEB_ROOT/usr/share/icons/hicolor/128x128/apps/ergopti.png" 2>/dev/null || \
  touch "$DEB_ROOT/usr/share/icons/hicolor/128x128/apps/ergopti.png"
echo "  Icon placeholder: ergopti.png"

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
cat > "$DEB_ROOT/usr/lib/systemd/user/ergopti.service" << 'SERVICE_EOF'
[Unit]
Description=Ergopti — ergonomic keyboard optimizer
Documentation=https://github.com/adrienm7/ergopti
After=graphical-session.target

[Service]
Type=simple
ExecStart=/usr/bin/ergopti --tray
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
SERVICE_EOF
echo "  systemd service: ergopti.service"

# ----------------------------------------------------------------------
# 9. DEBIAN control files
# ----------------------------------------------------------------------
cat > "$DEB_ROOT/DEBIAN/control" << CONTROL_EOF
Package: $PACKAGE_NAME
Version: $VERSION
Architecture: $ARCH
Maintainer: Ergopti Contributors <ergopti@example.com>
Depends: luajit (>= 2.1), ydotool, xdotool, xclip, libnotify-bin, curl
Recommends: lua-luv, lua-filesystem, openssl, kanata
Section: utils
Priority: optional
Homepage: https://github.com/adrienm7/ergopti
Description: Ergonomic keyboard optimizer with AI-powered hotstrings
 Ergopti is a cross-platform keyboard optimizer that provides an
 intelligent hotstring engine, keystroke metrics, and AI-assisted
 text expansion. It runs as a user daemon on Linux via systemd.
CONTROL_EOF
echo "  DEBIAN/control"

cat > "$DEB_ROOT/DEBIAN/postinst" << 'POSTINST_EOF'
#!/bin/bash
set -e

# Enable and start the systemd user service for all human users
for uid in $(awk -F: '$3 >= 1000 && $3 < 65534 {print $1}' /etc/passwd); do
  homedir=$(eval echo ~"$uid")
  if [ -d "$homedir" ]; then
    # Enable the user service (runs as the user, not root)
    su - "$uid" -c "systemctl --user daemon-reload" 2>/dev/null || true
    su - "$uid" -c "systemctl --user enable ergopti.service" 2>/dev/null || true
  fi
done

echo "ergopti: user service enabled. Start manually with:"
echo "  systemctl --user start ergopti.service"
POSTINST_EOF
chmod 755 "$DEB_ROOT/DEBIAN/postinst"
echo "  DEBIAN/postinst"

cat > "$DEB_ROOT/DEBIAN/prerm" << 'PRERM_EOF'
#!/bin/bash
set -e

# Stop the user service before removal
for uid in $(awk -F: '$3 >= 1000 && $3 < 65534 {print $1}' /etc/passwd); do
  su - "$uid" -c "systemctl --user stop ergopti.service" 2>/dev/null || true
  su - "$uid" -c "systemctl --user disable ergopti.service" 2>/dev/null || true
done
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
