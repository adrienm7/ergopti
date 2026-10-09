#!/bin/bash
# modules/llm/ensure-mlx-deps.sh

# ==============================================================================
# SCRIPT: Ensure Hammerspoon Python Dependencies
# DESCRIPTION:
# Provisions the MLX virtualenv (static/ergopti_plus/macos/.venv in a
# checkout, Application Support under the launcher) from the pinned
# pyproject.toml. mlx_deps_checker.lua runs it only when the user selects the
# MLX backend, never at startup or after an update, and then no manual setup
# is needed — no Homebrew, no pre-installed Python, no pre-installed uv.
#
# FEATURES & RATIONALE:
# 1. Self-bootstrapping uv: when no native 'uv' is in PATH or in the usual
#    install locations (~/.local/bin, ~/.cargo/bin), the script installs the
#    pinned uv wheel from PyPI (uv-release.sh), checked against its SHA-256.
#    The user does not need to install anything by hand.
# 2. Python without GitHub when possible: a native Python 3.11 to 3.14 the
#    Lua caller found (ERGOPTI_NATIVE_PYTHONS) builds the venv, and uv then
#    downloads no interpreter; only without one does uv fetch its managed
#    Apple silicon build, which comes from GitHub.
# 3. Single source of truth: all package versions live in pyproject.toml — this
#    script never pins a version inline.
# 4. Project-local venv only: no system Python, no $HOME/.mlx_py_env, no
#    --user installs. Eliminates a class of "it works on my machine" bugs
#    where a stray globally-installed package shadows the pinned one.
# 5. Hash-gated sync: hashes pyproject.toml plus uv.lock and compares the pair
#    against a marker written after the previous successful sync. On a match it
#    exits silently; on mismatch it runs 'uv sync' and prints
#    "VENV_SYNC_RAN" so the Hammerspoon caller can surface a "patientez"
#    notification only when real work happens.
# 6. Streaming progress markers: every long-running step (uv install, Python
#    install, venv creation, deps sync) prints an identifiable marker on
#    stdout so the Lua side can show the user a precise notification while
#    the operation is in progress. Markers are emitted via 'printf' followed
#    by an explicit redirect-flush trick so they reach Hammerspoon's
#    streaming callback in real time, not buffered until process exit.
# 7. Verbose pass-through: the raw stdout/stderr of 'uv' (which prints
#    "Resolved 47 packages…", "Downloading torch (220 MB)…" in real time)
#    is forwarded to stderr line by line. The Lua side logs each stderr
#    line via Logger.info so 'tail -f /tmp/ergopti.log' shows live progress.
# 8. Fail fast: any unrecoverable failure (no network, install blocked by a
#    firewall) aborts with a non-zero exit code after printing the line that
#    names the cause; mlx_bootstrap_diagnosis.lua turns it into the user's
#    message.
# 9. Bash 3.2 compatible: macOS still ships bash 3.2 as /bin/bash — no
#    associative arrays, no '${var,,}', nothing that requires bash 4+.
# 10. Import-proven publication: a candidate venv is published, and exit 0
#    reported, only after its interpreter imported the MLX packages; the
#    fast path proves the same before trusting an installed venv.
# 11. Owned locations: uv's own interpreter (Apple Silicon, never a system or
#    Homebrew Python), and under the launcher uv, its interpreters and its
#    cache in Ergopti's Application Support folder, so a ~/.local or ~/.cache
#    that belongs to another account cannot refuse the installation.
# 12. Repair: ERGOPTI_MLX_REPAIR=1 removes Ergopti's own venv (only that
#    folder, never a link or a folder without a Python environment) and
#    rebuilds it from freshly downloaded packages.
# 13. Never Rosetta: a uv or a venv interpreter whose Mach-O lacks a slice for
#    the processor the app runs on (ERGOPTI_NATIVE_ARCH, from the Lua caller)
#    is never started; macOS would run it under Rosetta and announce an Intel
#    app. Such a uv is skipped and such a venv rebuilt (hardening-h-no-rosetta).
# 14. Managed networks: every child gets the relay of the system network
#    settings and trusts the system store, where a company installs its
#    inspection certificate (apply_system_network in network-retry.sh). No
#    CA file overrides it: the Mozilla bundle this script once forced made uv
#    and curl refuse every download behind a TLS-inspecting company relay.
# ==============================================================================

set -eu

