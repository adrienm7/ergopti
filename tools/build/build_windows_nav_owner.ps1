# tools/build/build_windows_nav_owner.ps1
<#
==============================================================================
MODULE: Windows Navigation Event Owner Builder
DESCRIPTION:
Builds and validates the x64 Windows DLL that owns navigation-key decisions at
the low-level keyboard boundary. The same entrypoint is used locally and in CI
so release packaging cannot bypass the native core test or PE contract checks.

FEATURES & RATIONALE:
1. Portable toolchain discovery: imports the x64 MSVC environment through
	vswhere instead of depending on an already-configured developer shell.
2. Hook-free test gate: links and runs the C core test as a console executable;
	the test never installs the low-level keyboard hook.
3. Toolchain-independent drift gate: validates the tracked DLL separately and
	binds it to the current production sources and canonical build recipe through
	a deterministic manifest fingerprint.
4. Release-safe output: an explicit -UpdateTracked is required to replace the
	tracked DLL and regenerate its manifest.
==============================================================================
#>

[CmdletBinding()]
param(
	[switch]$UpdateTracked
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"





# ======================================
# ======================================
# ======= 1/ Toolchain Discovery =======
# ======================================
# ======================================

<#
.SYNOPSIS
Imports an x64 MSVC command-line environment into the current process.
#>
function Import-MsvcEnvironment {
	$vswhereCandidates = @()
	if (${env:ProgramFiles(x86)}) {
		$vswhereCandidates += Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
	}
	if ($env:ProgramFiles) {
		$vswhereCandidates += Join-Path $env:ProgramFiles "Microsoft Visual Studio\Installer\vswhere.exe"
	}

	$vswherePath = $vswhereCandidates |
		Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
		Select-Object -First 1

	if (-not $vswherePath) {
		$existingCompiler = Get-Command "cl.exe" -ErrorAction SilentlyContinue
		$existingInspector = Get-Command "dumpbin.exe" -ErrorAction SilentlyContinue
		if ($existingCompiler -and $existingInspector) {
			Write-Host "[native] Using the MSVC environment already present on PATH."
			return
		}
		throw "vswhere.exe was not found and MSVC is not available on PATH. Install the Visual C++ x64 build tools."
	}

	$installationPaths = @(& $vswherePath -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)
	$vswhereExitCode = $LASTEXITCODE
	$installationPath = $installationPaths |
		Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } |
		Select-Object -First 1
	if ($vswhereExitCode -ne 0 -or -not $installationPath) {
		throw "vswhere.exe could not locate a Visual Studio installation with the Visual C++ x64 build tools."
	}

	$vcVarsPath = Join-Path $installationPath "VC\Auxiliary\Build\vcvars64.bat"
	if (-not (Test-Path -LiteralPath $vcVarsPath -PathType Leaf)) {
		throw "The x64 MSVC environment script is missing: $vcVarsPath"
	}

	$environmentLines = @(& $env:ComSpec /d /s /c "`"$vcVarsPath`" >nul && set")
	if ($LASTEXITCODE -ne 0) {
		throw "vcvars64.bat failed with exit code $LASTEXITCODE."
	}
	foreach ($line in $environmentLines) {
		if ($line -notmatch "^([^=]+)=(.*)$") {
			continue
		}
		[Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], [EnvironmentVariableTarget]::Process)
	}

	if (-not (Get-Command "cl.exe" -ErrorAction SilentlyContinue)) {
		throw "vcvars64.bat completed but cl.exe is still unavailable."
	}
	if (-not (Get-Command "dumpbin.exe" -ErrorAction SilentlyContinue)) {
		throw "vcvars64.bat completed but dumpbin.exe is still unavailable."
	}
	Write-Host "[native] Imported the x64 MSVC environment from $installationPath."
}





# ====================================
# ====================================
# ======= 2/ Process Execution =======
# ====================================
# ====================================

<#
.SYNOPSIS
Runs a native command and fails immediately when it returns a non-zero status.
#>
function Invoke-CheckedNative {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Label,

		[Parameter(Mandatory = $true)]
		[string]$Executable,

		[Parameter(Mandatory = $true)]
		[AllowEmptyCollection()]
		[string[]]$Arguments
	)

	Write-Host "[native] $Label..."
	& $Executable @Arguments
	$exitCode = $LASTEXITCODE
	if ($exitCode -ne 0) {
		throw "$Label failed with exit code $exitCode."
	}
	Write-Host "[native] $Label completed."
}





# ================================
# ================================
# ======= 3/ PE Validation =======
# ================================
# ================================

<#
.SYNOPSIS
Reads the PE fields needed to validate the release DLL contract.
#>
function Get-PeMetadata {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Path
	)

	$stream = [System.IO.File]::OpenRead($Path)
	$reader = New-Object System.IO.BinaryReader($stream)
	try {
		if ($stream.Length -lt 64) {
			throw "The native output is too small to be a PE file: $Path"
		}

		[void]$stream.Seek(0x3c, [System.IO.SeekOrigin]::Begin)
		$peOffset = $reader.ReadInt32()
		if ($peOffset -lt 0 -or ($peOffset + 96) -gt $stream.Length) {
			throw "The native output has an invalid PE header offset: $Path"
		}

		[void]$stream.Seek($peOffset, [System.IO.SeekOrigin]::Begin)
		$signature = $reader.ReadUInt32()
		if ($signature -ne 0x00004550) {
			throw "The native output does not contain a PE signature: $Path"
		}

		$machine = $reader.ReadUInt16()
		[void]$stream.Seek($peOffset + 22, [System.IO.SeekOrigin]::Begin)
		$coffCharacteristics = $reader.ReadUInt16()
		[void]$stream.Seek($peOffset + 24, [System.IO.SeekOrigin]::Begin)
		$optionalMagic = $reader.ReadUInt16()
		[void]$stream.Seek($peOffset + 24 + 70, [System.IO.SeekOrigin]::Begin)
		$dllCharacteristics = $reader.ReadUInt16()

		return [PSCustomObject]@{
			Machine = $machine
			CoffCharacteristics = $coffCharacteristics
			OptionalMagic = $optionalMagic
			DllCharacteristics = $dllCharacteristics
		}
	}
	finally {
		$reader.Dispose()
		$stream.Dispose()
	}
}

<#
.SYNOPSIS
Asserts that the output is an x64 DLL with ASLR, DEP, and CFG enabled.
#>
function Assert-PeContract {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Path
	)

	$metadata = Get-PeMetadata -Path $Path
	if ($metadata.Machine -ne 0x8664) {
		throw ("Expected an x64 PE machine value (8664), found {0:X4}." -f $metadata.Machine)
	}
	if ($metadata.OptionalMagic -ne 0x020b) {
		throw ("Expected a PE32+ optional header (020B), found {0:X4}." -f $metadata.OptionalMagic)
	}
	if (($metadata.CoffCharacteristics -band 0x2000) -ne 0x2000) {
		throw "The native output is not marked as a DLL."
	}

	$requiredMitigations = @(
		@{ Name = "ASLR (/DYNAMICBASE)"; Flag = 0x0040 },
		@{ Name = "DEP (/NXCOMPAT)"; Flag = 0x0100 },
		@{ Name = "Control Flow Guard (/guard:cf)"; Flag = 0x4000 }
	)
	foreach ($mitigation in $requiredMitigations) {
		if (($metadata.DllCharacteristics -band $mitigation.Flag) -ne $mitigation.Flag) {
			throw "The native output is missing $($mitigation.Name)."
		}
	}
	Write-Host "[native] PE contract verified: x64 DLL with ASLR, DEP, and CFG."
}

<#
.SYNOPSIS
Returns the public symbols declared by a module-definition file.
#>
function Get-DefinitionExports {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Path
	)

	$exports = New-Object System.Collections.Generic.List[string]
	$insideExports = $false
	foreach ($rawLine in Get-Content -LiteralPath $Path -Encoding UTF8) {
		$line = ($rawLine -replace ";.*$", "").Trim()
		if (-not $line) {
			continue
		}
		if ($line -match "^(?i:EXPORTS)\s*(.*)$") {
			$insideExports = $true
			$line = $Matches[1].Trim()
			if (-not $line) {
				continue
			}
		}
		if (-not $insideExports) {
			continue
		}
		if ($line -match "^(?i:LIBRARY|DESCRIPTION|SECTIONS|VERSION)\b") {
			break
		}

		$token = ($line -split "\s+", 2)[0]
		$name = ($token -split "=", 2)[0]
		if ($name) {
			$exports.Add($name)
		}
	}
	return @($exports | Sort-Object -Unique)
}

<#
.SYNOPSIS
Asserts that the DLL exports exactly the stable C ABI declared in its DEF file.
#>
function Assert-ExportContract {
	param(
		[Parameter(Mandatory = $true)]
		[string]$DllPath,

		[Parameter(Mandatory = $true)]
		[string]$DefinitionPath
	)

	$expectedExports = @(Get-DefinitionExports -Path $DefinitionPath)
	if ($expectedExports.Count -eq 0) {
		throw "The module-definition file declares no exports: $DefinitionPath"
	}

	$dumpbinOutput = @(& dumpbin.exe /nologo /exports $DllPath 2>&1)
	if ($LASTEXITCODE -ne 0) {
		throw "dumpbin.exe could not inspect exports for $DllPath."
	}
	$actualExports = @(
		$dumpbinOutput |
			ForEach-Object {
				if ($_ -match "^\s+\d+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]+\s+(\S+)\s*$") {
					$Matches[1]
				}
			} |
			Sort-Object -Unique
	)

	$differences = @(Compare-Object -ReferenceObject $expectedExports -DifferenceObject $actualExports -CaseSensitive)
	if ($differences.Count -ne 0) {
		$summary = ($differences | ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" }) -join ", "
		throw "The DLL export table does not match nav_event_owner.def: $summary"
	}
	Write-Host "[native] Export contract verified ($($expectedExports.Count) symbol(s))."
}

<#
.SYNOPSIS
Rejects dynamic C/C++ runtime dependencies that would make deployment incomplete.
#>
function Assert-DependencyContract {
	param(
		[Parameter(Mandatory = $true)]
		[string]$DllPath
	)

	$dumpbinOutput = @(& dumpbin.exe /nologo /dependents $DllPath 2>&1)
	if ($LASTEXITCODE -ne 0) {
		throw "dumpbin.exe could not inspect dependencies for $DllPath."
	}
	$forbiddenPattern = "(?i)\b(?:vcruntime\d*|msvcp\d*|msvcr\d*|ucrtbase|libgcc_s[^\\\s]*|libstdc\+\+[^\\\s]*)\.dll\b"
	$forbiddenDependencies = @(
		[regex]::Matches(($dumpbinOutput -join "`n"), $forbiddenPattern) |
			ForEach-Object { $_.Value } |
			Sort-Object -Unique
	)
	if ($forbiddenDependencies.Count -ne 0) {
		throw "The DLL depends on a dynamic compiler runtime despite /MT: $($forbiddenDependencies -join ', ')"
	}
	Write-Host "[native] Dependency contract verified: no dynamic compiler runtime."
}





