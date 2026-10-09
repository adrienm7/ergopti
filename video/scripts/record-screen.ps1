# video/scripts/record-screen.ps1
#
# Records the real-capture clips of the film on a Windows machine running the
# Ergopti+ driver: for each scenario of real/scenarios.json, opens Notepad,
# records the top-left of the screen while the scenario types, and encodes
# assets/real/<name>.mp4 with Remotion's bundled ffmpeg. Updates
# assets/real/clips.json. Nothing is cut: a prediction is accepted as soon as
# the driver shows it. Leave the keyboard and mouse alone while it runs.
#
# Notepad, because it exposes a Win32 caret: the driver anchors its tooltip
# exactly at the caret there, while a browser field only offers the field's
# box. Windows only: it records the Windows driver. The scenario never sends
# Ctrl, Alt or Shift combinations, because the driver's tap-holds own those
# keys and would turn an injected Ctrl into a tap (LCtrl tap = Paste).
#
# Usage: npm run capture:screen [-- -Only ai]

param([string[]]$Only = @())

$ErrorActionPreference = 'Stop'
$VideoRoot = Split-Path -Parent $PSScriptRoot
$RealDir = Join-Path $VideoRoot 'assets/real'
. (Join-Path $PSScriptRoot 'real/SendInput.ps1')
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
# UTF-8 JSON rather than a .ps1: Windows PowerShell reads BOM-less scripts
# as ANSI, which would mangle ★ and accents.
$Config = Get-Content (Join-Path $PSScriptRoot 'real/scenarios.json') -Raw -Encoding utf8 | ConvertFrom-Json
$Scenarios = $Config.scenarios
$Utf8 = New-Object System.Text.UTF8Encoding $false
$Seed = 1
# Clip seconds kept before typing starts and after it ends.
$LeadSeconds = 0.6
# Time the viewer gets to read a prediction before it is accepted.
$ReadPredictionMs = 900

# The driver's own log says when the first prediction is on screen; a fixed
# delay is not enough, because the backend's latency varies. The first one is
# acceptable at once; alternatives keep arriving after it (final_visible).
$PredictionTimeoutMs = 30000
$DriverLog = Join-Path $env:LOCALAPPDATA ("ergopti_plus\logs\ErgoptiPlus_{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))

function Wait-DemoPrediction([datetime]$Since) {
	$deadline = (Get-Date).AddMilliseconds($PredictionTimeoutMs)
	while ((Get-Date) -lt $deadline) {
		Start-Sleep -Milliseconds 250
		$stream = [IO.File]::Open($DriverLog, 'Open', 'Read', 'ReadWrite')
		try {
			$reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8)
			if ($stream.Length -gt 65536) { [void]$stream.Seek(-65536, 'End'); [void]$reader.ReadLine() }
			$lines = $reader.ReadToEnd() -split "`n"
		} finally { $stream.Dispose() }
		foreach ($line in $lines) {
			if ($line -match '^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d):(\d{3}) .*presentation: stage=first_visible') {
				$at = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', $null).AddMilliseconds([int]$Matches[2])
				if ($at -ge $Since) { return $at }
			}
		}
	}
	throw "No prediction was shown within $PredictionTimeoutMs ms; check the driver's AI backend"
}

function Invoke-DemoSteps($steps) {
	$lastTyped = Get-Date
	foreach ($step in $steps) {
		if ($null -ne $step.text) { Send-DemoText $step.text $step.delay ($script:Seed++); $lastTyped = Get-Date }
		elseif ($null -ne $step.key) { Send-DemoKey $step.key }
		elseif ($null -ne $step.wait) { Start-Sleep -Milliseconds $step.wait }
		elseif ($step.accept) {
			Wait-DemoPrediction $lastTyped | Out-Null
			Start-Sleep -Milliseconds $ReadPredictionMs
			Send-DemoAccept
			$lastTyped = Get-Date
		}
		else { throw "Unknown scenario step: $($step | ConvertTo-Json -Compress)" }
	}
}

function Open-DemoNotepad {
	# Never type into the user's own notes.
	if (Get-Process notepad -ErrorAction SilentlyContinue | Where-Object MainWindowHandle -ne 0) {
		throw 'Close Notepad before recording: the capture opens its own window'
	}
	Start-Process notepad | Out-Null
	$deadline = (Get-Date).AddSeconds(10)
	do {
		Start-Sleep -Milliseconds 250
		$proc = Get-Process notepad -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
	} until ($proc -or (Get-Date) -gt $deadline)
	if (-not $proc) { throw 'Notepad did not open a window' }
	[ErgoptiDemo.Keys]::ShowWindow($proc.MainWindowHandle, 3) | Out-Null
	[ErgoptiDemo.Keys]::SetForegroundWindow($proc.MainWindowHandle) | Out-Null
	Start-Sleep -Milliseconds 800
	[ErgoptiDemo.Keys]::Target = $proc.MainWindowHandle
	return $proc
}

