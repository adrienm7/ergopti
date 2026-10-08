# vendor/ergopti_system_proxy_worker.ps1
# A tree-owned process bounds native PAC/WPAD discovery off the input thread.
param([Parameter(Mandatory = $true)][string]$InputPath)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Receipt = @{ version = 1; results = @(); status = 'refused' }
try {
    $InputRecord = Get-Content -LiteralPath $InputPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($InputRecord.version -ne 1 -or $InputRecord.auto_detect -isnot [bool] -or
        $InputRecord.pac_url -isnot [string] -or $InputRecord.urls -isnot [array] -or
        $InputRecord.urls.Count -eq 0 -or $InputRecord.urls.Count -gt 16 -or
        $InputRecord.policy_path -isnot [string] -or $InputRecord.updater_defaults_path -isnot [string] -or
        ($InputRecord.deadline_tick -isnot [int] -and $InputRecord.deadline_tick -isnot [long])) {
        throw 'Invalid private proxy input.'
    }
    if ($InputRecord.pac_url -eq '' -and -not $InputRecord.auto_detect) {
        throw 'No automatic proxy lookup was requested.'
    }
    foreach ($Destination in $InputRecord.urls) {
        [Uri]$Parsed = $null
        if ($Destination -isnot [string] -or $Destination -match '[\x00-\x1f\x7f]' -or
            -not [Uri]::TryCreate($Destination, [UriKind]::Absolute, [ref]$Parsed) -or
            $Parsed.Scheme -notin @('http', 'https') -or $Parsed.UserInfo -ne '') {
            throw 'Invalid private proxy destination.'
        }
    }
    if ($InputRecord.pac_url -ne '') {
        [Uri]$Pac = $null
        if ($InputRecord.pac_url -match '[\x00-\x1f\x7f]' -or
            -not [Uri]::TryCreate($InputRecord.pac_url, [UriKind]::Absolute, [ref]$Pac) -or
            $Pac.Scheme -notin @('http', 'https') -or $Pac.UserInfo -ne '') {
            throw 'Invalid automatic proxy configuration URL.'
        }
    }
    . (Join-Path $PSScriptRoot 'ergopti_network_routes.ps1')
    $Policy = Get-ErgoptiNetworkPolicy $InputRecord.policy_path
    $Defaults = Get-Content -LiteralPath $InputRecord.updater_defaults_path -Raw -Encoding UTF8 | ConvertFrom-Json
    $LookupBudget = $Defaults.release_sources.proxy_resolve_timeout_sec
    if (-not (Test-ErgoptiNetworkInt32 $LookupBudget) -or $LookupBudget -lt 1 -or $LookupBudget -gt [int]::MaxValue / 1000) {
        throw 'Canonical automatic lookup budget was refused.'
    }
    $Remaining = $InputRecord.deadline_tick - [ErgoptiNetworkPac]::CurrentTick()
    if ($Remaining -le 0 -or $Remaining -gt $LookupBudget * 1000) { throw 'Original private proxy deadline was refused.' }
    foreach ($Destination in $InputRecord.urls) {
        $Native = Resolve-ErgoptiFullUrlPac -DestinationUrl $Destination -PacUrl $InputRecord.pac_url `
            -AutoDetect $InputRecord.auto_detect -Deadline $InputRecord.deadline_tick -Policy $Policy
        if (-not $Native.OwnersRetired) { throw 'Native PAC owners have unacknowledged retirement.' }
        $Item = @{ok=$false;kind='refused';access_type=0;proxy='';bypass='';native_error=$Native.NativeError;stage='lookup'}
        if ($Native.OwnersRetired -and $Native.Kind -ceq 'no_auto_proxy' -and $Native.NativeError -eq 12180 -and
            $InputRecord.pac_url -eq '' -and $InputRecord.auto_detect) {
            $Item.kind = 'no_auto_proxy'
        } elseif ($Native.OwnersRetired -and $Native.Ok -and $Native.Kind -ceq 'pac_routes') {
            $Routes = ConvertFrom-ErgoptiPacRoutes $Native.Proxy $Policy
            # The legacy consumer owns one relay; never silently discard PAC failover entries.
            if ($Routes.Count -ne 1) { throw 'Legacy automatic route representation was refused.' }
            $Route = $Routes[0]
            $Item.ok=$true; $Item.native_error=0
            if ($Route.Kind -ceq 'direct') { $Item.kind='no_proxy';$Item.access_type=1 }
            else {
                $Relay=[Uri]$Route.Endpoint
                $Item.kind='named_proxy';$Item.access_type=3;$Item.proxy=$Relay.Host+':'+$Relay.Port
            }
        }
        $Receipt.results += $Item
    }
    $Receipt.status = 'completed'
} catch {
    # Exceptions may contain a destination, PAC URL or token. Emit only the
    # structured refusal; the parent records no native stderr or private input.
    $Receipt.results = @()
}
$Receipt | ConvertTo-Json -Depth 4 -Compress
if ($Receipt.status -ne 'completed') { exit 1 }
