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
# 5. ASCII-only log strings: PowerShell 5.1 reads .ps1 files in the system
#    codepage (CP1252/CP850), which corrupts UTF-8 string literals. All
#    user-visible text is localised by the AHK caller via i18n markers.
# ==============================================================================

param(
	[string]$Model   = "qwen2.5:3b",
	[string]$OutFile = ""
)

$ErrorActionPreference = "Continue"

$OLLAMA_INSTALLER_URL = "https://ollama.com/download/OllamaSetup.exe"
# Unique name avoids conflicts with a locked leftover from a previous run
$INSTALLER_PATH       = "$env:TEMP\OllamaSetup_ergopti_$([System.Diagnostics.Process]::GetCurrentProcess().Id).exe"
$OLLAMA_HEALTH_URL    = "http://localhost:11434/api/tags"
$OLLAMA_READY_TIMEOUT = 30
$UNIFIED_LOG          = "$env:TEMP\ergopti_ollama_serve.log"

# Write directly to OutFile via StreamWriter (UTF-8, no BOM) to bypass the
# double-encoding PowerShell 5.1 produces when stdout is captured by cmd.exe.
$_utf8nobom = [System.Text.UTF8Encoding]::new($false)
$_writer = if ($OutFile -ne "") {
	[System.IO.StreamWriter]::new($OutFile, $false, $_utf8nobom)
} else {
	$null
}




# ======================================
# ======================================
# ======= 1/ Helpers =======
# ======================================
# ======================================

function Emit([string]$line) {
	if ($script:_writer) {
		$script:_writer.WriteLine($line)
		$script:_writer.Flush()
	} else {
		Write-Output $line
	}
}

function Emit-Marker([string]$marker) { Emit $marker }

# Log-Info messages are developer-facing and must stay ASCII-only.
# PowerShell 5.1 reads .ps1 source in the system codepage, so any non-ASCII
# literal in the script itself gets corrupted before it can be written.
function Log-Info([string]$msg) { Emit "[OLLAMA-DEPS] $msg" }

function Close-Writer {
	if ($script:_writer) { $script:_writer.Close() }
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
	Log-Info "Downloading Ollama from $OLLAMA_INSTALLER_URL..."

	try {
		Invoke-WebRequest -Uri $OLLAMA_INSTALLER_URL -OutFile $INSTALLER_PATH -UseBasicParsing
	} catch {
		Log-Info "Download failed: $_"
		Close-Writer; exit 1
	}

	Log-Info "Running silent installer..."
	try {
		$proc = Start-Process -FilePath $INSTALLER_PATH -ArgumentList "/S" -Wait -PassThru
		if ($proc.ExitCode -ne 0) {
			Log-Info "Installer exited with code $($proc.ExitCode)."
			Close-Writer; exit 1
		}
	} catch {
		Log-Info "Could not launch installer: $_"
		Close-Writer; exit 1
	} finally {
		Remove-Item $INSTALLER_PATH -ErrorAction SilentlyContinue
	}

	# Re-resolve PATH so the freshly installed binary is discoverable
	$env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
	            [System.Environment]::GetEnvironmentVariable("Path", "User")

	if (-not (Test-OllamaOnPath)) {
		Log-Info "Ollama installed but not found in PATH."
		Close-Writer; exit 1
	}

	Log-Info "Ollama installed successfully."
}




# ==========================================
# ==========================================
# ======= 3/ Server Lifecycle =======
# ==========================================
# ==========================================

if (Test-ServerAlive) {
	# Fast path: server already running — model pull still happens below
} else {
	Emit-Marker "OLLAMA_STARTING"
	Log-Info "Starting Ollama server in background..."

	try {
		$serverProc = Start-Process -FilePath "ollama" -ArgumentList "serve" `
			-WindowStyle Hidden -PassThru `
			-RedirectStandardOutput $UNIFIED_LOG -RedirectStandardError $UNIFIED_LOG
	} catch {
		try {
			$serverProc = Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden -PassThru
		} catch {
			Log-Info "Could not start ollama serve: $_"
			Close-Writer; exit 1
		}
	}

	if (-not (Wait-ForServer)) {
		Log-Info "Server did not respond within ${OLLAMA_READY_TIMEOUT}s."
		Close-Writer; exit 1
	}

	Emit-Marker "OLLAMA_READY"
	Log-Info "Server ready at http://localhost:11434."
}




# ======================================
# ======================================
# ======= 4/ Model Pull =======
# ======================================
# ======================================

if ($Model -ne "") {
	Log-Info "Checking model '$Model'..."

	try {
		$tags_resp = Invoke-WebRequest -Uri $OLLAMA_HEALTH_URL -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
		$tags_json = $tags_resp.Content
		if ($tags_json -match [regex]::Escape('"' + $Model.Split(':')[0])) {
			Log-Info "Model '$Model' already available."
			Close-Writer; exit 0
		}
	} catch {}

	Log-Info "Pulling model '$Model'..."

	try {
		& ollama pull $Model 2>&1 | ForEach-Object { Emit "$_" }
		if ($LASTEXITCODE -ne 0) {
			Log-Info "Model pull failed (exit code $LASTEXITCODE)."
			Close-Writer; exit 1
		}
	} catch {
		Log-Info "Error during model pull: $_"
		Close-Writer; exit 1
	}

	Log-Info "Model '$Model' ready."
}

Close-Writer
exit 0
