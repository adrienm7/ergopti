#!/bin/bash
# modules/llm/native_python_bootstrap.sh
# Native-only bootstrap ports shared by dependency installers. The caller's
# signed native PTY guardian owns the original deadline and every subprocess.

native_bootstrap_python() {
	local root="$1" work rc uv_path interpreter actual_hash cached_uv_hash extracted_uv_hash uv_url uv_sha256 native_arch
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
	work="$(mktemp -d "${TMPDIR:-/tmp}/ergopti-native-runtime-python.XXXXXX")" || return 1
	if [ -f "$root/uv.whl" ] && [ ! -L "$root/uv.whl" ]; then
		actual_hash="$(shasum -a 256 "$root/uv.whl" | awk '{print $1}')" || actual_hash=""
	else
		actual_hash=""
	fi
	if [ "$actual_hash" != "$uv_sha256" ]; then
		if ! managed_bootstrap_download "$uv_url" "$work/uv.whl" "$uv_sha256" "" resilient; then
			rm -rf "$work"; return 1
		fi
		[ ! -L "$root/uv.whl" ] || { rm -rf "$work"; return 78; }
		mv -f "$work/uv.whl" "$root/uv.whl" || { rm -rf "$work"; return 1; }
	fi
	# Retained verified wheel bytes pin the executable even on a warm runtime.
	if ! /usr/bin/unzip -p "$root/uv.whl" "uv-$UV_RELEASE_VERSION.data/scripts/uv" > "$work/uv"; then
		rm -rf "$work"; return 1
	fi
	chmod 755 "$work/uv" || { rm -rf "$work"; return 1; }
	extracted_uv_hash="$(shasum -a 256 "$work/uv" | awk '{print $1}')" || { rm -rf "$work"; return 1; }
	if [ -f "$uv_path" ] && [ ! -L "$uv_path" ]; then
		cached_uv_hash="$(shasum -a 256 "$uv_path" | awk '{print $1}')" || cached_uv_hash=""
	else cached_uv_hash=""; fi
	if [ "$cached_uv_hash" != "$extracted_uv_hash" ]; then
		[ ! -L "$uv_path" ] || { rm -rf "$work"; return 78; }
		mv -f "$work/uv" "$uv_path" || { rm -rf "$work"; return 1; }
	fi
	if ! managed_bootstrap_download "$MANAGED_PYTHON_URL" "$work/$MANAGED_PYTHON_CACHE_BASENAME" "$MANAGED_PYTHON_SHA256" "" resilient; then
		rm -rf "$work"; return 1
	fi
	rc=0
	UV_PYTHON_CACHE_DIR="$work" "$uv_path" python install "$MANAGED_PYTHON_REQUEST" \
		--offline --no-config --python-downloads-json-url "$SCRIPT_DIR/$MANAGED_PYTHON_DOWNLOADS_BASENAME" >&2 || rc=$?
	rm -rf "$work"
	[ "$rc" -eq 0 ] || return "$rc"
	interpreter="$("$uv_path" python find "$MANAGED_PYTHON_REQUEST" --offline)" || return 1
	case "$interpreter" in "$root/python/"*) ;; *) return 78 ;; esac
	[ -x "$interpreter" ] || return 78
	export ERGOPTI_BOOTSTRAP_PYTHON="$interpreter"
}
