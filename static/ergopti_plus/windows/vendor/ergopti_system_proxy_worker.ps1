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
        $InputRecord.urls.Count -eq 0 -or $InputRecord.urls.Count -gt 16) {
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
    . (Join-Path $PSScriptRoot 'ergopti_native_proxy.ps1')
    foreach ($Destination in $InputRecord.urls) {
        $Native = [ErgoptiNativeProxy]::Resolve($Destination, $InputRecord.pac_url, $InputRecord.auto_detect)
        $Receipt.results += @{
            ok = $Native.Ok; kind = $Native.Kind; access_type = $Native.AccessType
            proxy = $Native.Proxy; bypass = $Native.Bypass
            native_error = $Native.NativeError; stage = $Native.Stage
        }
    }
    $Receipt.status = 'completed'
} catch {
    # Exceptions may contain a destination, PAC URL or token. Emit only the
    # structured refusal; the parent records no native stderr or private input.
    $Receipt.results = @()
}
$Receipt | ConvertTo-Json -Depth 4 -Compress
if ($Receipt.status -ne 'completed') { exit 1 }
