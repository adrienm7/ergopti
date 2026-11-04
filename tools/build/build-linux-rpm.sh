#!/usr/bin/env bash
# tools/build/build-linux-rpm.sh
#
# Assembles a .rpm package from the build/linux/ driver bundle.
# Requires Linux; actual .rpm creation also requires rpmbuild.
#
# The package carries the private runtime prefix the AppImage stages on the
# oldest supported LTS (tools/build/stage-linux-private-runtime.sh): LuaJIT,
# luv, luafilesystem, luaposix, curl, sqlite3, openssl and zstd run from
# there, never from a host package (owned runtimes, PIN). Fedora's lua-luv was
# built for the generic Lua ABI, not LuaJIT's, so this also replaces the luv
# binding the package used to compile for itself. Nothing is downloaded or
# compiled at installation.
#
# Usage:
#   bash tools/build/build-linux-rpm.sh              # full build + .rpm
#   bash tools/build/build-linux-rpm.sh --skip-rpm   # structure only

set -euo pipefail

SKIP_RPM=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-rpm) SKIP_RPM=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if ! "$SKIP_RPM" && ! command -v rpmbuild >/dev/null 2>&1; then
  echo "[ERR] rpmbuild is required to build an .rpm; use --skip-rpm for staging only." >&2
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
RPM_ROOT="$BUILD_DIR/rpm"
# The release-visible tree holds one runtime artifact; keep the complete native
# package set, including debug output, outside that publication boundary.
RPM_NATIVE_ROOT="$RPM_ROOT/native-rpms"
RPM_PUBLISHER="$RPM_ROOT/publish-linux-rpm.cjs"
PACKAGE_NAME="ergopti"
ARCH="x86_64"
RELEASE="1"

echo "=== ergopti .rpm packager ==="
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
mkdir -p "$RPM_NATIVE_ROOT"
mkdir -p "$RPM_ROOT/SOURCES"
mkdir -p "$RPM_ROOT/SPECS"
mkdir -p "$RPM_ROOT/SRPMS"
# Preserve the canonical publisher with the prepared native build structure.
cp "$SCRIPT_DIR/${RPM_PUBLISHER##*/}" "$RPM_PUBLISHER"

# Target install tree
INSTALL_ROOT="$RPM_ROOT/BUILD/payload"
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
VERSION=$(node "$SCRIPT_DIR/linux-package-version.cjs" rpm "$INSTALL_ROOT/usr/lib/ergopti/_shared" "$PROJECT_ROOT/package.json")
mv "$INSTALL_ROOT" "$RPM_ROOT/BUILD/ergopti-$VERSION"
INSTALL_ROOT="$RPM_ROOT/BUILD/ergopti-$VERSION"
echo "Package: $PACKAGE_NAME $VERSION-$RELEASE ($ARCH)"
install -D -m 644 "$BUILD_DIR/linux/install/99-ergopti-uinput.rules" "$INSTALL_ROOT/etc/udev/rules.d/99-ergopti-uinput.rules"
install -D -m 644 "$BUILD_DIR/linux/install/ergopti-uinput.conf" "$INSTALL_ROOT/etc/modules-load.d/ergopti-uinput.conf"


# ----------------------------------------------------------------------
# 3b. Private runtime
# ----------------------------------------------------------------------
bash "$SCRIPT_DIR/stage-linux-private-runtime.sh" "$BUILD_DIR/AppDir" "$INSTALL_ROOT/usr/lib/ergopti/runtime" /usr/lib/ergopti
install -m 644 "$BUILD_DIR/AppDir/usr/lib/ergopti/network-runtime-env.sh" "$INSTALL_ROOT/usr/lib/ergopti/network-runtime-env.sh"

chmod -R 755 "$INSTALL_ROOT/usr/lib/ergopti"
echo "  $(find "$INSTALL_ROOT/usr/lib/ergopti" -type f | wc -l) files"

