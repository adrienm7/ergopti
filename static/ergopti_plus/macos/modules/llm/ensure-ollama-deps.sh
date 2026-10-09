#!/bin/bash
# modules/llm/ensure-ollama-deps.sh

# ============================================================================
# SCRIPT: Ensure Ollama Engine Available
# DESCRIPTION:
# Publishes the pinned, checksum-verified official Ollama macOS release into
# the folder the Lua resolver names. Detection is not done here: the caller
# passes the executable modules/llm/ollama_binary.lua resolved (fast path) or
# an empty string after the user accepted the download. Daemon launch remains
# owned by ApiOllama.
#
# Usage: ensure-ollama-deps.sh <resolved-executable-or-empty> <install-dir>
#                            [resolved-native-python]
# ============================================================================

set -eu
set -o pipefail 2>/dev/null || true

if [ "$0" = "/dev/fd/3" ] && [ -n "${ERGOPTI_BOOTSTRAP_SCRIPT_DIR:-}" ]; then
	SCRIPT_DIR="$ERGOPTI_BOOTSTRAP_SCRIPT_DIR"
else
	SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
fi
NETWORK_RETRY_LIB="$SCRIPT_DIR/network-retry.sh"
OLLAMA_RELEASE_FILE="$SCRIPT_DIR/ollama-release.sh"
# System tools stay reachable when the caller hands over a minimal PATH.
export PATH="$PATH:/usr/bin:/bin:/usr/sbin:/sbin"

OLLAMA_RESOLVED_BIN="${1:-${ERGOPTI_BOOTSTRAP_OLLAMA_RESOLVED_BIN:-}}"
OLLAMA_INSTALL_DIR="${2:-${ERGOPTI_BOOTSTRAP_OLLAMA_INSTALL_DIR:-}}"
export ERGOPTI_BOOTSTRAP_PYTHON="${3:-${ERGOPTI_BOOTSTRAP_PYTHON:-}}"
INSTALL_TEMP=""
INSTALL_STAGE=""
INSTALL_ROLLBACK=""
DOWNLOAD_PID=""

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
	if [ -n "$DOWNLOAD_PID" ]; then
		kill "$DOWNLOAD_PID" 2>/dev/null || true
		wait "$DOWNLOAD_PID" 2>/dev/null || true
	fi
	if [ -n "$INSTALL_ROLLBACK" ] && [ -e "$INSTALL_ROLLBACK" ]; then
		if [ ! -e "$OLLAMA_INSTALL_DIR" ]; then
			mv "$INSTALL_ROLLBACK" "$OLLAMA_INSTALL_DIR" 2>/dev/null || true
		else
			rm -rf "$INSTALL_ROLLBACK" 2>/dev/null || true
		fi
	fi
	if [ -n "$INSTALL_STAGE" ] && [ -e "$INSTALL_STAGE" ]; then
		rm -rf "$INSTALL_STAGE" 2>/dev/null || true
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
	exit 0
fi

