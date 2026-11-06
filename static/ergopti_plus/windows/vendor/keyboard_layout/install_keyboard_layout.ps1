# vendor/keyboard_layout/install_keyboard_layout.ps1
<#
==============================================================================
MODULE: Ergopti System Layout Installer (Windows, elevated)
DESCRIPTION:
Installs or removes the Ergopti keyboard layout DLL as a Windows system
layout: the DLL builds into System32 (and the 32-bit build into SysWOW64 of a
64-bit Windows) and its entry under
HKLM\SYSTEM\CurrentControlSet\Control\Keyboard Layouts. It must run elevated:
the driver starts it through UAC (modules/keymap/system_layout_install.ahk)
and the release package's install.cmd does the same. Adding the layout to a
user's language list is not done here: an elevated process may be another
account, so the driver adds it for its own user once this succeeds.

FEATURES & RATIONALE:
1. The KLID is the one already naming the DLL, or the first free A0nn<language>
	(the MSKLC convention, which never collides with Windows' own layouts);
	"Layout Id" is one past the highest in use, as Windows needs a unique one
	for a layout with a custom KLID.
2. A DLL in use by a running process cannot be overwritten but can be renamed:
	the old file is moved aside and deleted at the next restart.
3. Fail fast: every outcome is written to -ResultPath as JSON
	({ status, klid, message }) and a failure exits 1; nothing is reported as
	installed unless every file and registry value is in place.
==============================================================================
#>

[CmdletBinding()]
param(
	[Parameter(Mandatory = $true)][ValidateSet("install", "uninstall")][string]$Action,
	[Parameter(Mandatory = $true)][string]$SpecPath,
	[Parameter(Mandatory = $true)][string]$SourceDirectory,
	[Parameter(Mandatory = $true)][string]$ResultPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$LayoutsKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layouts"
$ArchitectureKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment"
# The registry Layout Display Name reads string 1000 of the DLL's resources
# (tools/codegen/lib/windows-keyboard-layout.cjs writes it).
$DisplayNameResource = 1000





# ==================================
# ==================================
# ======= 1/ Helpers ===============
# ==================================
# ==================================

<#
.SYNOPSIS
Writes the outcome the driver reads.
#>
function Write-Outcome {
	param([string]$Status, [string]$Klid, [string]$Message)
	$json = [ordered]@{ status = $Status; klid = $Klid; message = $Message } | ConvertTo-Json -Compress
	[IO.File]::WriteAllText($ResultPath, $json, [Text.UTF8Encoding]::new($false))
}

Add-Type -Namespace ErgoptiLayout -Name Native -MemberDefinition @'
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern bool MoveFileEx(string existing, string replacement, int flags);
'@

<#
.SYNOPSIS
Moves an existing DLL aside (deleted at the next restart) so the new one can
take its name even while processes hold it.
#>
function Move-Aside {
	param([string]$Path)
	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
	$aside = "$Path.$([Guid]::NewGuid().ToString('N')).old"
	Move-Item -LiteralPath $Path -Destination $aside
	# MOVEFILE_DELAY_UNTIL_REBOOT with no replacement deletes it at restart.
	if (-not [ErgoptiLayout.Native]::MoveFileEx($aside, $null, 4)) {
		throw "The previous $Path was moved to $aside but its deletion at restart could not be scheduled (Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))."
	}
}

<#
.SYNOPSIS
The registry keys whose Layout File is the DLL.
#>
function Get-OwnLayoutKeys {
	param([string]$DllFile)
	return @(Get-ChildItem -LiteralPath $LayoutsKey | Where-Object {
			$file = (Get-ItemProperty -LiteralPath $_.PSPath -Name "Layout File" -ErrorAction Ignore)
			$file -and ([string]$file."Layout File") -ieq $DllFile
		})
}

<#
.SYNOPSIS
The first free KLID A0nn<language>.
#>
function Get-FreeKlid {
	param([string]$LanguageId)
	for ($index = 0; $index -le 0xFFF; $index++) {
		$klid = "A{0:X3}{1}" -f $index, $LanguageId
		if (-not (Test-Path -LiteralPath (Join-Path $LayoutsKey $klid))) { return $klid }
	}
	throw "No free keyboard layout id is left for language $LanguageId."
}

<#
.SYNOPSIS
One past the highest Layout Id in use, as four hex digits.
#>
function Get-FreeLayoutId {
	$highest = 0
	foreach ($key in Get-ChildItem -LiteralPath $LayoutsKey) {
		$value = Get-ItemProperty -LiteralPath $key.PSPath -Name "Layout Id" -ErrorAction Ignore
		if ($value) {
			$parsed = 0
			if ([int]::TryParse([string]$value."Layout Id", [Globalization.NumberStyles]::HexNumber, $null, [ref]$parsed) -and $parsed -gt $highest) {
				$highest = $parsed
			}
		}
	}
	if ($highest -ge 0x0FFF) { throw "Every keyboard Layout Id is in use." }
	return "{0:x4}" -f ($highest + 1)
}





# ==================================
# ==================================
# ======= 2/ Install / Remove ======
# ==================================
# ==================================

try {
	$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
	if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
		throw "The Ergopti system layout installer must run as administrator."
	}
	if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
		throw "Run the 64-bit PowerShell: a 32-bit one cannot reach System32."
	}
	$spec = Get-Content -Raw -LiteralPath $SpecPath | ConvertFrom-Json
	$dllFile = "$([string]$spec.dll_name).dll"
	$architecture = [string](Get-ItemProperty -LiteralPath $ArchitectureKey -Name PROCESSOR_ARCHITECTURE).PROCESSOR_ARCHITECTURE
	$placement = $spec.architectures.PSObject.Properties[$architecture]
	if (-not $placement) { throw "Windows on $architecture has no Ergopti layout build." }
	$targets = @([pscustomobject]@{ Build = [string]$placement.Value.system32; Directory = Join-Path $env:SystemRoot "System32" })
	if ($placement.Value.PSObject.Properties["syswow64"]) {
		$targets += [pscustomobject]@{ Build = [string]$placement.Value.syswow64; Directory = Join-Path $env:SystemRoot "SysWOW64" }
	}

	if ($Action -eq "uninstall") {
		foreach ($key in Get-OwnLayoutKeys -DllFile $dllFile) { Remove-Item -LiteralPath $key.PSPath -Recurse }
		foreach ($target in $targets) { Move-Aside -Path (Join-Path $target.Directory $dllFile) }
		Write-Outcome -Status "uninstalled" -Klid "" -Message ""
		exit 0
	}

	foreach ($target in $targets) {
		$source = Join-Path (Join-Path $SourceDirectory $target.Build) $dllFile
		if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "The $($target.Build) layout DLL is missing: $source." }
	}
	foreach ($target in $targets) {
		$destination = Join-Path $target.Directory $dllFile
		Move-Aside -Path $destination
		Copy-Item -LiteralPath (Join-Path (Join-Path $SourceDirectory $target.Build) $dllFile) -Destination $destination
	}

	$own = @(Get-OwnLayoutKeys -DllFile $dllFile)
	$klid = if ($own.Count -gt 0) { $own[0].PSChildName.ToUpperInvariant() } else { Get-FreeKlid -LanguageId ([string]$spec.language_id) }
	$keyPath = Join-Path $LayoutsKey $klid
	if (-not (Test-Path -LiteralPath $keyPath)) { New-Item -Path $keyPath | Out-Null }
	$existingId = Get-ItemProperty -LiteralPath $keyPath -Name "Layout Id" -ErrorAction Ignore
	$layoutId = if ($existingId) { [string]$existingId."Layout Id" } else { Get-FreeLayoutId }
	New-ItemProperty -LiteralPath $keyPath -Name "Layout File" -Value $dllFile -PropertyType String -Force | Out-Null
	New-ItemProperty -LiteralPath $keyPath -Name "Layout Text" -Value ([string]$spec.layout_text) -PropertyType String -Force | Out-Null
	New-ItemProperty -LiteralPath $keyPath -Name "Layout Display Name" -Value "@%SystemRoot%\system32\$dllFile,-$DisplayNameResource" -PropertyType ExpandString -Force | Out-Null
	New-ItemProperty -LiteralPath $keyPath -Name "Layout Id" -Value $layoutId -PropertyType String -Force | Out-Null
	Write-Outcome -Status "installed" -Klid $klid -Message ""
	exit 0
} catch {
	Write-Outcome -Status "failed" -Klid "" -Message $_.Exception.Message
	exit 1
}
