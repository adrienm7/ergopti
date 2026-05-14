# _shared/llm/install/ollama_install.ps1
#
# ==============================================================================
# SCRIPT: Ensure Ollama Engine Available (Windows)
# DESCRIPTION:
# Provisions a working Ollama install on Windows — downloads and installs
# the binary if missing, starts the local server, and optionally pulls a
# default model. Emits the same markers as the bash counterpart so the
# AHK deps checker can parse them identically:
#   OLLAMA_INSTALLING  — binary download/install in progress
#   OLLAMA_STARTING    — server launch in progress
#   OLLAMA_READY       — server confirmed reachable
#
# FEATURES & RATIONALE:
# 1. Idempotent fast path: when the server already answers, exits 0 silently.
# 2. Silent install: MSI run with /S flag, no UI shown.
# 3. Server lifecycle: spawns `ollama serve` detached and polls /api/tags.
# 4. Model pull: downloads the requested model after server is ready.
# ==============================================================================

param(
	[string]$Model = "qwen2.5:3b"
)

$ErrorActionPreference = "Stop"

$OLLAMA_INSTALLER_URL  = "https://ollama.com/download/OllamaSetup.exe"
$INSTALLER_PATH        = "$env:TEMP\OllamaSetup.exe"
$OLLAMA_HEALTH_URL     = "http://localhost:11434/api/tags"
$OLLAMA_READY_TIMEOUT  = 30   ; seconds to wait for server readiness
$UNIFIED_LOG           = "$env:TEMP\ergopti.log"




# ======================================
# ======================================
# ======= 1/ Helpers =======
# ======================================
# ======================================

function Emit-Marker([string]$marker) {
	Write-Output $marker
	[Console]::Out.Flush()
}

function Log-Info([string]$msg) {
	Write-Error "[OLLAMA-DEPS] $msg"
}

function Test-OllamaOnPath {
	return $null -ne (Get-Command "ollama" -ErrorAction SilentlyContinue)
}

function Test-ServerAlive {
	try {
		$resp = Invoke-WebRequest -Uri $OLLAMA_HEALTH_URL -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
		return $resp.StatusCode -eq 200
	} catch {
		return $false
	}
}

function Wait-ForServer {
	$elapsed = 0
	while ($elapsed -lt $OLLAMA_READY_TIMEOUT) {
		if (Test-ServerAlive) { return $true }
		Start-Sleep -Seconds 1
		$elapsed++
	}
	return $false
}




# =============================================
# =============================================
# ======= 2/ Binary Provisioning =======
# =============================================
# =============================================

if (-not (Test-OllamaOnPath)) {
	Emit-Marker "OLLAMA_INSTALLING"
	Log-Info "Téléchargement d'Ollama depuis $OLLAMA_INSTALLER_URL…"

	try {
		Invoke-WebRequest -Uri $OLLAMA_INSTALLER_URL -OutFile $INSTALLER_PATH -UseBasicParsing
	} catch {
		Log-Info "Échec du téléchargement : $_"
		exit 1
	}

	Log-Info "Lancement de l'installeur silencieux…"
	try {
		$proc = Start-Process -FilePath $INSTALLER_PATH -ArgumentList "/S" -Wait -PassThru
		if ($proc.ExitCode -ne 0) {
			Log-Info "L'installeur a échoué (code $($proc.ExitCode))."
			exit 1
		}
	} catch {
		Log-Info "Impossible de lancer l'installeur : $_"
		exit 1
	} finally {
		Remove-Item $INSTALLER_PATH -ErrorAction SilentlyContinue
	}

	# Re-resolve PATH so the freshly installed binary is discoverable
	$env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
	            [System.Environment]::GetEnvironmentVariable("Path", "User")

	if (-not (Test-OllamaOnPath)) {
		Log-Info "Ollama installé mais introuvable dans le PATH."
		exit 1
	}

	Log-Info "Ollama installé avec succès."
}




# ==========================================
# ==========================================
# ======= 3/ Server Lifecycle =======
# ==========================================
# ==========================================

if (Test-ServerAlive) {
	# Fast path: server already running — exit silently, no markers
	# Model pull still happens so we ensure the requested model is available
} else {
	Emit-Marker "OLLAMA_STARTING"
	Log-Info "Démarrage du serveur Ollama en arrière-plan…"

	try {
		$serverProc = Start-Process -FilePath "ollama" -ArgumentList "serve" `
			-WindowStyle Hidden -PassThru `
			-RedirectStandardOutput $UNIFIED_LOG -RedirectStandardError $UNIFIED_LOG
	} catch {
		# RedirectStandardOutput may fail if file is locked; try without redirect
		try {
			$serverProc = Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden -PassThru
		} catch {
			Log-Info "Impossible de démarrer ollama serve : $_"
			exit 1
		}
	}

	if (-not (Wait-ForServer)) {
		Log-Info "Le serveur Ollama n'a pas répondu dans les ${OLLAMA_READY_TIMEOUT}s."
		exit 1
	}

	Emit-Marker "OLLAMA_READY"
	Log-Info "Serveur Ollama prêt sur http://localhost:11434."
}




# ======================================
# ======================================
# ======= 4/ Model Pull =======
# ======================================
# ======================================

if ($Model -ne "") {
	Log-Info "Vérification du modèle '$Model'…"

	# Check if model already present
	try {
		$tags_resp = Invoke-WebRequest -Uri $OLLAMA_HEALTH_URL -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
		$tags_json = $tags_resp.Content
		if ($tags_json -match [regex]::Escape('"' + $Model.Split(':')[0])) {
			Log-Info "Modèle '$Model' déjà disponible."
			exit 0
		}
	} catch {}

	Log-Info "Téléchargement du modèle '$Model'…"
	Write-Output "Téléchargement du modèle $Model…"

	try {
		& ollama pull $Model 2>&1 | ForEach-Object { Write-Output $_ }
		if ($LASTEXITCODE -ne 0) {
			Log-Info "Échec du téléchargement du modèle '$Model' (code $LASTEXITCODE)."
			exit 1
		}
	} catch {
		Log-Info "Erreur lors du pull du modèle : $_"
		exit 1
	}

	Log-Info "Modèle '$Model' prêt."
}

exit 0
