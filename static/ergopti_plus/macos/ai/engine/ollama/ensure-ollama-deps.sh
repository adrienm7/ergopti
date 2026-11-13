#!/bin/bash
# ai/engine/ollama/ensure-ollama-deps.sh

# ============================================================================
# SCRIPT: Verify Ollama Engine
# DESCRIPTION:
# Verifies the executable ai/engine/ollama/binary.lua resolved, which is
# only ever Ergopti's own pinned runtime. Nothing is downloaded here: the
# stock official release and its installers are retired (owned-runtimes row
# "Ollama installers (legacy)"), and Ergopti's runtime is installed by
# ensure-ollama-native-deps.sh after the user's consent. Daemon launch
# remains owned by ApiOllama.
#
# Usage: ensure-ollama-deps.sh <resolved-executable> [<unused-install-dir>]
#                            [resolved-native-python]
# ============================================================================

set -eu

OLLAMA_RESOLVED_BIN="${1:-${ERGOPTI_BOOTSTRAP_OLLAMA_RESOLVED_BIN:-}}"

log_error() {
	printf "[OLLAMA-DEPS] ERROR: %s\n" "$1" >&2
}

# EX_USAGE: the driver resolved nothing, so there is nothing to verify; a
# missing runtime is the native installer's to provide, never this script's.
if [ -z "$OLLAMA_RESOLVED_BIN" ]; then
	log_error "No resolved Ollama executable; this script never downloads one."
	exit 64
fi
if [ ! -x "$OLLAMA_RESOLVED_BIN" ]; then
	log_error "The driver-resolved Ollama executable is no longer executable."
	exit 1
fi
exit 0
