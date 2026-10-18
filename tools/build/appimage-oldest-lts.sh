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
#     build/linux/Ergopti-<version>-x86_64.AppImage, owned by the caller.
#
#   bash tools/build/appimage-oldest-lts.sh smoke <AppImage>
#     Launches it in the conditions the catalogue sets with firejail: no
#     arguments (a desktop launch), no network, a user outside the input group.
#     Passes when a StatusNotifier host sees the tray icon and its menu and the
#     app is still running afterwards. firejail itself cannot sandbox inside a
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
		dconf-gsettings-backend gsettings-desktop-schemas
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
	apt_install fuse3 xvfb xauth dbus iproute2 python3 python3-gi gir1.2-glib-2.0 \
		libayatana-appindicator3-1
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
	*)
		echo "Usage: $0 build | smoke <AppImage>" >&2
		exit 2
		;;
esac