# ======================================
# ======================================
# ======= 4/ Artifact Provenance =======
# ======================================
# ======================================

<#
.SYNOPSIS
Resolves stable recipe placeholders to machine-local paths.
#>
function Resolve-RecipeArguments {
	param(
		[Parameter(Mandatory = $true)]
		[string[]]$Arguments,

		[Parameter(Mandatory = $true)]
		[string]$SourceDirectory,

		[Parameter(Mandatory = $true)]
		[string]$BuildDirectory
	)

	return @(
		$Arguments |
			ForEach-Object {
				$_.Replace("{source_dir}", $SourceDirectory).Replace(
					"{build_dir}", $BuildDirectory)
			}
	)
}

<#
.SYNOPSIS
Hashes one UTF-8 text input after deterministic line-ending normalization.
#>
function Get-CanonicalTextSha256 {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Path
	)

	$strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
	$text = [System.IO.File]::ReadAllText($Path, $strictUtf8)
	$normalizedText = $text.Replace("`r`n", "`n").Replace("`r", "`n")
	$payload = $strictUtf8.GetBytes($normalizedText)
	$sha256 = [System.Security.Cryptography.SHA256]::Create()
	try {
		$hashBytes = $sha256.ComputeHash($payload)
		return ([System.BitConverter]::ToString($hashBytes)).Replace("-", "")
	}
	finally {
		$sha256.Dispose()
	}
}

