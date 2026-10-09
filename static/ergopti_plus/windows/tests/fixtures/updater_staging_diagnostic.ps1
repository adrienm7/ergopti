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

function Get-ErgoptiStagingRouteKind {
    param($Value)
    if ($null -eq $Value) { return 'absent' }
    if ($Value -is [bool]) { return 'bool' }
    if ($Value -is [int]) { return 'int32' }
    if ($Value -is [long]) { return 'int64' }
    if ($Value -is [array]) { return 'array' }
    if ($Value -is [hashtable]) { return 'hashtable' }
    if ($Value -is [string]) { return 'string' }
    return 'other'
}

function Get-ErgoptiStagingRouteShape {
    param($Selection)
    # Do not enumerate or read property getters on unexpected resolver output.
    # Only the real canonical Hashtable has fields inspected; no field value
    # containing a URL, native input or exception text enters this receipt.
    $Fact = @{ schema_version = 1; selection_kind = (Get-ErgoptiStagingRouteKind $Selection);
        selection_arity = 1; ok_kind = 'unobserved'; ok_value = 'unavailable';
        routes_kind = 'unobserved'; routes_count = -1;
        max_routes_kind = 'unobserved'; max_routes_value = -1;
        max_redirects_kind = 'unobserved'; max_redirects_value = -1;
        receipt_kind = 'unobserved'; receipt_count = -1;
        receipt_backend_kind = 'unobserved'; receipt_stage_kind = 'unobserved' }
    if ($null -eq $Selection) { $Fact.selection_arity = 0 }
    elseif ($Selection -is [array]) {
        $Fact.selection_arity = if ($Selection.Length -le 4096) { $Selection.Length } else { -1 }
    }
    if ($Selection -isnot [hashtable]) { return $Fact }
    $Fact.ok_kind = Get-ErgoptiStagingRouteKind $Selection['Ok']
    if ($Selection['Ok'] -is [bool]) {
        $Fact.ok_value = if ($Selection['Ok']) { 'true' } else { 'false' }
    }
    $Fact.routes_kind = Get-ErgoptiStagingRouteKind $Selection['Routes']
    if ($Selection['Routes'] -is [array] -and $Selection['Routes'].Length -le 4096) {
        $Fact.routes_count = $Selection['Routes'].Length
    }
    foreach ($Pair in @(@('MaxRoutes', 'max_routes'), @('MaxRedirects', 'max_redirects'))) {
        $Value = $Selection[$Pair[0]]
        $Fact[$Pair[1] + '_kind'] = Get-ErgoptiStagingRouteKind $Value
        if (($Value -is [int] -or $Value -is [long]) -and $Value -ge -1 -and $Value -le [int]::MaxValue) {
            $Fact[$Pair[1] + '_value'] = [long]$Value
        }
    }
    $Receipt = $Selection['Receipt']
    $Fact.receipt_kind = Get-ErgoptiStagingRouteKind $Receipt
    if ($Receipt -is [hashtable] -and $Receipt.Count -le 64) {
        $Fact.receipt_count = $Receipt.Count
        $Fact.receipt_backend_kind = Get-ErgoptiStagingRouteKind $Receipt['backend']
        $Fact.receipt_stage_kind = Get-ErgoptiStagingRouteKind $Receipt['stage']
    }
    return $Fact
}

function Write-ErgoptiStagingRouteShape {
    param([string]$Path, [hashtable]$State)
    $Stream = $null
    try {
        if ($Path -eq '' -or -not $State.ContainsKey('FixtureRouteShape')) { return }
        $Bytes = [Text.UTF8Encoding]::new($false).GetBytes(($State.FixtureRouteShape | ConvertTo-Json -Depth 2 -Compress))
        if ($Bytes.Length -gt 2048) { throw 'Route observation bound refused.' }
        $Stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $Stream.Write($Bytes, 0, $Bytes.Length)
        $Stream.Flush($true)
    } catch {
        # This private optional observation never supplies routing authority.
        $script:StagingRouteShapeHealth = 'unavailable'
    } finally {
        if ($null -ne $Stream) { try { $Stream.Dispose() } catch { $script:StagingRouteShapeHealth = 'unavailable' } }
    }
}

