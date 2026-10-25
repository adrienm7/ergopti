#!/usr/bin/env bash
# static/ergopti_plus/linux/install/config_home.sh
#
# The XDG specification ignores relative environment bases. Keep installation,
# startup and removal on the same base as infra/config_paths.lua. Assign the
# caller's variable directly so native trailing newlines survive unchanged.

# @param $1 Caller variable receiving the absolute configuration base.
ergopti_resolve_config_home() {
	local ergopti_config_base="${XDG_CONFIG_HOME:-}"
	case "$ergopti_config_base" in
		/*) ;;
		*)
			local ergopti_account_home="$HOME"
			while [[ "$ergopti_account_home" != / && "$ergopti_account_home" == */ ]]; do
				ergopti_account_home="${ergopti_account_home%/}"
			done
			ergopti_config_base="${ergopti_account_home%/}/.config"
			;;
	esac
	while [[ "$ergopti_config_base" != / && "$ergopti_config_base" == */ ]]; do
		ergopti_config_base="${ergopti_config_base%/}"
	done
	printf -v "$1" '%s' "$ergopti_config_base"
}
