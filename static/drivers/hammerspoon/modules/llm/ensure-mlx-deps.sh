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
#    the operation is in progress.
# 7. Fail fast: any unrecoverable failure (no network, install blocked by a
#    firewall) aborts with a non-zero exit code and a clear French message
#    that the Lua side propagates verbatim to the user notification.
# 8. Bash 3.2 compatible: macOS still ships bash 3.2 as /bin/bash — no
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

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

# Emits a marker line on stdout. The Lua caller streams stdout line by line
# and surfaces a French "patientez" notification when it sees one of these.
emit_marker() {
	echo "$1"
}

# Logs a human-readable line on stderr so it never collides with the marker
# protocol on stdout.
log_info() {
	echo "[MLX-DEPS] $1" >&2
}

log_error() {
	echo "[MLX-DEPS] ❌ $1" >&2
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
	# both, then re-locate the binary explicitly.
	if ! curl -LsSf https://astral.sh/uv/install.sh | sh >&2; then
		log_error "Téléchargement / installation de uv impossible. Vérifiez votre connexion réseau (ou un éventuel pare-feu)."
		exit 1
	fi

	if ! UV_BIN="$(locate_uv)"; then
		log_error "uv installé mais introuvable dans le PATH (~/.local/bin ou ~/.cargo/bin). Installation bloquée — exit."
		exit 1
	fi
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
	if ! "$UV_BIN" python install "$PYTHON_VERSION" >&2; then
		log_error "Échec du téléchargement de Python $PYTHON_VERSION via uv. Vérifiez votre connexion réseau."
		exit 1
	fi
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
fi




# =====================================================
# =====================================================
# ======= 5/ Hash-Gated Dependencies Sync =============
# =====================================================
# =====================================================

# shasum is part of the macOS base install, so no extra dependency is
# required to compute the pyproject.toml fingerprint.
PYPROJECT_HASH="$(shasum -a 256 "$PYPROJECT" | awk '{print $1}')"

# Fast path: the venv exists, the hash file matches, and the python
# interpreter is intact — nothing to do, exit silently. No marker is
# emitted so the Lua side stays quiet on a normal reload.
if [ -x "$VENV_DIR/bin/python" ] && [ -f "$SYNC_HASH_FILE" ]; then
	LAST_HASH="$(cat "$SYNC_HASH_FILE" 2>/dev/null || true)"
	if [ "$LAST_HASH" = "$PYPROJECT_HASH" ]; then
		exit 0
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
if ! VIRTUAL_ENV="$VENV_DIR" "$UV_BIN" pip sync "$PYPROJECT" >&2; then
	log_error "'uv pip sync' a échoué — vérifiez votre connexion réseau et les versions épinglées dans pyproject.toml."
	exit 1
fi

# Persist the hash so the next invocation takes the silent fast path.
printf "%s" "$PYPROJECT_HASH" > "$SYNC_HASH_FILE"

log_info "✅ Virtualenv prêt : $VENV_DIR"
exit 0
