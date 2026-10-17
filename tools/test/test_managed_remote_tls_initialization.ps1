# tools/test/test_managed_remote_tls_initialization.ps1
# Compile the actual fixture type and receive its closed precondition failure.
param(
    [Parameter(Mandatory = $true)][string]$FixturePath
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$Text = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $FixturePath), [Text.Encoding]::UTF8)
$Sources = @([regex]::Matches($Text, "Add-Type -TypeDefinition @'\r?\n([\s\S]*?)\r?\n'@") |
    Where-Object { $_.Groups[1].Value.Contains('public sealed class ErgoptiFixtureOpenSsl') })
if ($Sources.Count -ne 1) { throw 'The original native TLS source must be unique.' }
Add-Type -TypeDefinition $Sources[0].Groups[1].Value
$Phase = [ErgoptiFixtureOpenSsl].GetProperty('InitializationPhase')
if ($null -eq $Phase -or !$Phase.GetGetMethod().IsStatic -or $Phase.CanWrite) {
    throw 'The native TLS initialization phase must be a read-only original producer fact.'
}
if ([ErgoptiFixtureOpenSsl]::InitializationPhase -cne 'not_entered') {
    throw 'The native TLS constructor has not run in this fresh process.'
}
[Console]::Out.WriteLine('PASS native TLS phase is read-only and initially unentered')
$Failure = $null
try {
    [ErgoptiFixtureOpenSsl]::new($null, $null) | Out-Null
} catch {
    $Failure = $_.Exception
    while ($null -ne $Failure.InnerException) { $Failure = $Failure.InnerException }
}
if ($null -eq $Failure -or $Failure.GetType().FullName -cne 'System.InvalidOperationException' -or
    $Failure.HResult -ne -2146233079 -or
    $Failure.Message -cne 'Native in-memory TLS fixture prerequisite unavailable.') {
    throw 'Phase observation must preserve the original native constructor refusal.'
}
if ([ErgoptiFixtureOpenSsl]::InitializationPhase -cne 'preconditions') {
    throw 'The actual refused constructor must retain its exact initialization boundary.'
}
[Console]::Out.WriteLine('PASS native TLS precondition refusal retains its phase and original error')
