#!/bin/bash

# ==============================================================================
# SCRIPT: Ensure MLX Server Dependencies
# DESCRIPTION:
# Verifies and upgrades the Python packages required to run the MLX inference
# server used by the Hammerspoon LLM module. Runs idempotently on every
# Hammerspoon startup so a fresh checkout (or a model that needs a newer
# mlx-lm) self-heals without user intervention.
#
# Lives next to the LLM module code (modules/llm/) so MLX-related concerns
# stay co-located. Invoked by lib/mlx_deps_checker.lua, which always sets
# $PROJECT_ROOT explicitly.
#
# FEATURES:
# 1. Project venv first: prefers $PROJECT_ROOT/.venv over system Python so the
#    same interpreter that runs `mlx_lm.server` is the one we maintain.
# 2. Install-only: only installs missing packages; never upgrades installed ones
#    on its own initiative. Auto-upgrade is handled by the MLX models manager
#    (models_manager_mlx.lua) which runs `pip install --upgrade --no-cache-dir
#    mlx-lm` only when a model crash signals an architecture mismatch.
# 3. Safe for repeated runs: silent when nothing changes, loud when it heals.
# ==============================================================================

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export SSL_CERT_FILE=/etc/ssl/cert.pem
export REQUESTS_CA_BUNDLE=/etc/ssl/cert.pem
export PIP_CERT=/etc/ssl/cert.pem
export HF_HUB_DISABLE_XET=1




# =====================================
# =====================================
# ======= 1/ Python Resolution ========
# =====================================
# =====================================

# Resolve project root: $PROJECT_ROOT (set by mlx_deps_checker.lua) wins,
# otherwise infer from this script's own location.
# This script lives at: <PROJECT_ROOT>/static/drivers/hammerspoon/modules/llm/
if [[ -z "${PROJECT_ROOT:-}" ]]; then
	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
fi

PYTHON_BIN=""

# Prefer the project venv (same interpreter as mlx_lm.server)
if [[ -x "$PROJECT_ROOT/.venv/bin/python3" ]]; then
	PYTHON_BIN="$PROJECT_ROOT/.venv/bin/python3"
elif [[ -x "$PROJECT_ROOT/venv/bin/python3" ]]; then
	PYTHON_BIN="$PROJECT_ROOT/venv/bin/python3"
elif [[ -n "${VIRTUAL_ENV:-}" && -x "$VIRTUAL_ENV/bin/python3" ]]; then
	PYTHON_BIN="$VIRTUAL_ENV/bin/python3"
else
	# Fall back to a dedicated MLX venv we manage ourselves so we never
	# have to write into the system or Homebrew Python (PEP 668).
	MLX_VENV="$HOME/.mlx_py_env"
	if [[ ! -x "$MLX_VENV/bin/python3" ]]; then
		if command -v /opt/homebrew/bin/python3 >/dev/null 2>&1; then
			/opt/homebrew/bin/python3 -m venv "$MLX_VENV"
		elif command -v python3 >/dev/null 2>&1; then
			python3 -m venv "$MLX_VENV"
		else
			echo "[MLX-DEPS] Python 3 introuvable — abandon."
			exit 1
		fi
	fi
	PYTHON_BIN="$MLX_VENV/bin/python3"
fi

echo "[MLX-DEPS] Python utilisé: $PYTHON_BIN"
"$PYTHON_BIN" --version




# =========================================
# =========================================
# ======= 2/ Dependency Maintenance =======
# =========================================
# =========================================

# Helper: print the installed version of a package, or empty string if absent
pkg_version() {
	"$PYTHON_BIN" - "$1" <<'PY' 2>/dev/null || true
import sys
try:
    from importlib.metadata import version
    print(version(sys.argv[1]))
except Exception:
    pass
PY
}

# Packages we INSTALL ON DEMAND if missing. We deliberately do NOT auto-upgrade
# mlx-lm here: a previous version of this script blindly upgraded it on every
# Hammerspoon startup, which silently rewrote the user's working environment
# whenever a new mlx-lm release changed its HTTP routes (the user then saw
# every endpoint return 404 with no obvious cause). The right behaviour is to
# install only what is missing, surface the installed versions clearly, and
# leave version bumps to an explicit user action (e.g. a menu entry).
INSTALL_IF_MISSING=(
	"mlx-lm"
	"huggingface_hub"
	"hf_transfer"
	"safetensors"
	"truststore"
)

MISSING=()
for pkg in "${INSTALL_IF_MISSING[@]}"; do
	if [[ -z "$(pkg_version "$pkg")" ]]; then
		MISSING+=("$pkg")
	fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
	echo "[MLX-DEPS] Paquets manquants à installer: ${MISSING[*]}"
	# pip itself only matters when we actually have to install something
	"$PYTHON_BIN" -m pip install --disable-pip-version-check --upgrade pip >/dev/null 2>&1 || true
	"$PYTHON_BIN" -m pip install --disable-pip-version-check --upgrade packaging >/dev/null 2>&1 || true
	if ! "$PYTHON_BIN" -m pip install --disable-pip-version-check "${MISSING[@]}"; then
		echo "[MLX-DEPS] Échec de l'installation pip — voir la sortie ci-dessus."
		exit 2
	fi
fi

# Always report the resolved versions so the Hammerspoon log captures the exact
# state of the MLX stack — useful when an mlx-lm release silently changes its
# HTTP routes and we need to correlate behaviour with version.
echo "[MLX-DEPS] Versions installées:"
for pkg in "${INSTALL_IF_MISSING[@]}"; do
	echo "[MLX-DEPS]   $pkg = $(pkg_version "$pkg")"
done

if [[ ${#MISSING[@]} -eq 0 ]]; then
	echo "[MLX-DEPS] Toutes les dépendances étaient déjà installées."
else
	echo "[MLX-DEPS] ${#MISSING[@]} paquet(s) installé(s)."
fi
