#!/usr/bin/env bash
# static/ergopti_plus/linux/tests/distro/e2e_install.sh
#
# A first-run install on one distribution, inside a throwaway container.
#
# The question this answers is the one a user asks the first time: "I ran the
# installer — does it work?" So nothing here is --no-deps: the real
# install.sh runs as an unprivileged user with sudo, against the distribution's
# own package manager and archives, and the result is checked through the
# INSTALLED tree rather than the checkout:
#   1. the installer exits 0;
#   2. the launcher runs and every runtime dependency it names is reachable;
#   3. every library the daemon binds through FFI loads under the installed
#      luajit (libatspi, the tray's libayatana-appindicator);
#   4. the tray icon registers with a StatusNotifierWatcher — the protocol every
#      modern panel speaks — carrying the Ergopti logo and a menu;
#   5. which optional Lua modules the installed luajit can actually require.
#
# Run as root inside the container; the checkout is mounted read-only at
# $ERGOPTI_SRC (default /src). Exit 0 = every mandatory check held.
#
# Usage (from the host): tests/distro/run_in_docker.sh <image>

set -uo pipefail

SRC="${ERGOPTI_SRC:-/src}"
E2E_USER="ergopti-e2e"
FAILURES=0

ok()   { printf '  ok   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
info() { printf '  ..   %s\n' "$*"; }
section() { printf '\n=== %s ===\n' "$*"; }

# Everything installed here is TEST tooling (a user with sudo, a D-Bus bus, an
# X server, PyGObject for the panel stand-in) — never a dependency of the
# product. The product's own dependencies are the installer's job, and
# pre-installing one would hide a missing arm in install.sh.
prepare_test_tooling() {
	if command -v apt-get >/dev/null 2>&1; then
		export DEBIAN_FRONTEND=noninteractive
		apt-get update -qq
		apt-get install -y -qq --no-install-recommends sudo ca-certificates curl \
			python3 python3-gi gir1.2-glib-2.0 dbus xvfb xauth procps >/dev/null
	elif command -v zypper >/dev/null 2>&1; then
		zypper --non-interactive install -y sudo curl python3 python3-gobject \
			typelib-1_0-Gio-2_0 dbus-1 dbus-1-daemon xorg-x11-server-Xvfb procps shadow >/dev/null
	elif command -v dnf >/dev/null 2>&1; then
		dnf install -y -q sudo curl python3 python3-gobject-base dbus-daemon dbus-tools \
			xorg-x11-server-Xvfb procps-ng findutils shadow-utils >/dev/null
	elif command -v pacman >/dev/null 2>&1; then
		pacman -Sy --noconfirm --needed sudo curl python python-gobject dbus \
			xorg-server-xvfb procps-ng which >/dev/null
	elif command -v apk >/dev/null 2>&1; then
		# No shadow package: BusyBox's addgroup is what an Alpine user has, and
		# pre-installing usermod would hide an installer that needs it.
		apk add --no-cache bash sudo curl python3 py3-gobject3 dbus dbus-x11 \
			xvfb procps coreutils >/dev/null
	else
		echo "ENVIRONMENT: no supported package manager in this image" >&2
		exit 2
	fi
}

# A host behind a TLS-intercepting proxy mounts its CA here; trusting it is the
# host's network, not the product, so it is applied before anything downloads.
trust_extra_ca() {
	[ -n "${ERGOPTI_E2E_EXTRA_CA:-}" ] && [ -f "${ERGOPTI_E2E_EXTRA_CA}" ] || return 0
	if [ -d /usr/local/share/ca-certificates ] && command -v update-ca-certificates >/dev/null 2>&1; then
		cp "${ERGOPTI_E2E_EXTRA_CA}" /usr/local/share/ca-certificates/ergopti-e2e.crt
		update-ca-certificates >/dev/null 2>&1
	elif command -v update-ca-trust >/dev/null 2>&1; then
		cp "${ERGOPTI_E2E_EXTRA_CA}" /etc/pki/ca-trust/source/anchors/ergopti-e2e.crt
		update-ca-trust
	elif command -v trust >/dev/null 2>&1; then
		trust anchor "${ERGOPTI_E2E_EXTRA_CA}"
	fi
}

section "Test tooling"
# A matrix entry may need one image-specific fix before any package can be
# fetched (a mirror rewrite, a keyring refresh). It is the image's problem, not
# the product's, so it runs here and nowhere near install.sh.
if [ -n "${ERGOPTI_E2E_PREP:-}" ]; then
	sh -c "${ERGOPTI_E2E_PREP}" || { echo "ENVIRONMENT: the image preparation failed" >&2; exit 2; }
fi
prepare_test_tooling || { echo "ENVIRONMENT: could not install the test tooling" >&2; exit 2; }
trust_extra_ca
ok "sudo, D-Bus, Xvfb and PyGObject are available for the checks"
if [ -r /etc/os-release ]; then
	# shellcheck disable=SC1091
	. /etc/os-release
	info "distribution: ${PRETTY_NAME:-unknown}"
fi

# An ordinary user with passwordless sudo: the installer's documented audience.
if ! id "${E2E_USER}" >/dev/null 2>&1; then
	useradd -m -s /bin/bash "${E2E_USER}" 2>/dev/null || adduser -D -s /bin/bash "${E2E_USER}"
fi
echo "${E2E_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${E2E_USER}"
chmod 0440 "/etc/sudoers.d/${E2E_USER}"
E2E_HOME="$(getent passwd "${E2E_USER}" | cut -d: -f6)"
# Only what the installer reads from a checkout: the product tree and the
# version source. The whole repository would drag node_modules along.
rm -rf "${E2E_HOME}/ergopti"
mkdir -p "${E2E_HOME}/ergopti/static"
cp -r "${SRC}/static/ergopti_plus" "${E2E_HOME}/ergopti/static/"
cp "${SRC}/package.json" "${E2E_HOME}/ergopti/"
chown -R "${E2E_USER}" "${E2E_HOME}/ergopti"

as_user() {
	# A login shell without a session bus: the shape of a first install over
	# SSH or from a container, where systemd --user is unreachable.
	su - "${E2E_USER}" -c "export https_proxy='${https_proxy:-}' HTTPS_PROXY='${HTTPS_PROXY:-}'; $1"
}


section "Installer"
INSTALL_LOG="$(mktemp)"
if as_user "bash ~/ergopti/static/ergopti_plus/linux/install.sh" >"${INSTALL_LOG}" 2>&1; then
	ok "install.sh exited 0 with dependencies"
else
	fail "install.sh failed — last lines:"
	tail -40 "${INSTALL_LOG}" | sed 's/^/       /'
fi
grep -E '✔|✗|⚠|→' "${INSTALL_LOG}" | sed 's/^/       /'

LAUNCHER="${E2E_HOME}/.local/bin/ergopti-hotstrings"
LIB_ROOT="${E2E_HOME}/.local/lib/ergopti"
if [ -x "${LAUNCHER}" ]; then ok "launcher installed at ~/.local/bin/ergopti-hotstrings"; else fail "no launcher"; fi
if as_user "${LAUNCHER} --help" >/dev/null 2>&1; then
	ok "the launcher runs (--help)"
else
	fail "the launcher does not run: $(as_user "${LAUNCHER} --help" 2>&1 | tail -3)"
fi

# The installed wrapper's own LUA_PATH, replayed rather than re-typed, so a
# check here cannot pass against a path the launcher does not set.
INSTALLED_LUA_PATH="${LIB_ROOT}/linux/?.lua;${LIB_ROOT}/linux/?/init.lua;${LIB_ROOT}/_shared/lua/?.lua;${LIB_ROOT}/_shared/lua/?/init.lua;;"


section "Runtime dependencies"
for cmd in luajit notify-send zenity xkbcli sha256sum unzip; do
	if as_user "command -v ${cmd}" >/dev/null 2>&1; then ok "${cmd} is on PATH"; else fail "${cmd} is missing after install"; fi
done
# kanata is optional by design (tap-holds and layers; hotstrings work without
# it) and the upstream binary needs glibc 2.39, so on an older distribution the
# honest outcome is "reported unavailable", not "installed". What must never
# happen is a silent absence.
if as_user "command -v kanata || test -x ~/.local/bin/kanata" >/dev/null 2>&1; then
	ok "kanata is installed"
elif grep -q "kanata indisponible" "${INSTALL_LOG}"; then
	info "kanata unavailable here ($(ldd --version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+$' || echo '?') glibc) — reported by the installer"
else
	fail "kanata is missing after install and the installer did not say so"
fi

ffi_load() {
	as_user "luajit -e \"local ffi=require('ffi'); for _, n in ipairs({$1}) do if pcall(ffi.load, n) then os.exit(0) end end; os.exit(1)\"" >/dev/null 2>&1
}
if ffi_load "'libatspi.so.0'"; then ok "libatspi loads (secure-field detection)"; else fail "libatspi does not load"; fi
if ffi_load "'ayatana-appindicator3.so.1','appindicator3.so.1'"; then
	ok "libayatana-appindicator loads (the tray backend)"
else
	fail "no appindicator library loads — the tray icon cannot appear"
fi

# The tray's windows (settings, editor, metrics, onboarding) are WebKit2GTK
# pages driven through lgi. Without both, every menu row that opens a window
# does nothing on a fresh install.
# ERGOPTI_E2E_KNOWN_LIMITATIONS names what a matrix entry declares missing on
# that distribution (Fedora packages lgi for Lua 5.4 only). Declared, not
# skipped: the entry fails the day the limitation disappears, so the
# declaration cannot outlive the fact.
known_limitation() {
	case " ${ERGOPTI_E2E_KNOWN_LIMITATIONS:-} " in *" $1 "*) return 0 ;; esac
	return 1
}
if as_user "luajit -e \"local core=require('lgi.core'); os.exit(core.gi.require('WebKit2') and 0 or 1)\"" >/dev/null 2>&1; then
	if known_limitation webkit; then
		fail "WebKit2GTK now loads through lgi here — remove the declared 'webkit' limitation"
	else
		ok "WebKit2GTK loads through lgi (the tray's windows can open)"
	fi
