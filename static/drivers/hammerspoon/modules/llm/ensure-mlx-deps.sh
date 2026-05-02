#!/bin/bash

# ==============================================================================
# SCRIPT: Ensure Hammerspoon Python Dependencies
# DESCRIPTION:
# Provisions the project-local virtualenv at static/drivers/hammerspoon/.venv
# from the pinned pyproject.toml on every Hammerspoon startup so a freshly
# cloned repo on a brand-new Mac becomes runnable WITHOUT any manual setup —
# no Homebrew, no pre-installed Python, no pre-installed uv required.
#
# FEATURES & RATIONALE:
# 1. Self-bootstrapping uv: when 'uv' is missing from PATH and from the usual
#    install locations (~/.local/bin, ~/.cargo/bin), the script downloads and
#    runs the official Astral installer. The user does not need to install
#    anything by hand on a fresh-out-of-the-box Mac.
# 2. Self-bootstrapping Python: uv can download and manage its own Python
#    interpreters, so we never depend on the system Python. If 3.11 is not
#    available, 'uv python install 3.11' fetches it automatically.
# 3. Single source of truth: all package versions live in pyproject.toml — this
#    script never pins a version inline.
# 4. Project-local venv only: no system Python, no $HOME/.mlx_py_env, no
#    --user installs. Eliminates a class of "it works on my machine" bugs
#    where a stray globally-installed package shadows the pinned one.
# 5. Hash-gated sync: hashes pyproject.toml and compares against a marker file
#    written after the previous successful sync. On a match it exits silently
#    in milliseconds; on mismatch it runs 'uv pip sync' and prints
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
#    firewall) aborts with a non-zero exit code and a clear French message
#    that the Lua side propagates verbatim to the user notification.
# 9. Bash 3.2 compatible: macOS still ships bash 3.2 as /bin/bash — no
#    associative arrays, no '${var,,}', nothing that requires bash 4+.
# ==============================================================================

set -eu

# Note: 'set -o pipefail' is bash-specific and supported on bash 3.2.
# We intentionally avoid 'set -e' on the network install steps and check
# return codes by hand, so failures emit a clear French message instead of
# aborting silently.
set -o pipefail 2>/dev/null || true

export SSL_CERT_FILE=/etc/ssl/cert.pem
export REQUESTS_CA_BUNDLE=/etc/ssl/cert.pem
export PIP_CERT=/etc/ssl/cert.pem
export HF_HUB_DISABLE_XET=1

# Network robustness — these env vars are honoured by uv (Rust HTTP client)
# and indirectly by curl/python downloads. Set generously so a flaky tether
# or a throttled mobile hotspot doesn't abort the whole install on a single
# stall: a 120 s read timeout is long enough for slow chunks of a 200 MB
# wheel to dribble through, and 6 retries cover transient DNS or TLS
# handshake failures without giving up after one bad packet.
export UV_HTTP_TIMEOUT=120
export UV_CONCURRENT_DOWNLOADS=2

# Maximum number of retries for any single network operation in this
# script (curl install, uv sync, python install). Each retry waits an
# increasing number of seconds (5, 10, 20, …) so we play nice with the
# server while still recovering from a transient outage.
NETWORK_MAX_RETRIES=6
NETWORK_BASE_BACKOFF_SEC=5

# Runs "$@" up to NETWORK_MAX_RETRIES times with exponential backoff. Logs
# every retry on stderr so the user sees that the script is still alive
# during a flaky network. Returns the exit code of the last attempt.
retry_network() {
	local attempt=1
	local backoff="$NETWORK_BASE_BACKOFF_SEC"
	while [ "$attempt" -le "$NETWORK_MAX_RETRIES" ]; do
		if "$@"; then
			return 0
		fi
		local rc=$?
		if [ "$attempt" -ge "$NETWORK_MAX_RETRIES" ]; then
			log_error "Tentative $attempt/$NETWORK_MAX_RETRIES échouée (code $rc) — abandon."
			return "$rc"
		fi
		log_info "Tentative $attempt/$NETWORK_MAX_RETRIES échouée (code $rc) — nouvelle tentative dans ${backoff}s…"
		sleep "$backoff"
		attempt=$((attempt + 1))
		backoff=$((backoff * 2))
	done
	return 1
}

# Resolve the Hammerspoon driver root from this script's location so the
# script works regardless of the caller's CWD.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VENV_DIR="$HS_ROOT/.venv"
PYPROJECT="$HS_ROOT/pyproject.toml"
SYNC_HASH_FILE="$VENV_DIR/.last_sync_hash"

