#!/bin/bash
# modules/llm/ollama-release.sh

# ============================================================================
# MODULE: Pinned Ollama Release
# DESCRIPTION:
# Single source for the on-demand macOS Ollama install (ensure-ollama-deps.sh).
# Digest and size come from the official GitHub release asset for this exact
# tag; the size only drives the download progress bar, the digest gates use.
# ============================================================================

OLLAMA_RELEASE_VERSION="0.24.0"
OLLAMA_DARWIN_TGZ_SHA256="e6d5e8b4bc0cb2a35ff7901c58d81ca2170403a819c4726f58798155fa682e38"
OLLAMA_DARWIN_TGZ_BYTES="133395504"
