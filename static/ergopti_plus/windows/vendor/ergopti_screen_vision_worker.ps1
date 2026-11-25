# vendor/ergopti_screen_vision_worker.ps1

# ==============================================================================
# MODULE: Ergopti Screen Vision Worker
# DESCRIPTION:
# The long-lived Windows half of the screen vision service
# (docs/design/screen-vision.md, platform/system/vision/screen_vision.ahk): captures
# a window or a region, finds library images in it, reads its text with
# Windows.Media.Ocr, and converts imported images to the library's PNG.
#
# FEATURES & RATIONALE:
# 1. One process for the whole session: the C# matcher and capture code is
#    loaded once from ergopti_screen_vision.dll, which
#    tools/build/build_windows_screen_vision.ps1 compiles at build time from
#    native/ergopti_screen_vision_*.cs, and one OCR engine is created once, so
#    a 700 ms tick pays neither again. Nothing is compiled at run time: a
#    runtime compiler stage in the bundle is what antivirus engines score
#    (tools/ci/windows-exe-av-surface.json), so framework assemblies are
#    loaded by strong name as well.
# 2. A folder protocol: the driver writes <id>.req.json into a private queue
#    folder and reads <id>.res.json, each written beside and then renamed, so a
#    half-written file is never read; the driver's process runner has no stdin
#    stream to a running child.
# 3. The worker exits by itself when its parent is gone or the stop file
#    appears, so no capture process outlives the driver.
# 4. Physical pixels: the process is per-monitor DPI aware before any capture.
# 5. Private: captures for OCR are written inside the queue folder and removed
#    after reading; no recognised text is written anywhere but the answer.
# ==============================================================================

param(
	[Parameter(Mandatory = $true)][string]$QueueDir,
	[Parameter(Mandatory = $true)][int]$ParentPid,
	[Parameter(Mandatory = $true)][int]$PollMs
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$MaxRequestBytes = 1048576




# ===================================
# ===================================
# ======= 1/ Start ==================
# ===================================
# ===================================

function Write-Answer {
	param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)]$Answer)
	$Final = Join-Path $QueueDir $Name
	$Partial = $Final + ".partial"
	[System.IO.File]::WriteAllText($Partial, ($Answer | ConvertTo-Json -Depth 8 -Compress),
		(New-Object System.Text.UTF8Encoding($false)))
	Move-Item -LiteralPath $Partial -Destination $Final -Force
}

$Ready = @{ ok = $true; capture = @{ ok = $true }; ocr = @{ ok = $true } }
try {
	foreach ($Assembly in @(
			"System.Drawing, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a",
			"PresentationCore, Version=4.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35",
			"WindowsBase, Version=4.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35",
			"System.Xaml, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089")) {
		[void][System.Reflection.Assembly]::Load($Assembly)
	}
	[void][System.Reflection.Assembly]::LoadFrom((Join-Path $PSScriptRoot "ergopti_screen_vision.dll"))
	[void][Ergopti.ScreenVision.Capture]::DeclareDpiAware()
} catch {
	Write-Answer "ready.json" @{ ok = $false; reason = "capture_unavailable" }
	exit 1
}

$OcrEngine = $null
$AsTask = $null
try {
	[void][System.Reflection.Assembly]::Load(
		"System.Runtime.WindowsRuntime, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089")
	$null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
	$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics, ContentType = WindowsRuntime]
	$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
	$null = [Windows.Storage.Streams.IRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
	$null = [Windows.Globalization.Language, Windows.Globalization, ContentType = WindowsRuntime]
	$AsTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
		$_.Name -eq "AsTask" -and $_.GetParameters().Count -eq 1 -and
		$_.GetParameters()[0].ParameterType.Name -eq "IAsyncOperation``1"
	} | Select-Object -First 1
	$OcrEngine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
	if ($null -eq $OcrEngine) { $Ready.ocr = @{ ok = $false; reason = "ocr_language_missing" } }
} catch {
	$Ready.ocr = @{ ok = $false; reason = "ocr_engine_missing" }
}
Write-Answer "ready.json" $Ready




# ===================================
# ===================================
# ======= 2/ Operations =============
# ===================================
# ===================================

function Wait-Async {
	param($Operation, [Type]$Type)
	$Task = $AsTask.MakeGenericMethod($Type).Invoke($null, @($Operation))
	[void]$Task.Wait(-1)
	return $Task.Result
}

