#!/bin/bash
# modules/llm/native_python_bootstrap.sh
# Native-only bootstrap ports shared by dependency installers. The caller's
# signed native PTY guardian owns the original deadline and every subprocess.

# Names the step the bootstrap entered, on stderr and in BOOTSTRAP_STAGE, so a
# caller's failure report says which child stopped (a signal leaves no text).
native_bootstrap_stage() {
	BOOTSTRAP_STAGE="$1"
	printf '[NATIVE-BOOTSTRAP] stage: %s\n' "$1" >&2
}

# The one temporary workspace this bootstrap owns at a time, and the signal
# handlers it displaced. A guardian SIGTERM ends bash between two children, so
# without its own handler the uv wheel and Python archive bytes stayed behind.
NATIVE_BOOTSTRAP_WORK=""
NATIVE_BOOTSTRAP_SAVED_TRAPS=""

# Removes the owned workspace only while it is still the directory this shell
# created: a symlink or a path now owned by someone else is left untouched.
native_bootstrap_release_work() {
	local work="$NATIVE_BOOTSTRAP_WORK"
	NATIVE_BOOTSTRAP_WORK=""
	[ -n "$work" ] || return 0
	if [ -L "$work" ] || [ ! -d "$work" ] || [ ! -O "$work" ]; then
		printf '[NATIVE-BOOTSTRAP] WARNING: workspace %s is no longer owned; left in place.\n' "$work" >&2
		return 0
	fi
	rm -rf "$work"
}

# Puts back the INT, TERM and HUP handlers the caller had before the bootstrap.
native_bootstrap_restore_interrupts() {
	trap - INT TERM HUP
	[ -z "$NATIVE_BOOTSTRAP_SAVED_TRAPS" ] || eval "$NATIVE_BOOTSTRAP_SAVED_TRAPS"
	NATIVE_BOOTSTRAP_SAVED_TRAPS=""
}

# Releases the workspace, restores the caller's handlers and re-raises the same
# signal, so the caller still sees the original 128 + N status and its own EXIT
# report names the stage.
native_bootstrap_interrupted() {
	printf '[NATIVE-BOOTSTRAP] stage %s interrupted by SIG%s; releasing its workspace.\n' "${BOOTSTRAP_STAGE:-unknown}" "$1" >&2
	native_bootstrap_release_work
	native_bootstrap_restore_interrupts
	kill -s "$1" "$BASHPID"
}

native_bootstrap_python() {
	local root="$1" work rc uv_path uv_url uv_sha256 native_arch
	case "$root" in
		"$HOME/Library/Application Support/Ergopti/native-bootstrap") ;;
		*) return 78 ;;
	esac
	native_arch="${ERGOPTI_NATIVE_ARCH:-$(/usr/bin/uname -m)}"
	[ ! -L "$root" ] || return 78
	[ -f "$SCRIPT_DIR/managed-python-release.sh" ] || return 78
	# Generated exclusively from the canonical reviewed upstream metadata.
	source "$SCRIPT_DIR/uv-release.sh"
	source "$SCRIPT_DIR/managed-python-release.sh" || return 78
	case "$native_arch" in
		arm64) uv_url="$UV_WHEEL_ARM64_URL"; uv_sha256="$UV_WHEEL_ARM64_SHA256" ;;
		x86_64) uv_url="$UV_WHEEL_X86_64_URL"; uv_sha256="$UV_WHEEL_X86_64_SHA256" ;;
		*) return 78 ;;
	esac
	[ "$MANAGED_PYTHON_UV_RELEASE" = "$UV_RELEASE_VERSION" ] || return 78
	mkdir -p "$root" "$root/bin" "$root/cache" "$root/python" "$root/python-bin" || return 1
	chmod 700 "$root" || return 1
	for directory in "$root/bin" "$root/cache" "$root/python" "$root/python-bin"; do
		[ ! -L "$directory" ] && [ -d "$directory" ] || return 78
	done
	export UV_INSTALL_DIR="$root/bin" UV_CACHE_DIR="$root/cache"
	export UV_PYTHON_INSTALL_DIR="$root/python" UV_PYTHON_BIN_DIR="$root/python-bin"
	export UV_NO_MODIFY_PATH=1 UV_PYTHON_DOWNLOADS=manual
	uv_path="$root/bin/uv"
	[ -z "$NATIVE_BOOTSTRAP_WORK" ] || return 78
	work="$(mktemp -d "${TMPDIR:-/tmp}/ergopti-native-runtime-python.XXXXXX")" || return 1
	NATIVE_BOOTSTRAP_WORK="$work"
	NATIVE_BOOTSTRAP_SAVED_TRAPS="$(trap -p INT TERM HUP)"
	trap 'native_bootstrap_interrupted INT' INT
	trap 'native_bootstrap_interrupted TERM' TERM
	trap 'native_bootstrap_interrupted HUP' HUP
	rc=0
	native_bootstrap_python_in_work "$root" "$work" "$uv_path" "$uv_url" "$uv_sha256" || rc=$?
	native_bootstrap_release_work
	native_bootstrap_restore_interrupts
	return "$rc"
}

