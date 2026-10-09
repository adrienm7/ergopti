# tests/fixtures/managed_remote_scope_control.ps1
# Exercise the actual guard functions without evaluating fixture acquisition.
param([string]$SourcePath)
$ErrorActionPreference = 'Stop'
$Tokens = $null
$Errors = $null
$Ast = [Management.Automation.Language.Parser]::ParseFile($SourcePath, [ref]$Tokens, [ref]$Errors)
if ($Errors.Count -ne 0) { throw 'The root-scope producer source did not parse.' }
foreach ($Name in @('Get-OwnedFixtureTokenElevation', 'Assert-OwnedFixtureRootScope', 'Invoke-OwnedRootSnapshot', 'Remove-OwnedRoot')) {
    $Functions = @($Ast.FindAll({ param($Node)
        $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -ceq $Name
    }, $true))
    if ($Functions.Count -ne 1) { throw 'The actual root-scope guard was not uniquely found.' }
    . ([scriptblock]::Create($Functions[0].Extent.Text))
}
& (Join-Path $PSScriptRoot 'managed_remote_snapshot_control.ps1') -SourcePath $SourcePath
$SavedActions = $env:GITHUB_ACTIONS
$SavedRunner = $env:RUNNER_ENVIRONMENT
$script:Reads = 0
$Reader = { $script:Reads++; return $true }
try {
    $env:GITHUB_ACTIONS = ''
    $env:RUNNER_ENVIRONMENT = ''
    Assert-OwnedFixtureRootScope 'CurrentUser' { throw 'CurrentUser must not query elevation.' }
    foreach ($Scope in @('', 'currentuser', 'localmachine', 'CURRENTUSER', 'LocalMachine ')) {
        $Rejected = $false
        try { Assert-OwnedFixtureRootScope $Scope $Reader } catch { $Rejected = $true }
        if (-not $Rejected) { throw 'A case alias or unknown root scope was admitted.' }
    }
    $Rejected = $false
    try { Assert-OwnedFixtureRootScope 'LocalMachine' $Reader } catch { $Rejected = $true }
    if (-not $Rejected -or $script:Reads -ne 0) { throw 'Unqualified intent reached the permission reader.' }
    $env:GITHUB_ACTIONS = 'true'
    $env:RUNNER_ENVIRONMENT = 'self-hosted'
    $Rejected = $false
    try { Assert-OwnedFixtureRootScope 'LocalMachine' $Reader } catch { $Rejected = $true }
    if (-not $Rejected -or $script:Reads -ne 0) { throw 'A persistent runner was admitted.' }
    $env:RUNNER_ENVIRONMENT = 'github-hosted'
    Assert-OwnedFixtureRootScope 'LocalMachine' $Reader
    if ($script:Reads -ne 1) { throw 'Qualified intent did not require explicit permission evidence.' }
    foreach ($Value in @($false, 1, 'true')) {
        $Rejected = $false
        try { Assert-OwnedFixtureRootScope 'LocalMachine' { return $Value } } catch { $Rejected = $true }
        if (-not $Rejected) { throw 'An untyped or false permission result was admitted.' }
    }
    $Rejected = $false
    try { Assert-OwnedFixtureRootScope 'LocalMachine' { throw 'Controlled query refusal.' } } catch { $Rejected = $true }
    if (-not $Rejected) { throw 'A failed token query was admitted.' }
    $NativeElevation = Get-OwnedFixtureTokenElevation
    if ($NativeElevation -isnot [bool]) { throw 'The own-process token reader did not return a boolean.' }
    foreach ($QueryFailed in @($false, $true)) {
        foreach ($CloseThrown in @($false, $true)) {
            $script:TokenControl = @{ token = [IntPtr]12345; queries = 0; closes = 0; ack = $false;
                queryFailed = $QueryFailed; closeThrown = $CloseThrown }
            $Open = [Func[IntPtr]]{ return $script:TokenControl.token }
            $Query = [Func[IntPtr, bool]]{
                param($Token)
                $script:TokenControl.queries++
                if ($Token -ne $script:TokenControl.token) { throw 'The query used a different token.' }
                if ($script:TokenControl.queryFailed) { throw 'CONTROLLED_QUERY_FAILURE' }
                return $true
            }
            $Close = [Func[IntPtr, bool]]{
                param($Token)
                $script:TokenControl.closes++
                if ($Token -ne $script:TokenControl.token) { throw 'Retirement used a different token.' }
                if ($script:TokenControl.closeThrown -and -not $script:TokenControl.ack) { throw 'CONTROLLED_CLOSE_FAILURE' }
                return $script:TokenControl.ack
            }
            $Owner = [ErgoptiOwnedFixtureToken+Observation]::new($Open, $Query, $Close)
            try {
                $Caught = $null
                try { $Owner.Observe() | Out-Null } catch { $Caught = $_.Exception }
                if ($null -eq $Caught -or $Owner.Token -ne [IntPtr]12345 -or $Owner.Complete -or
                    [ErgoptiOwnedFixtureToken]::PendingRetirements -ne 1) {
                    throw 'Incomplete observation lost its exact token ownership or granted permission.'
                }
                if ($QueryFailed -or $CloseThrown) {
                    $Expected = if ($QueryFailed) { $Owner.QueryFailure } else { $Owner.RetirementFailure }
                    while ($null -ne $Caught -and -not [Object]::ReferenceEquals($Caught, $Expected)) { $Caught = $Caught.InnerException }
                    if ($null -eq $Caught) { throw 'Token retirement replaced the first exception.' }
                }
                $FirstCloseFailure = $Owner.RetirementFailure
                if ($Owner.Retire()) { throw 'A refused close cannot clear exact retirement debt.' }
                if ($CloseThrown -and -not [Object]::ReferenceEquals($FirstCloseFailure, $Owner.RetirementFailure)) {
                    throw 'A retirement retry replaced its first exception.'
                }
                $Blocked = $false
                try { [ErgoptiOwnedFixtureToken]::ReadElevation() | Out-Null } catch { $Blocked = $true }
                if (-not $Blocked -or $script:TokenControl.queries -ne 1) { throw 'Incomplete debt retried permission observation.' }
                $script:TokenControl.ack = $true
                [ErgoptiOwnedFixtureToken]::RetryRetirement()
                if ($Owner.Token -ne [IntPtr]::Zero -or [ErgoptiOwnedFixtureToken]::PendingRetirements -ne 0 -or
                    $Owner.Complete -or $Owner.RetirementStatus -cne 'acknowledged') {
                    throw 'Exact retirement acknowledgment granted a failed observation or retained stale debt.'
                }
                $Blocked = $false
                try { $Owner.Observe() | Out-Null } catch { $Blocked = $true }
                if (-not $Blocked -or $script:TokenControl.queries -ne 1) { throw 'The same observation reopened permission acquisition.' }
            } finally {
                $script:TokenControl.ack = $true
                $Owner.Retire() | Out-Null
            }
        }
    }
    foreach ($QueryFailed in @($false, $true)) {
        $script:TokenControl = @{ token = [IntPtr]12345; queries = 0; closes = 0; queryFailed = $QueryFailed }
        $Owner = [ErgoptiOwnedFixtureToken+Observation]::new(
            [Func[IntPtr]]{ return $script:TokenControl.token },
            [Func[IntPtr, bool]]{
                param($Token)
                $script:TokenControl.queries++
                if ($Token -ne $script:TokenControl.token) { throw 'The query used a different token.' }
                if ($script:TokenControl.queryFailed) { throw 'CONTROLLED_QUERY_FAILURE' }
                return $true
            },
            [Func[IntPtr, bool]]{
                param($Token)
                $script:TokenControl.closes++
                if ($Token -ne $script:TokenControl.token) { throw 'Retirement used a different token.' }
                return $true
            })
        $Caught = $null
        try { $Elevated = $Owner.Observe() } catch { $Caught = $_.Exception }
        if ($QueryFailed) {
            while ($null -ne $Caught -and -not [Object]::ReferenceEquals($Caught, $Owner.QueryFailure)) { $Caught = $Caught.InnerException }
            if ($null -eq $Caught -or $Owner.Complete) { throw 'Acknowledged retirement replaced a failed query.' }
        } elseif ($null -ne $Caught -or -not $Elevated -or -not $Owner.Complete) {
            throw 'A complete observation did not return its actual permission result.'
        }
        if ($Owner.Token -ne [IntPtr]::Zero -or [ErgoptiOwnedFixtureToken]::PendingRetirements -ne 0 -or
            $script:TokenControl.queries -ne 1 -or $script:TokenControl.closes -ne 1) {
            throw 'Successful retirement left debt or repeated permission observation.'
        }
    }
    if (-not $NativeElevation) {
        $Rejected = $false
        try { Assert-OwnedFixtureRootScope 'LocalMachine' } catch { $Rejected = $true }
        if (-not $Rejected) { throw 'Intent strings bypassed the actual native token guard.' }
        $Rejected = $false
        try {
            Remove-OwnedRoot '00112233445566778899AABBCCDDEEFF00112233' `
                'CN=ErgoptiPlus managed-network fixture 00112233445566778899aabbccddeeff' 'LocalMachine'
        } catch { $Rejected = $true }
        if (-not $Rejected) { throw 'Cleanup entered machine-store access without native permission.' }
    } else {
        Assert-OwnedFixtureRootScope 'LocalMachine'
    }
} finally {
    $env:GITHUB_ACTIONS = $SavedActions
    $env:RUNNER_ENVIRONMENT = $SavedRunner
}
[Console]::Out.WriteLine('OWNED_ROOT_SCOPE_CONTROL_PASS')