function Get-MatchOptions {
	param($Raw)
	$Options = New-Object Ergopti.ScreenVision.MatchOptions
	$Options.Threshold = [double]$Raw.threshold
	$Options.Scales = [double[]]@($Raw.scales)
	$Options.CoarseMinPx = [int]$Raw.coarse_min_px
	$Options.CoarseMargin = [double]$Raw.coarse_margin
	$Options.CoarseCandidates = [int]$Raw.coarse_candidates
	return $Options
}

function Get-Target {
	param($Request)
	if ($null -ne $Request.window_id) {
		$Frame = [Ergopti.ScreenVision.Capture]::WindowFrame([long]$Request.window_id)
		if ($null -eq $Frame) { return @{ reason = "no_foreground_window" } }
	} elseif ($null -ne $Request.rect) {
		$Frame = New-Object Ergopti.ScreenVision.Frame
		$Frame.X = [int]$Request.rect.x
		$Frame.Y = [int]$Request.rect.y
		$Frame.Width = [int]$Request.rect.width
		$Frame.Height = [int]$Request.rect.height
		if ($Frame.Width -le 0 -or $Frame.Height -le 0) { return @{ reason = "capture_empty" } }
	} else {
		return @{ reason = "invalid_request" }
	}
	$Bitmap = [Ergopti.ScreenVision.Capture]::Screen($Frame)
	return @{ frame = $Frame; bitmap = $Bitmap }
}

function ConvertTo-FrameAnswer {
	param($Frame)
	return @{ x = $Frame.X; y = $Frame.Y; width = $Frame.Width; height = $Frame.Height }
}

function Find-Templates {
	param($Gray, $Request)
	$Options = Get-MatchOptions $Request.options
	$Hits = @()
	$Refused = @{}
	foreach ($Template in @($Request.templates)) {
		if ($null -eq $Template) { continue }
		try {
			$TemplateGray = [Ergopti.ScreenVision.Capture]::LoadGray([string]$Template.path)
		} catch {
			$Refused[[string]$Template.id] = "template_unreadable"
			continue
		}
		$PerTemplate = Get-MatchOptions $Request.options
		if ($null -ne $Template.threshold) { $PerTemplate.Threshold = [double]$Template.threshold }
		$Uniform = $false
		$Hit = [Ergopti.ScreenVision.Matcher]::Find($Gray, $TemplateGray, $PerTemplate, [ref]$Uniform)
		if ($null -ne $Hit) {
			$Hits += @{ id = [string]$Template.id; x = $Hit.X; y = $Hit.Y; width = $Hit.Width; height = $Hit.Height
				score = $Hit.Score; scale = $Hit.Scale }
		} elseif ($Uniform) {
			$Refused[[string]$Template.id] = "template_uniform"
		}
	}
	return @{ hits = $Hits; refused = $Refused }
}

function Read-Text {
	param([string]$Path, $Ocr)
	if ($null -eq $OcrEngine) { return @{ reason = $Ready.ocr.reason } }
	$Engine = $OcrEngine
	if ($null -ne $Ocr -and $null -ne $Ocr.languages) {
		foreach ($Tag in @($Ocr.languages)) {
			$Language = New-Object Windows.Globalization.Language([string]$Tag)
			if ([Windows.Media.Ocr.OcrEngine]::IsLanguageSupported($Language)) {
				$Engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($Language)
				break
			}
		}
	}
	$File = Wait-Async ([Windows.Storage.StorageFile]::GetFileFromPathAsync($Path)) ([Windows.Storage.StorageFile])
	$Stream = Wait-Async ($File.OpenAsync([Windows.Storage.FileAccessMode]::Read)) `
		([Windows.Storage.Streams.IRandomAccessStream])
	try {
		$Decoder = Wait-Async ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($Stream)) `
			([Windows.Graphics.Imaging.BitmapDecoder])
		$Bitmap = Wait-Async ($Decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
		if ($Bitmap.PixelWidth -gt [Windows.Media.Ocr.OcrEngine]::MaxImageDimension -or
			$Bitmap.PixelHeight -gt [Windows.Media.Ocr.OcrEngine]::MaxImageDimension) {
			return @{ reason = "ocr_failed" }
		}
		$Result = Wait-Async ($Engine.RecognizeAsync($Bitmap)) ([Windows.Media.Ocr.OcrResult])
	} finally {
		$Stream.Dispose()
	}
	$Words = @()
	$LineIndex = 0
	foreach ($Line in $Result.Lines) {
		$LineIndex += 1
		foreach ($Word in $Line.Words) {
			$Box = $Word.BoundingRect
			$Words += @{ text = $Word.Text; x = [int][Math]::Round($Box.X); y = [int][Math]::Round($Box.Y)
				width = [int][Math]::Round($Box.Width); height = [int][Math]::Round($Box.Height)
				confidence = 1; line = [string]$LineIndex }
		}
	}
	return @{ words = $Words }
}

