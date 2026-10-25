#!/usr/bin/env bash
# tools/test/run-linux-distro-unit.sh
#
# Runs one suite of the Linux module groups on one distribution's own LuaJIT,
# in a fresh container of the image and preparation that
# .github/linux-install-matrix.json authors for that distribution's archive
# installation lot, with the checkout mounted read-only. "unit" runs every
# group but integration (the distribution rows of the Unit stage, job
# test-linux of .github/workflows/ci-linux.yml), "integration" that group alone
# (the distribution rows of the Integration stage, job integration-linux). CI
# and a developer's machine share this entry point, so a red row reproduces
# locally with one line:
#
#   tools/test/run-linux-distro-unit.sh alpine unit
#
# The authored map stays the one source of each image and preparation; this
# script only reads it. prepare-linux-distro-unit.sh does the work inside.
# ERGOPTI_UNIT_DOCKER_ARGS adds docker-run arguments (a proxy, a CA bundle).

set -euo pipefail

distro="${1:?usage: run-linux-distro-unit.sh <distribution> <unit|integration>}"
suite="${2:?usage: run-linux-distro-unit.sh <distribution> <unit|integration>}"
# Refused before any container starts: a typo would otherwise cost a whole
# distribution preparation.
case "$suite" in
	unit|integration) ;;
	*) echo 'Unknown distribution suite: unit or integration.' >&2; exit 64 ;;
esac
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
image="$(node "$repo_root/tools/ci/linux-install-matrix.cjs" distro "$distro" image)"
prep="$(node "$repo_root/tools/ci/linux-install-matrix.cjs" distro "$distro" prep)"

# The preparation runs under sh: a minimal image may have no bash before it.
# shellcheck disable=SC2086
exec docker run --rm --network host \
	-v "$repo_root:/src:ro" \
	${ERGOPTI_UNIT_DOCKER_ARGS:-} \
	-e ERGOPTI_UNIT_PREP="$prep" \
	"$image" sh -c 'set -e
		eval "$ERGOPTI_UNIT_PREP"
		exec bash /src/tools/test/prepare-linux-distro-unit.sh "$1" /src "$2"' distro-unit "$distro" "$suite"
