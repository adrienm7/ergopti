#!/bin/bash
# modules/llm/ensure-ollama-native-deps.sh
# Install the separately published, source-qualified native HTTP runtime only
# after explicit backend selection. Model-store and daemon ownership are kept
# by the existing callers; this script never starts a daemon or moves models.

set -eu
set -o pipefail
# The native PTY guardian runs a private snapshot of this file; its sources
# stay in the folder the guardian names. Any other path is its own folder.
if [ -n "${ERGOPTI_BOOTSTRAP_SNAPSHOT:-}" ] && [ "$0" = "$ERGOPTI_BOOTSTRAP_SNAPSHOT" ] \
	&& [ -n "${ERGOPTI_BOOTSTRAP_SCRIPT_DIR:-}" ]; then
	SCRIPT_DIR="$ERGOPTI_BOOTSTRAP_SCRIPT_DIR"
else
	SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
fi
source "$SCRIPT_DIR/network-retry.sh"
source "$SCRIPT_DIR/native_python_bootstrap.sh"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# Last stage entered; native_python_bootstrap.sh names its own stages here too.
BOOTSTRAP_STAGE="start"

bootstrap_stage() {
	BOOTSTRAP_STAGE="$1"
	printf '[OLLAMA-DEPS] stage: %s\n' "$1" >&2
}

# Names the stage a failed run stopped in and, for a status of 128 + N, the
# signal. A child killed by a signal ends this script through set -e with that
# status, so the line names it; no line at all means bash itself was killed
# (field run 2026-10-27 22:32: exit 137 with no output).
report_failed_stage() {
	local status=$? signal_name=""
	[ "$status" -ne 0 ] || return 0
	if [ "$status" -gt 128 ]; then signal_name="$(kill -l $((status - 128)) 2>/dev/null || true)"; fi
	printf '[OLLAMA-DEPS] ERROR: stage %s ended with exit %s%s.\n' "$BOOTSTRAP_STAGE" "$status" \
		"${signal_name:+ (signal SIG${signal_name#SIG})}" >&2
}
trap report_failed_stage EXIT

# Only the canonical pinned native bootstrap may supply this interpreter.
# An inherited executable path is not an admitted private runtime.
unset ERGOPTI_BOOTSTRAP_PYTHON
printf '%s\n' 'OLLAMA_INSTALLING'
if [ ! -x "${ERGOPTI_BOOTSTRAP_PYTHON:-}" ]; then
	bootstrap_stage python_bootstrap
	native_bootstrap_python "$HOME/Library/Application Support/Ergopti/native-bootstrap"
fi
bootstrap_stage runtime_install
# The original PTY guardian's 30-minute deadline remains earliest through the
# native Python bootstrap and this receiver; no subprocess resets that owner.
"$ERGOPTI_BOOTSTRAP_PYTHON" "$SCRIPT_DIR/managed_ollama_runtime.py" install \
	--timeout "$(( ${ERGOPTI_BOOTSTRAP_TIMEOUT_MS:?native bootstrap owner budget is missing} / 1000 ))" \
	--idle-timeout "$CURL_STALL_SEC" --connect-timeout "$CURL_CONNECT_TIMEOUT_SEC" \
	--minimum-bytes-per-second "$CURL_STALL_BYTES_PER_SEC"
printf '%s\n' 'OLLAMA_VERIFIED' 'OLLAMA_INSTALLED'
