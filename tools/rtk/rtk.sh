#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
if rtk_path=$("$script_dir/bootstrap.sh" print-path); then
	exec "$rtk_path" "$@"
else
	status=$?
fi
if [ "$status" -eq 3 ] && [ -n "${CI:-}" ]; then
	[ "$#" -gt 0 ] || { echo "no command supplied and RTK is unavailable in CI" >&2; exit 64; }
	exec "$@"
fi

exit "$status"
