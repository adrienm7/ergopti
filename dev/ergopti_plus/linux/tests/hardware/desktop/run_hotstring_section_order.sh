#!/usr/bin/env bash
# static/ergopti_plus/linux/tests/hardware/desktop/run_hotstring_section_order.sh
#
# Container proof of TODO « Hotstring section order » on Linux: moves and
# resets a category's sections through the tray as a panel clicks it, restarts
# the tray process and reads the order back, then proves a menu built before an
# external config.toml edit refuses to write over it.
#
# The tray is tests/hardware/desktop/hotstring_order_tray_host.lua (real catalogue, real
# menu builder, real libayatana-appindicator); the panel is tray_panel.py over
# the session bus. The daemon process itself needs an evdev keyboard, which a
# container without /dev/input cannot give it.
#
# Needs Xvfb, dbus-launch, openbox, luajit, lua-lgi, libayatana-appindicator3,
# python3-gi. Exit 0 = every check held; 1 = a check failed; 2 = no environment.

set -u
cd "$(dirname "$0")/../../.." || exit 2
command -v xdotool >/dev/null 2>&1 || { echo "ENVIRONMENT: xdotool is missing" >&2; exit 2; }
command -v pgrep >/dev/null 2>&1 || { echo "ENVIRONMENT: pgrep is missing" >&2; exit 2; }
. tests/hardware/desktop/desktop_session.sh
desktop_session_start "${ERGOPTI_DESKTOP_DISPLAY:-71}"
trap desktop_session_stop EXIT

CONFIG="${XDG_CONFIG_HOME}/ergopti/config.toml"
STATE="${DESKTOP_HOME}/state"
FAILURES=0
CATEGORY="⚡ Hotstrings > Autocorrection"
ORDER="${CATEGORY} > Ordre des sections"

check() {
	if [ "$1" = 0 ]; then echo "  PASS $2"; else echo "  FAIL $2"; FAILURES=$((FAILURES + 1)); fi
}

# One tray process and one panel walk. Arguments go to the panel; the JSON
# report lands in ${STATE}/panel.json and the tray log in ${STATE}/host.log.
# EXTERNAL_EDIT, when set, is appended to config.toml once the menu is up.
tray_session() {
	rm -rf "${STATE}"
	mkdir -p "${STATE}"
	"${PYTHON}" tests/hardware/desktop/tray_panel.py --ready-file "${STATE}/panel" --timeout 30 \
		--wait-for "${STATE}/go" "$@" > "${STATE}/panel.json" &
	local panel=$!
	for _ in $(seq 100); do [ -f "${STATE}/panel" ] && break; sleep 0.1; done
	luajit tests/hardware/desktop/hotstring_order_tray_host.lua "${STATE}" 40 > "${STATE}/host.log" 2>&1 &
	local host=$!
	for _ in $(seq 300); do [ -f "${STATE}/ready" ] && break; sleep 0.1; done
	if [ -n "${EXTERNAL_EDIT:-}" ]; then printf '%s' "${EXTERNAL_EDIT}" >> "${CONFIG}"; fi
	touch "${STATE}/go"
	# A refused write opens the modal error dialog the tray waits on: record that
	# it appeared, then dismiss it as a user would, so the tray can answer.
	if [ -n "${EXPECT_ERROR_DIALOG:-}" ]; then
		# xdotool's name search cannot match the title's em dash, so the dialog
		# host is found by its command line and its title read back.
		local dialog="" pid=""
		for _ in $(seq 200); do
			pid="$(pgrep -f "dialog_host.lua --error" | head -n 1)"
			[ -n "${pid}" ] && dialog="$(xdotool search --onlyvisible --pid "${pid}" 2>/dev/null | head -n 1)"
			[ -n "${dialog}" ] && break
			sleep 0.1
		done
		if [ -n "${dialog}" ] && [ "$(xdotool getwindowname "${dialog}")" = "ErgoptiPlus — Erreur" ]; then
			touch "${STATE}/error_dialog"
			xdotool windowactivate --sync "${dialog}" key Escape
		fi
	fi
	wait "${panel}"
	local status=$?
	touch "${STATE}/stop"
	wait "${host}"
	return "${status}"
}