elif known_limitation webkit; then
	info "KNOWN LIMITATION: no LuaJIT build of lgi on this distribution — the tray works, its windows do not"
else
	fail "WebKit2GTK does not load through lgi — the tray's windows cannot open"
fi

# Informational: which optional modules the INSTALLED luajit can require. Each
# is loaded through pcall by the daemon, so absence degrades rather than fails
# — but a module installed for Lua 5.4 is invisible to LuaJIT, and that
# difference is exactly what a table like this makes visible per distribution.
for mod in luv lfs posix lgi; do
	if as_user "luajit -e \"require('${mod}')\"" >/dev/null 2>&1; then
		info "optional Lua module '${mod}': available to luajit"
	else
		info "optional Lua module '${mod}': NOT available to luajit"
	fi
done


# Which packages this archive offers for the modules LuaJIT could not load.
# Informational: it is how the per-distribution candidate names in install.sh
# are kept honest when an archive renames a package.
lua_package_search() {
	if command -v apt-cache >/dev/null 2>&1; then apt-cache search --names-only "$1" 2>/dev/null
	elif command -v zypper >/dev/null 2>&1; then zypper --non-interactive search "$1" 2>/dev/null | grep -E "\| *[a-z0-9.-]*$1" 
	elif command -v dnf >/dev/null 2>&1; then dnf -q search "$1" 2>/dev/null
	elif command -v pacman >/dev/null 2>&1; then pacman -Ss "$1" 2>/dev/null | grep -v "^ "
	elif command -v apk >/dev/null 2>&1; then apk search "$1" 2>/dev/null
	fi | head -8 | sed 's/^/          /'
}
for mod in luv lgi posix filesystem; do
	if ! as_user "luajit -e \"require('$( [ "${mod}" = filesystem ] && echo lfs || echo "${mod}")')\"" >/dev/null 2>&1; then
		info "archive packages matching '${mod}':"
		lua_package_search "${mod}"
	fi
