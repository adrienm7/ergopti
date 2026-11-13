#!/usr/bin/env bash
# static/ergopti_plus/linux/tests/hardware/run_container_proofs.sh
#
# The Linux "To confirm on Linux" checks a container can close (maintainer
# decision of 2026-11-10): the real daemon over the kernel model
# (core/virtual_kernel_preload.c), a real X server or Wayland compositor, real
# editors read back through AT-SPI or the clipboard. Each proof runs in a
# private mount namespace, where the model's nodes replace /dev/input and its
# device list replaces /proc/bus/input/devices.
#
# Needs root (mounts), gcc, luajit with lua-luv and lua-lgi, Xvfb, openbox,
# dbus-launch, at-spi2-core, mousepad, xclip, sway, mutter, wl-clipboard,
# wayland-scanner, libwayland-dev, libxkbcommon-dev, libxkbcommon-tools,
# libxkbcommon-x11-0, libayatana-appindicator3, python3 with Gtk 3 and Atspi.
# PYTHON overrides python3.
# Exit 0 = every proof held; 1 = a failure; 2 = no environment.

set -u
cd "$(dirname "$0")" || exit 2
PYTHON="${PYTHON:-python3}"
[ "$(id -u)" = "0" ] || { echo "ENVIRONMENT: the proofs mount over /dev/input and need root" >&2; exit 2; }
for tool in unshare gcc luajit Xvfb openbox dbus-launch mousepad xclip sway mutter wl-paste wayland-scanner pkg-config xkbcli; do
	command -v "${tool}" >/dev/null 2>&1 || { echo "ENVIRONMENT: ${tool} is missing" >&2; exit 2; }
done
# The latency budgets boot the daemon with its tray (run_perf_budget_container.py),
# which refuses to start without the indicator library.
"${PYTHON}" -c 'import ctypes.util, sys; sys.exit(not ctypes.util.find_library("ayatana-appindicator3"))' \
	|| { echo "ENVIRONMENT: libayatana-appindicator3 is missing" >&2; exit 2; }
"${PYTHON}" -c 'import gi; gi.require_version("Gtk", "3.0"); gi.require_version("Atspi", "2.0")' 2>/dev/null \
	|| { echo "ENVIRONMENT: ${PYTHON} has no Gtk 3 / Atspi bindings" >&2; exit 2; }
status=0
for proof in run_nav_pointer_container.py keyboard/run_tap_copy_container.py run_ai_inline_container.py \
	layouts/run_physical_shortcut_container.py run_perf_budget_container.py \
	run_bytecode_installed_tree.py; do
	echo "=== ${proof} ==="
	unshare --mount --propagation private "${PYTHON}" "${proof}"
	result=$?
	[ "${result}" = "2" ] && exit 2
	[ "${result}" = "0" ] || status=1
done
exit "${status}"