case "$OLLAMA_INSTALL_DIR" in
	/*) ;;
	*)
		log_error "The Ollama install folder must be an absolute path."
		exit 1
		;;
esac

emit_marker "OLLAMA_INSTALLING"
log_info "Downloading the official Ollama $OLLAMA_RELEASE_VERSION release…"

for required_command in curl shasum tar mktemp; do
	if ! command -v "$required_command" >/dev/null 2>&1; then
		log_error "Required command '$required_command' is unavailable."
		exit 1
	fi
done

# The relay of the system network settings and the system trust store reach
# the download (network-retry.sh).
apply_system_network

INSTALL_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/ergopti-ollama.XXXXXX")"
archive_path="$INSTALL_TEMP/ollama-darwin.tgz"
archive_url="https://github.com/ollama/ollama/releases/download/v$OLLAMA_RELEASE_VERSION/ollama-darwin.tgz"

# Prints one progress marker from the bytes already written.
report_download_progress() {
	[ -f "$archive_path" ] || return 0
	local size
	size="$(wc -c < "$archive_path" | tr -d ' ')"
	[ -n "$size" ] || return 0
	local percent=$((size * 100 / OLLAMA_DARWIN_TGZ_BYTES))
	[ "$percent" -le 100 ] || percent=100
	emit_marker "OLLAMA_DOWNLOAD_PROGRESS $percent"
}

# Runs one stall-bounded curl while the foreground reports progress every
# second. Each attempt resumes the bytes earlier ones wrote, so a slow link
# keeps its progress; the SHA-256 gate below judges only the complete file.
download_archive() {
	local size=0
	if [ -f "$archive_path" ]; then
		size="$(wc -c < "$archive_path" | tr -d ' ')"
	fi
	if [ "$size" -gt "$OLLAMA_DARWIN_TGZ_BYTES" ]; then
		# Longer than the pinned asset: nothing in it can be trusted to resume.
		rm -f "$archive_path"
	elif [ "$size" -eq "$OLLAMA_DARWIN_TGZ_BYTES" ]; then
		return 0
	fi
	managed_bootstrap_download "$archive_url" "$archive_path" "$OLLAMA_DARWIN_TGZ_SHA256" "$OLLAMA_DARWIN_TGZ_BYTES" resumable --replace-owner &
	DOWNLOAD_PID=$!
	while kill -0 "$DOWNLOAD_PID" 2>/dev/null; do
		report_download_progress
		sleep 1
	done
	local rc=0
	wait "$DOWNLOAD_PID" || rc=$?
	DOWNLOAD_PID=""
	report_download_progress
	return "$rc"
}

if ! retry_network download_archive; then
	emit_marker "OLLAMA_ERROR_NETWORK"
	log_error "Ollama download failed after the bounded retry budget."
	exit 1
fi

if ! actual_sha="$(shasum -a 256 "$archive_path" | awk '{print $1}')"; then
	log_error "Ollama archive SHA-256 checksum could not be computed."
	exit 1
fi
if [ "$actual_sha" != "$OLLAMA_DARWIN_TGZ_SHA256" ]; then
	emit_marker "OLLAMA_ERROR_CHECKSUM"
	log_error "Ollama archive SHA-256 checksum mismatch; refusing extraction."
	exit 1
fi
emit_marker "OLLAMA_VERIFIED"

# The release archive is the Contents/Resources folder of the official
# Ollama.app: the CLI plus the runtime libraries it loads from its own folder.
# Stage the whole verified archive beside the target, then swap atomically.
parent_dir="$(dirname "$OLLAMA_INSTALL_DIR")"
mkdir -p "$parent_dir"
INSTALL_STAGE="$(mktemp -d "$parent_dir/.ollama.ergopti.XXXXXX")"
# Preserve pinned member modes even under the native private-process umask.
# Preserve literal AppleDouble archive members and their published modes.
# BSD tar's reader consumes these before copyfile extraction options apply;
# its reader option is scoped to this child and is ignored by GNU tar.
if ! COPYFILE_DISABLE=1 TAR_READER_OPTIONS='tar:!mac-ext' tar -xzpf "$archive_path" -C "$INSTALL_STAGE"; then
	log_error "The verified Ollama archive could not be extracted."
	exit 1
fi
if [ ! -f "$INSTALL_STAGE/ollama" ] || [ -L "$INSTALL_STAGE/ollama" ]; then
	log_error "The verified Ollama archive does not contain one regular binary."
	exit 1
fi
if ! chmod 0755 "$INSTALL_STAGE/ollama"; then
	log_error "The verified Ollama binary could not be marked executable."
	exit 1
fi
# Quarantine is lifted only from the files that passed the checksum above.
if command -v xattr >/dev/null 2>&1; then
	xattr -dr com.apple.quarantine "$INSTALL_STAGE" 2>/dev/null || true
fi

if [ -e "$OLLAMA_INSTALL_DIR" ]; then
	INSTALL_ROLLBACK="$OLLAMA_INSTALL_DIR.rollback.$$"
	if ! mv "$OLLAMA_INSTALL_DIR" "$INSTALL_ROLLBACK"; then
		log_error "The previous Ollama folder could not be set aside."
		exit 1
	fi
fi
if ! mv "$INSTALL_STAGE" "$OLLAMA_INSTALL_DIR"; then
	log_error "Ollama atomic publication failed."
	exit 1
fi
INSTALL_STAGE=""
if [ -n "$INSTALL_ROLLBACK" ]; then
	rm -rf "$INSTALL_ROLLBACK" 2>/dev/null || true
	INSTALL_ROLLBACK=""
fi
if [ ! -x "$OLLAMA_INSTALL_DIR/ollama" ]; then
	log_error "Ollama was published but is not executable."
	exit 1
fi
log_info "Official Ollama $OLLAMA_RELEASE_VERSION installed at $OLLAMA_INSTALL_DIR."

exit 0
