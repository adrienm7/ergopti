# tools/test/test_updater_staging_observation.ps1
param([string]$OriginalScriptPath, [string]$HelperPath, [string]$OwnedDirectory,
    [string]$WorkerSourcePath = '')
$ErrorActionPreference = 'Stop'
. $HelperPath
if ($WorkerSourcePath -ne '') {
    $WorkerText = [IO.File]::ReadAllText($WorkerSourcePath)
    $Start = $WorkerText.IndexOf('_Updater_BuildStagingWorkerScript() {', [StringComparison]::Ordinal)
    if ($Start -lt 0) { throw 'Actual staging generator is required.' }
    $Body = $WorkerText.Substring($Start).Split([string[]]@("`n}"), [StringSplitOptions]::None)[0]
    $Parts = [regex]::Matches($Body, "(?:return |\. )'([^']*)'")
    if ($Parts.Count -ne 36) { throw 'Actual staging expression changed.' }
    $Source = (@($Parts | ForEach-Object { $_.Groups[1].Value }) -join "`n") + "`n"
} else { $Source = [IO.File]::ReadAllText($OriginalScriptPath) }
$Observed = New-ErgoptiObservedStagingScript $Source ''
$Reversed = $Observed.Source
foreach ($Seam in @($Observed.Seams)[($Observed.Seams.Count - 1)..0]) {
    $Reversed = $Reversed.Replace($Seam.after, $Seam.before)
}
if ($Reversed -cne $Source) { throw 'Whole original staging source must reverse exactly.' }
$ArrayFact = Get-ErgoptiStagingScalarFact @('PRIVATE_ONE', 'PRIVATE_TWO')
if ($ArrayFact.type -cne 'array' -or $ArrayFact.arity -ne 2 -or $ArrayFact.ContainsKey('size')) { throw 'Array is not scalar size.' }
$Path = Join-Path $OwnedDirectory 'pure-fact.json'
if ([IO.File]::Exists($Path)) { throw 'The observation control namespace must be fresh.' }
Write-ErgoptiStagingDiagnostic $Path 'content_length' ([long]524289) ([long]524288) ([InvalidOperationException]::new('PRIVATE_NONCE_OR_PATH')) 'file_read'
$Text = [IO.File]::ReadAllText($Path)
if ($Text.Length -gt 2048 -or $Text.Contains('PRIVATE')) { throw 'Fact must be bounded and private-content-free.' }
$Fact = $Text | ConvertFrom-Json
if ($Fact.operation -cne 'content_length' -or $Fact.expected.size -ne 524289 -or $Fact.actual.size -ne 524288) { throw 'Actual observation must preserve numeric facts.' }
Write-ErgoptiStagingDiagnostic $Path 'metadata' $null $null ([Exception]::new('PRIVATE')) 'file_read'
if ([IO.File]::ReadAllText($Path) -cne $Text -or $script:StagingDiagnosticHealth -cne 'unavailable') { throw 'Duplicate capture refuses without overwrite.' }
foreach($Control in @(@{family='invalid_operation'; exception=[InvalidOperationException]::new('PRIVATE');stage='proxy_resolve';code=-2146233079},@{family='argument';exception=[ArgumentException]::new('PRIVATE');stage='file_create';code=-2147024809},@{family='win32';exception=[ComponentModel.Win32Exception]::new(5,'PRIVATE');stage='PRIVATE_STAGE';code=-2147467259})){
 $Path=Join-Path $OwnedDirectory 'pure-fact.json'
 [IO.File]::Delete($Path)
 Write-ErgoptiStagingDiagnostic $Path 'not_file_read' $null $null $Control.exception $Control.stage
 $Text=[IO.File]::ReadAllText($Path);$Fact=$Text|ConvertFrom-Json
 if($Fact.schema_version -ne 2 -or $Fact.exception_family -cne $Control.family -or $Fact.hresult -ne $Control.code -or $Text.Contains('PRIVATE')){throw 'New native diagnostic provenance refused.'}
 if($Control.stage -ceq 'PRIVATE_STAGE'){$Expected='unknown'}else{$Expected=$Control.stage}
 if($Fact.observed_stage -cne $Expected){throw 'Stage provenance refused.'}
}
# Genuine legacy helper + actual PowerShell pipeline models. These controls
# stop at route admission: no HTTP operation, certificate store or PAC worker.
if ($WorkerSourcePath -eq '') { throw 'The source-qualified legacy helper is required.' }
$DownloadPath = Join-Path (Split-Path $WorkerSourcePath -Parent) '../../vendor/ergopti_updater_download.ps1'
$DownloadPath = [IO.Path]::GetFullPath($DownloadPath)
# Execute the exact caller injection in a child script scope, as the actual
# transformed orchestrator does. The native module loads first; only its
# legacy function is replaced, with every original statement still present.
$ModuleSeam = @($Observed.Seams | Where-Object { $_.before -ceq '  . $DownloadModulePath' })
if ($ModuleSeam.Count -ne 1) { throw 'Actual module-load join is required.' }
$Prelude = 'param([string]$DownloadModulePath)' + "`n" + $ModuleSeam[0].after + "`n" + '$Joined=(Get-Command Invoke-ErgoptiUpdaterDownload).Definition; if($Joined.IndexOf("FixtureRouteShape",[StringComparison]::Ordinal) -lt 0){throw "Fixture caller scope was lost."};if((Get-Command Get-ErgoptiUpdaterFailureReceipt).CommandType -ne "Function"){throw "Native support function scope was lost."}'
$PreludeOutput = @(& ([scriptblock]::Create($Prelude)) $DownloadPath)
if ($PreludeOutput.Count -ne 0) { throw 'Caller source join added pipeline output.' }
. $DownloadPath
$OriginalDownload = (Get-Command Invoke-ErgoptiUpdaterDownload).Definition
$ObservedDownload = New-ErgoptiObservedDownloadFunction $OriginalDownload
if ($ObservedDownload.Source.Replace($ObservedDownload.After, $ObservedDownload.Before) -cne $OriginalDownload) {
    throw 'Whole actual legacy function must reverse exactly.'
}
${function:Invoke-ErgoptiUpdaterDownload} = [scriptblock]::Create($ObservedDownload.Source)
try {
    $Receipt = @{ backend = 'winhttp'; stage = 'proxy_resolve'; failure_provenance = 'unknown'; proxy_resolution_status = 'unavailable' }
    $One = @{ Ok = $false; Routes = @(); Receipt = $Receipt }
    $Two = @{ Ok = $false; Routes = @(); Receipt = $Receipt }
    $Controls = @(
        @{ result = $One; kind = 'hashtable'; arity = 1; ok = 'bool'; receipt = 'hashtable'; max = 'absent'; routes = 'array' },
        @{ result = @($One, $Two); kind = 'array'; arity = 2; ok = 'unobserved'; receipt = 'unobserved'; max = 'unobserved'; routes = 'unobserved' },
        @{ result = $null; kind = 'absent'; arity = 0; ok = 'unobserved'; receipt = 'unobserved'; max = 'unobserved'; routes = 'unobserved' },
        @{ result = @{ Ok = $true; Routes = @(@{ Kind = 'direct'; Endpoint = '' }); MaxRoutes = $true; MaxRedirects = 5 }; kind = 'hashtable'; arity = 1; ok = 'bool'; receipt = 'absent'; max = 'bool'; routes = 'array' },
        @{ result = @{ Ok = $true; Routes = 'PRIVATE_ROUTE'; MaxRoutes = 8; MaxRedirects = 5 }; kind = 'hashtable'; arity = 1; ok = 'bool'; receipt = 'absent'; max = 'int32'; routes = 'string' },
        @{ result = @{ Ok = $true; Routes = @(@{ Kind = 'direct'; Endpoint = '' }); MaxRoutes = 8 }; kind = 'hashtable'; arity = 1; ok = 'bool'; receipt = 'absent'; max = 'int32'; routes = 'array' }
    )
    $Ordinal = 0
    foreach ($Control in $Controls) {
        $Ordinal++
        $Selection = $Control.result
        $Resolver = { param($Destination, $Budget) return $Selection }.GetNewClosure()
        $State = @{ Stage = 'proxy_resolve'; Receipt = @{}; CleanupDebt = @() }
        $Target = Join-Path $OwnedDirectory ('route-control-' + $Ordinal + '.bin')
        $Request = [Net.HttpWebRequest]::Create('https://route-control.invalid/private')
        $Started = [long][ErgoptiUpdaterMonotonicClock]::GetTickCount64()
        $Captured = [Collections.Generic.List[object]]::new()
        $Refused = $false
        try {
            Invoke-ErgoptiUpdaterDownload $Request $Target 5000 $State $Resolver 20000 $Started | ForEach-Object { $Captured.Add($_) }
        } catch {
            $Refused = $_.Exception -is [InvalidOperationException]
        }
        if (-not $Refused -or $State.Stage -cne 'proxy_resolve' -or $Captured.Count -ne 0 -or [IO.File]::Exists($Target)) {
            throw 'Actual legacy refusal/pipeline/namespace semantics changed.'
        }
        $Fact = $State.FixtureRouteShape
        if ($Fact.Count -ne 15 -or $Fact.selection_kind -cne $Control.kind -or $Fact.selection_arity -ne $Control.arity -or
            $Fact.ok_kind -cne $Control.ok -or $Fact.receipt_kind -cne $Control.receipt -or
            $Fact.max_routes_kind -cne $Control.max -or $Fact.routes_kind -cne $Control.routes) {
            throw 'Actual helper route shape differs from independent literal controls.'
        }
        $Path = Join-Path $OwnedDirectory ('route-shape-' + $Ordinal + '.json')
        Write-ErgoptiStagingRouteShape $Path $State
        $Text = [IO.File]::ReadAllText($Path)
        if ($Text.Length -gt 2048 -or $Text.Contains('PRIVATE') -or $Text.Contains('invalid')) { throw 'Shape leaked request values.' }
        Write-ErgoptiStagingRouteShape $Path @{ FixtureRouteShape = @{ private = 'PRIVATE' } }
        if ([IO.File]::ReadAllText($Path) -cne $Text -or $script:StagingRouteShapeHealth -cne 'unavailable') {
            throw 'Shape publication replaced owned existing bytes.'
        }
    }
} finally {
    ${function:Invoke-ErgoptiUpdaterDownload} = [scriptblock]::Create($OriginalDownload)
}
Write-Output 'PASS: staging observation checks=15 native_watch=0 network=0 certificate=0'
