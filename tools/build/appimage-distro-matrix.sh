#!/usr/bin/env bash
# tools/build/appimage-distro-matrix.sh
#
# Launches a built AppImage in a matrix of distribution containers and checks
# that each one runs it, or refuses it in words, as its C library dictates
# (tools/build/appimage-distro-check.sh does the checks inside each image).
# The AppImage uses the recipient's glibc: an image at or above GLIBC_CEILING
# must run it, an older glibc or a musl image must get the AppRun preflight's
# refusal. Extract-and-run mode stands in for FUSE, which containers lack.
#
# Usage:
#   bash tools/build/appimage-distro-matrix.sh <AppImage> [image...]
#     Needs Docker. Without images, runs DEFAULT_IMAGES one after the other and
#     exits non-zero when any of them fails.
#
#   ERGOPTI_MATRIX_DOCKER_ARGS="--network host"   (optional)
#     Extra `docker run` arguments, split on spaces: a network that reaches the
#     package mirrors only through a host proxy needs the host network, with
#     images whose package manager is configured for that proxy.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DEFAULT_IMAGES=(
	ubuntu:20.04 ubuntu:22.04 ubuntu:24.04 ubuntu:26.04
	debian:11 debian:12 debian:13
	fedora:latest opensuse/leap:latest archlinux:latest alpine:latest
)
CEILING="$(node -p "require('$SCRIPT_DIR/check-elf-glibc-ceiling.cjs').GLIBC_CEILING")"
REFUSAL_EXIT="$(node -p "require('$SCRIPT_DIR/render-appimage-libc-preflight.cjs').REFUSAL_EXIT")"

if [ $# -lt 1 ] || [ ! -f "$1" ]; then
	echo "Usage: $0 <AppImage> [image...]" >&2
	exit 2
fi
appimage="$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")"
shift
images=("$@")
[ ${#images[@]} -gt 0 ] || images=("${DEFAULT_IMAGES[@]}")

read -r -a docker_args <<< "${ERGOPTI_MATRIX_DOCKER_ARGS:-}"
failed=()
for image in "${images[@]}"; do
	echo "=== $image ==="
	if docker run --rm "${docker_args[@]}" \
		-v "$appimage:/tmp/matrix.AppImage:ro" -v "$SCRIPT_DIR/appimage-distro-check.sh:/tmp/check.sh:ro" \
		"$image" sh /tmp/check.sh /tmp/matrix.AppImage "$CEILING" "$REFUSAL_EXIT"; then
		echo "[OK] $image"
	else
		echo "[ERR] $image" >&2
		failed+=("$image")
	fi
done
if [ ${#failed[@]} -gt 0 ]; then
	echo "[ERR] ${#failed[@]} of ${#images[@]} image(s) failed: ${failed[*]}" >&2
	exit 1
fi
echo "[OK] All ${#images[@]} image(s) behave as their C library dictates."