children() {
	"${PYTHON}" -c 'import json,sys; print("|".join(json.load(open(sys.argv[1]))["children"]))' "${STATE}/panel.json"
}

enabled() {
	"${PYTHON}" -c 'import json,sys; print("|".join(str(v).lower() for v in json.load(open(sys.argv[1]))["enabled"]))' "${STATE}/panel.json"
}

saved_order() {
	TOML="${CONFIG}" luajit -e 'local f = assert(io.open(os.getenv("TOML"), "rb")); local d = require("core.text.engine.toml_codec").decode(f:read("*a"))
		local o = ((d.hotstrings or {}).order_overrides or {}).autocorrection
		print(o and table.concat(o, "|") or "none")'
}

section_rows() {
	children | tr '|' '\n' | grep -E '^(names|abbreviations|technical_terms) \(' | sed 's/ (.*//' | tr '\n' '|' | sed 's/|$//'
}

echo "=== hotstring section order through the tray (display ${DISPLAY}) ==="
tray_session --click "⚡ Hotstrings > Activer les hotstrings" --dump-children "${CATEGORY}"
check $? "the panel switches the hotstrings on and opens the Autocorrection submenu"
DEFAULT_ROWS="$(section_rows)"
echo "  catalogue order: ${DEFAULT_ROWS}"
[ "${DEFAULT_ROWS}" = "names|abbreviations|technical_terms" ]
check $? "the submenu lists the catalogue's own order"

tray_session --click "${ORDER} > abbreviations > Monter" --dump-children "${CATEGORY}"
check $? "Ordre des sections > abbreviations > Monter is clicked"
[ "$(section_rows)" = "abbreviations|names|technical_terms" ]
check $? "the rebuilt menu moves abbreviations above names at once ($(section_rows))"
[ "$(saved_order)" = "abbreviations|names|technical_terms" ]
check $? "config.toml keeps hotstrings.order_overrides.autocorrection = $(saved_order)"

tray_session --dump-children "${ORDER} > abbreviations"
check $? "a restarted tray process opens the moved section's own rows"
[ "$(enabled)" = "false|true" ]
check $? "after the restart the first section's Monter is greyed and Descendre is offered ($(enabled))"
tray_session --dump-children "${CATEGORY}"
[ "$(section_rows)" = "abbreviations|names|technical_terms" ]
check $? "the restarted tray draws the saved order ($(section_rows))"

tray_session --click "${ORDER} > Revenir au défaut" --dump-children "${CATEGORY}"
check $? "Ordre des sections > Revenir au défaut is clicked"
[ "$(saved_order)" = "none" ] && [ "$(section_rows)" = "${DEFAULT_ROWS}" ]
check $? "the reset removes the override and redraws the catalogue order ($(saved_order); $(section_rows))"

tray_session --click "${ORDER} > abbreviations > Monter"
[ "$(saved_order)" = "abbreviations|names|technical_terms" ]
check $? "a second move is saved before the stale-menu case"
EXTERNAL_EDIT=$'\n[external]\nedited = "while the menu was open" # kept\n'
cp "${CONFIG}" "${DESKTOP_HOME}/expected.toml"
printf '%s' "${EXTERNAL_EDIT}" >> "${DESKTOP_HOME}/expected.toml"
EXPECT_ERROR_DIALOG=1 EXTERNAL_EDIT="${EXTERNAL_EDIT}" tray_session --click "${ORDER} > abbreviations > Descendre"
check $? "the menu built before the external edit is clicked"
[ -f "${STATE}/error_dialog" ]
check $? "the refusal opens the « ErgoptiPlus — Erreur » dialog"
[ "$(sha256sum < "${DESKTOP_HOME}/expected.toml")" = "$(sha256sum < "${CONFIG}")" ]
check $? "config.toml still holds the external edit, byte for byte"
[ "$(saved_order)" = "abbreviations|names|technical_terms" ]
check $? "the stale move was not written ($(saved_order))"
grep -q "Section order was not persisted; the menu remains unchanged" "${STATE}/host.log"
check $? "the tray log names the refusal"

if [ "${FAILURES}" -ne 0 ]; then
	echo "=== ${FAILURES} check(s) failed; last tray log tail: ==="
	tail -n 20 "${STATE}/host.log"
	exit 1
fi
echo "=== every check held ==="
exit 0
