#!/bin/bash
# modules/llm/uv-release.sh

# ============================================================================
# MODULE: Pinned uv Release
# DESCRIPTION:
# Single source for the uv that ensure-mlx-deps.sh installs when no native uv
# is found: the official Apple silicon wheel of this exact version on PyPI
# (files.pythonhosted.org, the host the MLX packages come from anyway), never
# the GitHub release the Astral installer fetches, which company networks
# often block. The digest is PyPI's own SHA-256 of that wheel and gates use.
# ============================================================================

UV_RELEASE_VERSION="0.12.21"
UV_WHEEL_ARM64_URL="https://files.pythonhosted.org/packages/66/72/389b430ec12bd15547d4d3641622479cbf7a5c94af0ffb14fee2ed58f891/uv-0.12.21-py3-none-macosx_11_0_arm64.whl"
UV_WHEEL_ARM64_SHA256="eb4f75e8ed770e1f142e03a134b9507e7f4710c4b2cec385d4bf8c5810a91094"