<#
.SYNOPSIS
Hashes ordered build inputs and the exact canonical DLL recipe.
#>
function Get-SourceRecipeFingerprint {
	param(
		[Parameter(Mandatory = $true)]
		[string]$RepoRoot,

		[Parameter(Mandatory = $true)]
		[string[]]$FingerprintFiles,

		[Parameter(Mandatory = $true)]
		[string]$RecipeExecutable,

		[Parameter(Mandatory = $true)]
		[string[]]$RecipeArguments
	)

	$lines = New-Object System.Collections.Generic.List[string]
	[void]$lines.Add("ergopti-nav-owner-source-recipe-v1")
	for ($index = 0; $index -lt $FingerprintFiles.Count; ++$index) {
		$relativePath = $FingerprintFiles[$index]
		if ($relativePath.Contains("\")) {
			throw "Fingerprint source paths must use forward slashes: $relativePath"
		}
		$sourceFilePath = Join-Path $RepoRoot $relativePath.Replace("/", "\")
		if (-not (Test-Path -LiteralPath $sourceFilePath -PathType Leaf)) {
			throw "Fingerprint source is missing: $sourceFilePath"
		}
		$sourceHash = Get-CanonicalTextSha256 -Path $sourceFilePath
		[void]$lines.Add("input[$index].path=$relativePath")
		[void]$lines.Add("input[$index].sha256=$sourceHash")
	}
	[void]$lines.Add("recipe.executable=$RecipeExecutable")
	for ($index = 0; $index -lt $RecipeArguments.Count; ++$index) {
		[void]$lines.Add("recipe.argument[$index]=$($RecipeArguments[$index])")
	}

	$payload = [System.Text.Encoding]::UTF8.GetBytes(($lines -join "`n") + "`n")
	$sha256 = [System.Security.Cryptography.SHA256]::Create()
	try {
		$hashBytes = $sha256.ComputeHash($payload)
		return ([System.BitConverter]::ToString($hashBytes)).Replace("-", "")
	}
	finally {
		$sha256.Dispose()
	}
}

<#
.SYNOPSIS
Asserts that an ordered JSON string array matches its canonical recipe value.
#>
function Assert-StringArrayContract {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Label,

		[Parameter(Mandatory = $true)]
		[AllowEmptyCollection()]
		[object[]]$Actual,

		[Parameter(Mandatory = $true)]
		[AllowEmptyCollection()]
		[string[]]$Expected
	)

	if ($Actual.Count -ne $Expected.Count) {
		throw "$Label count changed: expected $($Expected.Count), found $($Actual.Count)."
	}
	for ($index = 0; $index -lt $Expected.Count; ++$index) {
		if ([string]$Actual[$index] -cne $Expected[$index]) {
			throw "$Label entry $index changed: expected '$($Expected[$index])', found '$($Actual[$index])'."
		}
	}
}

<#
.SYNOPSIS
Writes the deterministic provenance manifest for the tracked DLL.
#>
function Write-TrackedManifest {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Path,

		[Parameter(Mandatory = $true)]
		[int]$SchemaVersion,

		[Parameter(Mandatory = $true)]
		[string]$ArtifactPath,

		[Parameter(Mandatory = $true)]
		[string]$SourceFingerprint,

		[Parameter(Mandatory = $true)]
		[string]$DllHash,

		[Parameter(Mandatory = $true)]
		[string[]]$FingerprintFiles,

		[Parameter(Mandatory = $true)]
		[string]$RecipeExecutable,

		[Parameter(Mandatory = $true)]
		[string[]]$RecipeArguments
	)

	$manifest = [ordered]@{
		schema_version = $SchemaVersion
		artifact_path = $ArtifactPath
		source_fingerprint_sha256 = $SourceFingerprint
		dll_sha256 = $DllHash
		fingerprint_files = @($FingerprintFiles)
		build_recipe = [ordered]@{
			executable = $RecipeExecutable
			arguments = @($RecipeArguments)
		}
	}
	$json = ($manifest | ConvertTo-Json -Depth 5) -replace "`r`n", "`n"
	[System.IO.File]::WriteAllText(
		$Path,
		$json + "`n",
		[System.Text.UTF8Encoding]::new($false))
	Write-Host "[native] Updated tracked provenance manifest: $Path"
}

