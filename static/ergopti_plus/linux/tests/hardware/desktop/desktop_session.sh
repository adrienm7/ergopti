# static/ergopti_plus/linux/tests/hardware/desktop/desktop_session.sh
#
# Sourced by the tests/hardware/desktop/run_*.sh container proofs: an owned Xvfb display
# with openbox, a private session bus, a private HOME with pinned XDG roots,
# and the driver's Lua paths. Each proof names its own display number so two
# proofs can run side by side.
#
# desktop_session_start DISPLAY_NUMBER  starts the session and exports its
#                                       variables; exits 2 when a tool is missing.
# desktop_session_stop                  stops everything it started.
# desktop_python                        echoes a python3 that can import gi
#                                       (a container's default python3 may be
#                                       another version than the distro's).

DESKTOP_PIDS=""

desktop_python() {
	local candidate
	for candidate in python3 /usr/bin/python3 /usr/bin/python3.12; do
		if command -v "${candidate}" >/dev/null 2>&1 && "${candidate}" -c 'import gi' >/dev/null 2>&1; then
			echo "${candidate}"
			return 0
		fi
	done
	return 1
}

desktop_session_start() {
	local number="$1" tool
	for tool in Xvfb dbus-launch openbox luajit; do
		command -v "${tool}" >/dev/null 2>&1 || { echo "ENVIRONMENT: ${tool} is missing" >&2; exit 2; }
	done
	PYTHON="$(desktop_python)" || { echo "ENVIRONMENT: no python3 can import gi (python3-gi)" >&2; exit 2; }
	export PYTHON
	DESKTOP_HOME="$(mktemp -d "${TMPDIR:-/tmp}/ergopti-desktop-XXXXXX")"
	export HOME="${DESKTOP_HOME}" XDG_CONFIG_HOME="${DESKTOP_HOME}/.config"
	export XDG_DATA_HOME="${DESKTOP_HOME}/.local/share" XDG_STATE_HOME="${DESKTOP_HOME}/.local/state"
	export XDG_CACHE_HOME="${DESKTOP_HOME}/.cache"
	mkdir -p "${XDG_CONFIG_HOME}" "${XDG_DATA_HOME}" "${XDG_STATE_HOME}" "${XDG_CACHE_HOME}"
	export LUA_PATH='./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;;/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua'
	export LUA_CPATH="/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;;"
	Xvfb ":${number}" -screen 0 1280x800x24 -nolisten tcp >/dev/null 2>&1 &
	DESKTOP_PIDS="$!"
	export DISPLAY=":${number}"
	unset WAYLAND_DISPLAY
	export XDG_SESSION_TYPE=x11
	# Xvfb creates its socket once it accepts clients.
	for _ in $(seq 50); do [ -S "/tmp/.X11-unix/X${number}" ] && break; sleep 0.1; done
	eval "$(dbus-launch --sh-syntax)"
	DESKTOP_PIDS="${DESKTOP_PIDS} ${DBUS_SESSION_BUS_PID}"
	openbox >/dev/null 2>&1 &
	DESKTOP_PIDS="${DESKTOP_PIDS} $!"
	sleep 0.5
}

desktop_session_stop() {
	local pid
	for pid in ${DESKTOP_PIDS}; do kill "${pid}" 2>/dev/null; done
	[ -n "${DESKTOP_HOME:-}" ] && rm -rf "${DESKTOP_HOME}"
}
