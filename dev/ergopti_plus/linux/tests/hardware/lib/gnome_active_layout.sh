#!/bin/sh
# tests/hardware/lib/gnome_active_layout.sh
#
# Prints what <AD01> types on the source GNOME Shell itself has active, read
# through Eval on a shell started with --unsafe-mode: the compositor's own
# state, not the gsettings the adapter writes. ERGOPTI_LIVE_SIGNATURES maps
# each source id to it ("us=q fr=a"); a switch may reorder the sources, so the
# id names the layout, not its position.
set -eu
command -v gdbus >/dev/null 2>&1 || { echo "gdbus is missing" >&2; exit 2; }
answer="$(gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell \
	--method org.gnome.Shell.Eval \
	'String(Main.panel.statusArea.keyboard._inputSourceManager.currentSource.id)')"
id="$(printf '%s' "${answer}" | sed -n "s/^(true, '\"\\([A-Za-z0-9_+-]*\\)\"')$/\\1/p")"
[ -n "${id}" ] || { echo "the shell did not answer: ${answer}" >&2; exit 1; }
for pair in ${ERGOPTI_LIVE_SIGNATURES}; do
	[ "${pair%%=*}" = "${id}" ] && { echo "${pair#*=}"; exit 0; }
done
echo "unknown source ${id}" >&2
exit 1