# Note: 'set -o pipefail' is bash-specific and supported on bash 3.2.
# We intentionally avoid 'set -e' on the network install steps and check
# return codes by hand, so failures emit a clear French message instead of
# aborting silently.
set -o pipefail 2>/dev/null || true

export HF_HUB_DISABLE_XET=1

# The native no-Python PTY retains the admitted source as descriptor 3. Its
# trusted source directory is derived by that native owner before executing
# the descriptor; ordinary pathname invocations never use the override.
case "$0" in
	/dev/fd/3)
		case "${ERGOPTI_BOOTSTRAP_SCRIPT_DIR:-}" in /*) ;; *) exit 78 ;; esac
		SCRIPT_DIR="$(cd "$ERGOPTI_BOOTSTRAP_SCRIPT_DIR" && pwd)"
		;;
	*) SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)" ;;
esac
NETWORK_RETRY_LIB="$SCRIPT_DIR/network-retry.sh"
UV_RELEASE_FILE="$SCRIPT_DIR/uv-release.sh"
for dependency_file in "$NETWORK_RETRY_LIB" "$UV_RELEASE_FILE"; do
	if [ ! -f "$dependency_file" ]; then
		printf "[MLX-DEPS] ERROR: Required bootstrap source is missing at %s.\n" "$dependency_file" >&2
		exit 1
	fi
done
. "$NETWORK_RETRY_LIB"
. "$UV_RELEASE_FILE"

# Network robustness — these env vars are honoured by uv (Rust HTTP client)
# and indirectly by curl/python downloads. Set generously so a flaky tether
# or a throttled mobile hotspot doesn't abort the whole install on a single
# stall: a 120 s read timeout is long enough for slow chunks of a 200 MB
# wheel to dribble through, and 6 retries cover transient DNS or TLS
# handshake failures without giving up after one bad packet.
export UV_HTTP_TIMEOUT=120
export UV_CONCURRENT_DOWNLOADS=2

HS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VENV_DIR="$HS_ROOT/.venv"
PYPROJECT="$HS_ROOT/pyproject.toml"
UV_LOCK="$HS_ROOT/uv.lock"

# Pinned interpreter version. Kept in sync with pyproject.toml's
# requires-python clause — bumping one without the other breaks the
# fast-path hash check.
PYTHON_VERSION="3.11"
# The exact interpreter uv provides: MLX publishes Apple Silicon wheels only,
# so an x86_64 Python (an Intel Homebrew under /usr/local, or an x86_64 uv
# under Rosetta) could never install it. System and Homebrew interpreters are
# never used: they can be externally managed or disappear on an upgrade.
PYTHON_REQUEST="cpython-${PYTHON_VERSION}-macos-aarch64-none"

# The statement both this script and the Lua import probe of
# ui/menu/menu_llm/models_manager_mlx.lua run: a venv that cannot import these
# is never published nor reused.
MLX_IMPORT_PROBE="import mlx_lm; import huggingface_hub; import jinja2; import safetensors; import truststore"

# Prepend the canonical uv install locations so a freshly installed uv is
# discoverable without re-sourcing the shell profile. Order matters: prefer
# Homebrew when present, then the Astral installer's default targets.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

# Disable I/O buffering on Python child processes — uv spawns python which
# would otherwise buffer its progress messages until exit on a non-tty.
export PYTHONUNBUFFERED=1

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

# Emits a marker line on stdout. The Lua caller streams stdout line by line
# and surfaces a French "patientez" notification when it sees one of these.
# Use 'printf' + a no-op redirect to coax bash into flushing the line in real
# time; without it, stdout is fully buffered when not attached to a tty and
# the markers only reach the Lua side on process exit, defeating the whole
# purpose of progress notifications.
emit_marker() {
	printf "%s\n" "$1"
	# Force the kernel to drain any pending stdio buffers immediately. The
	# combination "printf + sync" is portable across macOS bash 3.2 and gives
	# us deterministic real-time delivery to hs.task's streaming callback.
	sync 2>/dev/null || true
}

# Logs a human-readable line on stderr so it never collides with the marker
# protocol on stdout. The Lua side captures stderr too and forwards each
# line to Logger.info, so 'tail -f /tmp/ergopti.log' shows live progress.
log_info() {
	printf "[MLX-DEPS] %s\n" "$1" >&2
}

log_error() {
	printf "[MLX-DEPS] ❌ %s\n" "$1" >&2
}

# Imports the MLX packages with an interpreter. On failure the interpreter's
# own error is printed, since it names the cause (a missing module, a library
# macOS refused to load, a permission).
probe_imports() {
	local probe_output
	if probe_output="$("$1" -c "$MLX_IMPORT_PROBE" 2>&1)"; then
		return 0
	fi
	printf "%s\n" "$probe_output" >&2
	log_error "MLX packages do not import with $1: $(printf "%s\n" "$probe_output" | tail -n 1)"
	return 1
}

# Drops the quarantine attribute from files this script just installed, so
# macOS never refuses to load their libraries. Absent outside macOS.
clear_quarantine() {
	if [ -x /usr/bin/xattr ] && [ -e "$1" ]; then
		/usr/bin/xattr -dr com.apple.quarantine "$1" 2>/dev/null || true
	fi
}

# The system relay and trust store reach every child from here on.
apply_system_network

# The processor the app runs on, as the Lua caller names it
# (adapters/python_interpreter.lua); uname answers when run by hand.
NATIVE_ARCH="${ERGOPTI_NATIVE_ARCH:-$(/usr/bin/uname -m)}"

# Succeeds only for a Mach-O executable without a slice for NATIVE_ARCH, one
# macOS would start under Rosetta. A script or an unreadable file is left to
# the command that runs it.
lacks_native_slice() {
	local description
	description="$(/usr/bin/file -bL "$1" 2>/dev/null)" || return 1
	case "$description" in
		*Mach-O*) ;;
		*) return 1 ;;
	esac
	case "$description" in
		*"$NATIVE_ARCH"*) return 1 ;;
	esac
	return 0
}

# Locates uv in PATH or in the well-known install directories. Prints the
# absolute path on success, returns non-zero on failure. A uv built for
# another processor (an Intel Homebrew's /usr/local/bin/uv on Apple silicon)
# is skipped: starting it would run it under Rosetta.
locate_uv() {
	local candidate
	for candidate in "$(command -v uv 2>/dev/null || true)" "${UV_INSTALL_DIR:+$UV_INSTALL_DIR/uv}" \
		"$HOME/.local/bin/uv" "$HOME/.cargo/bin/uv"; do
		if [ -z "$candidate" ] || [ ! -x "$candidate" ]; then
			continue
		fi
		if lacks_native_slice "$candidate"; then
			log_info "Skipping $candidate: it is built for another processor than $NATIVE_ARCH."
			continue
		fi
		echo "$candidate"
		return 0
	done
	return 1
}

# When the Swift launcher starts Ergopti.app it exports ERGOPTI_CONFIG_DIR.
# The .app bundle is read-only, so the venv cannot be created inside it.
# We redirect VENV_DIR to ~/Library/Application Support/Ergopti/mlx-venv
# and set UV_SYNC_FROZEN_FLAG to "--frozen" so uv never tries to rewrite
# uv.lock (the lock file is already committed inside the read-only bundle
# and must not be mutated).
if [ -n "${ERGOPTI_CONFIG_DIR:-}" ]; then
	APP_SUPPORT_DIR="$HOME/Library/Application Support/Ergopti"
	mkdir -p "$APP_SUPPORT_DIR"
	VENV_DIR="$APP_SUPPORT_DIR/mlx-venv"
	UV_SYNC_FROZEN_FLAG="--frozen"
	log_info "Mode bundle détecté — venv redirigé vers $VENV_DIR"
	# uv, its interpreters and its cache live in Ergopti's folder: a ~/.local
	# or ~/.cache owned by another account (a former "sudo pip") refused them.
	UV_OWNED_DIR="$APP_SUPPORT_DIR/mlx-uv"
	export UV_INSTALL_DIR="$UV_OWNED_DIR/bin"
	export UV_CACHE_DIR="$UV_OWNED_DIR/cache"
	export UV_PYTHON_INSTALL_DIR="$UV_OWNED_DIR/python"
	export UV_PYTHON_BIN_DIR="$UV_OWNED_DIR/python-bin"
else
	UV_SYNC_FROZEN_FLAG=""
fi

# The Astral installer never edits the user's shell profiles: this script
# finds uv by path, and a profile it cannot write aborted the installation.
export UV_NO_MODIFY_PATH=1

REPAIR_MODE=0
if [ "${ERGOPTI_MLX_REPAIR:-}" = "1" ]; then
	REPAIR_MODE=1
fi

# Derived from VENV_DIR after the potential bundle-mode override so the
# marker file lands next to the actual environment.
SYNC_HASH_FILE="$VENV_DIR/.last_sync_hash"




# =====================================
# =====================================
# ======= 1/ Sanity Validation ========
# =====================================
# =====================================

if [ ! -f "$UV_LOCK" ]; then
	log_error "uv.lock is missing at $UV_LOCK — the project is incomplete."
	exit 1
fi

if [ ! -f "$PYPROJECT" ]; then
	log_error "pyproject.toml introuvable à $PYPROJECT — projet corrompu."
	exit 1
fi

# ====================================
# ====================================
# ======= 2/ Bootstrap of uv =========
# ====================================
# ====================================

# Installs the pinned uv wheel's executable into the install folder: PyPI's
# own file, checked against its SHA-256, and no installer script.
install_pinned_uv() {
	local target_dir="${UV_INSTALL_DIR:-$HOME/.local/bin}"
	local work wheel digest
	work="$(mktemp -d "${TMPDIR:-/tmp}/ergopti-uv.XXXXXX")" || return 1
	wheel="$work/uv.whl"
	if ! managed_bootstrap_download "$UV_WHEEL_ARM64_URL" "$wheel" "$UV_WHEEL_ARM64_SHA256" "" resilient >&2; then
		rm -rf "$work"
		return 1
	fi
	digest="$(shasum -a 256 "$wheel" | awk '{print $1}')"
	if [ "$digest" != "$UV_WHEEL_ARM64_SHA256" ]; then
		log_error "The uv $UV_RELEASE_VERSION wheel does not match its pinned SHA-256 (got $digest)."
		rm -rf "$work"
		return 1
	fi
	if ! /usr/bin/unzip -q -o "$wheel" "uv-$UV_RELEASE_VERSION.data/scripts/uv" -d "$work/unpacked" >&2; then
		log_error "The uv $UV_RELEASE_VERSION wheel could not be unpacked."
		rm -rf "$work"
		return 1
	fi
	mkdir -p "$target_dir" \
		&& mv -f "$work/unpacked/uv-$UV_RELEASE_VERSION.data/scripts/uv" "$target_dir/uv" \
		&& chmod 755 "$target_dir/uv"
	local rc=$?
	rm -rf "$work"
	return "$rc"
}

UV_BIN=""
if UV_BIN="$(locate_uv)"; then
	:
else
	# uv is not present anywhere we know about: install the pinned wheel. The
	# marker comes BEFORE the download so the Lua side can tell the user
	# "Installation de uv…" at once.
	emit_marker "UV_INSTALLING"
	if [ "$NATIVE_ARCH" != "arm64" ]; then
		log_error "MLX needs Apple silicon; this Mac runs $NATIVE_ARCH."
		exit 1
	fi
	log_info "Installation de uv $UV_RELEASE_VERSION depuis PyPI…"
	if ! retry_network install_pinned_uv; then
		log_error "Téléchargement / installation de uv impossible. Vérifiez votre connexion réseau (ou un éventuel pare-feu)."
		exit 1
	fi
	if ! UV_BIN="$(locate_uv)"; then
		log_error "uv installé mais introuvable (~/.local/bin ou le dossier d'Ergopti). Installation bloquée — exit."
		exit 1
	fi
	emit_marker "UV_INSTALLED"
fi

# A uv older than --system-certs reads the system trust store through the
# setting it replaced.
if ! "$UV_BIN" --help 2>/dev/null | grep -q -- "--system-certs"; then
	export UV_NATIVE_TLS=1
fi

# Sanity-check that uv actually runs. A binary on disk that segfaults or
# has the wrong architecture would otherwise fail much later in the process
# with a confusing error.
if ! uv_version_output="$("$UV_BIN" --version 2>&1)"; then
	# The binary's own error names the cause ("Bad CPU type in executable").
	printf "%s\n" "$uv_version_output" >&2
	log_error "Le binaire uv ($UV_BIN) ne s'exécute pas correctement."
	exit 1
fi




# ===========================================
# ===========================================
# ======= 3/ Bootstrap of Python =============
# ===========================================
# ===========================================

# A native Python 3.11 to 3.14 the Lua caller found (its Mach-O carries this
# processor's slice) builds the venv, and uv downloads no interpreter: the
# managed builds come from GitHub, which company networks often block. The
# versions are those MLX publishes wheels for in uv.lock.
SYSTEM_PYTHON=""
if [ -n "${ERGOPTI_NATIVE_PYTHONS:-}" ]; then
	saved_ifs="$IFS"
	IFS=":"
	for candidate_python in $ERGOPTI_NATIVE_PYTHONS; do
		if [ -z "$SYSTEM_PYTHON" ] && [ -x "$candidate_python" ] && ! lacks_native_slice "$candidate_python" \
			&& "$candidate_python" -c 'import sys; sys.exit(0 if (3, 11) <= sys.version_info[:2] <= (3, 14) else 1)' \
				>/dev/null 2>&1; then
			SYSTEM_PYTHON="$candidate_python"
		fi
	done
	IFS="$saved_ifs"
fi

# Native request staging removes uv's outgoing network dependency. Cached
# imports still return without staging; explicit environment routes retain the
# original uv client. The resolved PTY interpreter is also the input helper,
# never an uninspected PATH Python or the xcode-select shim.
native_offline_bootstrap() {
	[ -n "${ERGOPTI_LAUNCHER_EXECUTABLE:-}" ] \
		&& [ -z "$OPAQUE_NETWORK_INHERITED_HTTPS_ROUTE" ] \
		&& [ -f "$SCRIPT_DIR/managed_bootstrap_http.py" ] \
		&& { [ -x "${ERGOPTI_BOOTSTRAP_PYTHON:-}" ] || managed_bootstrap_launcher_available; }
}

# A fresh Mac needs no preinstalled interpreter to stage the pinned uv runtime.
# Generated metadata comes from the shared release contract; genuine uv owns
# the offline hash check, extraction and publication of its Python directory.
native_install_managed_python_without_python() {
	local work rc python_path
	[ -f "$SCRIPT_DIR/managed-python-release.sh" ] || return 78
	# shellcheck source=/dev/null
	source "$SCRIPT_DIR/managed-python-release.sh"
	[ "$MANAGED_PYTHON_UV_RELEASE" = "$UV_RELEASE_VERSION" ] || return 78
	case "$MANAGED_PYTHON_REQUEST" in cpython-"$PYTHON_VERSION".*-macos-aarch64-none) ;; *) return 78 ;; esac
	[ -f "$SCRIPT_DIR/$MANAGED_PYTHON_DOWNLOADS_BASENAME" ] || return 78
	work="$(mktemp -d "${TMPDIR:-/tmp}/ergopti-native-python.XXXXXX")" || return 1
	if ! managed_bootstrap_download "$MANAGED_PYTHON_URL" "$work/$MANAGED_PYTHON_CACHE_BASENAME" "$MANAGED_PYTHON_SHA256" "" resilient >&2; then
		rm -rf "$work"
		return 1
	fi
	UV_PYTHON_CACHE_DIR="$work" UV_PYTHON_DOWNLOADS=manual "$UV_BIN" python install "$MANAGED_PYTHON_REQUEST" \
		--offline --no-config --python-downloads-json-url "$SCRIPT_DIR/$MANAGED_PYTHON_DOWNLOADS_BASENAME" >&2
	rc=$?
	rm -rf "$work"
	[ "$rc" -eq 0 ] || return "$rc"
	python_path="$("$UV_BIN" python find "$MANAGED_PYTHON_REQUEST" --offline)" || return 1
	[ -x "$python_path" ] && ! lacks_native_slice "$python_path" || return 1
	export ERGOPTI_BOOTSTRAP_PYTHON="$python_path"
}

if [ -n "$SYSTEM_PYTHON" ]; then
	PYTHON_FOR_VENV="$SYSTEM_PYTHON"
	export UV_PYTHON_PREFERENCE=only-system
	export UV_PYTHON_DOWNLOADS=never
	log_info "Using the native Python $SYSTEM_PYTHON: no interpreter download."
else
	PYTHON_FOR_VENV="$PYTHON_REQUEST"
	export UV_PYTHON_PREFERENCE=only-managed
	# 'uv python find' returns non-zero when no managed interpreter matching
	# the request is available. In that case we ask uv to download one.
	if ! "$UV_BIN" python find "$PYTHON_REQUEST" >/dev/null 2>&1; then
		if ! native_offline_bootstrap; then apply_system_network opaque || exit $?; fi
		emit_marker "PYTHON_INSTALLING"
		log_info "Téléchargement de Python $PYTHON_VERSION via uv (interpréteur managé)…"
		# uv prints "Downloading cpython-3.11.x (45 MB)…" on stderr — we forward
		# it verbatim so the live log shows real download progress. Wrapped in
		# retry_network so a tethered / throttled connection doesn't fail the
		# whole bootstrap on a single TCP reset.
		uv_python_install() {
			if native_offline_bootstrap; then
				if [ ! -x "${ERGOPTI_BOOTSTRAP_PYTHON:-}" ]; then
					native_install_managed_python_without_python
					return $?
				fi
				"$ERGOPTI_BOOTSTRAP_PYTHON" "$SCRIPT_DIR/managed_bootstrap_http.py" \
					--timeout "$CURL_MAX_TIME_SEC" --idle-timeout "$CURL_STALL_SEC" \
					python-install --uv "$UV_BIN" --request "$PYTHON_REQUEST" >&2
			else
				"$UV_BIN" python install "$PYTHON_REQUEST" >&2
			fi
		}
		if ! retry_network uv_python_install; then
			log_error "Échec du téléchargement de Python $PYTHON_VERSION via uv. Vérifiez votre connexion réseau."
			exit 1
		fi
		emit_marker "PYTHON_INSTALLED"
	fi
fi




# =====================================================
# =====================================================
# ======= 4/ Hash-Gated Atomic Venv Publication =======
# =====================================================
# =====================================================

# shasum is part of the macOS base install. Keep each fixed-width component
# explicit so a change to either the declared dependencies or their exact
# resolution invalidates the environment.
dependency_fingerprint() {
	local pyproject_hash lock_hash
	pyproject_hash="$(shasum -a 256 "$PYPROJECT" | awk '{print $1}')" || return 1
	lock_hash="$(shasum -a 256 "$UV_LOCK" | awk '{print $1}')" || return 1
	printf "%s:%s" "$pyproject_hash" "$lock_hash"
}

if ! DEPS_FINGERPRINT="$(dependency_fingerprint)"; then
	log_error "Cannot fingerprint pyproject.toml and uv.lock."
	exit 1
fi

# Repair: remove Ergopti's own venv, and the staging leftovers of an
# interrupted run, before anything else can reuse them. Only the folder this
# script derived, and only when it is a real folder holding a Python
# environment (or nothing): never a link, a file, or a foreign folder.
venv_is_removable() {
	if [ -L "$VENV_DIR" ]; then
		log_error "Refusing to remove '$VENV_DIR': it is a symbolic link, not Ergopti's MLX venv."
		return 1
	fi
	if [ ! -e "$VENV_DIR" ]; then
		return 0
	fi
	if [ ! -d "$VENV_DIR" ]; then
		log_error "Refusing to remove '$VENV_DIR': it is not a folder."
		return 1
	fi
	if [ -f "$VENV_DIR/pyvenv.cfg" ] || [ -e "$VENV_DIR/bin/python" ] || [ -L "$VENV_DIR/bin/python" ]; then
		return 0
	fi
	if [ -z "$(ls -A "$VENV_DIR" 2>/dev/null)" ]; then
		return 0
	fi
	log_error "Refusing to remove '$VENV_DIR': it holds no Python environment."
	return 1
}

if [ "$REPAIR_MODE" = "1" ]; then
	emit_marker "VENV_SYNC_RAN"
	emit_marker "VENV_REMOVING"
	if ! venv_is_removable; then
		exit 5
	fi
	if ! native_offline_bootstrap; then apply_system_network opaque || exit $?; fi
	for leftover in "$VENV_DIR" "$VENV_DIR".bootstrap.* "$VENV_DIR".rollback.*; do
		if [ ! -e "$leftover" ] && [ ! -L "$leftover" ]; then
			continue
		fi
		log_info "Removing $leftover before rebuilding the MLX venv."
		if ! remove_output="$(rm -rf -- "$leftover" 2>&1)"; then
			printf "%s\n" "$remove_output" >&2
			log_error "Cannot remove '$leftover': $(printf "%s\n" "$remove_output" | tail -n 1)"
			exit 6
		fi
	done
fi

# Fast path: the venv exists, the hash file matches, AND the pinned imports
# the Hammerspoon side expects all resolve — nothing to do, exit silently.
# The import probe is the safety net: an earlier run could have written the
# hash marker without actually installing anything (e.g. the pre-fix
# `uv pip sync pyproject.toml` was a silent no-op, or a venv whose libraries
# macOS refuses to load), and a hash-only check would then keep skipping work
# forever. When the imports fail, the slow path rebuilds it below.
# A venv built on an interpreter for another processor is never started, not
# even to probe it: it is rebuilt on uv's own interpreter below.
VENV_NOT_NATIVE=0
if [ -e "$VENV_DIR/bin/python" ] && lacks_native_slice "$VENV_DIR/bin/python"; then
	VENV_NOT_NATIVE=1
	log_info "The installed venv's Python is built for another processor than $NATIVE_ARCH — rebuilding it."
fi
if [ "$VENV_NOT_NATIVE" = "0" ] && [ -x "$VENV_DIR/bin/python" ] && [ -f "$SYNC_HASH_FILE" ]; then
	LAST_HASH="$(cat "$SYNC_HASH_FILE" 2>/dev/null || true)"
	if [ "$LAST_HASH" = "$DEPS_FINGERPRINT" ]; then
		# Cheap disk check before the python import probe: globbing the
		# site-packages directory takes microseconds, while spawning python
		# and importing mlx_lm pulls in torch / numpy / etc. and can stall
		# for several seconds — long enough to make the menubar feel frozen
		# on every reload. We only fall back to the slower import probe
		# when the disk check passes.
		# The venv's own version: a native system Python may be 3.11 to 3.14.
		SP_DIR=""
		for candidate_sp in "$VENV_DIR"/lib/python3.*/site-packages; do
			if [ -d "$candidate_sp" ]; then SP_DIR="$candidate_sp"; fi
		done
		if [ -d "$SP_DIR/mlx_lm" ] && [ -d "$SP_DIR/huggingface_hub" ] \
			&& [ -d "$SP_DIR/jinja2" ] && [ -d "$SP_DIR/safetensors" ] \
				&& [ -d "$SP_DIR/truststore" ]; then
			# The directories exist; the venv is reused only when they import.
			# The Lua side reuses an installed venv without running this
			# script, so this probe runs only on a selection that found none.
			if probe_imports "$VENV_DIR/bin/python"; then
				exit 0
			fi
			log_info "The installed venv does not import MLX — rebuilding it."
		else
			log_info "Hash matched but site-packages incomplete — re-syncing dependencies."
		fi
	fi
