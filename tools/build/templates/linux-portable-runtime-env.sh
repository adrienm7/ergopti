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
SHARED_LUA="$DRIVER_ROOT/_shared/lua"
export LUA_PATH="$DRIVER_ROOT/?.lua;$DRIVER_ROOT/?/init.lua;$SHARED_LUA/?.lua;$SHARED_LUA/?/init.lua;;"
export LUA_CPATH="$ERGOPTI_PACKAGE_PREFIX/lib/lua/5.1/?.so${LUA_CPATH:+;$LUA_CPATH};;"
export PATH="$ERGOPTI_PACKAGE_PREFIX/bin:$PATH"
export LD_LIBRARY_PATH="$ERGOPTI_PACKAGE_PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export GIO_MODULE_DIR="$ERGOPTI_PACKAGE_PREFIX/lib/gio/modules"
export GIO_EXTRA_MODULES="$ERGOPTI_PACKAGE_PREFIX/lib/gio/modules"
export GSETTINGS_SCHEMA_DIR="$ERGOPTI_PACKAGE_PREFIX/share/glib-2.0/schemas"
export XDG_DATA_DIRS="$ERGOPTI_PACKAGE_PREFIX/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"

for ERGOPTI_PACKAGE_COMPONENT in \
  "$ERGOPTI_PACKAGE_PREFIX/bin/luajit" \
  "$ERGOPTI_PACKAGE_PREFIX/bin/curl" \
  "$ERGOPTI_PACKAGE_PREFIX/lib/lua/5.1/luv.so" \
  "$GIO_MODULE_DIR/libgiolibproxy.so" \
  "$GSETTINGS_SCHEMA_DIR/gschemas.compiled"; do
  if [ ! -f "$ERGOPTI_PACKAGE_COMPONENT" ]; then
    echo "Required installed native package component unavailable." >&2
    return 1
  fi
done

# BEGIN GENERATED LINUX PORTABLE TRUST
ERGOPTI_SYSTEM_CA_FILES=("/etc/ssl/certs/ca-certificates.crt" "/etc/pki/tls/certs/ca-bundle.crt" "/usr/share/ssl/certs/ca-bundle.crt" "/usr/local/share/certs/ca-root-nss.crt" "/etc/ssl/cert.pem")
# END GENERATED LINUX PORTABLE TRUST

# Respect explicit trust configuration. Otherwise select a recipient system
# bundle from curl's documented build-time autodetection candidates; never
# ship a frozen CA store or disable certificate verification.
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
    echo "Recipient system certificate bundle unavailable for the native package." >&2
    return 1
  fi
fi