<#
.SYNOPSIS
Validates the tracked manifest against current sources, recipe, and DLL bytes.
#>
function Assert-TrackedManifest {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Path,

		[Parameter(Mandatory = $true)]
		[int]$SchemaVersion,

		[Parameter(Mandatory = $true)]
		[string]$DllPath,

		[Parameter(Mandatory = $true)]
		[string]$ArtifactPath,

		[Parameter(Mandatory = $true)]
		[string]$ExpectedSourceFingerprint,

		[Parameter(Mandatory = $true)]
		[string[]]$ExpectedFingerprintFiles,

		[Parameter(Mandatory = $true)]
		[string]$ExpectedRecipeExecutable,

		[Parameter(Mandatory = $true)]
		[string[]]$ExpectedRecipeArguments
	)

	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
		throw "The tracked provenance manifest is missing. Re-run with -UpdateTracked after reviewing the native changes."
	}
	try {
		$manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $Path | ConvertFrom-Json
	}
	catch {
		throw "The tracked provenance manifest is invalid JSON: $Path ($($_.Exception.Message))"
	}
	if ($null -eq $manifest) {
		throw "The tracked provenance manifest must contain a JSON object: $Path"
	}

	$requiredProperties = @(
		"schema_version",
		"artifact_path",
		"source_fingerprint_sha256",
		"dll_sha256",
		"fingerprint_files",
		"build_recipe"
	)
	$propertyNames = @($manifest.PSObject.Properties.Name)
	foreach ($propertyName in $requiredProperties) {
		if ($propertyNames -notcontains $propertyName) {
			throw "The tracked provenance manifest is missing '$propertyName'."
		}
	}
	if ($manifest.schema_version -ne $SchemaVersion) {
		throw "The tracked provenance manifest schema changed: expected $SchemaVersion, found $($manifest.schema_version)."
	}
	if ([string]$manifest.artifact_path -cne $ArtifactPath) {
		throw "The tracked provenance manifest names the wrong artifact: $($manifest.artifact_path)"
	}

	$manifestFingerprint = [string]$manifest.source_fingerprint_sha256
	if ($manifestFingerprint -cnotmatch "^[0-9A-F]{64}$") {
		throw "The tracked provenance manifest contains a non-canonical source fingerprint."
	}
	if ($manifestFingerprint -cne $ExpectedSourceFingerprint) {
		throw "The tracked vendor DLL source or build recipe is stale. Re-run with -UpdateTracked after reviewing the native changes."
	}
	Assert-StringArrayContract -Label "Manifest fingerprint file" -Actual @($manifest.fingerprint_files) -Expected $ExpectedFingerprintFiles

	$recipeProperties = @($manifest.build_recipe.PSObject.Properties.Name)
	if ($recipeProperties -notcontains "executable" -or $recipeProperties -notcontains "arguments") {
		throw "The tracked provenance manifest contains an incomplete build recipe."
	}
	if ([string]$manifest.build_recipe.executable -cne $ExpectedRecipeExecutable) {
		throw "The tracked provenance manifest names the wrong recipe executable."
	}
	Assert-StringArrayContract -Label "Manifest recipe argument" -Actual @($manifest.build_recipe.arguments) -Expected $ExpectedRecipeArguments

	$manifestDllHash = [string]$manifest.dll_sha256
	if ($manifestDllHash -cnotmatch "^[0-9A-F]{64}$") {
		throw "The tracked provenance manifest contains a non-canonical DLL hash."
	}
	$actualDllHash = (Get-FileHash -LiteralPath $DllPath -Algorithm SHA256).Hash
	if ($manifestDllHash -cne $actualDllHash) {
		throw "The tracked vendor DLL does not match its provenance manifest. Re-run with -UpdateTracked after reviewing the artifact."
	}
	Write-Host "[native] Provenance contract verified (source/recipe $manifestFingerprint, DLL $actualDllHash)."
}