fi

# Admission precedes uv venv (which may fetch Python) and uv sync. A verified
# cached environment returned above requires no opaque network capability.
if ! native_offline_bootstrap; then apply_system_network opaque || exit $?; fi

# Slow path: real work is about to happen. Emit VENV_SYNC_RAN FIRST so the
# Hammerspoon caller surfaces a "patientez" notification immediately, then
# emit the granular DEPS_SYNCING marker so the user knows we are at the
# pip-sync step specifically. A repair already emitted it.
if [ "$REPAIR_MODE" != "1" ]; then
	emit_marker "VENV_SYNC_RAN"
fi
emit_marker "VENV_CREATING"

# Build the replacement beside the live environment. A signal may arrive at
# any instruction below; the trap either removes the unpublished candidate or
# restores the exact prior environment after the atomic rename boundary.
STAGING_VENV="${VENV_DIR}.bootstrap.$$"
ROLLBACK_VENV="${VENV_DIR}.rollback.$$"
if [ -e "$STAGING_VENV" ] || [ -e "$ROLLBACK_VENV" ]; then
	log_error "Un ancien espace de staging MLX existe encore; publication refusée."
	exit 1
fi

cleanup_staged_venv() {
	cleanup_rc=$?
	trap - EXIT INT TERM HUP
	if [ -e "$ROLLBACK_VENV" ]; then
		if [ ! -e "$VENV_DIR" ]; then
			mv "$ROLLBACK_VENV" "$VENV_DIR" 2>/dev/null || true
		else
			rm -rf "$ROLLBACK_VENV"
		fi
	fi
	if [ -e "$STAGING_VENV" ]; then rm -rf "$STAGING_VENV"; fi
	exit "$cleanup_rc"
}
trap cleanup_staged_venv EXIT
# Preserve a terminal exit status even when the signal interrupts a shell
# builtin whose previous status was zero. EXIT owns the exact restoration.
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

