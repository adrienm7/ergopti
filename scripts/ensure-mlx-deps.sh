#!/bin/bash

# ==============================================================================
# SCRIPT: Ensure MLX Server Dependencies
# DESCRIPTION:
# Verifies that all required Python packages for MLX are installed with correct versions.
# Called automatically on first Hammerspoon startup to ensure factory-reset macOS works.
#
# FEATURES:
# 1. Detects Python 3 installation (system or Homebrew)
# 2. Checks each dependency version
# 3. Auto-upgrades outdated packages
# 4. Safe for repeated runs (no-op if versions are OK)
# ==============================================================================

set -e

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export SSL_CERT_FILE=/etc/ssl/cert.pem
export REQUESTS_CA_BUNDLE=/etc/ssl/cert.pem
export PIP_CERT=/etc/ssl/cert.pem
export HF_HUB_DISABLE_XET=1

# Find Python 3
PYTHON_BIN=""
if command -v /usr/local/bin/python3 &>/dev/null; then
	PYTHON_BIN="/usr/local/bin/python3"
elif command -v /opt/homebrew/bin/python3 &>/dev/null; then
	PYTHON_BIN="/opt/homebrew/bin/python3"
elif command -v python3 &>/dev/null; then
	PYTHON_BIN="python3"
else
	echo "[MLX-DEPS] ❌ Python 3 not found. Cannot auto-install MLX dependencies."
	exit 1
fi

echo "[MLX-DEPS] Using Python: $PYTHON_BIN"
"$PYTHON_BIN" --version

# Check and upgrade each required package
check_and_install() {
	local pkg_name="$1"
	local min_version="$2"
	
	echo -n "[MLX-DEPS] Checking $pkg_name... "

	if "$PYTHON_BIN" - <<PY >/dev/null 2>&1
from importlib.metadata import version
from packaging.version import Version
pkg = "$pkg_name"
cur = Version(version(pkg))
need = Version("$min_version")
raise SystemExit(0 if cur >= need else 1)
PY
	then
		local installed_version=$($PYTHON_BIN - <<PY
from importlib.metadata import version
print(version("$pkg_name"))
PY
)
		echo "$installed_version (OK >= $min_version)"
	else
		echo "upgrade required (>= $min_version)"
		"$PYTHON_BIN" -m pip install --user --upgrade "$pkg_name>=$min_version" >/dev/null 2>&1 && \
			echo "[MLX-DEPS]   ✅ Installed/updated $pkg_name" || \
			echo "[MLX-DEPS]   ⚠️ Install failed: $pkg_name"
	fi
}

# Core MLX dependencies
"$PYTHON_BIN" -m pip install --user --upgrade packaging >/dev/null 2>&1 || true
check_and_install "jinja2" "3.1.0"
check_and_install "huggingface_hub" "0.21.0"
check_and_install "truststore" "0.10.0"
check_and_install "mlx-lm" "0.0.1"
check_and_install "safetensors" "0.4.0"

echo "[MLX-DEPS] ✅ All required packages checked and installed."
