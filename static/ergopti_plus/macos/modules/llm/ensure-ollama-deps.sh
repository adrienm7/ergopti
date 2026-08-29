#!/bin/bash
# modules/llm/ensure-ollama-deps.sh

# ============================================================================
# SCRIPT: Ensure Ollama Engine Available
# DESCRIPTION:
# Publishes one pinned, checksum-verified universal Ollama binary in the
# user-local bin directory. Daemon launch remains owned by ApiOllama.
# ============================================================================

set -eu
set -o pipefail 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NETWORK_RETRY_LIB="$SCRIPT_DIR/network-retry.sh"
OLLAMA_RELEASE_FILE="$SCRIPT_DIR/ollama-release.sh"
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

OLLAMA_RESOLVED_BIN="${1:-}"
INSTALL_TEMP=""
INSTALL_STAGE=""

emit_marker() {
	printf "%s\n" "$1"
	sync 2>/dev/null || true
}

log_info() {
	printf "[OLLAMA-DEPS] %s\n" "$1" >&2
}

log_error() {
	printf "[OLLAMA-DEPS] ERROR: %s\n" "$1" >&2
}

cleanup_install() {
	if [ -n "$INSTALL_STAGE" ] && [ -e "$INSTALL_STAGE" ]; then
		rm -f "$INSTALL_STAGE" 2>/dev/null || true
	fi
	if [ -n "$INSTALL_TEMP" ] && [ -d "$INSTALL_TEMP" ]; then
		rm -rf "$INSTALL_TEMP" 2>/dev/null || true
	fi
}

trap cleanup_install EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

for dependency_file in "$NETWORK_RETRY_LIB" "$OLLAMA_RELEASE_FILE"; do
	if [ ! -f "$dependency_file" ]; then
		log_error "Required bootstrap source is missing at $dependency_file."
		exit 1
	fi
done
. "$NETWORK_RETRY_LIB"
. "$OLLAMA_RELEASE_FILE"

if [ -n "$OLLAMA_RESOLVED_BIN" ]; then
	if [ ! -x "$OLLAMA_RESOLVED_BIN" ]; then
		log_error "The driver-resolved Ollama executable is no longer executable."
		exit 1
	fi
elif ! command -v ollama >/dev/null 2>&1; then
	emit_marker "OLLAMA_INSTALLING"
	log_info "Downloading pinned Ollama $OLLAMA_RELEASE_VERSION…"

	for required_command in curl shasum tar mktemp; do
		if ! command -v "$required_command" >/dev/null 2>&1; then
			log_error "Required command '$required_command' is unavailable."
			exit 1
		fi
	done

	INSTALL_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/ergopti-ollama.XXXXXX")"
	archive_path="$INSTALL_TEMP/ollama-darwin.tgz"
	extract_path="$INSTALL_TEMP/extracted"
	archive_url="https://github.com/ollama/ollama/releases/download/v$OLLAMA_RELEASE_VERSION/ollama-darwin.tgz"
	mkdir -p "$extract_path"

	download_archive() {
		curl_resilient -o "$archive_path" "$archive_url"
	}
	if ! retry_network download_archive; then
		log_error "Ollama download failed after the bounded retry budget."
		exit 1
	fi

	if ! actual_sha="$(shasum -a 256 "$archive_path" | awk '{print $1}')"; then
		log_error "Ollama archive SHA-256 checksum could not be computed."
		exit 1
	fi
	if [ "$actual_sha" != "$OLLAMA_DARWIN_TGZ_SHA256" ]; then
		log_error "Ollama archive SHA-256 checksum mismatch; refusing extraction."
		exit 1
	fi

	if ! tar -xzf "$archive_path" -C "$extract_path"; then
		log_error "The verified Ollama archive could not be extracted."
		exit 1
	fi
	if [ ! -f "$extract_path/ollama" ] || [ -L "$extract_path/ollama" ]; then
		log_error "The verified Ollama archive does not contain one regular binary."
		exit 1
	fi

	target_dir="$HOME/.local/bin"
	target_path="$target_dir/ollama"
	mkdir -p "$target_dir"
	INSTALL_STAGE="$(mktemp "$target_dir/.ollama.ergopti.XXXXXX")"
	if ! cp "$extract_path/ollama" "$INSTALL_STAGE" || ! chmod 0755 "$INSTALL_STAGE"; then
		log_error "Ollama staging publication failed."
		exit 1
	fi
	if ! mv -f "$INSTALL_STAGE" "$target_path"; then
		log_error "Ollama atomic publication failed."
		exit 1
	fi
	INSTALL_STAGE=""
	if [ ! -x "$target_path" ]; then
		log_error "Ollama was published but is not executable."
		exit 1
	fi
	log_info "Pinned Ollama $OLLAMA_RELEASE_VERSION installed at $target_path."
fi

exit 0
