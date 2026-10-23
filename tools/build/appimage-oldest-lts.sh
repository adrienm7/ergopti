#!/usr/bin/env bash
# tools/build/appimage-oldest-lts.sh
#
# Builds and launches the AppImage on the oldest Ubuntu LTS in standard support,
# which is where the AppImage catalogue (appimage.github.io) tests it.
#
# The AppImage bundles LuaJIT, curl, luv and their libraries but uses the
# recipient's glibc. Built on ubuntu-latest, its luajit needed GLIBC_2.38 and
# the catalogue's Ubuntu 22.04 (glibc 2.35) killed it before any tray icon
# appeared. Building inside that release's own container makes every bundled
# file need at most its glibc; check-elf-glibc-ceiling.cjs proves it on the
# packaged tree. The container also rebuilds the driver's native archive backend
# in build/linux, so the .deb, .rpm and tarball made from the bundle afterwards
# load on it too.
#
# Usage:
#   bash tools/build/appimage-oldest-lts.sh build
#     Needs Docker and the bundle from build-linux-driver.sh. Leaves
#     build/linux/ErgoptiPlus-x86_64.AppImage and its .zsync, owned by the caller.
#
#   bash tools/build/appimage-oldest-lts.sh smoke <AppImage>
#     Launches it in the conditions the catalogue sets with firejail: no
#     arguments (a desktop launch), no network, a user outside the input group.
#     Passes when a StatusNotifier host sees the tray icon and its menu and the
#     app is still running afterwards, then when, with no session bus, the icon
#     docks in stalonetray as in the catalogue, the no-keyboard status window
#     is on screen, and a left and a right click on the docked icon each map
#     the tray menu (checked with xwininfo, no screenshot). The host has GTK 3 but no
#     libayatana, like the catalogue's runner: the image brings its own. firejail itself cannot sandbox inside a
#     container (it takes Docker for a sandbox already in place and runs the
#     image bare), so a network namespace of its own stands in for --net=none
#     and the image mounts through FUSE as on a desktop.

set -euo pipefail

OLDEST_LTS_IMAGE="ubuntu:22.04"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
BUILD_ROOT="$PROJECT_ROOT/build/linux"
SELF="tools/build/appimage-oldest-lts.sh"
SMOKE_USER="catalogue"

apt_install() {
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -q
	apt-get install -y -q --no-install-recommends "$@"
}

# ----------------------------------------------------------------------
# Inside the container: the build
# ----------------------------------------------------------------------
container_build() {
	apt_install bash ca-certificates curl binutils file gcc libc6-dev pkg-config python3 \
		luajit lua-luv libssl-dev libglib2.0-dev libglib2.0-bin glib-networking \
		dconf-gsettings-backend gsettings-desktop-schemas libayatana-appindicator3-1
	# The runner's Node, mounted read-only: the release's own is too old for the
	# build scripts, and Node itself ships nothing into the image.
	export PATH="/opt/node/bin:$PATH"
	node --version

	# The bundle's backend was compiled on the runner: replace it with one built
	# here, which every package made from the bundle then carries.
	local backend="libergopti_archive_publication.so"
	rm -f "$BUILD_ROOT/linux/bin/$backend"
	bash tools/build/build-linux-native-output.sh

	# appimagetool ships as an AppImage and a container has no FUSE: unpack it.
	local tools
	tools="$(mktemp -d)"
	curl -fsSL --retry 3 --retry-delay 5 -o "$tools/appimagetool" \
		https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
	chmod +x "$tools/appimagetool"
	(cd "$tools" && ./appimagetool --appimage-extract >/dev/null)
	ln -sf "$tools/squashfs-root/AppRun" /usr/local/bin/appimagetool

	bash tools/build/build-linux-appimage.sh
	chown -R "$HOST_UID:$HOST_GID" "$BUILD_ROOT"
}

# ----------------------------------------------------------------------
# Inside the container: the catalogue's launch
# ----------------------------------------------------------------------
container_smoke() {
	# GTK 3 but no libayatana, as on the catalogue's runner: the image brings its
	# own tray library. stalonetray and xwininfo replay the catalogue's tray check.
	apt_install fuse3 xvfb xauth dbus iproute2 python3 python3-gi gir1.2-glib-2.0 \
		libgtk-3-0 stalonetray x11-utils xdotool
	if ldconfig -p | grep -q 'libayatana-appindicator3\.so\.1 '; then
		echo "ENVIRONMENT: the smoke host must not provide libayatana-appindicator3" >&2
		return 2
	fi
	useradd --create-home "$SMOKE_USER"
	cp /tmp/ergopti.AppImage "/home/$SMOKE_USER/ErgoptiPlus.AppImage"
	chown "$SMOKE_USER:" "/home/$SMOKE_USER/ErgoptiPlus.AppImage"
	chmod 755 "/home/$SMOKE_USER/ErgoptiPlus.AppImage"
	unshare --net -- runuser -u "$SMOKE_USER" -- \
		bash "$SELF" smoke-as-user "/home/$SMOKE_USER/ErgoptiPlus.AppImage"
}

