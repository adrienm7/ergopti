# _shared/llm/install/ollama_install.ps1
#
# Downloads and installs Ollama on Windows, then pulls a default model.
# Run as administrator for system-wide installation.
#
# Usage:
#   .\ollama_install.ps1
#   .\ollama_install.ps1 -Model "phi4-mini"

param(
	[string]$Model = "qwen2.5:3b"
)

$ErrorActionPreference = "Stop"

$OLLAMA_DOWNLOAD_URL = "https://ollama.com/download/OllamaSetup.exe"
$INSTALLER_PATH      = "$env:TEMP\OllamaSetup.exe"




# ===================================
# ===================================
# ======= 1/ Prerequisite Check =======
# ===================================
# ===================================

function Test-OllamaInstalled {
	$cmd = Get-Command "ollama" -ErrorAction SilentlyContinue
	return $null -ne $cmd
}

function Test-OllamaRunning {
	try {
		$resp = Invoke-WebRequest -Uri "http://localhost:11434" -TimeoutSec 2 -ErrorAction Stop
		return $resp.StatusCode -eq 200
	} catch {
		return $false
	}
}




# ===================================
# ===================================
# ======= 2/ Installation =======
# ===================================
# ===================================

function Install-Ollama {
	Write-Host "Téléchargement d'Ollama depuis $OLLAMA_DOWNLOAD_URL…"
	Invoke-WebRequest -Uri $OLLAMA_DOWNLOAD_URL -OutFile $INSTALLER_PATH -UseBasicParsing

	Write-Host "Lancement de l'installeur…"
	Start-Process -FilePath $INSTALLER_PATH -ArgumentList "/S" -Wait

	Remove-Item $INSTALLER_PATH -ErrorAction SilentlyContinue
	Write-Host "Ollama installé avec succès."
}

function Start-OllamaService {
	Write-Host "Démarrage du serveur Ollama…"
	Start-Process "ollama" -ArgumentList "serve" -WindowStyle Hidden
	Start-Sleep -Seconds 3
}

function Pull-Model {
	param([string]$ModelName)
	Write-Host "Téléchargement du modèle '$ModelName'…"
	& ollama pull $ModelName
	if ($LASTEXITCODE -ne 0) {
		Write-Warning "Échec du téléchargement du modèle '$ModelName'. Vérifiez le nom et réessayez."
	} else {
		Write-Host "Modèle '$ModelName' prêt."
	}
}




# ===================================
# ===================================
# ======= 3/ Main =======
# ===================================
# ===================================

Write-Host "=== Installation Ergopti — Backend IA (Ollama) ==="

if (Test-OllamaInstalled) {
	Write-Host "Ollama est déjà installé."
} else {
	Install-Ollama
}

if (-not (Test-OllamaRunning)) {
	Start-OllamaService
}

if ($Model -ne "") {
	Pull-Model -ModelName $Model
}

Write-Host ""
Write-Host "Configuration terminée. Relancez Ergopti pour activer les suggestions IA."