log_info "Création du virtualenv candidat : $STAGING_VENV"
UV_VENV_COMMAND=("$UV_BIN" venv "$STAGING_VENV" --python "$PYTHON_FOR_VENV")
if native_offline_bootstrap; then UV_VENV_COMMAND+=(--offline --no-python-downloads); fi
if ! "${UV_VENV_COMMAND[@]}" >&2; then
	log_error "Impossible de créer le virtualenv candidat via 'uv venv'."
	exit 1
fi
emit_marker "VENV_CREATED"
emit_marker "DEPS_SYNCING"
log_info "Synchronisation des dépendances depuis pyproject.toml…"
cd "$HS_ROOT"
# Use 'uv sync' (project-aware) rather than 'uv pip sync' — the latter expects
# a requirements.txt-style file and silently installs nothing when handed a
# pyproject.toml. With '[tool.uv] package = false' in pyproject.toml, uv sync
# only resolves and installs the declared dependencies, exactly what we need.
# --verbose makes uv print "Resolved 47 packages in 12 ms",
# "Downloading torch (220 MB)…" line by line on stderr; --no-progress avoids
# carriage-return progress bars that confuse the line-buffered Lua streamer.
# Wrap uv sync in retry_network so a flaky connection (mobile tether,
# captive portal, packet loss) doesn't fail the bootstrap on a single
# stalled wheel download. uv has internal retries but they are not
# configurable, so this outer retry covers cases where uv itself gives up.
# A repair downloads every package again instead of trusting the cache.
UV_SYNC_REPAIR_FLAG=""
if [ "$REPAIR_MODE" = "1" ]; then
	UV_SYNC_REPAIR_FLAG="--refresh"
