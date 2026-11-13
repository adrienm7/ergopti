#!/usr/bin/env bash
# static/ergopti_plus/linux/install/standalone_launcher.sh
#
# Copied to the standalone bundle's bin directory. Keeping this launcher in
# the payload makes updates and rollback select the matching startup policy.

set -euo pipefail
unset ERGOPTI_LITERAL_DRIVER_ROOT ERGOPTI_LITERAL_SHARED_ROOT ERGOPTI_LITERAL_DIRECT ERGOPTI_LITERAL_DAEMON ERGOPTI_LITERAL_NATIVE_MODULES
WRAPPER_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
INSTALL_ROOT="$(cd -- "$WRAPPER_DIR/.." && pwd -P)"
DRIVER_ROOT="$INSTALL_ROOT/linux"
SHARED_LUA="$INSTALL_ROOT/_shared"
if [ -e "$DRIVER_ROOT/runtime" ] || [ -L "$DRIVER_ROOT/runtime" ]; then
	# A release install carries the private runtime every package runs; its
	# environment refuses a missing part. _shared sits beside linux/ here, so
	# LUA_PATH is this layout's, with the runtime's Lua packages after it.
	source "$DRIVER_ROOT/network-runtime-env.sh" "$DRIVER_ROOT/runtime" "$DRIVER_ROOT"
	export LUA_PATH="$DRIVER_ROOT/?.lua;$DRIVER_ROOT/?/init.lua;$SHARED_LUA/?.lua;$SHARED_LUA/?/init.lua;$ERGOPTI_RUNTIME_PREFIX/share/lua/5.1/?.lua;$ERGOPTI_RUNTIME_PREFIX/share/lua/5.1/?/init.lua;;"
else
	export LUA_PATH="$DRIVER_ROOT/?.lua;$DRIVER_ROOT/?/init.lua;$SHARED_LUA/?.lua;$SHARED_LUA/?/init.lua;;"
	# A checkout install publishes native_modules only for a system without a LuaJIT luv.
	source "$DRIVER_ROOT/install/native_modules_env.sh"
	ergopti_admit_native_modules "$DRIVER_ROOT" optional
fi
case "$DRIVER_ROOT${ERGOPTI_RUNTIME_PREFIX:-}" in
	*[\;\?]*)
		export ERGOPTI_LITERAL_DRIVER_ROOT="$DRIVER_ROOT"
		export ERGOPTI_LITERAL_SHARED_ROOT="$SHARED_LUA"
		export LUA_PATH=';;' ;;
esac
# The standalone installer already selected its startup owner.
exec bash "$DRIVER_ROOT/install/launch.sh" --service "$@"
