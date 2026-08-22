[CmdletBinding()]
param(
	[ValidateSet("ensure", "verify", "print-path")]
	[string]$Action = "ensure"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Version = "v0.43.0"
$RepositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$CacheDirectory = Join-Path $RepositoryRoot ".rtk"
$CachePath = Join-Path $CacheDirectory "path"
$ManifestPath = Join-Path $PSScriptRoot "release.tsv"

function Test-RtkBinary {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Path,
		[switch]$RequirePinnedVersion
	)

	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
		return $false
	}

	try {
		$VersionOutput = @(& $Path --version 2>$null)
		$VersionExit = $LASTEXITCODE
		$VersionText = $VersionOutput | Select-Object -First 1
		if ($VersionExit -ne 0 -or $VersionText -notmatch '^rtk\s+') {
			return $false
		}
		if ($RequirePinnedVersion -and $VersionText -ne "rtk $($Version.TrimStart('v'))") {
			return $false
		}

		$GainOutput = @(& $Path gain --help 2>$null)
		$GainExit = $LASTEXITCODE
		$GainHelp = $GainOutput -join "`n"
		return $GainExit -eq 0 -and $GainHelp -match '(?i)token savings'
	}
	catch {
		return $false
	}
}

function Write-CachedPath {
	param([Parameter(Mandatory = $true)][string]$Path)

	[System.IO.Directory]::CreateDirectory($CacheDirectory) | Out-Null
	$TemporaryPath = Join-Path $CacheDirectory ("path." + [System.Guid]::NewGuid().ToString("N") + ".tmp")
	[System.IO.File]::WriteAllText(
		$TemporaryPath,
		([System.IO.Path]::GetFullPath($Path) + "`n"),
		[System.Text.UTF8Encoding]::new($false)
	)
	Move-Item -LiteralPath $TemporaryPath -Destination $CachePath -Force
}

function Find-RtkBinary {
	if (Test-Path -LiteralPath $CachePath -PathType Leaf) {
		$Cached = [System.IO.File]::ReadAllText($CachePath).Trim()
		if ($Cached -and (Test-RtkBinary -Path $Cached -RequirePinnedVersion)) {
			return [System.IO.Path]::GetFullPath($Cached)
		}
	}

	$Command = Get-Command rtk -CommandType Application -ErrorAction SilentlyContinue |
		Select-Object -First 1
	if ($null -ne $Command -and (Test-RtkBinary -Path $Command.Source -RequirePinnedVersion)) {
		Write-CachedPath -Path $Command.Source
		return [System.IO.Path]::GetFullPath($Command.Source)
	}

	$InstallBase = if ($env:LOCALAPPDATA) {
		Join-Path $env:LOCALAPPDATA "Programs\rtk"
	}
	else {
		Join-Path $HOME ".local\share\rtk"
	}
	$InstalledPath = Join-Path $InstallBase "$Version\rtk.exe"
	if (Test-RtkBinary -Path $InstalledPath -RequirePinnedVersion) {
		Write-CachedPath -Path $InstalledPath
		return [System.IO.Path]::GetFullPath($InstalledPath)
	}

	return $null
}

function Get-ReleaseRow {
	if (-not [System.Environment]::Is64BitOperatingSystem -or $env:PROCESSOR_ARCHITECTURE -notmatch '^(AMD64|x86_64)$') {
		throw "RTK $Version has no supported Windows asset for this architecture."
	}

	$Rows = Import-Csv -LiteralPath $ManifestPath -Delimiter "`t"
	$Matches = @($Rows | Where-Object {
		$_.version -eq $Version -and $_.os -eq "windows" -and $_.arch -eq "x86_64"
	})
	if ($Matches.Count -ne 1) {
		throw "The RTK release manifest must contain exactly one Windows x86_64 row."
	}
	return $Matches[0]
}

