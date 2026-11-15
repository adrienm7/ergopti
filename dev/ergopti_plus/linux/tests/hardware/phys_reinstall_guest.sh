#!/usr/bin/env bash
# static/ergopti_plus/linux/tests/hardware/phys_reinstall_guest.sh
#
# A reinstall over an older tree, on the live proof host of phys_live_guest.sh
# (run it after that script: it reuses its user and installation). install.sh
# runs twice for that user: first from a source carrying one extra driver file,
# then from the source without it. Checks:
#   1. the file the second source no longer ships is gone;
#   2. the reinstalled tree passes its own receipt (Ownership.verify);
#   3. a copy of it as <root>.old passes the check the updater makes before it
#      retires a previous backup (backup_is_owned = Ownership.verify).
# Before the fix, the extra file stayed behind and both verifications refused.
#
# Run as root. Receipts go to $ERGOPTI_PHYS_RECEIPTS (default /root/phys-receipts).
# Exit 0 = every check held; 1 = a check failed; 2 = no environment.

set -uo pipefail
SRC="${ERGOPTI_SRC:-/src}"
RECEIPTS="${ERGOPTI_PHYS_RECEIPTS:-/root/phys-receipts}"
PHYS_USER="ergopti-phys"
EXTRA="linux/phys-retired-probe.lua"
FAILURES=0
CHECKS=0
mkdir -p "${RECEIPTS}"
SUMMARY="${RECEIPTS}/reinstall-summary.txt"
: > "${SUMMARY}"
say()   { printf '%s\n' "$*" | tee -a "${SUMMARY}"; }
check() {
	local label="$1"; shift
	CHECKS=$((CHECKS + 1))
	if "$@"; then say "  ok   ${label}"; else FAILURES=$((FAILURES + 1)); say "  FAIL ${label}"; fi
}
environment() { echo "ENVIRONMENT: $*" >&2; exit 2; }

[ "$(id -u)" -eq 0 ] || environment "run as root"
id "${PHYS_USER}" >/dev/null 2>&1 || environment "run phys_live_guest.sh first"
PHYS_UID="$(id -u "${PHYS_USER}")"
PHYS_HOME="$(sed -n "s/^${PHYS_USER}:[^:]*:[^:]*:[^:]*:[^:]*:\([^:]*\):.*/\1/p" /etc/passwd)"
RUNTIME_DIR="/run/user/${PHYS_UID}"
LIB_ROOT="${PHYS_HOME}/.local/lib/ergopti"
[ -f "${LIB_ROOT}/.ergopti-owned-files" ] || environment "no installation for ${PHYS_USER}"
as_user() {
	sudo -u "${PHYS_USER}" env HOME="${PHYS_HOME}" XDG_RUNTIME_DIR="${RUNTIME_DIR}" \
		DBUS_SESSION_BUS_ADDRESS="unix:path=${RUNTIME_DIR}/bus" \
		https_proxy="${https_proxy:-}" HTTPS_PROXY="${HTTPS_PROXY:-}" bash -c "cd ~ && $1"
}
install_from() { # tree log
	rm -rf "${PHYS_HOME}/ergopti"
	mkdir -p "${PHYS_HOME}/ergopti/static/layouts" "${PHYS_HOME}/ergopti/tools/build"
	cp -r "$1/static/ergopti_plus" "${PHYS_HOME}/ergopti/static/"
	cp -r "$1/static/layouts/registry" "${PHYS_HOME}/ergopti/static/layouts/"
	cp "$1/package.json" "${PHYS_HOME}/ergopti/"
	cp "$1/tools/build/build-linux-native-output.sh" "${PHYS_HOME}/ergopti/tools/build/"
	chown -R "${PHYS_USER}" "${PHYS_HOME}/ergopti"
	as_user "bash ~/ergopti/static/ergopti_plus/linux/install.sh" > "$2" 2>&1
}
VERIFY_SCRIPT="$(mktemp /tmp/ergopti-phys-verify.XXXXXX.lua)"
cat > "${VERIFY_SCRIPT}" <<'LUA'
local identity, why = require("modules.updater.ownership_receipt").verify(arg[1], arg[2])
print(identity or why)
os.exit(identity and 0 or 1)
LUA
chmod 644 "${VERIFY_SCRIPT}"
verify() { # root
	as_user "LUA_PATH='${LIB_ROOT}/linux/?.lua;${LIB_ROOT}/linux/?/init.lua;${LIB_ROOT}/_shared/?.lua;${LIB_ROOT}/_shared/?/init.lua;;' \
		LUA_CPATH='${LIB_ROOT}/linux/native_modules/?.so;;' luajit '${VERIFY_SCRIPT}' '$1' '${LIB_ROOT}'"
}

say "=== Reinstall over an older tree ==="
OLDER="$(mktemp -d)"
cp -a "${SRC}/." "${OLDER}/"
printf -- '-- A driver file the newer version no longer ships.\nreturn {}\n' \
	> "${OLDER}/static/ergopti_plus/${EXTRA}"
check "the older version installs" install_from "${OLDER}" "${RECEIPTS}/reinstall-older.log"
check "the older tree ships ${EXTRA}" test -f "${LIB_ROOT}/${EXTRA}"
rm -rf "${OLDER}"
check "the newer version installs over it" install_from "${SRC}" "${RECEIPTS}/reinstall-newer.log"
check "${EXTRA} is gone" test ! -e "${LIB_ROOT}/${EXTRA}"
check "the reinstalled tree passes its own receipt: $(verify "${LIB_ROOT}" 2>&1 | tail -1)" verify "${LIB_ROOT}"
rm -rf "${LIB_ROOT}.old"
cp -a "${LIB_ROOT}" "${LIB_ROOT}.old"
chown -R "${PHYS_USER}" "${LIB_ROOT}.old"
check "as <root>.old it passes the updater's retirement check: $(verify "${LIB_ROOT}.old" 2>&1 | tail -1)" \
	verify "${LIB_ROOT}.old"
rm -rf "${LIB_ROOT}.old" "${VERIFY_SCRIPT}"
say ""
say "${CHECKS} checks, ${FAILURES} failures"
[ "${FAILURES}" -eq 0 ]