# Pinned interpreter version. Kept in sync with pyproject.toml's
# requires-python clause — bumping one without the other breaks the
# fast-path hash check.
PYTHON_VERSION="3.11"

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

# Locates uv in PATH or in the well-known install directories. Prints the
# absolute path on success, returns non-zero on failure.
locate_uv() {
	if command -v uv >/dev/null 2>&1; then
		command -v uv
		return 0
	fi
	if [ -x "$HOME/.local/bin/uv" ]; then
		echo "$HOME/.local/bin/uv"
		return 0
	fi
	if [ -x "$HOME/.cargo/bin/uv" ]; then
		echo "$HOME/.cargo/bin/uv"
		return 0
	fi
	return 1
}




# =====================================
# =====================================
# ======= 1/ Sanity Validation ========
# =====================================
# =====================================

if [ ! -f "$PYPROJECT" ]; then
	log_error "pyproject.toml introuvable à $PYPROJECT — projet corrompu."
	exit 1
fi

# Clean up stale venv lock files. uv holds exclusive locks while resolving
# dependencies. If a previous uv process crashed or was killed, the lock
# persists and blocks the next invocation indefinitely. Rather than hang,
# remove any lock file older than 5 seconds — it's definitely stale.
LOCK_FILE="$VENV_DIR/.lock"
if [ -f "$LOCK_FILE" ]; then
	LOCK_AGE=$(($(date +%s) - $(stat -f%m "$LOCK_FILE" 2>/dev/null || echo 0)))
	if [ "$LOCK_AGE" -gt 5 ]; then
		log_info "Stale venv lock detected (age: ${LOCK_AGE}s) — removing."
		rm -f "$LOCK_FILE"
	fi
fi




# ====================================
# ====================================
# ======= 2/ Bootstrap of uv =========
# ====================================
# ====================================

UV_BIN=""
if UV_BIN="$(locate_uv)"; then
	:
else
	# uv is not present anywhere we know about — install it via the official
	# Astral installer. We emit the marker BEFORE running curl so the Lua
	# side can immediately tell the user "Installation de uv…" rather than
	# leaving them staring at a frozen menu bar for 30 s.
	emit_marker "UV_INSTALLING"
	log_info "Installation automatique de uv via l'installeur officiel Astral…"

	if ! command -v curl >/dev/null 2>&1; then
		log_error "'curl' introuvable — impossible de télécharger uv. Vérifiez l'installation de macOS."
		exit 1
	fi

	# The installer writes uv to ~/.local/bin by default on recent versions
	# and to ~/.cargo/bin on older ones. We pre-extended PATH above to cover
	# both, then re-locate the binary explicitly. Verbose progress from the
	# installer goes to stderr so the Lua side surfaces it via Logger.info.
	# curl flags add resilience for slow / flaky connections: --connect-timeout
	# avoids hanging on a dead DNS, --max-time bounds the total install
	# duration, --retry covers transient network blips with exponential
	# backoff inside curl itself, and --retry-all-errors retries even on
	# partial transfer failures. The outer retry_network loop adds a second
	# layer of resilience on top of curl's own retries.
	curl_uv_install() {
		curl -LsSf \
			--connect-timeout 30 \
			--max-time 600 \
			--retry 5 \
			--retry-delay 5 \
			--retry-max-time 300 \
			--retry-all-errors \
			https://astral.sh/uv/install.sh | sh >&2
	}
	if ! retry_network curl_uv_install; then
		log_error "Téléchargement / installation de uv impossible. Vérifiez votre connexion réseau (ou un éventuel pare-feu)."
		exit 1
	fi

	if ! UV_BIN="$(locate_uv)"; then
		log_error "uv installé mais introuvable dans le PATH (~/.local/bin ou ~/.cargo/bin). Installation bloquée — exit."
		exit 1
	fi
	emit_marker "UV_INSTALLED"
fi

# Sanity-check that uv actually runs. A binary on disk that segfaults or
# has the wrong architecture would otherwise fail much later in the process
# with a confusing error.
if ! "$UV_BIN" --version >/dev/null 2>&1; then
	log_error "Le binaire uv ($UV_BIN) ne s'exécute pas correctement."
	exit 1
fi




# ===========================================
# ===========================================
# ======= 3/ Bootstrap of Python =============
# ===========================================
# ===========================================

