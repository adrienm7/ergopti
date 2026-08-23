#!/bin/bash
# modules/llm/ensure-ollama-deps.sh

# ==============================================================================
# SCRIPT: Ensure Ollama Engine Available
# DESCRIPTION:
# Provisions the Ollama executable on a freshly cloned macOS. Daemon launch is
# deliberately delegated back to ApiOllama so one Lua lifecycle owner retains
# the native task and can synchronously fence/join it during ScriptControl pause.
#
# FEATURES & RATIONALE:
# 1. Self-bootstrapping: prefers the official `curl … | sh` installer (works on
#    a Mac vierge with no Homebrew), falls back to `brew install ollama` when
#    Homebrew is already there. Either path lands a usable `ollama` binary.
# 2. Streaming marker: emits OLLAMA_INSTALLING only when installation work is
#    real, so the Lua side keeps the existing silent fast path.
# 3. Verbose pass-through: forwards installer stderr verbatim so the user
#    sees real download progress in the live log instead of a frozen banner.
# 4. Bash 3.2 compatible: macOS still ships bash 3.2; no associative arrays,
#    no `${var,,}`, nothing that requires bash 4+.
# 5. Idempotent fast path: when `ollama` is already resolved, the script exits
#    silently without creating any unowned background process.
# ==============================================================================

set -eu
set -o pipefail 2>/dev/null || true

# Prepend the canonical Homebrew install locations so a freshly installed
# ollama is discoverable without re-sourcing the shell profile.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

OLLAMA_RESOLVED_BIN="${1:-}"


# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

emit_marker() {
	printf "%s\n" "$1"
	sync 2>/dev/null || true
}

log_info() {
	printf "[OLLAMA-DEPS] %s\n" "$1" >&2
}

log_error() {
	printf "[OLLAMA-DEPS] ❌ %s\n" "$1" >&2
}

# ====================================
# ====================================
# ======= 1/ Binary Provisioning =====
# ====================================
# ====================================

if [ -n "$OLLAMA_RESOLVED_BIN" ]; then
	if [ ! -x "$OLLAMA_RESOLVED_BIN" ]; then
		log_error "The driver-resolved Ollama executable is no longer executable."
		exit 1
	fi
elif ! command -v ollama >/dev/null 2>&1; then
	emit_marker "OLLAMA_INSTALLING"
	log_info "Installation automatique d’Ollama…"

	if command -v brew >/dev/null 2>&1; then
		log_info "Homebrew détecté — installation via 'brew install ollama'."
		if ! brew install ollama >&2; then
			log_error "'brew install ollama' a échoué — vérifiez votre connexion réseau."
			exit 1
		fi
	else
		log_info "Pas d’Homebrew — utilisation de l'installeur officiel curl … | sh."
		if ! command -v curl >/dev/null 2>&1; then
			log_error "'curl' introuvable — impossible de télécharger Ollama. Vérifiez l'installation de macOS."
			exit 1
		fi
		if ! curl -fsSL https://ollama.com/install.sh | sh >&2; then
			log_error "Téléchargement / installation d’Ollama impossible. Vérifiez votre réseau (ou un éventuel pare-feu)."
			exit 1
		fi
	fi

	# Re-resolve PATH after the install so the freshly placed binary is
	# discoverable for the rest of this script run.
	export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
	if ! command -v ollama >/dev/null 2>&1; then
		log_error "Ollama installé mais introuvable dans le PATH."
		exit 1
	fi
fi




exit 0
