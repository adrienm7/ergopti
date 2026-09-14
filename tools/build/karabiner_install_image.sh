#!/bin/bash
# tools/build/karabiner_install_image.sh
# Install an authenticated image only inside disposable native acceptance.
set -euo pipefail

if [[ "${GITHUB_ACTIONS:-}" != "true" || "${RUNNER_ENVIRONMENT:-}" != "github-hosted" || "$(uname -s)" != "Darwin" ]]; then
	echo "Karabiner image installation is restricted to hosted macOS acceptance." >&2
	exit 1
fi
if [[ $# -ne 1 || ! -f "$1" ]]; then
	echo "Expected one previously authenticated disk image." >&2
	exit 1
fi

image="$1"
mount_point="$(mktemp -d "${RUNNER_TEMP:?}/hs274-install.XXXXXX")"
(
	cleanup() {
		local status=$?
		if ! hdiutil detach "$mount_point" -quiet; then status=1; fi
		rmdir "$mount_point" || status=1
		exit "$status"
	}
	trap cleanup EXIT
	hdiutil attach "$image" -nobrowse -readonly -mountpoint "$mount_point"
	test -f "$mount_point/Karabiner-Elements.pkg"
	sudo -n /usr/sbin/installer -pkg "$mount_point/Karabiner-Elements.pkg" -target /
)
