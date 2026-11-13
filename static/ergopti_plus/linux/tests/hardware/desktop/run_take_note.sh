#!/usr/bin/env bash
# static/ergopti_plus/linux/tests/hardware/desktop/run_take_note.sh
#
# Container proof of TODO « Daily notes » on Linux: the catalogue action
# `take_note` runs through the gesture manager's executor with the real
# xdg-mime, gtk-launch and notify-send. With no text/plain handler registered,
# the desktop's notification server receives the specific refusal and no note
# is created. With a registered editor (a .desktop file whose Exec records the
# path it was given and the file's bytes at that moment), the editor opens the
# current daily note, an existing note keeps every byte, a second use opens
# the same file again, and an absent note is created empty and still reaches
# the editor (xdg-open sent an empty file to a browser: inode/x-empty).
#
# The desktop file and the notification server are owned: XDG_DATA_DIRS points
# at a private folder, so no system handler answers for text/plain.
#
# Needs Xvfb, dbus-launch, openbox, luajit, xdg-utils, libgtk-3-bin
# (gtk-launch), libnotify-bin (notify-send), python3-gi.
# Exit 0 = every check held; 1 = a check failed; 2 = no environment.

set -u
cd "$(dirname "$0")/../../.." || exit 2
for tool in gtk-launch xdg-open notify-send; do
	command -v "${tool}" >/dev/null 2>&1 || { echo "ENVIRONMENT: ${tool} is missing" >&2; exit 2; }
done
. tests/hardware/desktop/desktop_session.sh
desktop_session_start "${ERGOPTI_DESKTOP_DISPLAY:-72}"
trap 'kill ${NOTIFY_PID:-} 2>/dev/null; desktop_session_stop' EXIT

export XDG_DATA_DIRS="${DESKTOP_HOME}/system-share" XDG_CONFIG_DIRS="${DESKTOP_HOME}/system-config"
export XDG_CURRENT_DESKTOP=X-Generic
unset DESKTOP_SESSION
mkdir -p "${XDG_DATA_DIRS}/applications" "${XDG_CONFIG_DIRS}"
FAILURES=0
NOTICES="${DESKTOP_HOME}/notifications.jsonl"
EDITOR_LOG="${DESKTOP_HOME}/editor.log"
NOTE="${XDG_DATA_HOME}/ergopti/notes/Notes_$(date +%d_%m_%Y).txt"

check() {
	if [ "$1" = 0 ]; then echo "  PASS $2"; else echo "  FAIL $2"; FAILURES=$((FAILURES + 1)); fi
}

wait_for_lines() {
	local file="$1" count="$2"
	for _ in $(seq 100); do
		[ -f "${file}" ] && [ "$(wc -l < "${file}")" -ge "${count}" ] && return 0
		sleep 0.1
	done
	return 1
}

"${PYTHON}" tests/hardware/desktop/notification_server.py --ready-file "${DESKTOP_HOME}/notify-ready" \
	--log "${NOTICES}" --timeout 120 &
NOTIFY_PID=$!
for _ in $(seq 50); do [ -f "${DESKTOP_HOME}/notify-ready" ] && break; sleep 0.1; done

echo "=== daily notes through the registered text editor (display ${DISPLAY}) ==="
echo "--- 1. no text/plain handler ---"
luajit tests/hardware/desktop/take_note_action.lua > "${DESKTOP_HOME}/run1.log" 2>&1
check $? "the action runs"
wait_for_lines "${NOTICES}" 1
check $? "the desktop's notification server receives one notice"
EXPECTED="$(luajit -e 'require("core.lifecycle.engine.compat.utf8").install(); local i = require("core.i18n.engine.i18n"); i.init()
	io.write(i.get("notify.take_note_no_text_handler"))')"
"${PYTHON}" -c 'import json,sys; n=json.loads(open(sys.argv[1]).readline()); sys.exit(0 if n["body"]==sys.argv[2] and "✖" in n["summary"] else 1)' \
	"${NOTICES}" "${EXPECTED}"