fi
uv_deps_sync() {
	if native_offline_bootstrap; then
		# The actual candidate interpreter supplies its PEP 425/508 platform
		# tags. All selected locked wheels cross the native request owner, then
		# uv consumes their hashes offline; the original imports judge them.
		"$STAGING_VENV/bin/python" "$SCRIPT_DIR/managed_bootstrap_http.py" \
			--timeout "$CURL_MAX_TIME_SEC" --idle-timeout "$CURL_STALL_SEC" \
			sync --uv "$UV_BIN" --project "$HS_ROOT" --python "$STAGING_VENV/bin/python" >&2
		return $?
	fi
	# $UV_SYNC_FROZEN_FLAG is "--frozen" in bundle mode (read-only .app) so uv
	# reads the committed lock file without attempting to rewrite it.
	# shellcheck disable=SC2086
	UV_PROJECT_ENVIRONMENT="$STAGING_VENV" VIRTUAL_ENV="$STAGING_VENV" "$UV_BIN" sync \
		--project "$HS_ROOT" \
		--python "$STAGING_VENV/bin/python" \
		$UV_SYNC_FROZEN_FLAG $UV_SYNC_REPAIR_FLAG \
		--verbose --no-progress >&2
}
if ! retry_network uv_deps_sync; then
	log_error "uv sync failed; the uv error above names the cause."
	exit 1
