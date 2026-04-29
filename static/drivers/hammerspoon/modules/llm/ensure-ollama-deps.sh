#!/bin/bash

# ==============================================================================
# SCRIPT: Ensure Ollama Engine Available
# DESCRIPTION:
# Provisions a working Ollama install on a freshly cloned macOS — installs the
# `ollama` binary if missing, then makes sure the local server is reachable on
# http://localhost:11434 so the rest of the stack can talk to it. No manual
# user setup required: the user's first Hammerspoon reload after switching to
# (or installing on) the Ollama backend bootstraps everything.
#
# FEATURES & RATIONALE:
# 1. Self-bootstrapping: prefers the official `curl … | sh` installer (works on
#    a Mac vierge with no Homebrew), falls back to `brew install ollama` when
#    Homebrew is already there. Either path lands a usable `ollama` binary.
# 2. Server lifecycle: after the binary is installed, queries
#    http://localhost:11434/api/tags. If the server is not running, launches
#    `ollama serve` in the background (detached, redirected to /tmp/ergopti.log)
#    and waits up to OLLAMA_READY_TIMEOUT_SEC seconds for it to come online.
# 3. Streaming markers: emits identifiable lines on stdout (OLLAMA_INSTALLING,
#    OLLAMA_STARTING, OLLAMA_READY) so the Lua side can map each to a precise
#    French step label in the unified progress UI.
# 4. Verbose pass-through: forwards installer stderr verbatim so the user
#    sees real download progress in the live log instead of a frozen banner.
# 5. Bash 3.2 compatible: macOS still ships bash 3.2; no associative arrays,
#    no `${var,,}`, nothing that requires bash 4+.
# 6. Idempotent fast path: when `ollama` is on PATH AND the server already
#    answers, the script exits 0 silently in milliseconds without printing
#    any markers — a normal reload stays invisible to the user.
# ==============================================================================

set -eu
set -o pipefail 2>/dev/null || true

# Prepend the canonical Homebrew install locations so a freshly installed
# ollama is discoverable without re-sourcing the shell profile.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

# Number of seconds to wait for `ollama serve` to become reachable after we
# spawn it. Generous to account for first-run filesystem priming on slower
# disks; capped low enough that a real install failure surfaces promptly.
OLLAMA_READY_TIMEOUT_SEC=20

# Server endpoint we probe to determine readiness. `/api/tags` returns 200
# OK with an empty list on a freshly installed server, so it's a reliable
# liveness signal that does not depend on any model already being present.
OLLAMA_HEALTH_URL="http://localhost:11434/api/tags"

# Path to the unified log file used by Hammerspoon. Spawning `ollama serve`
# with stdout/stderr appended here means `tail -f /tmp/ergopti.log` shows
# the server output alongside the rest of the stack.
UNIFIED_LOG="/tmp/ergopti.log"


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

# Returns 0 when the local Ollama server answers a tags request, non-zero
# otherwise. Uses curl with a tight connect timeout so we do not block.
ollama_server_alive() {
	curl -fsS --max-time 2 "$OLLAMA_HEALTH_URL" >/dev/null 2>&1
}

# Waits up to OLLAMA_READY_TIMEOUT_SEC for the server to answer. Returns 0
# on success, non-zero on timeout.
wait_for_server() {
	local elapsed=0
	while [ "$elapsed" -lt "$OLLAMA_READY_TIMEOUT_SEC" ]; do
		if ollama_server_alive; then
			return 0
		fi
		sleep 1
		elapsed=$((elapsed + 1))
	done
	return 1
}




# ====================================
# ====================================
# ======= 1/ Binary Provisioning =====
# ====================================
# ====================================

if ! command -v ollama >/dev/null 2>&1; then
	emit_marker "OLLAMA_INSTALLING"
	log_info "Installation automatique d'Ollama…"

	if command -v brew >/dev/null 2>&1; then
		log_info "Homebrew détecté — installation via 'brew install ollama'."
		if ! brew install ollama >&2; then
			log_error "'brew install ollama' a échoué — vérifiez votre connexion réseau."
			exit 1
		fi
	else
		log_info "Pas d'Homebrew — utilisation de l'installeur officiel curl … | sh."
		if ! command -v curl >/dev/null 2>&1; then
			log_error "'curl' introuvable — impossible de télécharger Ollama. Vérifiez l'installation de macOS."
			exit 1
		fi
		if ! curl -fsSL https://ollama.com/install.sh | sh >&2; then
			log_error "Téléchargement / installation d'Ollama impossible. Vérifiez votre réseau (ou un éventuel pare-feu)."
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




# =================================
# =================================
# ======= 2/ Server Lifecycle =====
# =================================
# =================================

if ollama_server_alive; then
	# Fast path: server already running. Exit silently — the Lua side will
	# treat the absence of OLLAMA_READY as "nothing to do".
	exit 0
fi

emit_marker "OLLAMA_STARTING"
log_info "Démarrage du serveur Ollama en arrière-plan…"

# Spawn the server fully detached so it survives this script's exit.
# Output is appended to the unified log so `tail -f /tmp/ergopti.log` shows
# the server's startup banner and any subsequent runtime errors.
nohup ollama serve >>"$UNIFIED_LOG" 2>&1 &
disown 2>/dev/null || true

if ! wait_for_server; then
	log_error "Le serveur Ollama n'a pas répondu dans les ${OLLAMA_READY_TIMEOUT_SEC}s — voir $UNIFIED_LOG."
	exit 1
fi

emit_marker "OLLAMA_READY"
log_info "✅ Serveur Ollama prêt sur http://localhost:11434."
exit 0
