# tools/test/test-windows-keyboard-layout.ps1
<#
==============================================================================
MODULE: Windows Keyboard Layout Install Probe (CI)
DESCRIPTION:
Installs the built Ergopti keyboard layout DLL on an ephemeral GitHub Actions
runner through the installer the release package starts
(windows/vendor/keyboard_layout/install_keyboard_layout.ps1), loads it, and
asks Windows itself what keys type (ToUnicodeEx): letters, Shift, AltGr, a
ligature and a dead key. Then removes it and checks nothing is left.

FEATURES & RATIONALE:
1. The DLL is exercised by the system that will load it, not by a reading of
	its sources; the expected characters are those of the registry .keylayout,
	which test-windows-keyboard-layout-codegen.cjs pins on the generated tables.
2. Restricted to an elevated ephemeral runner: it writes HKLM and System32.
3. Never activates the layout for the session: LoadKeyboardLayout with
	KLF_NOTELLSHELL and an explicit HKL for ToUnicodeEx.
==============================================================================
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ($env:GITHUB_ACTIONS -cne "true" -or -not $env:RUNNER_TEMP) {
	throw "The layout install probe writes System32 and HKLM: it only runs on an ephemeral GitHub Actions runner."
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$SpecPath = Join-Path $RepoRoot "static\ergopti_plus\_shared\modules\layouts\windows_system_layout.json"
$VendorDirectory = Join-Path $RepoRoot "static\ergopti_plus\windows\vendor\keyboard_layout"
$Installer = Join-Path $VendorDirectory "install_keyboard_layout.ps1"
$ResultPath = Join-Path $env:RUNNER_TEMP "ergopti-layout-install.json"

Add-Type -Namespace ErgoptiProbe -Name Keyboard -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern IntPtr LoadKeyboardLayout(string klid, uint flags);
[DllImport("user32.dll", SetLastError = true)]
public static extern bool UnloadKeyboardLayout(IntPtr hkl);
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern int ToUnicodeEx(uint vk, uint scan, byte[] state, System.Text.StringBuilder buffer, int size, uint flags, IntPtr hkl);
[DllImport("user32.dll")]
public static extern uint MapVirtualKeyEx(uint code, uint mapType, IntPtr hkl);
'@

$failures = [Collections.Generic.List[string]]::new()

<#
.SYNOPSIS
Runs the installer and returns its outcome.
#>
function Invoke-Installer {
	param([string]$Action)
	Remove-Item -LiteralPath $ResultPath -Force -ErrorAction Ignore
	# The Windows PowerShell the package starts the installer with.
	& (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") -NoProfile -ExecutionPolicy Bypass -File $Installer `
		-Action $Action -SpecPath $SpecPath -SourceDirectory $VendorDirectory -ResultPath $ResultPath
	$code = $LASTEXITCODE
	if (-not (Test-Path -LiteralPath $ResultPath)) { throw "The installer ($Action) wrote no outcome (exit $code)." }
	$outcome = Get-Content -Raw -LiteralPath $ResultPath | ConvertFrom-Json
	if ($code -ne 0) { throw "The installer ($Action) failed: $($outcome.message)" }
	return $outcome
}

<#
.SYNOPSIS
What one key types on the layout with the given modifiers.
#>
function Get-Typed {
	param([IntPtr]$Hkl, [int]$ScanCode, [string[]]$Modifiers = @())
	$state = [byte[]]::new(256)
	foreach ($modifier in $Modifiers) {
		switch ($modifier) {
			"shift" { $state[0x10] = 0x80; $state[0xA0] = 0x80 }
			"altgr" { $state[0x11] = 0x80; $state[0xA2] = 0x80; $state[0x12] = 0x80; $state[0xA5] = 0x80 }
			default { throw "Unknown modifier $modifier." }
		}
	}
	# MAPVK_VSC_TO_VK_EX: the virtual key this layout gives the scan code.
	$vk = [ErgoptiProbe.Keyboard]::MapVirtualKeyEx([uint32]$ScanCode, 3, $Hkl)
	$buffer = [Text.StringBuilder]::new(16)
	$count = [ErgoptiProbe.Keyboard]::ToUnicodeEx($vk, [uint32]$ScanCode, $state, $buffer, $buffer.Capacity, 0, $Hkl)
	return [pscustomobject]@{ Vk = $vk; Count = $count; Text = $buffer.ToString().Substring(0, [Math]::Max(0, [Math]::Abs($count))) }
}

<#
.SYNOPSIS
Records a failure when what Windows typed differs.
#>
function Assert-Typed {
	param([string]$What, $Typed, [int]$Count, [string]$Text)
	if ($Typed.Count -ne $Count -or $Typed.Text -cne $Text) {
		$failures.Add("${What}: expected $Count '$Text', Windows typed $($Typed.Count) '$($Typed.Text)' (VK 0x{0:X2})" -f $Typed.Vk)
	} else {
		Write-Host "  ok  $What"
	}
}

$outcome = Invoke-Installer -Action "install"
$klid = [string]$outcome.klid
Write-Host "[layout-probe] Installed as $klid."
$spec = Get-Content -Raw -LiteralPath $SpecPath | ConvertFrom-Json
$entry = Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layouts\$klid"
if ($entry."Layout File" -ine "$($spec.dll_name).dll") { $failures.Add("The registry entry names $($entry.'Layout File').") }
if (-not (Test-Path -LiteralPath (Join-Path $env:SystemRoot "System32\$($spec.dll_name).dll"))) { $failures.Add("System32 has no layout DLL.") }

# KLF_NOTELLSHELL: loaded for this process, never activated for the session.
$hkl = [ErgoptiProbe.Keyboard]::LoadKeyboardLayout($klid, 0x80)
if ($hkl -eq [IntPtr]::Zero) { throw "Windows refused to load $klid (Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))." }
try {
	# Scan codes of static/ergopti_plus/_shared/modules/layouts/mac_keycodes.json.
	Assert-Typed "KeyA types a" (Get-Typed $hkl 0x1E) 1 "a"
	Assert-Typed "Shift+KeyA types A" (Get-Typed $hkl 0x1E @("shift")) 1 "A"
	Assert-Typed "AltGr+KeyA types <" (Get-Typed $hkl 0x1E @("altgr")) 1 "<"
	Assert-Typed "KeyE types o" (Get-Typed $hkl 0x12) 1 "o"
	Assert-Typed "KeyZ types e acute" (Get-Typed $hkl 0x2C) 1 ([string][char]0x00E9)
	Assert-Typed "AltGr+KeyT types the guillemet and its no-break space" (Get-Typed $hkl 0x14 @("altgr")) 2 ("" + [char]0x00AB + [char]0x00A0)
	Assert-Typed "Backslash is the circumflex dead key" (Get-Typed $hkl 0x2B) -1 "^"
	Assert-Typed "then KeyA types a circumflex" (Get-Typed $hkl 0x1E) 1 ([string][char]0x00E2)
} finally {
	[void][ErgoptiProbe.Keyboard]::UnloadKeyboardLayout($hkl)
}

# The user step the package runs next, as the runner's own user.
$addResult = Join-Path $env:RUNNER_TEMP "ergopti-layout-add.json"
$tip = "{0}:{1}" -f ([string]$spec.language_id).ToUpperInvariant(), $klid.ToUpperInvariant()
& (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") -NoProfile -ExecutionPolicy Bypass `
	-File (Join-Path $VendorDirectory "add_user_keyboard_layout.ps1") -Klid $klid -LanguageId $spec.language_id `
	-LocaleName $spec.locale_name -ResultPath $addResult
$added = Get-Content -Raw -LiteralPath $addResult | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $added.status -ne "added") {
	$failures.Add("Adding the layout to the user's languages answered '$($added.status)': $($added.message)")
} else {
	$listed = Get-WinUserLanguageList | Where-Object { $_.LanguageTag -ieq $spec.locale_name } | Select-Object -First 1
	if (-not $listed -or @($listed.InputMethodTips | Where-Object { $_ -ieq $tip }).Count -ne 1) {
		$failures.Add("The user's languages do not list $tip.")
	} else {
		Write-Host "  ok  the user's languages list $tip"
		$list = Get-WinUserLanguageList
		$language = $list | Where-Object { $_.LanguageTag -ieq $spec.locale_name } | Select-Object -First 1
		[void]$language.InputMethodTips.Remove(($language.InputMethodTips | Where-Object { $_ -ieq $tip } | Select-Object -First 1))
		if ($language.InputMethodTips.Count -eq 0) { [void]$list.Remove($language) }
		Set-WinUserLanguageList -LanguageList $list -Force
	}
}

[void](Invoke-Installer -Action "uninstall")
if (Test-Path -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layouts\$klid") { $failures.Add("The uninstall left $klid in the registry.") }

if ($failures.Count -gt 0) {
	$failures | ForEach-Object { Write-Host "::error::$_" }
	exit 1
}
Write-Host "[layout-probe] Windows types the Ergopti layout as the .keylayout does."