# =================================
# =================================
# ======= 5/ Build Pipeline =======
# =================================
# =================================

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$sourceDir = Join-Path $repoRoot "static\ergopti_plus\windows\native\nav_event_owner"
$buildDir = Join-Path $repoRoot "static\ergopti_plus\windows\build\native\nav_event_owner"
$vendorDir = Join-Path $repoRoot "static\ergopti_plus\windows\vendor"
$sourcePath = Join-Path $sourceDir "nav_event_owner.c"
$headerPath = Join-Path $sourceDir "nav_event_owner.h"
$definitionPath = Join-Path $sourceDir "nav_event_owner.def"
$testSourcePath = Join-Path $sourceDir "nav_event_owner_test.c"
$cmakePath = Join-Path $sourceDir "CMakeLists.txt"
$testExePath = Join-Path $buildDir "ergopti_nav_event_owner_test.exe"
$buildDllPath = Join-Path $buildDir "ergopti_nav_owner.dll"
$vendorDllPath = Join-Path $vendorDir "ergopti_nav_owner.dll"
$manifestPath = Join-Path $vendorDir "ergopti_nav_owner.manifest.json"
$manifestSchemaVersion = 1
$vendorDllRelativePath = "static/ergopti_plus/windows/vendor/ergopti_nav_owner.dll"
$buildScriptRelativePath = "tools/build/build_windows_nav_owner.ps1"

