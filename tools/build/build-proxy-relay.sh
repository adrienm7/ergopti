#!/usr/bin/env bash
# tools/build/build-proxy-relay.sh
#
# Builds ergopti-proxy-relay, the local NTLM/Negotiate relay
# (docs/design/proxy-auth-relay.md), from the repository's Go sources.
#
# The relay is standard-library only, so the build is offline: GOTOOLCHAIN=local
# never downloads a toolchain and GOPROXY=off never fetches a module. cgo is on
# by default, because the macOS and Linux Negotiate sign-in opens GSS-API with
# dlopen; a build without cgo would answer sign_in_unavailable for every
# Kerberos proxy, so it is refused here. The CI cells pass the repository's Go
# pin (managed_ollama_runtime.json go_version) through actions/setup-go.
#
# Usage:
#   bash tools/build/build-proxy-relay.sh --output FILE [--goarch amd64|arm64]
#        [--source-directory DIR] [--cc COMPILER] [--go EXECUTABLE]
#
# --source-directory is the native_http module (a package staging that carries
# the sources elsewhere, the Flatpak SDK build). --goarch and --cc cross-build
# one macOS slice for lipo. --go names an absolute toolchain instead of the go on
# PATH: the macOS developer app's private copy (tools/dev/macos_dev_go.py). The
# output path must not exist: an occupied destination is refused, and the binary
# is moved in only after its smoke run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# The macOS build runs this under /bin/bash 3.2, whose cd has no -e: -P already
# resolves the physical directory, and an empty PWD is refused below.
IFS= read -r -d '' REPO_ROOT < <(CDPATH= cd -P -- "${SCRIPT_DIR}/../.." && printf '%s\0' "$PWD")
[[ -n "$REPO_ROOT" && -d "$REPO_ROOT" ]] || { echo "[ERR] Repository root unresolved." >&2; exit 1; }
SOURCE_DIR="${REPO_ROOT}/static/ergopti_plus/_shared/go/native_http"
OUTPUT=""
GOARCH_TARGET=""
COMPILER=""
GO_EXECUTABLE=""

while [[ $# -gt 0 ]]; do
	case "$1" in
		--output) [[ $# -ge 2 ]] || exit 2; OUTPUT="$2"; shift 2 ;;
		--goarch) [[ $# -ge 2 ]] || exit 2; GOARCH_TARGET="$2"; shift 2 ;;
		--source-directory) [[ $# -ge 2 ]] || exit 2; SOURCE_DIR="$2"; shift 2 ;;
		--cc) [[ $# -ge 2 ]] || exit 2; COMPILER="$2"; shift 2 ;;
		--go) [[ $# -ge 2 ]] || exit 2; GO_EXECUTABLE="$2"; shift 2 ;;
		*) echo "[ERR] Unknown proxy relay build option: $1" >&2; exit 2 ;;
	esac
done

[[ "$OUTPUT" == /* ]] || { echo "[ERR] --output must be an absolute path" >&2; exit 2; }
[[ ! -e "$OUTPUT" && ! -L "$OUTPUT" ]] || { echo "[ERR] Proxy relay destination occupied: $OUTPUT" >&2; exit 1; }
case "$GOARCH_TARGET" in
	""|amd64|arm64) ;;
	*) echo "[ERR] Unsupported proxy relay architecture: $GOARCH_TARGET" >&2; exit 2 ;;
esac
[[ -f "${SOURCE_DIR}/go.mod" && -f "${SOURCE_DIR}/cmd/ergopti-proxy-relay/main.go" ]] \
	|| { echo "[ERR] Proxy relay sources missing under $SOURCE_DIR" >&2; exit 1; }
if [[ -n "$GO_EXECUTABLE" ]]; then
	[[ "$GO_EXECUTABLE" == /* && -x "$GO_EXECUTABLE" ]] \
		|| { echo "[ERR] --go must be an absolute executable: $GO_EXECUTABLE" >&2; exit 2; }
	PATH="${GO_EXECUTABLE%/*}:$PATH"
fi
command -v go >/dev/null || { echo "[ERR] Go toolchain unavailable: the proxy relay cannot be built" >&2; exit 1; }

export GOTOOLCHAIN=local GOPROXY=off GOFLAGS=-mod=readonly GOWORK=off CGO_ENABLED=1
GOOS_HOST="$(go env GOOS)"
GOARCH_HOST="$(go env GOARCH)"
[[ "$GOOS_HOST" == linux || "$GOOS_HOST" == darwin ]] \
	|| { echo "[ERR] The proxy relay builder runs on Linux or macOS (Windows: tools/build/build_windows_proxy_relay.ps1)" >&2; exit 1; }
export GOARCH="${GOARCH_TARGET:-$GOARCH_HOST}"
[[ -z "$COMPILER" ]] || export CC="$COMPILER"
[[ "$(go env CGO_ENABLED)" == 1 ]] || { echo "[ERR] cgo is unavailable: Negotiate would never sign in" >&2; exit 1; }

OUTPUT_DIR="$(dirname "$OUTPUT")"
mkdir -p "$OUTPUT_DIR"
STAGE="$(mktemp "${OUTPUT_DIR}/.ergopti-proxy-relay.XXXXXX")"
trap 'rm -f -- "$STAGE"' EXIT

echo "--- Building ergopti-proxy-relay ($(go env GOVERSION), ${GOOS_HOST}/${GOARCH}, cgo) ---"
(cd "$SOURCE_DIR" && go build -trimpath -buildvcs=false -ldflags='-s -w' -o "$STAGE" ./cmd/ergopti-proxy-relay)

# A slice for the host architecture is run once: no arguments is the named
# invalid_arguments refusal with exit 2, which proves the binary starts.
if [[ "$GOARCH" == "$GOARCH_HOST" ]]; then
	set +e
	smoke="$("$STAGE" 2>&1)"
	status=$?
	set -e
	if [[ "$status" != 2 || "$smoke" != *"relay_refused invalid_arguments"* ]]; then
		echo "[ERR] The built proxy relay did not answer its smoke run (exit $status)" >&2
		exit 1
	fi
fi
chmod 755 "$STAGE"
mv -- "$STAGE" "$OUTPUT"
trap - EXIT
echo "  Proxy relay: $OUTPUT"