function Invoke-Request {
	param($Request, [string]$Id)
	switch ([string]$Request.op) {
		"availability" { return $Ready }
		"capture" {
			$Target = Get-Target $Request
			if ($null -ne $Target.reason) { return @{ ok = $false; reason = $Target.reason } }
			try {
				[Ergopti.ScreenVision.Capture]::WriteBitmapPng($Target.bitmap, [string]$Request.out_path)
			} finally { $Target.bitmap.Dispose() }
			return @{ ok = $true; frame = (ConvertTo-FrameAnswer $Target.frame); scale = 1
				width = $Target.frame.Width; height = $Target.frame.Height; source = [string]$Request.out_path }
		}
		"match" {
			$Gray = [Ergopti.ScreenVision.Capture]::LoadGray([string]$Request.source)
			$Found = Find-Templates $Gray $Request
			return @{ ok = $true; hits = $Found.hits; refused = $Found.refused; scale = 1 }
		}
		"ocr" {
			$Read = Read-Text ([string]$Request.source) $Request.ocr
			if ($null -ne $Read.reason) { return @{ ok = $false; reason = $Read.reason } }
			return @{ ok = $true; words = $Read.words }
		}
		"scan" {
			$Target = Get-Target $Request
			if ($null -ne $Target.reason) { return @{ ok = $false; reason = $Target.reason } }
			try {
				$Gray = [Ergopti.ScreenVision.Capture]::ToGray($Target.bitmap)
				$Found = Find-Templates $Gray $Request
				$Answer = @{ ok = $true; frame = (ConvertTo-FrameAnswer $Target.frame); scale = 1
					width = $Gray.Width; height = $Gray.Height; hits = $Found.hits; refused = $Found.refused }
				if ($null -ne $Request.ocr) {
					$Private = Join-Path $QueueDir ($Id + ".scan.png")
					try {
						[Ergopti.ScreenVision.Capture]::WriteBitmapPng($Target.bitmap, $Private)
						$Read = Read-Text $Private $Request.ocr
					} finally { Remove-Item -LiteralPath $Private -Force -ErrorAction SilentlyContinue }
					$Answer.words = if ($null -ne $Read.words) { $Read.words } else { @() }
					if ($null -ne $Read.reason) { $Answer.text_reason = $Read.reason }
				}
				return $Answer
			} finally { $Target.bitmap.Dispose() }
		}
		"import" {
			try {
				$Source = [Ergopti.ScreenVision.Capture]::Decode([string]$Request.path)
			} catch { return @{ ok = $false; reason = "import_unsupported_format" } }
			$Gray = [Ergopti.ScreenVision.Capture]::LoadGray([string]$Request.path)
			if ([Ergopti.ScreenVision.Matcher]::IsUniform($Gray)) { return @{ ok = $false; reason = "template_uniform" } }
			try {
				[Ergopti.ScreenVision.Capture]::WritePng($Source, [string]$Request.out_path)
			} catch { return @{ ok = $false; reason = "import_write_failed" } }
			return @{ ok = $true; width = $Source.PixelWidth; height = $Source.PixelHeight }
		}
		default { return @{ ok = $false; reason = "invalid_request" } }
	}
}




# ===================================
# ===================================
# ======= 3/ Loop ===================
# ===================================
# ===================================

$StopFile = Join-Path $QueueDir "stop"
while ($true) {
	if (Test-Path -LiteralPath $StopFile) { break }
	if ($null -eq (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)) { break }
	$Requests = @(Get-ChildItem -LiteralPath $QueueDir -Filter "*.req.json" -File | Sort-Object Name)
	foreach ($Entry in $Requests) {
		$Id = $Entry.Name.Substring(0, $Entry.Name.Length - ".req.json".Length)
		try {
			if ($Entry.Length -gt $MaxRequestBytes) { throw "request too large" }
			$Request = Get-Content -LiteralPath $Entry.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
			$Answer = Invoke-Request $Request $Id
		} catch {
			$Answer = @{ ok = $false; reason = "ocr_failed" }
		}
		Remove-Item -LiteralPath $Entry.FullName -Force -ErrorAction SilentlyContinue
		Write-Answer ($Id + ".res.json") $Answer
	}
	Start-Sleep -Milliseconds $PollMs
}
