# tests/fixtures/updater_staging_diagnostic.ps1
# Passive fixture observations; no field participates in staging admission.

function Get-ErgoptiStagingScalarFact {
    param($Value)
    $Kind = if ($null -eq $Value) { 'absent' } elseif ($Value -is [int]) { 'int32' }
        elseif ($Value -is [long]) { 'int64' } elseif ($Value -is [array]) { 'array' }
        elseif ($Value -is [string]) { 'string' } else { 'other' }
    $Arity = if ($null -eq $Value) { 0 } elseif ($Value -is [array]) {
        if ($Value.Length -le 1024) { $Value.Length } else { -1 }
    } else { 1 }
    $Fact = @{ type = $Kind; arity = [int]$Arity; size_available = 'unavailable' }
    if (($Value -is [int] -or $Value -is [long]) -and $Value -ge -1 -and $Value -le 2147483647) {
        $Fact.size_available = 'available'
        $Fact.size = [long]$Value
    }
    return $Fact
}

function Write-ErgoptiStagingDiagnostic {
    param([string]$Path, [string]$Operation, $Expected, $Actual, [Exception]$Exception, [string]$Stage)
    $Stream = $null
    try {
        if ($Path -eq '') { return }
        $Operations = @('metadata', 'content_length', 'minimum', 'digest_format', 'digest_read', 'budget', 'digest_compare', 'not_file_read')
        if ($Stage -cne 'file_read') { $Operation = 'not_file_read' }
        if ($Operation -cnotin $Operations) { $Operation = 'not_file_read' }
        $Kind = if ($Exception -is [System.Management.Automation.CommandNotFoundException]) { 'command_not_found' }
            elseif ($Exception -is [System.Management.Automation.ItemNotFoundException]) { 'item_not_found' }
            elseif ($Exception -is [System.Management.Automation.PropertyNotFoundException]) { 'property_not_found' }
            elseif ($Exception -is [System.Management.Automation.MethodInvocationException]) { 'method_invocation' }
            elseif ($Exception -is [System.IO.IOException]) { 'io' }
            elseif ($Exception -is [UnauthorizedAccessException]) { 'unauthorized' }
            elseif ($Exception -is [TimeoutException]) { 'timeout' }
            elseif ($Exception -is [System.Management.Automation.RuntimeException]) { 'runtime' } else { 'other' }
        $Family = if ($Exception -is [ComponentModel.Win32Exception]) { 'win32' }
            elseif ($Exception -is [Net.WebException]) { 'web' }
            elseif ($Exception -is [ArgumentException]) { 'argument' }
            elseif ($Exception -is [InvalidOperationException]) { 'invalid_operation' }
            elseif ($Exception -is [Security.SecurityException]) { 'security' }
            elseif ($Exception -is [TypeInitializationException]) { 'type_initialization' }
            else { $Kind }
        $SafeStage = if ($Stage -cin @('proxy_resolve', 'proxy_connect', 'connect', 'tls', 'http',
            'file_create', 'file_read', 'file_write', 'file_remove', 'file_rename')) { $Stage } else { 'unknown' }
        $Fact = @{ schema_version = 2; operation = $Operation; exception = $Kind;
            observed_stage = $SafeStage; exception_family = $Family; hresult = [int]$Exception.HResult;
            expected = (Get-ErgoptiStagingScalarFact $Expected); actual = (Get-ErgoptiStagingScalarFact $Actual) }
        $Bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Fact | ConvertTo-Json -Depth 3 -Compress))
        if ($Bytes.Length -gt 2048) { throw 'Diagnostic bound refused.' }
        $Stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $Stream.Write($Bytes, 0, $Bytes.Length)
        $Stream.Flush($true)
    } catch {
        # Optional diagnostic refusal remains an absent/invalid sidecar, never success.
        $script:StagingDiagnosticHealth = 'unavailable'
        return
    } finally {
        if ($null -ne $Stream) { try { $Stream.Dispose() } catch { $script:StagingDiagnosticHealth = 'unavailable' } }
    }
}

function New-ErgoptiObservedStagingScript {
    param([string]$Source, [string]$DiagnosticPath)
    # The unique fixture environment supplies the path; it never comes from user data.
    $Initialization = '$StagingDiagnosticExpected=$null;$StagingDiagnosticActual=$null;$StagingDiagnosticOperation="not_file_read"'
    $Seams = @(
        @{ before = '$ErrorActionPreference = "Stop"'; after = ('$ErrorActionPreference = "Stop"' + "`n" + $Initialization) },
        @{ before = '  $State.Stage="file_read"'; after = '  $State.Stage="file_read";$StagingDiagnosticExpected=$ExpectedSize;$StagingDiagnosticOperation="metadata"' },
        @{ before = '  if ($ExpectedSize -gt 0'; after = '  $StagingDiagnosticActual=$ActualSize;$StagingDiagnosticOperation="content_length"' + "`n" + '  if ($ExpectedSize -gt 0' },
        @{ before = '  if ($ActualSize -lt'; after = '  $StagingDiagnosticOperation="minimum"' + "`n" + '  if ($ActualSize -lt' },
        @{ before = '  if ($ExpectedSha256 -cnotmatch'; after = '  $StagingDiagnosticOperation="digest_format"' + "`n" + '  if ($ExpectedSha256 -cnotmatch' },
        @{ before = '  $ActualDigest='; after = '  $StagingDiagnosticOperation="digest_read"' + "`n" + '  $ActualDigest=' },
        @{ before = '  $null=Get-ErgoptiUpdaterRemainingMilliseconds $StartedTick $DeadlineMs $State' + "`n" + '  if ($ActualDigest'; after = '  $StagingDiagnosticOperation="budget"' + "`n" + '  $null=Get-ErgoptiUpdaterRemainingMilliseconds $StartedTick $DeadlineMs $State' + "`n" + '  $StagingDiagnosticOperation="digest_compare"' + "`n" + '  if ($ActualDigest' },
        @{ before = '} catch {'; after = '} catch {' + "`n" + '  Write-ErgoptiStagingDiagnostic $env:ERGOPTI_FIXTURE_STAGING_DIAGNOSTIC $StagingDiagnosticOperation $StagingDiagnosticExpected $StagingDiagnosticActual $_.Exception $State.Stage' }
    )
    foreach ($Seam in $Seams) {
        if (($Source.Split([string[]]@($Seam.before), [StringSplitOptions]::None)).Length -ne 2) { throw 'Staging observation seam drifted.' }
        $Source = $Source.Replace($Seam.before, $Seam.after)
    }
    return [pscustomobject]@{ Source = $Source; Seams = $Seams }
}
