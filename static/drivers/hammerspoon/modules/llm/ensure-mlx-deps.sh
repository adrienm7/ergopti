#!/bin/bash

# ==============================================================================
# SCRIPT: Ensure Hammerspoon Python Dependencies
# DESCRIPTION:
# Provisions the project-local virtualenv at static/drivers/hammerspoon/.venv
# from the pinned pyproject.toml so every Hammerspoon Python invocation runs
# against the same, reproducible interpreter. Called automatically on every
# Hammerspoon startup so a freshly cloned repo becomes runnable without any
# manual setup.
#
# FEATURES & RATIONALE:
# 1. Single source of truth: all package versions live in pyproject.toml — this
#    script never pins a version inline.
# 2. Project-local venv only: no system Python, no $HOME/.mlx_py_env, no
#    --user installs. Eliminates a class of "it works on my machine" bugs
#    where a stray globally-installed package shadows the pinned one.
# 3. Hash-gated sync: the script hashes pyproject.toml and compares it against
#    a marker file written after the previous successful sync. On a match it
#    exits silently in milliseconds; on mismatch it runs 'uv pip sync' and
#    prints the marker line "VENV_SYNC_RAN" so the Hammerspoon caller can
#    surface a "patientez" notification only when real work happens.
# 4. Fail fast: any failure (uv missing, venv creation, sync) aborts the
#    script with a non-zero exit code and an explicit French message.
# ==============================================================================

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export SSL_CERT_FILE=/etc/ssl/cert.pem
export REQUESTS_CA_BUNDLE=/etc/ssl/cert.pem
export PIP_CERT=/etc/ssl/cert.pem
export HF_HUB_DISABLE_XET=1

# Resolve the Hammerspoon driver root from this script's location so the
# script works regardless of the caller's CWD.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VENV_DIR="$HS_ROOT/.venv"
PYPROJECT="$HS_ROOT/pyproject.toml"
SYNC_HASH_FILE="$VENV_DIR/.last_sync_hash"

if [ ! -f "$PYPROJECT" ]; then
	echo "[MLX-DEPS] ❌ pyproject.toml introuvable à $PYPROJECT — projet corrompu." >&2
	exit 1
fi

if ! command -v uv >/dev/null 2>&1; then
	echo "[MLX-DEPS] ❌ 'uv' introuvable dans le PATH. Installez uv via 'brew install uv' puis relancez." >&2
	exit 1
fi

# Compute the hash of pyproject.toml. shasum is part of the macOS base install,
# so no extra dependency is required.
PYPROJECT_HASH="$(shasum -a 256 "$PYPROJECT" | awk '{print $1}')"

# Fast path: the venv exists, the hash file matches, and the python interpreter
# is intact — nothing to do, exit silently.
if [ -x "$VENV_DIR/bin/python" ] && [ -f "$SYNC_HASH_FILE" ]; then
	LAST_HASH="$(cat "$SYNC_HASH_FILE" 2>/dev/null || true)"
	if [ "$LAST_HASH" = "$PYPROJECT_HASH" ]; then
		# Silent success — no marker emitted, caller treats this as a no-op.
		exit 0
	fi
fi

# Slow path: real work is about to happen. Emit the marker FIRST so the
# Hammerspoon caller can surface a "patientez" notification immediately,
# before the heavy uv operations run.
echo "VENV_SYNC_RAN"

# Provision the venv on first run. uv venv is idempotent — it succeeds without
# touching an existing venv that already matches the requested interpreter.
if [ ! -x "$VENV_DIR/bin/python" ]; then
	echo "[MLX-DEPS] Création du virtualenv local : $VENV_DIR"
	if ! uv venv "$VENV_DIR" --python 3.11; then
		echo "[MLX-DEPS] ❌ Impossible de créer le virtualenv via 'uv venv'." >&2
		exit 1
	fi
fi

# Sync the venv to the exact set of pinned dependencies in pyproject.toml.
echo "[MLX-DEPS] Synchronisation des dépendances depuis pyproject.toml…"
cd "$HS_ROOT"
if ! VIRTUAL_ENV="$VENV_DIR" uv pip sync "$PYPROJECT"; then
	echo "[MLX-DEPS] ❌ 'uv pip sync' a échoué — vérifiez votre connexion réseau et les versions épinglées." >&2
	exit 1
fi

# Persist the hash so the next invocation takes the fast path.
printf "%s" "$PYPROJECT_HASH" > "$SYNC_HASH_FILE"

echo "[MLX-DEPS] ✅ Virtualenv prêt : $VENV_DIR"