# Error notices are marked in the title, at normal urgency: a critical one never
# times out on most desktops (platform/system/notifier.lua).
check $? "it is the specific refusal, titled as an error: « ${EXPECTED} »"
[ ! -e "${NOTE}" ]
check $? "no note file was created"
grep -q "Daily note refused: the desktop has no registered text/plain handler" "${DESKTOP_HOME}/run1.log"
check $? "the log names the missing handler"

echo "--- 2. a registered text editor ---"
cat > "${DESKTOP_HOME}/proof-editor" <<EOF
#!/bin/sh
# Records what a text editor is handed: its argument and the file's bytes.
{ printf 'ARG %s\n' "\$1"; printf 'SHA %s\n' "\$(sha256sum < "\$1" | cut -d' ' -f1)"; } >> '${EDITOR_LOG}'
EOF
chmod +x "${DESKTOP_HOME}/proof-editor"
mkdir -p "${XDG_DATA_HOME}/applications"
cat > "${XDG_DATA_HOME}/applications/proof-editor.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Proof Editor
Exec=${DESKTOP_HOME}/proof-editor %f
MimeType=text/plain;
Terminal=false
EOF
# What `xdg-mime default` and a desktop's settings write: the driver's own
# xdg-mime query reads it back below.
printf '[Default Applications]\ntext/plain=proof-editor.desktop\n' > "${XDG_CONFIG_HOME}/mimeapps.list"

mkdir -p "$(dirname "${NOTE}")"
printf 'Existing line one\nExisting line two, no final newline' > "${NOTE}"
BEFORE="$(sha256sum < "${NOTE}" | cut -d' ' -f1)"
luajit tests/hardware/desktop/take_note_action.lua > "${DESKTOP_HOME}/run2.log" 2>&1
check $? "the action runs"
wait_for_lines "${EDITOR_LOG}" 2
check $? "the registered editor is started"
[ "$(sed -n 1p "${EDITOR_LOG}")" = "ARG ${NOTE}" ]
check $? "it is handed today's note: $(basename "${NOTE}")"
[ "$(sed -n 2p "${EDITOR_LOG}")" = "SHA ${BEFORE}" ] && [ "$(sha256sum < "${NOTE}" | cut -d' ' -f1)" = "${BEFORE}" ]
check $? "the existing note keeps every byte, at open time and after"
grep -q "Opening the daily note in the desktop text editor" "${DESKTOP_HOME}/run2.log"
check $? "the log says the note was opened"

luajit tests/hardware/desktop/take_note_action.lua > "${DESKTOP_HOME}/run3.log" 2>&1
wait_for_lines "${EDITOR_LOG}" 4
check $? "a second use opens the editor again"
[ "$(sed -n 3p "${EDITOR_LOG}")" = "ARG ${NOTE}" ] && [ "$(sed -n 4p "${EDITOR_LOG}")" = "SHA ${BEFORE}" ]
check $? "on the same, unchanged note"

rm -f "${NOTE}"
luajit tests/hardware/desktop/take_note_action.lua > "${DESKTOP_HOME}/run4.log" 2>&1
wait_for_lines "${EDITOR_LOG}" 6
[ -f "${NOTE}" ] && [ ! -s "${NOTE}" ] && [ "$(sed -n 5p "${EDITOR_LOG}")" = "ARG ${NOTE}" ]
check $? "an absent note is created empty and opened"
[ "$(wc -l < "${NOTICES}")" -eq 1 ]
check $? "no notice was shown for the successful opens"

if [ "${FAILURES}" -ne 0 ]; then
	echo "=== ${FAILURES} check(s) failed ==="
	tail -n 15 "${DESKTOP_HOME}"/run*.log "${NOTICES}" "${EDITOR_LOG}"
	exit 1
fi
echo "=== every check held ==="
exit 0
