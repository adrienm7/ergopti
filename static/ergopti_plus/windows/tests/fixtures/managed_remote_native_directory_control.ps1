# tests/fixtures/managed_remote_native_directory_control.ps1
# Execute the actual TLS owner's directory selection without acquiring TLS or trust.
param([Parameter(Mandatory = $true)][string]$SourcePath)
$ErrorActionPreference = 'Stop'
$Source = [IO.File]::ReadAllText($SourcePath, [Text.Encoding]::UTF8)
$Start = $Source.IndexOf('public sealed class ErgoptiFixtureOpenSsl : IDisposable', [StringComparison]::Ordinal)
$End = $Source.IndexOf('public sealed class ErgoptiManagedNetworkFixture', $Start, [StringComparison]::Ordinal)
if ($Start -lt 0) { throw 'The original native TLS source owner is missing.' }
if ($End -lt 0) { $End = $Source.Length }
$Owner = $Source.Substring($Start, $End - $Start)
$Assignment = [regex]::Matches($Owner, '(?m)^        nativeDirectory = ([^\r\n]+);$')
$Verifier = [regex]::Matches($Owner, '(?ms)^    private static void VerifyDirectory\(string path\)\n    \{.*?^    \}')
$Resolver = [regex]::Matches($Owner, '(?ms)^    private static string ResolveNativeDirectory\(string installationRoot\)\n    \{.*?^    \}')
if ($Assignment.Count -ne 1 -or $Verifier.Count -ne 1 -or $Resolver.Count -gt 1) {
    throw 'The actual native directory selection must be uniquely extracted.'
}
$Expression = $Assignment[0].Groups[1].Value.Replace('Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles)', 'programFiles')
$Extra = if ($Resolver.Count -eq 1) { $Resolver[0].Value } else { '' }
$Code = @"
using System;
using System.IO;
public static class ErgoptiNativeDirectoryControl {
    $Extra
    $($Verifier[0].Value)
    public static string Select(string programFiles) {
        string nativeDirectory = $Expression;
        VerifyDirectory(nativeDirectory);
        return nativeDirectory;
    }
}
"@
Add-Type -TypeDefinition $Code -ErrorAction Stop
$Root = Join-Path ([IO.Path]::GetTempPath()) ('ergopti_tls_directory_' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($Root)
$Passed = 0
function New-NativePrefix([string]$Case, [string]$Prefix, [string]$Executable = 'git.exe') {
    $Directory = Join-Path $Case ('Git/' + $Prefix + '/bin')
    [void][IO.Directory]::CreateDirectory($Directory)
    if ($Executable -ne '') { [IO.File]::WriteAllBytes((Join-Path $Directory $Executable), [byte[]]@(0)) }
    return [IO.Path]::GetFullPath($Directory)
}
function Assert-Selected([string]$Case, [string]$Expected) {
    $Actual = [ErgoptiNativeDirectoryControl]::Select($Case)
    if ($Actual -cne $Expected) { throw 'The actual native TLS constructor selected a different prefix.' }
    $script:Passed++
}
function Assert-Refused([string]$Case) {
    $Refused = $false
    try { $null = [ErgoptiNativeDirectoryControl]::Select($Case) } catch { $Refused = $true }
    if (-not $Refused) { throw 'An ambiguous or absent native Git owner was admitted.' }
    $script:Passed++
}
try {
    $Case = Join-Path $Root 'legacy'
    $Expected = New-NativePrefix $Case 'mingw64'
    Assert-Selected $Case $Expected
    [Console]::Out.WriteLine('PASS native TLS directory: legacy native owner')
    $Case = Join-Path $Root 'ucrt'
    $Expected = New-NativePrefix $Case 'ucrt64'
    Assert-Selected $Case $Expected
    [Console]::Out.WriteLine('PASS native TLS directory: UCRT native owner')
    $Case = Join-Path $Root 'credential_compatibility'
    $Expected = New-NativePrefix $Case 'ucrt64'
    $null = New-NativePrefix $Case 'mingw64' 'git-credential-manager.exe'
    Assert-Selected $Case $Expected
    [Console]::Out.WriteLine('PASS native TLS directory: credential compatibility is not native Git')
    $Case = Join-Path $Root 'ambiguous'
    $null = New-NativePrefix $Case 'mingw64'
    $null = New-NativePrefix $Case 'ucrt64'
    Assert-Refused $Case
    [Console]::Out.WriteLine('PASS native TLS directory: ambiguous owners refused')
    $Case = Join-Path $Root 'empty_prefix'
    $null = New-NativePrefix $Case 'mingw64' ''
    Assert-Refused $Case
    [Console]::Out.WriteLine('PASS native TLS directory: empty prefix refused')
    $Case = Join-Path $Root 'absent'
    [void][IO.Directory]::CreateDirectory($Case)
    Assert-Refused $Case
    [Console]::Out.WriteLine('PASS native TLS directory: absent installation refused')
    if ($Passed -ne 6) { throw 'The complete native directory selection was not received.' }
    [Console]::Out.WriteLine('NATIVE_TLS_DIRECTORY_CONTROL_OK 6/6')
} finally {
    # Only this process's direct temporary child is eligible for recursive cleanup.
    $Resolved = [IO.Path]::GetFullPath($Root)
    $Parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $Resolved.StartsWith($Parent, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($Resolved) -cnotmatch '^ergopti_tls_directory_[0-9a-f]{32}$') {
        throw 'Native directory control cleanup boundary changed.'
    }
    Remove-Item -LiteralPath $Resolved -Recurse -Force
}
