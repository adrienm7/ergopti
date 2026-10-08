#!/usr/bin/env bash
# static/ergopti_plus/linux/install/standalone_launcher.sh
#
# Copied to the standalone bundle's bin directory. Keeping this launcher in
# the payload makes updates and rollback select the matching startup policy.

set -euo pipefail
WRAPPER_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
INSTALL_ROOT="$(cd -- "$WRAPPER_DIR/.." && pwd -P)"
DRIVER_ROOT="$INSTALL_ROOT/linux"
SHARED_LUA="$INSTALL_ROOT/_shared/lua"
export LUA_PATH="$DRIVER_ROOT/?.lua;$DRIVER_ROOT/?/init.lua;$SHARED_LUA/?.lua;$SHARED_LUA/?/init.lua;;"
if [ -d "$DRIVER_ROOT/native_modules" ]; then
	[ ! -L "$DRIVER_ROOT/native_modules" ] && [ -f "$DRIVER_ROOT/native_modules/luv.so" ] \
		&& [ ! -L "$DRIVER_ROOT/native_modules/luv.so" ] || exit 1
	export LUA_CPATH="$DRIVER_ROOT/native_modules/?.so;${LUA_CPATH:-;;}"
fi
# The standalone installer already selected its startup owner.
exec bash "$DRIVER_ROOT/install/launch.sh" --service "$@"
