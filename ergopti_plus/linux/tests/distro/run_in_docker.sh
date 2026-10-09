#!/usr/bin/env bash
# static/ergopti_plus/linux/tests/distro/run_in_docker.sh
#
# Runs tests/distro/e2e_install.sh in a fresh container of the given image,
# with the repository mounted read-only. The same entry point serves CI and a
# developer's machine, so a red matrix entry reproduces locally with one line:
#
#   static/ergopti_plus/linux/tests/distro/run_in_docker.sh fedora:latest
#
# ERGOPTI_E2E_DOCKER_ARGS adds docker-run arguments (a proxy, a CA bundle).

set -euo pipefail

IMAGE="${1:?usage: run_in_docker.sh <image>}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd -P)"

# shellcheck disable=SC2086
exec docker run --rm --network host \
	-v "${REPO_ROOT}:/src:ro" \
	${ERGOPTI_E2E_DOCKER_ARGS:-} \
	"${IMAGE}" sh -c 'command -v bash >/dev/null 2>&1 || apk add --no-cache bash >/dev/null
		exec bash /src/static/ergopti_plus/linux/tests/distro/e2e_install.sh'
