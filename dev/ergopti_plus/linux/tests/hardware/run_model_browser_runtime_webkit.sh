#!/usr/bin/env bash
# static/ergopti_plus/linux/tests/hardware/run_model_browser_runtime_webkit.sh
#
# The setting of run_model_browser_runtime_webkit.lua: the native archive
# helper (libergopti_archive_publication.so) built from its C source into the
# driver's bin/ as install.sh ships it, a private profile below HOME (the
# managed runtime resolver refuses /tmp and other writable-by-others
# ancestors), Xvfb and a private session bus. The profile, with the published
# runtime (several gigabytes), is removed on every exit.
#
# Needs a C compiler, curl, zstd, xvfb-run, dbus-run-session, luajit with luv
# and lgi, WebKit2GTK 4.1 and HTTPS access to github.com.
# Exit 0 = every check held; 1 = a failure; 2 = no environment.

set -u
cd "$(dirname "$0")/../.." || exit 2
DRIVER="$(pwd -P)"
need() {
	command -v "$1" >/dev/null 2>&1 || { echo "ENVIRONMENT: $1 is missing" >&2; exit 2; }
}
for tool in cc curl zstd xvfb-run dbus-run-session luajit; do need "${tool}"; done
export LUA_PATH='./?.lua;./?/init.lua;../_shared/?.lua;../_shared/?/init.lua;;'
export LUA_PATH="$LUA_PATH;/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua"
export LUA_CPATH="/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;;"

HELPER="${DRIVER}/bin/libergopti_archive_publication.so"
if [ ! -e "${HELPER}" ]; then
	mkdir -p "${DRIVER}/bin" || exit 1
	STAGE="$(mktemp -d "${DRIVER}/bin/.model-browser-native-XXXXXX")" || exit 1
	bash ../../../tools/build/build-linux-native-output.sh \
		--source-directory "${DRIVER}/native/archive_output" --output-directory "${STAGE}" || exit 1
	mv -n "${STAGE}/libergopti_archive_publication.so" "${HELPER}" || exit 1
	rmdir "${STAGE}"
fi

umask 077
PARENT="${HOME}/.ergopti-model-browser-runtime"
mkdir -p "${PARENT}" || exit 1
PROFILE="$(mktemp -d "${PARENT}/profile-XXXXXX")" || exit 1
trap 'rm -rf "${PROFILE}"' EXIT
for name in config/ergopti data state run models; do mkdir -p "${PROFILE}/${name}" || exit 1; done
printf '[llm]\nenabled = false\n[llm.models]\nselected = "ollama"\nollama = "granite4:350m-h"\n' \
	> "${PROFILE}/config/ergopti/config.toml"

XDG_CONFIG_HOME="${PROFILE}/config" XDG_DATA_HOME="${PROFILE}/data" XDG_STATE_HOME="${PROFILE}/state" \
	XDG_CACHE_HOME="${PROFILE}/state/cache" XDG_RUNTIME_DIR="${PROFILE}/run" OLLAMA_MODELS="${PROFILE}/models" \
	XDG_SESSION_TYPE=x11 GDK_BACKEND=x11 \
	xvfb-run -a dbus-run-session -- luajit tests/hardware/run_model_browser_runtime_webkit.lua