# Every step that writes into the owned workspace; each refusal returns its own
# status and the caller above releases the workspace exactly once.
native_bootstrap_python_in_work() {
	local root="$1" work="$2" uv_path="$3" uv_url="$4" uv_sha256="$5"
	local rc interpreter actual_hash cached_uv_hash extracted_uv_hash
	if [ -f "$root/uv.whl" ] && [ ! -L "$root/uv.whl" ]; then
		actual_hash="$(shasum -a 256 "$root/uv.whl" | awk '{print $1}')" || actual_hash=""
	else
		actual_hash=""
	fi
	if [ "$actual_hash" != "$uv_sha256" ]; then
		native_bootstrap_stage uv_download
		if ! managed_bootstrap_download "$uv_url" "$work/uv.whl" "$uv_sha256" "" resilient; then
			return 1
		fi
		[ ! -L "$root/uv.whl" ] || return 78
		mv -f "$work/uv.whl" "$root/uv.whl" || return 1
	fi
	# Retained verified wheel bytes pin the executable even on a warm runtime.
	native_bootstrap_stage uv_extract
	if ! /usr/bin/unzip -p "$root/uv.whl" "uv-$UV_RELEASE_VERSION.data/scripts/uv" > "$work/uv"; then
		return 1
	fi
	chmod 755 "$work/uv" || return 1
	extracted_uv_hash="$(shasum -a 256 "$work/uv" | awk '{print $1}')" || return 1
	if [ -f "$uv_path" ] && [ ! -L "$uv_path" ]; then
		cached_uv_hash="$(shasum -a 256 "$uv_path" | awk '{print $1}')" || cached_uv_hash=""
	else cached_uv_hash=""; fi
	if [ "$cached_uv_hash" != "$extracted_uv_hash" ]; then
		[ ! -L "$uv_path" ] || return 78
		mv -f "$work/uv" "$uv_path" || return 1
	fi
	native_bootstrap_stage python_download
	if ! managed_bootstrap_download "$MANAGED_PYTHON_URL" "$work/$MANAGED_PYTHON_CACHE_BASENAME" "$MANAGED_PYTHON_SHA256" "" resilient; then
		return 1
	fi
	native_bootstrap_stage python_install
	rc=0
	UV_PYTHON_CACHE_DIR="$work" "$uv_path" python install "$MANAGED_PYTHON_REQUEST" \
		--offline --no-config --python-downloads-json-url "$SCRIPT_DIR/$MANAGED_PYTHON_DOWNLOADS_BASENAME" >&2 || rc=$?
	[ "$rc" -eq 0 ] || return "$rc"
	native_bootstrap_stage python_find
	interpreter="$("$uv_path" python find "$MANAGED_PYTHON_REQUEST" --offline)" || return 1
	case "$interpreter" in "$root/python/"*) ;; *) return 78 ;; esac
	[ -x "$interpreter" ] || return 78
	export ERGOPTI_BOOTSTRAP_PYTHON="$interpreter"
}