function Install-RtkBinary {
	if ($env:CI) {
		throw "RTK installation is disabled in CI."
	}

	$Row = Get-ReleaseRow
	$InstallBase = if ($env:LOCALAPPDATA) {
		Join-Path $env:LOCALAPPDATA "Programs\rtk"
	}
	else {
		Join-Path $HOME ".local\share\rtk"
	}
	$VersionDirectory = Join-Path $InstallBase $Version
	$Destination = Join-Path $VersionDirectory "rtk.exe"
	[System.IO.Directory]::CreateDirectory($VersionDirectory) | Out-Null

	$LockPath = Join-Path $VersionDirectory ".install.lock"
	try {
		$Lock = [System.IO.File]::Open(
			$LockPath,
			[System.IO.FileMode]::CreateNew,
			[System.IO.FileAccess]::Write,
			[System.IO.FileShare]::None
		)
	}
	catch {
		if (Test-RtkBinary -Path $Destination -RequirePinnedVersion) {
			return $Destination
		}
		throw "Another RTK installation owns $LockPath. Retry after it finishes."
	}

	$TemporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("rtk-" + [System.Guid]::NewGuid().ToString("N"))
	try {
		[System.IO.Directory]::CreateDirectory($TemporaryDirectory) | Out-Null
		$ArchivePath = Join-Path $TemporaryDirectory $Row.asset
		$Url = "https://github.com/rtk-ai/rtk/releases/download/$Version/$($Row.asset)"
		Invoke-WebRequest -Uri $Url -OutFile $ArchivePath -UseBasicParsing

		$ActualHash = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
		if ($ActualHash -ne $Row.sha256) {
			throw "RTK archive checksum mismatch for $($Row.asset)."
		}

		Add-Type -AssemblyName System.IO.Compression.FileSystem
		$Archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
		try {
			$Candidates = @($Archive.Entries | Where-Object { $_.Name -eq "rtk.exe" })
			if ($Candidates.Count -ne 1) {
				throw "The RTK archive must contain exactly one rtk.exe."
			}
			$Entry = $Candidates[0]
			$NormalizedName = $Entry.FullName.Replace('\', '/')
			if ($NormalizedName.StartsWith('/') -or $NormalizedName.Split('/') -contains '..') {
				throw "The RTK archive contains an unsafe executable path."
			}

			$CandidatePath = Join-Path $TemporaryDirectory "rtk.exe"
			$InputStream = $Entry.Open()
			$OutputStream = [System.IO.File]::Open(
				$CandidatePath,
				[System.IO.FileMode]::CreateNew,
				[System.IO.FileAccess]::Write,
				[System.IO.FileShare]::None
			)
			try {
				$InputStream.CopyTo($OutputStream)
			}
			finally {
				$OutputStream.Dispose()
				$InputStream.Dispose()
			}
		}
		finally {
			$Archive.Dispose()
		}

		if (-not (Test-RtkBinary -Path $CandidatePath -RequirePinnedVersion)) {
			throw "The downloaded executable is not Rust Token Killer $Version."
		}

		$AtomicPath = Join-Path $VersionDirectory ("rtk." + [System.Guid]::NewGuid().ToString("N") + ".tmp.exe")
		Copy-Item -LiteralPath $CandidatePath -Destination $AtomicPath
		Move-Item -LiteralPath $AtomicPath -Destination $Destination -Force
		return $Destination
	}
	finally {
		if ($null -ne $Lock) {
			$Lock.Dispose()
		}
		Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
		if (Test-Path -LiteralPath $TemporaryDirectory) {
			Remove-Item -LiteralPath $TemporaryDirectory -Recurse -Force
		}
	}
}

$Resolved = Find-RtkBinary
if ($Action -eq "verify") {
	if (-not $Resolved) {
		[Console]::Error.WriteLine("Rust Token Killer is unavailable or is the wrong rtk package.")
		exit 3
	}
	Write-Output $Resolved
	exit 0
}

if (-not $Resolved) {
	if ($env:CI) {
		exit 3
	}
	$Resolved = Install-RtkBinary
	Write-CachedPath -Path $Resolved
}

Write-Output $Resolved
