#!/usr/bin/env bash
# tools/build/build-linux-rpm.sh
#
# Assembles a .rpm package from the build/linux/ driver bundle.
# Requires rpm-build (Linux only). The script validates structure on any platform
# but actual .rpm creation requires rpmbuild.
#
# Usage:
#   bash tools/build/build-linux-rpm.sh              # full build + .rpm
#   bash tools/build/build-linux-rpm.sh --skip-rpm   # structure only (cross-platform)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/build/linux"
RPM_ROOT="$BUILD_DIR/rpm"
PACKAGE_NAME="ergopti"
VERSION=$(node -e "try { process.stdout.write(require('$PROJECT_ROOT/package.json').version) } catch(e) { process.stdout.write('0.1.0') }" 2>/dev/null || echo "0.1.0")
ARCH="x86_64"
RELEASE="1"

echo "=== ergopti .rpm packager ==="
echo "Package: $PACKAGE_NAME $VERSION-$RELEASE ($ARCH)"
echo ""

# ----------------------------------------------------------------------
# 1. Ensure the driver bundle exists
# ----------------------------------------------------------------------
if [ ! -d "$BUILD_DIR" ] || [ ! -f "$BUILD_DIR/linux/ergopti_hotstrings.lua" ]; then
  echo "[ERR] Driver bundle not found at $BUILD_DIR"
  echo "      Run 'bash tools/build/build-linux-driver.sh' first."
  exit 1
fi

echo "[OK] Driver bundle found."

# ----------------------------------------------------------------------
# 2. Create .rpm directory structure
# ----------------------------------------------------------------------
rm -rf "$RPM_ROOT"
mkdir -p "$RPM_ROOT/BUILD"
mkdir -p "$RPM_ROOT/RPMS"
mkdir -p "$RPM_ROOT/SOURCES"
mkdir -p "$RPM_ROOT/SPECS"
mkdir -p "$RPM_ROOT/SRPMS"

# Target install tree
INSTALL_ROOT="$RPM_ROOT/BUILD/ergopti-$VERSION"
rm -rf "$INSTALL_ROOT"
mkdir -p "$INSTALL_ROOT/usr/lib/ergopti"
mkdir -p "$INSTALL_ROOT/usr/bin"
mkdir -p "$INSTALL_ROOT/usr/share/applications"
mkdir -p "$INSTALL_ROOT/usr/share/icons/hicolor/512x512/apps"
mkdir -p "$INSTALL_ROOT/etc/ergopti"
mkdir -p "$INSTALL_ROOT/usr/lib/systemd/user"

# ----------------------------------------------------------------------
# 3. Copy driver files
# ----------------------------------------------------------------------
echo "Copying driver files..."
# The whole driver tree — see build-linux-deb.sh for why the per-directory list
# this replaced was a bug: it dropped _generated and platform, and said nothing.
cp -r "$BUILD_DIR/linux/." "$INSTALL_ROOT/usr/lib/ergopti/"
rm -rf "$INSTALL_ROOT/usr/lib/ergopti/tests" "$INSTALL_ROOT/usr/lib/ergopti/__pycache__"

# The assembled bundle is the runtime closure. Copy it whole so newly shared
# roots such as tap_hold/ cannot disappear from only the system packages.
mkdir -p "$INSTALL_ROOT/usr/lib/ergopti/_shared"
cp -r "$BUILD_DIR/_shared/." "$INSTALL_ROOT/usr/lib/ergopti/_shared/"
# The stamp build-linux-driver.sh wrote is how the installed daemon names its
# commit; a package without it would report "unknown".
bash "$SCRIPT_DIR/write_build_stamp.sh" verify "$INSTALL_ROOT/usr/lib/ergopti/_shared"
install -D -m 644 "$BUILD_DIR/linux/install/99-ergopti-uinput.rules" "$INSTALL_ROOT/etc/udev/rules.d/99-ergopti-uinput.rules"
install -D -m 644 "$BUILD_DIR/linux/install/ergopti-uinput.conf" "$INSTALL_ROOT/etc/modules-load.d/ergopti-uinput.conf"

chmod -R 755 "$INSTALL_ROOT/usr/lib/ergopti"
echo "  $(find "$INSTALL_ROOT/usr/lib/ergopti" -type f | wc -l) files"

# ----------------------------------------------------------------------
# 4. Wrapper script
# ----------------------------------------------------------------------
cat > "$INSTALL_ROOT/usr/bin/ergopti" << 'WRAPPER_EOF'
#!/bin/bash
DRIVER_ROOT="/usr/lib/ergopti"
SHARED_LUA="$DRIVER_ROOT/_shared/lua"
export LUA_PATH="$DRIVER_ROOT/?.lua;$DRIVER_ROOT/?/init.lua;$SHARED_LUA/?.lua;$SHARED_LUA/?/init.lua;;"
exec bash "$DRIVER_ROOT/install/launch.sh" "$@"
WRAPPER_EOF
chmod 755 "$INSTALL_ROOT/usr/bin/ergopti"

# ----------------------------------------------------------------------
# 5. Desktop entry
# ----------------------------------------------------------------------
cat > "$INSTALL_ROOT/usr/share/applications/ergopti.desktop" << 'DESKTOP_EOF'
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
mkdir -p "$INSTALL_ROOT/etc/xdg/autostart"
sed 's|^Exec=.*|Exec=ergopti --session-start --tray|' \
  "$INSTALL_ROOT/usr/share/applications/ergopti.desktop" \
  > "$INSTALL_ROOT/etc/xdg/autostart/ergopti.desktop"