function New-ErgoptiObservedDownloadFunction {
    param([string]$Source)
    $Before = '            $Selection = & $ResolveRoutes $Destination.AbsoluteUri $Remaining'
    $After = $Before + "`n" + '            try { $State.FixtureRouteShape = Get-ErgoptiStagingRouteShape $Selection } catch { $script:StagingRouteShapeHealth = "unavailable" }'
    if (($Source.Split([string[]]@($Before), [StringSplitOptions]::None)).Length -ne 2) {
        throw 'Legacy route observation seam drifted.'
    }
    return [pscustomobject]@{ Source = $Source.Replace($Before, $After); Before = $Before; After = $After }
}

function New-ErgoptiObservedStagingScript {
    param([string]$Source, [string]$DiagnosticPath)
    # The unique fixture environment supplies the path; it never comes from user data.
    $Initialization = '$StagingDiagnosticExpected=$null;$StagingDiagnosticActual=$null;$StagingDiagnosticOperation="not_file_read"'
    $Seams = @(
        @{ before = '  . $DownloadModulePath'; after = '  . $DownloadModulePath' + "`n" + '  $ObservedDownload=New-ErgoptiObservedDownloadFunction ((Get-Command Invoke-ErgoptiUpdaterDownload).Definition);${function:Invoke-ErgoptiUpdaterDownload}=[scriptblock]::Create($ObservedDownload.Source)' },
        @{ before = '$ErrorActionPreference = "Stop"'; after = ('$ErrorActionPreference = "Stop"' + "`n" + $Initialization) },
        @{ before = '  $State.Stage="file_read"'; after = '  $State.Stage="file_read";$StagingDiagnosticExpected=$ExpectedSize;$StagingDiagnosticOperation="metadata"' },
        @{ before = '  if ($ExpectedSize -gt 0'; after = '  $StagingDiagnosticActual=$ActualSize;$StagingDiagnosticOperation="content_length"' + "`n" + '  if ($ExpectedSize -gt 0' },
        @{ before = '  if ($ActualSize -lt'; after = '  $StagingDiagnosticOperation="minimum"' + "`n" + '  if ($ActualSize -lt' },
        @{ before = '  if ($ExpectedSha256 -cnotmatch'; after = '  $StagingDiagnosticOperation="digest_format"' + "`n" + '  if ($ExpectedSha256 -cnotmatch' },
        @{ before = '  $ActualDigest='; after = '  $StagingDiagnosticOperation="digest_read"' + "`n" + '  $ActualDigest=' },
        @{ before = '  $null=Get-ErgoptiUpdaterRemainingMilliseconds $StartedTick $DeadlineMs $State' + "`n" + '  if ($ActualDigest'; after = '  $StagingDiagnosticOperation="budget"' + "`n" + '  $null=Get-ErgoptiUpdaterRemainingMilliseconds $StartedTick $DeadlineMs $State' + "`n" + '  $StagingDiagnosticOperation="digest_compare"' + "`n" + '  if ($ActualDigest' },
        @{ before = '} catch {'; after = '} catch {' + "`n" + '  Write-ErgoptiStagingDiagnostic $env:ERGOPTI_FIXTURE_STAGING_DIAGNOSTIC $StagingDiagnosticOperation $StagingDiagnosticExpected $StagingDiagnosticActual $_.Exception $State.Stage' + "`n" + '  Write-ErgoptiStagingRouteShape $env:ERGOPTI_FIXTURE_STAGING_ROUTE_SHAPE $State'  }
    )
    foreach ($Seam in $Seams) {
        if (($Source.Split([string[]]@($Seam.before), [StringSplitOptions]::None)).Length -ne 2) { throw 'Staging observation seam drifted.' }
        $Source = $Source.Replace($Seam.before, $Seam.after)
    }
    return [pscustomobject]@{ Source = $Source; Seams = $Seams }
}
