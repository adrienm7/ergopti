#!/usr/bin/env bash
# tools/build/build-linux-native-output.sh
# Build the private retained-archive backend from the repository C/header.
# SOURCE ONLY until native qualification and packaging-owner integration.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"
SOURCE_DIR="${REPO_ROOT}/static/ergopti_plus/linux/native/archive_output"
OUTPUT_DIR="${REPO_ROOT}/build/linux/linux/bin"

while [[ $# -gt 0 ]]; do
	case "$1" in
		--source-directory) [[ $# -ge 2 ]] || exit 2; SOURCE_DIR="$2"; shift 2 ;;
		--output-directory) [[ $# -ge 2 ]] || exit 2; OUTPUT_DIR="$2"; shift 2 ;;
		*) echo "Unknown native output build option" >&2; exit 2 ;;
	esac
done

[[ "$(uname -s)" == Linux ]] || { echo "Native archive output requires Linux" >&2; exit 1; }
[[ "$SOURCE_DIR" == /* && "$OUTPUT_DIR" == /* ]] || { echo "Absolute owned build directories required" >&2; exit 1; }
SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd -P)"
for source_name in archive_publication.c archive_publication.h; do
	[[ -f "${SOURCE_DIR}/${source_name}" && ! -L "${SOURCE_DIR}/${source_name}" ]] || {
		echo "Ordinary native backend source required" >&2; exit 1;
	}
done

TASK_COMPILER="${CC:-cc}"
command -v "$TASK_COMPILER" >/dev/null || { echo "Native C compiler unavailable" >&2; exit 1; }
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd -P)"
DESTINATION="${OUTPUT_DIR}/libergopti_archive_publication.so"
[[ ! -e "$DESTINATION" && ! -L "$DESTINATION" ]] || { echo "Native backend destination occupied" >&2; exit 1; }
STAGE_DIR="$(mktemp -d "${OUTPUT_DIR}/.ergopti-native-output.XXXXXX")"
COMPILE_ACTIVE=0
cleanup_stage() {
	if [[ "$COMPILE_ACTIVE" == 1 ]]; then
		echo "Native build stage retained: compiler retirement unobserved" >&2
		return
	fi
	rm -f -- "${STAGE_DIR}/libergopti_archive_publication.so"
	rmdir -- "$STAGE_DIR" || echo "Native build stage cleanup incomplete" >&2
}
trap cleanup_stage EXIT

COMPILE_ACTIVE=1
if "$TASK_COMPILER" -std=c11 -O2 -fPIC -shared -Wall -Wextra -Werror \
	-Wl,-z,defs -Wl,-z,relro,-z,now -Wl,-soname,libergopti_archive_publication.so \
	-I "$SOURCE_DIR" "$SOURCE_DIR/archive_publication.c" \
	-o "${STAGE_DIR}/libergopti_archive_publication.so"; then
	COMPILE_ACTIVE=0
else
	TASK_COMPILE_STATUS=$?
	# Failure/cancellation does not prove every compiler descendant retired.
	# Retain this owned stage for the external build-process owner to settle.
	exit "$TASK_COMPILE_STATUS"
fi
chmod 755 "${STAGE_DIR}/libergopti_archive_publication.so"
# Atomic no-replace publication, including a concurrent destination arrival.
ln -T -- "${STAGE_DIR}/libergopti_archive_publication.so" "$DESTINATION"
echo "Native retained archive backend generated"