# ----------------------------------------------------------------------
# 4. Wrapper script
# ----------------------------------------------------------------------
cat > "$INSTALL_ROOT/usr/bin/ergopti" << 'WRAPPER_EOF'
#!/bin/bash
# The package's private runtime decides LUA_PATH, LUA_CPATH and the programs
# the driver runs (network-runtime-env.sh, shared with the AppImage).
set -euo pipefail
DRIVER_ROOT="/usr/lib/ergopti"
source "$DRIVER_ROOT/network-runtime-env.sh" "$DRIVER_ROOT/runtime" "$DRIVER_ROOT"
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
# The package carries the x86_64 native archive backend
# (bin/libergopti_archive_publication.so), like the amd64 .deb, so it is
# built for that architecture: rpmbuild refuses arch-dependent binaries in a
# noarch package. The release asset carries the same architecture in its
# name, ErgoptiPlus-linux-$ARCH.rpm (ci-linux.yml renames the rpmbuild output).
cat > "$RPM_ROOT/SPECS/ergopti.spec" << SPEC_EOF
Name:           $PACKAGE_NAME
Version:        $VERSION
Release:        $RELEASE%{?dist}
Summary:        Ergonomic keyboard optimizer with AI-powered hotstrings
License:        MIT
URL:            https://$ERGOPTI_HOST_GITHUB/adrienm7/ergopti
Source0:        %{name}-%{version}.tar.gz

BuildArch:      $ARCH

# BEGIN GENERATED LINUX NATIVE REQUIREMENTS
Requires:       xclip
Requires:       libnotify
Requires:       libxkbcommon
Requires:       libxkbcommon-utils
Requires:       at-spi2-core
Requires:       polkit
Requires:       kmod
Requires:       systemd-udev
Requires:       libayatana-appindicator-gtk3
Requires:       shadow-utils
Requires:       util-linux
Requires:       xdg-utils
Requires:       libsecret
Requires:       libxkbcommon-x11
Requires:       libX11
Requires:       libX11-xcb
# END GENERATED LINUX NATIVE REQUIREMENTS
Recommends:     yad
Recommends:     xdotool
Recommends:     wmctrl
# The private runtime's libraries serve its own programs only: they must not
# answer another package's dependency, and its programs' needs are met inside it.
%global __provides_exclude_from ^/usr/lib/ergopti/runtime/.*\$
%global __requires_exclude_from ^/usr/lib/ergopti/runtime/.*\$

%description
Ergopti is a cross-platform keyboard optimizer that provides an intelligent
hotstring engine, keystroke metrics, and AI-assisted text expansion. It runs
as a user daemon on Linux via systemd.

%prep
%setup -q

%install
# Expand the canonical environment at execution time: macro-expanded path bytes
# inserted into shell source could split a prefix and remove an unrelated tree.
: "\${RPM_BUILD_ROOT:?RPM build root unavailable}"
rm -rf -- "\$RPM_BUILD_ROOT"
mkdir -p -- "\$RPM_BUILD_ROOT"
# RPM owns the extracted source cwd; _builddir itself changes on newer RPM.
cp -r -- . "\$RPM_BUILD_ROOT/"

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

# Source0 is the package handoff. RPM may relocate its build directory, so it
# must extract its own complete source tree rather than reach into our staging.
tar -czf "$RPM_ROOT/SOURCES/${PACKAGE_NAME}-${VERSION}.tar.gz" \
  -C "$RPM_ROOT/BUILD" "${PACKAGE_NAME}-${VERSION}"

# ----------------------------------------------------------------------
# 9. Build the .rpm (Linux only)
# ----------------------------------------------------------------------
NATIVE_COMMAND=(rpmbuild --define "_topdir $RPM_ROOT" --define "_rpmdir $RPM_NATIVE_ROOT" -bb "$RPM_ROOT/SPECS/ergopti.spec")
PUBLISH_COMMAND=(node "$RPM_PUBLISHER" "$RPM_NATIVE_ROOT" "$RPM_ROOT/RPMS" "$PACKAGE_NAME" "$VERSION" "$ARCH")
print_packaging_command() {
  printf '  '
  printf '%q ' "${NATIVE_COMMAND[@]}"
  printf '&& '
  printf '%q ' "${PUBLISH_COMMAND[@]}"
  printf '\n'
}

if [ "$SKIP_RPM" = true ]; then
  echo ""
  echo "=== Structure complete (--skip-rpm) ==="
  echo "RPM root: $RPM_ROOT"
  echo "To package on Fedora/RHEL:"
  print_packaging_command
  exit 0
fi

echo ""
echo "Building .rpm package..."
"${NATIVE_COMMAND[@]}"

RPM_FILE=$("${PUBLISH_COMMAND[@]}")
echo ""
echo "=== .rpm built successfully ==="
echo "Package: $RPM_FILE"
echo ""
echo "Install with: sudo dnf install $RPM_FILE"