# Application icon
# ----------------------------------------------------------------------
install -m 644 "$BUILD_DIR/_shared/assets/ergopti_tray.png" "$INSTALL_ROOT/usr/share/icons/hicolor/512x512/apps/ergopti.png"

echo "  Application icon: ergopti.png"

# ----------------------------------------------------------------------
# 6. Default config
# ----------------------------------------------------------------------
if [ -f "$BUILD_DIR/linux/_generated/config_template.toml" ]; then
  cp "$BUILD_DIR/linux/_generated/config_template.toml" \
     "$INSTALL_ROOT/etc/ergopti/config.toml"
else
  cat > "$INSTALL_ROOT/etc/ergopti/config.toml" << 'CONFIG_EOF'
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

# ----------------------------------------------------------------------
# 7. systemd user service
# ----------------------------------------------------------------------
sed 's|^ExecStart=.*|ExecStart=/usr/bin/ergopti --service --tray|' \
  "$BUILD_DIR/linux/ergopti-hotstrings.service" \
  > "$INSTALL_ROOT/usr/lib/systemd/user/ergopti-hotstrings.service"

# ----------------------------------------------------------------------
# 8. SPEC file
# ----------------------------------------------------------------------
cat > "$RPM_ROOT/SPECS/ergopti.spec" << SPEC_EOF
Name:           $PACKAGE_NAME
Version:        $VERSION
Release:        $RELEASE%{?dist}
Summary:        Ergonomic keyboard optimizer with AI-powered hotstrings
License:        MIT
URL:            https://github.com/adrienm7/ergopti
Source0:        %{name}-%{version}.tar.gz

BuildArch:      noarch

# BEGIN GENERATED LINUX NATIVE REQUIREMENTS
Requires:       luajit >= 2.1
Requires:       xclip
Requires:       libnotify
Requires:       curl
Requires:       libxkbcommon
Requires:       libxkbcommon-utils
Requires:       at-spi2-core
Requires:       polkit
Requires:       kmod
Requires:       systemd-udev
Requires:       libayatana-appindicator-gtk3
Requires:       zenity
Requires:       shadow-utils
Requires:       util-linux
Requires:       libxkbcommon-x11
Requires:       libX11
Requires:       libX11-xcb
# END GENERATED LINUX NATIVE REQUIREMENTS
Recommends:     lua-luv
Recommends:     lua-filesystem
Recommends:     openssl
Recommends:     yad

%description
Ergopti is a cross-platform keyboard optimizer that provides an intelligent
hotstring engine, keystroke metrics, and AI-assisted text expansion. It runs
as a user daemon on Linux via systemd.

%prep
# Nothing to prep — files are staged directly.

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}
# Driver files are in %{_builddir} (the BUILD directory).
cp -r %{_builddir}/ergopti-%{version}/* %{buildroot}/

%files
/usr/lib/ergopti/
/usr/bin/ergopti
/usr/share/applications/ergopti.desktop
/usr/share/icons/hicolor/512x512/apps/ergopti.png
/usr/lib/systemd/user/ergopti-hotstrings.service
/etc/xdg/autostart/ergopti.desktop
%config(noreplace) /etc/ergopti/config.toml
%config(noreplace) /etc/udev/rules.d/99-ergopti-uinput.rules
%config(noreplace) /etc/modules-load.d/ergopti-uinput.conf

%post
bash /usr/lib/ergopti/install/setup_permissions.sh --active-sessions

%preun
if [ "\$1" -eq 0 ]; then
  bash /usr/lib/ergopti/install/stop_sessions.sh
fi

%changelog
* $(date +"%a %b %d %Y") Ergopti Contributors <ergopti@example.com> - $VERSION-$RELEASE
- Initial RPM packaging for Fedora/RHEL.
SPEC_EOF

echo "  SPEC: $RPM_ROOT/SPECS/ergopti.spec"

# ----------------------------------------------------------------------
# 9. Build the .rpm (Linux only)
# ----------------------------------------------------------------------
if [ "${1:-}" = "--skip-rpm" ]; then
  echo ""
  echo "=== Structure complete (--skip-rpm) ==="
  echo "RPM root: $RPM_ROOT"
  echo "To package on Fedora/RHEL:"
  echo "  rpmbuild --define '_topdir $RPM_ROOT' -bb $RPM_ROOT/SPECS/ergopti.spec"
  exit 0
fi

if ! command -v rpmbuild &>/dev/null; then
  echo ""
  echo "=== Structure complete (rpmbuild not available) ==="
  echo "RPM root: $RPM_ROOT"
  echo "Run on Fedora/RHEL to package:"
  echo "  rpmbuild --define '_topdir $RPM_ROOT' -bb $RPM_ROOT/SPECS/ergopti.spec"
  exit 0
fi

echo ""
echo "Building .rpm package..."
rpmbuild --define "_topdir $RPM_ROOT" -bb "$RPM_ROOT/SPECS/ergopti.spec"

RPM_FILE=$(find "$RPM_ROOT/RPMS" -name "*.rpm" -type f | head -1)
if [ -n "$RPM_FILE" ]; then
  echo ""
  echo "=== .rpm built successfully ==="
  echo "Package: $RPM_FILE"
  echo ""
  echo "Install with: sudo dnf install $RPM_FILE"
else
  echo "[ERR] rpmbuild did not produce a package file."
  exit 1
fi
