#!/usr/bin/env bash
# tools/test/run-linux-distro-unit.sh
#
# Runs the Linux unit suite on one distribution's own LuaJIT, in a fresh
# container of the image and preparation that .github/linux-install-matrix.json
# authors for that distribution's archive installation lot, with the checkout
# mounted read-only. The distribution rows of the Unit stage (job test-linux of
# .github/workflows/ci-linux.yml) and a developer's machine share this entry
# point, so a red row reproduces locally with one line:
#
#   tools/test/run-linux-distro-unit.sh alpine
#
# The authored map stays the one source of each image and preparation; this
# script only reads it. prepare-linux-distro-unit.sh does the work inside.
# ERGOPTI_UNIT_DOCKER_ARGS adds docker-run arguments (a proxy, a CA bundle).

set -euo pipefail

distro="${1:?usage: run-linux-distro-unit.sh <distribution>}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
image="$(node "$repo_root/tools/ci/linux-install-matrix.cjs" unit "$distro" image)"
prep="$(node "$repo_root/tools/ci/linux-install-matrix.cjs" unit "$distro" prep)"

# The preparation runs under sh: a minimal image may have no bash before it.
# shellcheck disable=SC2086
exec docker run --rm --network host \
	-v "$repo_root:/src:ro" \
	${ERGOPTI_UNIT_DOCKER_ARGS:-} \
	-e ERGOPTI_UNIT_PREP="$prep" \
	"$image" sh -c 'set -e
		eval "$ERGOPTI_UNIT_PREP"
		exec bash /src/tools/test/prepare-linux-distro-unit.sh "$1" /src' distro-unit "$distro"
