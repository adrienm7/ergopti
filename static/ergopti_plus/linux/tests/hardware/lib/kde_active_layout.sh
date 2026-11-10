#!/bin/sh
# tests/hardware/lib/kde_active_layout.sh
#
# Prints the entry of ERGOPTI_LIVE_LAYOUTS (what <AD01> types on each of the
# session's layouts, in its order) for the layout KWin applies now, read from
# the compositor through org.kde.KeyboardLayouts.getLayout.
set -eu
index="$(gdbus call --session --dest org.kde.keyboard --object-path /Layouts \
	--method org.kde.KeyboardLayouts.getLayout | sed -n 's/.* \([0-9][0-9]*\),).*/\1/p')"
# shellcheck disable=SC2086
set -- ${ERGOPTI_LIVE_LAYOUTS}
shift "${index}"
echo "$1"