foreach ($requiredSource in @($sourcePath, $headerPath, $definitionPath, $testSourcePath, $cmakePath)) {
	if (-not (Test-Path -LiteralPath $requiredSource -PathType Leaf)) {
		throw "Required native source is missing: $requiredSource"
	}
}
$fingerprintFiles = @(
	Get-ChildItem -LiteralPath $sourceDir -File |
		Where-Object {
			$_.Extension -cin @(".c", ".h", ".def") -or
			$_.Name -ceq "CMakeLists.txt"
		} |
		ForEach-Object {
			$_.FullName.Substring($repoRoot.Length + 1).Replace("\", "/")
		}
	$buildScriptRelativePath
) | Sort-Object -Unique

$commonCompilerRecipeFlags = @(
	"/nologo",
	"/Brepro",
	"/TC",
	"/std:c11",
	"/W4",
	"/WX",
	# MSVC 19.29 reports C5105 inside Windows SDK 19041 under /std:c11
	"/wd5105",
	"/O2",
	"/MT",
	"/guard:cf",
	"/I{source_dir}"
)
$commonLinkerRecipeFlags = @(
	"/Brepro",
	"/MACHINE:X64",
	"/DYNAMICBASE",
	"/NXCOMPAT",
	"/guard:cf",
	"user32.lib"
)
$dllRecipeArguments = $commonCompilerRecipeFlags + @(
	"/LD",
	"{source_dir}\nav_event_owner.c",
	"/link",
	"/DEF:{source_dir}\nav_event_owner.def",
	"/OUT:{build_dir}\ergopti_nav_owner.dll",
	"/IMPLIB:{build_dir}\ergopti_nav_owner.lib"
) + $commonLinkerRecipeFlags
$commonCompilerFlags = Resolve-RecipeArguments `
	-Arguments $commonCompilerRecipeFlags `
	-SourceDirectory $sourceDir `
	-BuildDirectory $buildDir
$commonLinkerFlags = Resolve-RecipeArguments `
	-Arguments $commonLinkerRecipeFlags `
	-SourceDirectory $sourceDir `
	-BuildDirectory $buildDir
$dllArguments = Resolve-RecipeArguments `
	-Arguments $dllRecipeArguments `
	-SourceDirectory $sourceDir `
	-BuildDirectory $buildDir
$sourceFingerprintBeforeBuild = Get-SourceRecipeFingerprint `
	-RepoRoot $repoRoot `
	-FingerprintFiles $fingerprintFiles `
	-RecipeExecutable "cl.exe" `
	-RecipeArguments $dllRecipeArguments

Import-MsvcEnvironment
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
New-Item -ItemType Directory -Force -Path $vendorDir | Out-Null

Push-Location $buildDir
try {
	$testArguments = $commonCompilerFlags + @(
		"/DERGOPTI_NAV_TESTING=1",
		$testSourcePath,
		$sourcePath,
		"/Fe:$testExePath",
		"/link"
	) + $commonLinkerFlags
	Invoke-CheckedNative -Label "Compiling the hook-free native core test" -Executable "cl.exe" -Arguments $testArguments
	Invoke-CheckedNative -Label "Running the hook-free native core test" -Executable $testExePath -Arguments @()

	Invoke-CheckedNative -Label "Compiling the x64 navigation event owner DLL" -Executable "cl.exe" -Arguments $dllArguments
}
finally {
	Pop-Location
}

$sourceFingerprint = Get-SourceRecipeFingerprint `
	-RepoRoot $repoRoot `
	-FingerprintFiles $fingerprintFiles `
	-RecipeExecutable "cl.exe" `
	-RecipeArguments $dllRecipeArguments
if ($sourceFingerprint -cne $sourceFingerprintBeforeBuild) {
	throw "Native source changed while the gate was building. Re-run against a stable worktree snapshot."
}

Write-Host "[native] Validating the current-toolchain build output..."
Assert-PeContract -Path $buildDllPath
Assert-ExportContract -DllPath $buildDllPath -DefinitionPath $definitionPath
Assert-DependencyContract -DllPath $buildDllPath

$builtHash = (Get-FileHash -LiteralPath $buildDllPath -Algorithm SHA256).Hash
if ($UpdateTracked) {
	Copy-Item -LiteralPath $buildDllPath -Destination $vendorDllPath -Force
	$publishedHash = (Get-FileHash -LiteralPath $vendorDllPath -Algorithm SHA256).Hash
	if ($builtHash -cne $publishedHash) {
		throw "The updated vendor DLL does not match the validated build output."
	}
} elseif (-not (Test-Path -LiteralPath $vendorDllPath -PathType Leaf)) {
	throw "The tracked vendor DLL is missing. Re-run with -UpdateTracked after reviewing the native changes."
}

Write-Host "[native] Validating the tracked vendor DLL..."
Assert-PeContract -Path $vendorDllPath
Assert-ExportContract -DllPath $vendorDllPath -DefinitionPath $definitionPath
Assert-DependencyContract -DllPath $vendorDllPath
$publishedHash = (Get-FileHash -LiteralPath $vendorDllPath -Algorithm SHA256).Hash

if ($UpdateTracked) {
	Write-TrackedManifest `
		-Path $manifestPath `
		-SchemaVersion $manifestSchemaVersion `
		-ArtifactPath $vendorDllRelativePath `
		-SourceFingerprint $sourceFingerprint `
		-DllHash $publishedHash `
		-FingerprintFiles $fingerprintFiles `
		-RecipeExecutable "cl.exe" `
		-RecipeArguments $dllRecipeArguments
}
Assert-TrackedManifest `
	-Path $manifestPath `
	-SchemaVersion $manifestSchemaVersion `
	-DllPath $vendorDllPath `
	-ArtifactPath $vendorDllRelativePath `
	-ExpectedSourceFingerprint $sourceFingerprint `
	-ExpectedFingerprintFiles $fingerprintFiles `
	-ExpectedRecipeExecutable "cl.exe" `
	-ExpectedRecipeArguments $dllRecipeArguments
$sourceFingerprintAfterValidation = Get-SourceRecipeFingerprint `
	-RepoRoot $repoRoot `
	-FingerprintFiles $fingerprintFiles `
	-RecipeExecutable "cl.exe" `
	-RecipeArguments $dllRecipeArguments
if ($sourceFingerprintAfterValidation -cne $sourceFingerprint) {
	throw "Native source changed while the gate was validating artifacts. Re-run against a stable worktree snapshot."
}

$publishedSize = (Get-Item -LiteralPath $vendorDllPath).Length
$verb = "Verified"
if ($UpdateTracked) {
	$verb = "Updated"
}
Write-Host "[native] $verb $vendorDllPath ($publishedSize bytes, SHA-256 $publishedHash)."