user_smoke() {
	local appimage="$1" work bus ready host app status alive
	# Offline means no interface but loopback, and loopback down.
	if ip -o link show | grep -v ': lo:' | grep -q . || ip -o link show lo | grep -q 'state UP'; then
		echo "ENVIRONMENT: the smoke must run without any network" >&2
		return 2
	fi
	if id -nG | tr ' ' '\n' | grep -qx input; then
		echo "ENVIRONMENT: the smoke user must be outside the input group" >&2
		return 2
	fi
	work="$(mktemp -d)"
	export XDG_RUNTIME_DIR="$work/runtime"
	mkdir -m 700 "$XDG_RUNTIME_DIR"
	bus="$XDG_RUNTIME_DIR/bus"
	dbus-daemon --session --nofork --address="unix:path=$bus" &
	export DBUS_SESSION_BUS_ADDRESS="unix:path=$bus"
	for _ in $(seq 1 40); do [ -S "$bus" ] && break; sleep 0.25; done
	[ -S "$bus" ] || { echo "ENVIRONMENT: the session bus never started" >&2; return 2; }

	ready="$work/sni-ready"
	python3 static/ergopti_plus/linux/tests/hardware/sni_host.py --ready-file "$ready" \
		--timeout 60 --settle 3 --min-labels 2 --expect-icon-file > "$work/sni.json" &
	host=$!
	for _ in $(seq 1 40); do [ -f "$ready" ] && break; sleep 0.25; done
	[ -f "$ready" ] || { echo "ENVIRONMENT: the StatusNotifier host never started" >&2; return 2; }

	xvfb-run -a "$appimage" > "$work/app.log" 2>&1 &
	app=$!
	status=0
	wait "$host" || status=$?
	alive=true
	kill -0 "$app" 2>/dev/null || alive=false
	echo "--- what the panel saw ---"
	cat "$work/sni.json"
	echo "--- what the AppImage printed ---"
	cat "$work/app.log"
	kill "$app" 2>/dev/null || true
	if [ "$status" != 0 ]; then
		echo "[ERR] No tray icon appeared: the catalogue would fail this AppImage." >&2
		return 1
	fi
	if [ "$alive" != true ]; then
		echo "[ERR] The AppImage exited after showing its icon." >&2
		return 1
	fi
	echo "[OK] Offline on $OLDEST_LTS_IMAGE, the AppImage shows its tray icon and stays up."

	# The catalogue has no StatusNotifier host: it docks XEmbed icons into
	# stalonetray, with no session bus. A fresh runtime directory keeps GLib
	# from finding the bus above through $XDG_RUNTIME_DIR/bus.
	export XDG_RUNTIME_DIR="$work/runtime-xembed"
	mkdir -m 700 "$XDG_RUNTIME_DIR"
	env -u DBUS_SESSION_BUS_ADDRESS xvfb-run -a bash "$SELF" xembed-in-display "$appimage"
}

