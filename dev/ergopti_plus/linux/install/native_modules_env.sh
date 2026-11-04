#!/usr/bin/env bash
# static/ergopti_plus/linux/install/native_modules_env.sh
#
# Admits the LuaJIT native modules a package publishes beside its driver tree.
# The standalone launcher and the .rpm wrapper both source this file, so one
# owner decides how LUA_CPATH reaches the published luv binding. A published
# directory whose module is missing, symlinked or not a file refuses the start
# instead of letting a generic Lua binding of another ABI answer the require.

# The refusals, in the user's language (install/messages.sh).
source "${BASH_SOURCE[0]%/*}/messages.sh"

# @param $1 Absolute driver root that may hold native_modules/luv.so.
# @param $2 "required" when the package always publishes the module, or
#           "optional" when the installer publishes it only for a system
#           without a LuaJIT luv binding.
ergopti_admit_native_modules() {
	if [ "$#" -ne 2 ] || [[ "$1" != /* ]]; then
		ergopti_msg native_modules.call_refused >&2
		return 1
	fi
	local modules="$1/native_modules"
	case "$2" in
		required) ;;
		optional)
			if [ ! -e "$modules" ] && [ ! -L "$modules" ]; then return 0; fi
			;;
		*)
			ergopti_msg native_modules.call_refused >&2
			return 1
			;;
	esac
	if [ -L "$modules" ] || [ ! -d "$modules" ] \
		|| [ -L "$modules/luv.so" ] || [ ! -f "$modules/luv.so" ]; then
		ergopti_msg native_modules.module_unpublished "$modules/luv.so" >&2
		return 1
	fi
	export LUA_CPATH="$modules/?.so;${LUA_CPATH:-;;}"
}