# Closes the untitled tab through File > Close tab > Don't save, so Notepad's
# session restore keeps nothing; a closed last tab closes the window.
function Close-DemoNotepad($proc) {
	[ErgoptiDemo.Keys]::Target = [IntPtr]::Zero
	$A = [System.Windows.Automation.AutomationElement]
	$Scope = [System.Windows.Automation.TreeScope]::Descendants
	$ofType = { param($t) New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, $t) }
	$root = $A::FromHandle($proc.MainWindowHandle)
	$file = $root.FindAll($Scope, (& $ofType ([System.Windows.Automation.ControlType]::MenuItem))) |
		Where-Object { $_.Current.Name -match '^(Fichier|File)$' } | Select-Object -First 1
	if (-not $file) { throw 'Notepad File menu not found' }
	$file.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
	# The menu opens late while the driver is busy; look again until it shows.
	$deadline = (Get-Date).AddSeconds(5)
	do {
		Start-Sleep -Milliseconds 400
		$close = $A::RootElement.FindAll($Scope, (& $ofType ([System.Windows.Automation.ControlType]::MenuItem))) |
			Where-Object { $_.Current.ProcessId -eq $proc.Id -and $_.Current.Name -match 'Fermer l.onglet|Close tab' } | Select-Object -First 1
	} until ($close -or (Get-Date) -gt $deadline)
	if (-not $close) { throw 'Notepad Close tab command not found' }
	$close.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
	# The save prompt can take seconds to appear; keep looking until it does or
	# the window closes on its own.
	$deadline = (Get-Date).AddSeconds(8)
	do {
		Start-Sleep -Milliseconds 500
		$discard = $root.FindAll($Scope, (New-Object System.Windows.Automation.PropertyCondition($A::NameProperty, 'Ne pas enregistrer'))) | Select-Object -First 1
		if (-not $discard) {
			$discard = $root.FindAll($Scope, (New-Object System.Windows.Automation.PropertyCondition($A::NameProperty, "Don't save"))) | Select-Object -First 1
		}
	} until ($discard -or $proc.HasExited -or (Get-Date) -gt $deadline)
	if ($discard) { $discard.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() }
	if (-not $proc.WaitForExit(5000)) { throw 'Notepad did not close; close it without saving' }
}

New-Item -ItemType Directory -Force $RealDir | Out-Null
$clipsPath = Join-Path $RealDir 'clips.json'
$manifest = [IO.File]::ReadAllText($clipsPath) | ConvertFrom-Json
$clips = [System.Collections.ArrayList]@($manifest.clips | Where-Object { $_ })
$region = ($Config.region | ForEach-Object { [string]$_ }) -join ','

foreach ($scenario in $Scenarios) {
	$name = $scenario.name
	if ($Only.Count -gt 0 -and $Only -notcontains $name) { continue }
	$frames = Join-Path ([IO.Path]::GetTempPath()) "ergopti-capture-$name"
	if (Test-Path $frames) { Remove-Item -Recurse -Force $frames }
	$stop = "$frames.stop"
	if (Test-Path $stop) { Remove-Item -Force $stop }

	Write-Host "record-screen: $name"
	$notepad = Open-DemoNotepad
	$capture = Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList @(
		'-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'real/Capture.ps1'),
		'-OutDir', $frames, '-StopFile', $stop, '-Region', $region
	)
	Start-Sleep -Milliseconds ([int]($LeadSeconds * 1000) + 400)
	try {
		Invoke-DemoSteps $scenario.steps
	} finally {
		Start-Sleep -Milliseconds ([int]($LeadSeconds * 1000))
		New-Item -ItemType File $stop | Out-Null
		$capture.WaitForExit()
		Remove-Item -Force $stop
		Close-DemoNotepad $notepad
	}
	if ($capture.ExitCode -ne 0) { throw "Screen capture failed for $name" }

	$info = Get-Content (Join-Path $frames 'capture.json') -Raw | ConvertFrom-Json
	$mp4 = Join-Path $RealDir "$name.mp4"
	Push-Location $frames
	try {
		# Remotion's CLI through node, not npx: npx.cmd re-parses arguments with
		# cmd.exe, and Windows PowerShell splits a bare -c:v; a quoted array
		# straight to node avoids both.
		$ffmpegArgs = @((Join-Path $VideoRoot 'node_modules/@remotion/cli/remotion-cli.js'), 'ffmpeg', '-y', '-loglevel', 'error',
			'-f', 'concat', '-safe', '0', '-i', 'frames.ffconcat', '-r', '30', '-c:v', 'libx264', '-preset', 'slow',
			'-crf', '18', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', $mp4)
		& node @ffmpegArgs
		if ($LASTEXITCODE -ne 0) { throw "ffmpeg failed for $name" }
	} finally { Pop-Location }
	Remove-Item -Recurse -Force $frames

	$keep = @(, @(0.3, [Math]::Round($info.seconds - 0.2, 2)))
	$entry = [ordered]@{ file = "$name.mp4"; caption = $scenario.caption; segments = $keep }
	$existing = $clips | Where-Object { $_.file -eq $entry.file }
	if ($existing) { $clips.Remove($existing) }
	[void]$clips.Add([pscustomobject]$entry)
	$manifest.aspect = [Math]::Round($info.width / $info.height, 4)
	Write-Host ("record-screen: {0} - {1} frames, {2:N1} fps, {3:N1} s, {4} segment(s)" -f $mp4, $info.frames, $info.fps, $info.seconds, $keep.Count)
}

# Keep the scenario order of scenarios.json.
$ordered = foreach ($scenario in $Scenarios) { $clips | Where-Object { $_.file -eq "$($scenario.name).mp4" } }
$manifest.clips = @($ordered)
[IO.File]::WriteAllText($clipsPath, ((($manifest | ConvertTo-Json -Depth 5) -replace "`r`n", "`n") + "`n"), $Utf8)
# The repository's formatter owns JSON layout; PowerShell's is not it.
& node (Join-Path $VideoRoot '../node_modules/prettier/bin/prettier.cjs') --write --log-level warn $clipsPath
if ($LASTEXITCODE -ne 0) { throw 'Prettier could not format clips.json' }