fi

emit_marker "DEPS_SYNCED"

# Nothing is published, and no fingerprint written, before the candidate's
# interpreter imported the MLX packages: a venv that cannot import mlx_lm was
# once published as installed and then reused for good.
emit_marker "IMPORT_CHECKING"
clear_quarantine "$STAGING_VENV"
clear_quarantine "${UV_PYTHON_INSTALL_DIR:-}"
if ! probe_imports "$STAGING_VENV/bin/python"; then
	exit 4
fi

# Development-mode uv sync may update uv.lock while resolving. Recompute after
# the successful sync so the newly published environment already owns the
# exact resolution it installed and the next launch can take the fast path.
if ! DEPS_FINGERPRINT="$(dependency_fingerprint)"; then
	log_error "Cannot recompute the pyproject.toml and uv.lock fingerprint."
	exit 1
fi

# Persist the combined fingerprint inside the unpublished candidate, then
# atomically swap the whole environment. The live path is never partial.
printf "%s" "$DEPS_FINGERPRINT" > "$STAGING_VENV/.last_sync_hash"
if [ -e "$VENV_DIR" ]; then
	if ! mv "$VENV_DIR" "$ROLLBACK_VENV"; then
		log_error "Impossible de préserver le virtualenv MLX existant."
		exit 1
	fi
fi
if ! mv "$STAGING_VENV" "$VENV_DIR"; then
	log_error "Publication atomique du virtualenv MLX refusée."
	exit 1
fi
if [ -e "$ROLLBACK_VENV" ]; then rm -rf "$ROLLBACK_VENV"; fi
trap - EXIT INT TERM HUP

log_info "✅ Virtualenv prêt : $VENV_DIR"
exit 0