done


section "Tray icon"
READY="$(mktemp -u)"
SNI_REPORT="$(mktemp)"
chmod 0666 "${SNI_REPORT}"
TRAY_SCRIPT="$(mktemp)"
cat > "${TRAY_SCRIPT}" << TRAY
set -u
export LUA_PATH='${INSTALLED_LUA_PATH}'
# A private session bus started by hand: dbus-run-session is not shipped
# everywhere (openSUSE), dbus-daemon is.
DBUS_SESSION_BUS_ADDRESS="\$(dbus-daemon --session --fork --print-address=1 --print-pid=3 3>/tmp/ergopti-e2e-dbus.pid)"
export DBUS_SESSION_BUS_ADDRESS
Xvfb :77 -screen 0 1024x768x24 >/dev/null 2>&1 &
XVFB=\$!
export DISPLAY=:77
python3 '${SRC}/static/ergopti_plus/linux/tests/hardware/sni_host.py' --ready-file '${READY}' \
	--timeout 30 --expect-label 'Ergopti+ tray probe' --expect-icon-file > '${SNI_REPORT}' &
HOST=\$!
for _ in \$(seq 1 60); do [ -f '${READY}' ] && break; sleep 0.25; done
cd '${LIB_ROOT}/linux'
luajit '${SRC}/static/ergopti_plus/linux/tests/hardware/run_tray_icon.lua' 10
PROBE=\$?
wait \$HOST; STATUS=\$?
kill \$XVFB 2>/dev/null
kill "\$(cat /tmp/ergopti-e2e-dbus.pid)" 2>/dev/null
[ "\$PROBE" = "0" ] || exit 10
exit \$STATUS
TRAY
chmod 0755 "${TRAY_SCRIPT}"
if as_user "bash ${TRAY_SCRIPT}" >"${SNI_REPORT}.log" 2>&1; then
	ok "the tray item registered, Active, with the Ergopti logo and its menu"
else
	fail "the tray icon did not appear through a StatusNotifier host"
	grep -vE 'DEBUG|fd limit' "${SNI_REPORT}.log" | tail -15 | sed 's/^/       /'
fi
sed 's/^/       /' "${SNI_REPORT}"


section "Result"
if [ "${FAILURES}" -eq 0 ]; then
	echo "PASS — first-run install verified on ${PRETTY_NAME:-this distribution}"
	exit 0
fi
echo "FAIL — ${FAILURES} check(s) failed on ${PRETTY_NAME:-this distribution}"
exit 1
