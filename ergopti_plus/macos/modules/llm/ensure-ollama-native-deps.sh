#!/bin/bash
# modules/llm/ensure-ollama-native-deps.sh
# Install the separately published, source-qualified native HTTP runtime only
# after explicit backend selection. Model-store and daemon ownership are kept
# by the existing callers; this script never starts a daemon or moves models.

set -eu
set -o pipefail
if [ "$0" = "/dev/fd/3" ] && [ -n "${ERGOPTI_BOOTSTRAP_SCRIPT_DIR:-}" ]; then
	SCRIPT_DIR="$ERGOPTI_BOOTSTRAP_SCRIPT_DIR"
else
	SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
fi
source "$SCRIPT_DIR/network-retry.sh"
source "$SCRIPT_DIR/native_python_bootstrap.sh"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
# Only the canonical pinned native bootstrap may supply this interpreter.
# An inherited executable path is not an admitted private runtime.
unset ERGOPTI_BOOTSTRAP_PYTHON
printf '%s\n' 'OLLAMA_INSTALLING'
if [ ! -x "${ERGOPTI_BOOTSTRAP_PYTHON:-}" ]; then
	native_bootstrap_python "$HOME/Library/Application Support/Ergopti/native-bootstrap"
fi
# The original PTY guardian's 30-minute deadline remains earliest through the
# native Python bootstrap and this receiver; no subprocess resets that owner.
"$ERGOPTI_BOOTSTRAP_PYTHON" "$SCRIPT_DIR/managed_ollama_runtime.py" install \
	--timeout "$(( ${ERGOPTI_BOOTSTRAP_TIMEOUT_MS:?native bootstrap owner budget is missing} / 1000 ))" \
	--idle-timeout "$CURL_STALL_SEC" --connect-timeout "$CURL_CONNECT_TIMEOUT_SEC" \
	--minimum-bytes-per-second "$CURL_STALL_BYTES_PER_SEC"
printf '%s\n' 'OLLAMA_VERIFIED' 'OLLAMA_INSTALLED'
