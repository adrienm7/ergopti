#!/usr/bin/env bash
# tools/build/templates/linux-portable-runtime-env.sh
# Source with the package prefix and exact installed driver root. No settings
# or host files are modified. Native trust remains the recipient's trust.

if [ "$#" -ne 2 ] || [[ "$1" != /* ]] || [[ "$2" != /* ]]; then
  echo "Native package environment refused." >&2
  return 1
fi
ERGOPTI_PACKAGE_PREFIX="$1"
DRIVER_ROOT="$2"
SHARED_LUA="$DRIVER_ROOT/_shared"
# Only a prefix that builds its GIO modules and schemas against its own GLib
# (the Flatpak's /app, on its runtime's GLib) points GIO at them. The private
# runtime of the AppImage, the .deb, the .rpm and the tarball carries none: a
# module loads into the recipient's GLib and GTK inside the daemon, and the
# Ubuntu 22.04 libdconfsettings.so it once bundled crashed luajit on Arch.
# GIO_MODULE_DIR also replaced the recipient's own module directory there.
if [ -d "$ERGOPTI_PACKAGE_PREFIX/lib/gio/modules" ]; then
  ERGOPTI_PACKAGE_OWNS_GIO=true
else
  ERGOPTI_PACKAGE_OWNS_GIO=false
fi
# The host's value of every variable this file changes, recorded once before
# any change so the daemon can start host programs (pkexec, setxkbmap,
# xdg-open, notify-send...) with their own environment
# (core/process/adapters/host_environment.lua). A nested launch from the bundle
# keeps the first record: its environment is already the bundle's.
if [ -z "${ERGOPTI_HOST_ENV_NAMES+x}" ]; then
  ERGOPTI_HOST_ENV_NAMES="LUA_PATH LUA_CPATH CURL_CA_BUNDLE GI_TYPELIB_PATH"
  if [ "$ERGOPTI_PACKAGE_OWNS_GIO" = true ]; then
    ERGOPTI_HOST_ENV_NAMES="$ERGOPTI_HOST_ENV_NAMES GIO_MODULE_DIR GIO_EXTRA_MODULES GSETTINGS_SCHEMA_DIR XDG_DATA_DIRS"
  fi
  for ERGOPTI_PACKAGE_HOST_NAME in $ERGOPTI_HOST_ENV_NAMES; do
    if [ -n "${!ERGOPTI_PACKAGE_HOST_NAME+x}" ]; then
      export "ERGOPTI_HOST_ENV_SET_$ERGOPTI_PACKAGE_HOST_NAME=${!ERGOPTI_PACKAGE_HOST_NAME}"
    fi
  done
  export ERGOPTI_HOST_ENV_NAMES
fi
# A command naming this root runs a driver script: it keeps the bundle's environment.
export ERGOPTI_HOST_ENV_DRIVER_ROOT="$DRIVER_ROOT"
unset ERGOPTI_LITERAL_DIRECT ERGOPTI_LITERAL_DAEMON ERGOPTI_LITERAL_NATIVE_MODULES
# The private prefix's Lua packages (luaposix) after the driver's own modules.
case "$DRIVER_ROOT$ERGOPTI_PACKAGE_PREFIX" in
  *[\;\?]*)
    # Lua templates cannot encode these filename bytes. Explicit app entry
    # points use the literal owner; host/default search paths stay available.
    export ERGOPTI_LITERAL_DRIVER_ROOT="$DRIVER_ROOT"
    export ERGOPTI_LITERAL_SHARED_ROOT="$SHARED_LUA"
    export LUA_PATH=';;'
    export LUA_CPATH="${LUA_CPATH:-;;}"
    ;;
  *)
    unset ERGOPTI_LITERAL_DRIVER_ROOT ERGOPTI_LITERAL_SHARED_ROOT
    export LUA_PATH="$DRIVER_ROOT/?.lua;$DRIVER_ROOT/?/init.lua;$SHARED_LUA/?.lua;$SHARED_LUA/?/init.lua;$ERGOPTI_PACKAGE_PREFIX/share/lua/5.1/?.lua;$ERGOPTI_PACKAGE_PREFIX/share/lua/5.1/?/init.lua;;"
    export LUA_CPATH="$ERGOPTI_PACKAGE_PREFIX/lib/lua/5.1/?.so${LUA_CPATH:+;$LUA_CPATH};;"
    ;;
esac
# The driver runs its owned programs from this prefix only, by absolute path
# (settings/engine/preferences/owned_programs.lua), so PATH stays the host's:
# a prefix bin/ in front of it reached every host program the daemon starts.
export ERGOPTI_RUNTIME_PREFIX="$ERGOPTI_PACKAGE_PREFIX"
# No LD_LIBRARY_PATH either: every staged file finds lib/ through its own RUNPATH.
ERGOPTI_PACKAGE_COMPONENTS=()
if [ "$ERGOPTI_PACKAGE_OWNS_GIO" = true ]; then
  export GIO_MODULE_DIR="$ERGOPTI_PACKAGE_PREFIX/lib/gio/modules"
  export GIO_EXTRA_MODULES="$ERGOPTI_PACKAGE_PREFIX/lib/gio/modules"
  export GSETTINGS_SCHEMA_DIR="$ERGOPTI_PACKAGE_PREFIX/share/glib-2.0/schemas"
  export XDG_DATA_DIRS="$ERGOPTI_PACKAGE_PREFIX/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
  ERGOPTI_PACKAGE_COMPONENTS=("$GIO_MODULE_DIR/libgiolibproxy.so" "$GSETTINGS_SCHEMA_DIR/gschemas.compiled")
fi
# The prefix's lgi links the build host's libgirepository, whose built-in search
# names only the Debian multiarch directory. The recipient's typelibs come
# first (Fedora and openSUSE, Debian and Ubuntu, then Arch, whose lib64 is a
# link to lib), so the recipient's GTK and WebKitGTK describe themselves; the
# prefix's GLib and freedesktop typelibs only fill a recipient without them.
export GI_TYPELIB_PATH="${GI_TYPELIB_PATH:+$GI_TYPELIB_PATH:}/usr/lib64/girepository-1.0:/usr/lib/x86_64-linux-gnu/girepository-1.0:/usr/lib/girepository-1.0:$ERGOPTI_PACKAGE_PREFIX/lib/girepository-1.0"

for ERGOPTI_PACKAGE_COMPONENT in \
  "$ERGOPTI_PACKAGE_PREFIX/bin/luajit" \
  "$ERGOPTI_PACKAGE_PREFIX/bin/curl" \
  "$ERGOPTI_PACKAGE_PREFIX/bin/sqlite3" \
  "$ERGOPTI_PACKAGE_PREFIX/bin/openssl" \
  "$ERGOPTI_PACKAGE_PREFIX/bin/zstd" \
  "$ERGOPTI_PACKAGE_PREFIX/lib/lua/5.1/luv.so" \
  "$ERGOPTI_PACKAGE_PREFIX/lib/lua/5.1/lfs.so" \
  "$ERGOPTI_PACKAGE_PREFIX/lib/lua/5.1/posix/sys/stat.so" \
  "$ERGOPTI_PACKAGE_PREFIX/share/lua/5.1/posix/init.lua" \
  "$ERGOPTI_PACKAGE_PREFIX/lib/lua/5.1/lgi/corelgilua51.so" \
  "$ERGOPTI_PACKAGE_PREFIX/share/lua/5.1/lgi.lua" \
  "$ERGOPTI_PACKAGE_PREFIX/lib/girepository-1.0/GObject-2.0.typelib" \
  "${ERGOPTI_PACKAGE_COMPONENTS[@]}"; do
  if [ ! -f "$ERGOPTI_PACKAGE_COMPONENT" ]; then
    echo "Required installed native package component unavailable." >&2
    return 1
  fi
done

# BEGIN GENERATED LINUX PORTABLE TRUST
ERGOPTI_SYSTEM_CA_FILES=("/etc/ssl/certs/ca-certificates.crt" "/etc/pki/tls/certs/ca-bundle.crt" "/usr/share/ssl/certs/ca-bundle.crt" "/usr/local/share/certs/ca-root-nss.crt" "/etc/ssl/cert.pem" "/etc/ssl/ca-bundle.pem")
# END GENERATED LINUX PORTABLE TRUST

# Respect explicit trust configuration. Otherwise select a recipient system
# bundle from curl's documented build-time autodetection candidates; never
# ship a frozen CA store or disable certificate verification. A machine with
# no bundle still starts the app: only HTTPS needs one, and curl then fails
# each request with its own certificate error. Refusing here kept a sandbox
# without /etc/ssl from showing the tray at all.
if [ -z "${CURL_CA_BUNDLE:-}" ] && [ -z "${SSL_CERT_FILE:-}" ] && [ -z "${SSL_CERT_DIR:-}" ]; then
  ERGOPTI_SYSTEM_CA_FOUND=false
  for ERGOPTI_SYSTEM_CA_FILE in "${ERGOPTI_SYSTEM_CA_FILES[@]}"; do
    if [ -r "$ERGOPTI_SYSTEM_CA_FILE" ] && [ -s "$ERGOPTI_SYSTEM_CA_FILE" ]; then
      export CURL_CA_BUNDLE="$ERGOPTI_SYSTEM_CA_FILE"
      ERGOPTI_SYSTEM_CA_FOUND=true
      break
    fi
  done
  if [ "$ERGOPTI_SYSTEM_CA_FOUND" != true ]; then
    echo "Recipient system certificate bundle unavailable for the native package: HTTPS requests will fail." >&2
  fi
fi
