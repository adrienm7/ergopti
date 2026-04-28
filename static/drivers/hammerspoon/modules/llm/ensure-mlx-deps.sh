#!/bin/bash

# ==============================================================================
# SCRIPT: Ensure Hammerspoon Python Dependencies
# DESCRIPTION:
# Provisions the project-local virtualenv at static/drivers/hammerspoon/.venv
# from the pinned pyproject.toml so every Hammerspoon Python invocation runs
# against the same, reproducible interpreter. Called automatically on first
# Hammerspoon startup (and on demand from the menu) so a freshly cloned repo
# becomes runnable without any manual setup.
#
# FEATURES & RATIONALE:
# 1. Single source of truth: all package versions live in pyproject.toml — this
#    script never pins a version inline.
# 2. Project-local venv only: no system Python, no $HOME/.mlx_py_env, no
#    --user installs. Eliminates a class of "it works on my machine" bugs
#    where a stray globally-installed package shadows the pinned one.
# 3. Fail fast: any failure (uv missing, venv creation, sync) aborts the
#    script with a non-zero exit code and an explicit French message — the
#    user is the one expected to fix it, so silent fallback is never useful.
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

if [ ! -f "$PYPROJECT" ]; then
	echo "[MLX-DEPS] ❌ pyproject.toml introuvable à $PYPROJECT — projet corrompu." >&2
	exit 1
fi

if ! command -v uv >/dev/null 2>&1; then
	echo "[MLX-DEPS] ❌ 'uv' introuvable dans le PATH. Installez uv via 'brew install uv' puis relancez." >&2
	exit 1
fi

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
# uv pip sync is fast on no-op runs (compares the venv against the lockfile),
# so calling this on every HS startup is cheap and guarantees the venv never
# drifts from pyproject.toml.
echo "[MLX-DEPS] Synchronisation des dépendances depuis pyproject.toml…"
cd "$HS_ROOT"
if ! VIRTUAL_ENV="$VENV_DIR" uv pip sync "$PYPROJECT"; then
	echo "[MLX-DEPS] ❌ 'uv pip sync' a échoué — vérifiez votre connexion réseau et les versions épinglées." >&2
	exit 1
fi

echo "[MLX-DEPS] ✅ Virtualenv prêt : $VENV_DIR"
