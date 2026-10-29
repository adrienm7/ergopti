#!/usr/bin/env bash
# tools/build/build-linux-packaged-luv.sh
#
# Builds the LuaJIT luv binding the .rpm publishes in native_modules/, from the
# pinned recipe the source installer uses (build_native_luv.sh). The result
# needs the build host's glibc at least, so the release build runs this in the
# oldest supported LTS container (appimage-oldest-lts.sh) and hands the module
# to build-linux-rpm.sh. The host needs git, cmake, make, a C compiler,
# pkg-config, luajit and the LuaJIT development files.
#
# Usage:
#   bash tools/build/build-linux-packaged-luv.sh <absolute empty stage directory>
#     Leaves <stage>/luv.so, loaded and checked through the host's LuaJIT.

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <absolute empty stage directory>" >&2
  exit 2
fi
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# The external hosts are declared once in _shared/data/identifiers.json.
# shellcheck source=../../static/ergopti_plus/_shared/data/identifiers.sh
. "$PROJECT_ROOT/static/ergopti_plus/_shared/data/identifiers.sh"
# BEGIN GENERATED LINUX PACKAGED LUV SOURCE
NATIVE_LUV_SOURCE_URL="https://$ERGOPTI_HOST_GITHUB/luvit/luv.git"
NATIVE_LUV_SOURCE_REVISION="26e62e49b0230891ece45a78cc1f63c074e60020"
NATIVE_LUV_CMAKE_OPTIONS=("-DLUA_BUILD_TYPE=System" "-DWITH_LUA_ENGINE=LuaJIT" "-DBUILD_MODULE=ON" "-DBUILD_SHARED_LIBS=OFF" "-DBUILD_STATIC_LIBS=OFF" "-DWITH_SHARED_LIBUV=OFF")
# END GENERATED LINUX PACKAGED LUV SOURCE

echo "Building the LuaJIT luv binding from $NATIVE_LUV_SOURCE_URL at $NATIVE_LUV_SOURCE_REVISION..."
bash "$PROJECT_ROOT/static/ergopti_plus/linux/install/build_native_luv.sh" "$1" \
  "$NATIVE_LUV_SOURCE_URL" "$NATIVE_LUV_SOURCE_REVISION" "${NATIVE_LUV_CMAKE_OPTIONS[@]}"