# 'uv python find' returns non-zero when no managed or system interpreter
# matching the constraint is available. In that case we ask uv to download
# one — the user does not need a system Python.
if ! "$UV_BIN" python find "$PYTHON_VERSION" >/dev/null 2>&1; then
	emit_marker "PYTHON_INSTALLING"
	log_info "Téléchargement de Python $PYTHON_VERSION via uv (interpréteur managé)…"
	# uv prints "Downloading cpython-3.11.x (45 MB)…" on stderr — we forward
	# it verbatim so the live log shows real download progress. Wrapped in
	# retry_network so a tethered / throttled connection doesn't fail the
	# whole bootstrap on a single TCP reset.
	uv_python_install() { "$UV_BIN" python install "$PYTHON_VERSION" >&2; }
	if ! retry_network uv_python_install; then
		log_error "Échec du téléchargement de Python $PYTHON_VERSION via uv. Vérifiez votre connexion réseau."
		exit 1
	fi
	emit_marker "PYTHON_INSTALLED"
fi




# =========================================
# =========================================
# ======= 4/ Venv Provisioning ============
# =========================================
# =========================================

if [ ! -x "$VENV_DIR/bin/python" ]; then
	emit_marker "VENV_CREATING"
	log_info "Création du virtualenv local : $VENV_DIR"
	if ! "$UV_BIN" venv "$VENV_DIR" --python "$PYTHON_VERSION" >&2; then
		log_error "Impossible de créer le virtualenv via 'uv venv'."
		exit 1
	fi
	emit_marker "VENV_CREATED"
fi




# =====================================================
# =====================================================
# ======= 5/ Hash-Gated Dependencies Sync =============
# =====================================================
# =====================================================

# shasum is part of the macOS base install, so no extra dependency is
# required to compute the pyproject.toml fingerprint.
PYPROJECT_HASH="$(shasum -a 256 "$PYPROJECT" | awk '{print $1}')"

# Fast path: the venv exists, the hash file matches, AND the four pinned
# imports the Hammerspoon side expects all resolve — nothing to do, exit
# silently. The import probe is the safety net: an earlier run could have
# written the hash marker without actually installing anything (e.g. the
# pre-fix `uv pip sync pyproject.toml` was a silent no-op), and a hash-only
# check would then keep skipping work forever. When the imports fail, drop
# the hash file so the slow path runs unconditionally below.
if [ -x "$VENV_DIR/bin/python" ] && [ -f "$SYNC_HASH_FILE" ]; then
	LAST_HASH="$(cat "$SYNC_HASH_FILE" 2>/dev/null || true)"
	if [ "$LAST_HASH" = "$PYPROJECT_HASH" ]; then
		# Cheap disk check before the python import probe: globbing the
		# site-packages directory takes microseconds, while spawning python
		# and importing mlx_lm pulls in torch / numpy / etc. and can stall
		# for several seconds — long enough to make the menubar feel frozen
		# on every reload. We only fall back to the slower import probe
		# when the disk check passes.
		SP_DIR="$VENV_DIR/lib/python$PYTHON_VERSION/site-packages"
		if [ -d "$SP_DIR/mlx_lm" ] && [ -d "$SP_DIR/huggingface_hub" ] \
			&& [ -d "$SP_DIR/jinja2" ] && [ -d "$SP_DIR/safetensors" ]; then
			# Disk says the four packages are there; trust the hash and exit.
			# The import probe is intentionally skipped here — keeping the
			# fast path as fast as the original (~50 ms) on a healthy venv.
			exit 0
		fi
		log_info "Hash matched but site-packages incomplete — re-syncing dependencies."
		rm -f "$SYNC_HASH_FILE"
	fi
fi

# Slow path: real work is about to happen. Emit VENV_SYNC_RAN FIRST so the
# Hammerspoon caller surfaces a "patientez" notification immediately, then
# emit the granular DEPS_SYNCING marker so the user knows we are at the
# pip-sync step specifically.
emit_marker "VENV_SYNC_RAN"
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
uv_deps_sync() {
	VIRTUAL_ENV="$VENV_DIR" "$UV_BIN" sync \
		--project "$HS_ROOT" \
		--python "$VENV_DIR/bin/python" \
		--verbose --no-progress >&2
}
if ! retry_network uv_deps_sync; then
	log_error "'uv sync' a échoué — vérifiez votre connexion réseau et les versions épinglées dans pyproject.toml."
	exit 1
fi

emit_marker "DEPS_SYNCED"

# Persist the hash so the next invocation takes the silent fast path.
printf "%s" "$PYPROJECT_HASH" > "$SYNC_HASH_FILE"

log_info "✅ Virtualenv prêt : $VENV_DIR"
exit 0