# The catalogue's own tray check, run inside an X display without a session bus.
xembed_smoke() {
	local appimage="$1" tray_window="" icon="" app log
	stalonetray --geometry 1x1+0+0 --icon-size 48 -bg white --window-type dock \
		--decorations none --skip-taskbar > /dev/null 2>&1 &
	for _ in $(seq 1 40); do
		tray_window="$(xwininfo -name stalonetray 2>/dev/null | awk '/Window id:/ { print $4 }' || true)"
		[ -n "$tray_window" ] && break
		sleep 0.25
	done
	[ -n "$tray_window" ] || { echo "ENVIRONMENT: stalonetray never started" >&2; return 2; }
	log="$(mktemp)"
	"$appimage" > "$log" 2>&1 &
	app=$!
	# Docked icons are child windows of the tray; it always has a 1x1 one.
	for _ in $(seq 1 30); do
		sleep 1
		kill -0 "$app" 2>/dev/null || break
		icon="$(xwininfo -tree -id "$tray_window" 2>/dev/null | grep -E '^ +0x' | grep -v ' 1x1+' | tail -n 1 || true)"
		[ -n "$icon" ] && break
	done
	echo "--- what the AppImage printed without a StatusNotifier host ---"
	cat "$log"
	if [ -z "$icon" ]; then
		kill "$app" 2>/dev/null || true
		echo "[ERR] No icon docked in stalonetray: the catalogue would fail this AppImage." >&2
		return 1
	fi
	if ! kill -0 "$app" 2>/dev/null; then
		echo "[ERR] The AppImage exited after docking its icon." >&2
		return 1
	fi
	echo "[OK] Without libayatana or a session bus, the icon docks in an XEmbed tray."

	# The catalogue screenshots the first named window it finds. Without a
	# keyboard the app opens its status window, a direct child of the root here
	# since no window manager runs.
	local status_window
	status_window="$(xwininfo -root -children 2>/dev/null | awk '/"Ergopti\+": \(/ { print $1; exit }')"
	if [ -z "$status_window" ] || ! xwininfo -id "$status_window" | grep -q 'Map State: IsViewable'; then
		kill "$app" 2>/dev/null || true
		echo "[ERR] No status window: the catalogue would screenshot the bare tray icon." >&2
		return 1
	fi
	echo "[OK] The status window $status_window is on screen."

	# Then the clicks a user makes on the icon: each must map the tray menu, an
	# override-redirect popup. A tooltip is one too, hence the minimum height.
	local icon_id x y w h button
	icon_id="$(awk '{ print $1 }' <<<"$icon")"
	read -r x y w h < <(xwininfo -id "$icon_id" | awk '/Absolute upper-left X/ { x = $NF } /Absolute upper-left Y/ { y = $NF }
		/Width/ { w = $NF } /Height/ { h = $NF } END { print x, y, w, h }')
	for button in 1 3; do
		xdotool mousemove $((x + w / 2)) $((y + h / 2)) click "$button"
		if ! wait_for_menu_popups 1; then
			kill "$app" 2>/dev/null || true
			echo "[ERR] Clicking the tray icon with button $button opened no menu." >&2
			return 1
		fi
		echo "[OK] Button $button on the tray icon opens the menu."
		xdotool key Escape
		if ! wait_for_menu_popups 0; then
			kill "$app" 2>/dev/null || true
			echo "[ERR] The tray menu did not close on Escape." >&2
			return 1
		fi
	done
	kill "$app" 2>/dev/null || true
}

# The viewable override-redirect windows at least 60 px tall: popup menus.
menu_popup_count() {
	local id count=0 info
	for id in $(xwininfo -root -children 2>/dev/null | awk '/^ +0x/ { print $1 }'); do
		info="$(xwininfo -id "$id" 2>/dev/null || true)"
		grep -q 'Map State: IsViewable' <<<"$info" || continue
		grep -q 'Override Redirect State: yes' <<<"$info" || continue
		[ "$(awk '/Height:/ { print $NF }' <<<"$info")" -ge 60 ] || continue
		count=$((count + 1))
	done
	echo "$count"
}

# Waits up to 10 s for exactly as many popup menus as expected (0, or 1+).
wait_for_menu_popups() {
	local expected="$1" count
	for _ in $(seq 1 40); do
		count="$(menu_popup_count)"
		if [ "$expected" = 0 ] && [ "$count" = 0 ]; then return 0; fi
		if [ "$expected" != 0 ] && [ "$count" -ge "$expected" ]; then return 0; fi
		sleep 0.25
	done
	return 1
}

# ----------------------------------------------------------------------
# On the host
# ----------------------------------------------------------------------
case "${1:-}" in
	build)
		[ -f "$BUILD_ROOT/linux/ergopti_hotstrings.lua" ] || {
			echo "[ERR] No driver bundle: run tools/build/build-linux-driver.sh first." >&2
			exit 1
		}
		node_root="$(cd "$(dirname "$(command -v node)")/.." && pwd -P)"
		docker run --rm \
			-v "$PROJECT_ROOT:/src" -v "$node_root:/opt/node:ro" -w /src \
			-e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
			-e ERGOPTI_BUILD_VERSION \
			"$OLDEST_LTS_IMAGE" bash "$SELF" container-build
		;;
	smoke)
		[ $# -eq 2 ] && [ -f "$2" ] || { echo "Usage: $0 smoke <AppImage>" >&2; exit 2; }
		appimage="$(cd "$(dirname "$2")" && pwd -P)/$(basename "$2")"
		# Privileged for the network namespace and the FUSE mount, as on a desktop.
		docker run --rm --privileged \
			-v "$PROJECT_ROOT:/src:ro" -v "$appimage:/tmp/ergopti.AppImage:ro" -w /src \
			"$OLDEST_LTS_IMAGE" bash "$SELF" container-smoke
		;;
	container-build) container_build ;;
	container-smoke) container_smoke ;;
	smoke-as-user) user_smoke "$2" ;;
	xembed-in-display) xembed_smoke "$2" ;;
	*)
		echo "Usage: $0 build | smoke <AppImage>" >&2
		exit 2
		;;
esac
