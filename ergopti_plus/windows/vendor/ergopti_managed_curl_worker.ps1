# vendor/ergopti_managed_curl_worker.ps1
# One request-owned Job contains discovery, capability observation and transport.
param([Parameter(Mandatory=$true)][string]$InputPath)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Answer = @{ schema_version = 1; ok = $false; status = 0; child_quiesced = $false;
    receipt = @{ backend = 'curl'; stage = 'connect'; failure_provenance = 'unknown' } }
$AttemptEngine = $null

function Test-ErgoptiManagedInt32 {
    param($Value)
    # JSON integer storage may be Int32 or Int64; never coerce other JSON kinds.
    return (($Value -is [int] -or $Value -is [long]) -and
        $Value -ge [int]::MinValue -and $Value -le [int]::MaxValue)
}

function Get-RemainingBudget { return $AttemptEngine.GetRemainingBudget() }
function Get-NativeRemainingBudget { return $AttemptEngine.GetNativeRemainingBudget() }

try {
    $InputValue = Get-Content -LiteralPath $InputPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not (Test-ErgoptiManagedInt32 $InputValue.schema_version) -or $InputValue.schema_version -ne 1 -or -not (Test-ErgoptiManagedInt32 $InputValue.budget_ms) -or $InputValue.budget_ms -lt 1 -or
        ($InputValue.started_tick -isnot [int] -and $InputValue.started_tick -isnot [long]) -or $InputValue.started_tick -lt 0 -or
        -not (Test-ErgoptiManagedInt32 $InputValue.deadline_ms) -or $InputValue.deadline_ms -lt 1 -or
        $InputValue.request_id -isnot [string] -or $InputValue.request_id -cnotmatch '^[0-9]+_[0-9]+$' -or
        $InputValue.method -cnotin @('GET', 'POST', 'DELETE') -or $InputValue.body -isnot [string] -or
        $InputValue.headers -isnot [array] -or -not (Test-ErgoptiManagedInt32 $InputValue.max_response_bytes) -or
        $InputValue.max_response_bytes -lt 1 -or -not (Test-ErgoptiManagedInt32 $InputValue.max_header_bytes) -or
        $InputValue.max_header_bytes -lt 1 -or -not (Test-ErgoptiManagedInt32 $InputValue.connect_timeout_ms) -or
        $InputValue.connect_timeout_ms -lt 1 -or $InputValue.revocation_best_effort -isnot [bool]) {
        throw 'The private managed HTTP input was refused.'
    }
    foreach ($Name in @('policy_path', 'defaults_path', 'route_path', 'capability_path', 'response_path', 'header_path')) {
        if ($InputValue.$Name -isnot [string] -or $InputValue.$Name -eq '' -or
            $InputValue.$Name -match '[\x00-\x1f\x7f"]' -or -not [IO.Path]::IsPathRooted($InputValue.$Name)) {
            throw 'A required explicit private path was refused.'
        }
    }
    foreach ($Header in $InputValue.headers) {
        if ($Header.name -isnot [string] -or $Header.name -cnotmatch '^[!#$%&''*+.^_`|~0-9A-Za-z-]+$' -or
            $Header.value -isnot [string] -or $Header.value -match '[\x00-\x1f\x7f-\x9f]') {
            throw 'A private request header was refused.'
        }
    }
    $Directory = [IO.Path]::GetDirectoryName($InputPath)
    $CapabilityInput = Join-Path $Directory 'capability.json'
    $PayloadPath = Join-Path $Directory 'payload.bin'
    $CurlConfig = Join-Path $Directory 'transport.conf'
    . $InputValue.route_path
    . (Join-Path $PSScriptRoot 'ergopti_curl_attempt.ps1')
    $AttemptEngine = New-ErgoptiCurlAttemptEngine $InputValue $Answer $CapabilityInput $PayloadPath $CurlConfig
    $null = Get-RemainingBudget
    $Policy = Get-ErgoptiNetworkPolicy $InputValue.policy_path
    $Destination = Get-ErgoptiDestination $InputValue.url
    function Resolve-ErgoptiManagedFreshSelection {
        param([Uri]$Destination)
        if ($InputValue.fixed_proxy -is [string]) {
            $Endpoint = $InputValue.fixed_proxy
            if ($Endpoint -ne '') { $Endpoint = Get-ErgoptiHttpRelay $Endpoint $Policy }
            $Selection = @{ Ok = $true; MaxRoutes = $Policy.max_selections; MaxRedirects = $Policy.redirects.max_hops;
                Routes = @(@{ Kind = $(if ($Endpoint -eq '') { 'direct' } else { 'proxy' }); Endpoint = $Endpoint;
                    Authentication = $(if ($Endpoint -eq '') { 'none' } else { 'current_user_proxy_only' }) }) }
        } else {
            $SettingsReader = $null
            if ($null -ne $InputValue.settings_override) {
                $SettingsReader = { param($MaximumBytes) $InputValue.settings_override }
            }
            $Selection = Resolve-ErgoptiNativeNetworkRoutes $Destination.AbsoluteUri (Get-RemainingBudget) $SettingsReader $null $InputValue.policy_path $InputValue.defaults_path
        }
        if ($Selection.CleanupDebt) { throw 'Native route callbacks have unacknowledged retirement.' }
        if (-not $Selection.Ok) {
            $Answer.receipt = $Selection.Receipt
            throw 'Native full-URL routing was refused.'
        }
        if ($Selection.Routes.Count -lt 1 -or $Selection.Routes.Count -gt $Selection.MaxRoutes) { throw 'Native route count was refused.' }
        # The current shared policy preserves environment bypass for selected
        # system relays too. An explicit curl proxy must not erase no_proxy.
        if ($Policy.selected_proxy_bypass -cne 'environment') { throw 'Canonical selected-proxy bypass policy was refused.' }
        $Bypass = ''
        foreach ($Name in $Policy.environment_bypass_precedence) {
            $Value = [Environment]::GetEnvironmentVariable($Name)
            if ($null -ne $Value -and $Value -ne '') { $Bypass = $Value; break }
        }
        if (Test-ErgoptiEnvironmentBypass $Destination $Bypass $Policy) {
            $Selection.Routes = @(@{ Kind = 'direct'; Endpoint = ''; Authentication = 'none'; Source = 'environment_bypass' })
        }
        $null = Get-RemainingBudget
        return $Selection
    }
    $OriginalOrigin = $Destination.GetLeftPart([UriPartial]::Authority)
    $Method = $InputValue.method
    $SendBody = $true
    $SendHeaders = $true
    $Capability = $null
    $TransportAdmitted = $false
    $Redirects = 0
    while ($true) {
        $Answer.receipt = @{ backend = 'curl'; stage = 'proxy_resolve'; failure_provenance = 'unknown' }
        $Selection = Resolve-ErgoptiManagedFreshSelection $Destination
        $Metrics = $null
        if ($null -eq $Capability) {
            # OS trust belongs to DIRECT requests too. SSPI/SPNEGO admission is
            # required separately only when a proxy route is actually attempted.
            $Capability = $AttemptEngine.ObserveCapability()
            if ([version]$Capability.version -lt [version]'8.7.0') { throw 'Native proxy-use provenance is unavailable.' }
            # Observation can outlast a settings revision; reroute before staging
            # the first credential/body transport config under the same budget.
            if ($InputValue.fixed_proxy -isnot [string]) { continue }
        }
        if (-not $TransportAdmitted) {
            foreach ($Route in $Selection.Routes) {
                if ($Route.Kind -ceq 'proxy' -and (-not $Capability.sspi -or -not $Capability.spnego)) {
                    throw 'Missing native proxy features refuse before secret staging.'
                }
            }
            $Ack = @{ schema_version = 1; request_id = $InputValue.request_id;
                state = 'ready'; tls_backend = $Capability.tls_backend; child_quiesced = $true }
            $AckStaged = Join-Path $Directory 'admission.pending'
            $AckPath = Join-Path $Directory 'admission.json'
            [IO.File]::WriteAllText($AckStaged, ($Ack | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
            [IO.File]::Move($AckStaged, $AckPath)
            $TransportPath = Join-Path $Directory 'transport.json'
            while (-not [IO.File]::Exists($TransportPath)) {
                $null = Get-RemainingBudget
                Start-Sleep -Milliseconds 10
            }
            $TransportInput = Get-Content -LiteralPath $TransportPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($TransportInput.schema_version -ne 1 -or $TransportInput.request_id -cne $InputValue.request_id -or
                $TransportInput.body -isnot [string] -or $TransportInput.headers -isnot [array]) {
                throw 'The exact admitted transport input was refused.'
            }
            foreach ($Header in $TransportInput.headers) {
                if ($Header.name -isnot [string] -or $Header.name -cnotmatch '^[!#$%&''*+.^_`|~0-9A-Za-z-]+$' -or
                    $Header.value -isnot [string] -or $Header.value -match '[\x00-\x1f\x7f-\x9f]') {
                    throw 'An admitted private request header was refused.'
                }
            }
            $InputValue.body = $TransportInput.body
            $InputValue.headers = $TransportInput.headers
            [IO.File]::WriteAllText($PayloadPath, $InputValue.body, [Text.UTF8Encoding]::new($false))
            $TransportAdmitted = $true
            # Consent and filesystem publication can outlast a settings change.
            # Route the exact complete URL again before the first transport.
            if ($InputValue.fixed_proxy -isnot [string]) { continue }
        }
        for ($DiscoveryOrdinal = 0; $DiscoveryOrdinal -lt $Selection.Routes.Count; $DiscoveryOrdinal++) {
            $Route = $Selection.Routes[$DiscoveryOrdinal]
            if ($Route.Kind -cnotin @('direct', 'proxy')) { throw 'A native route kind was refused.' }
            if ($Route.Kind -ceq 'proxy') {
                if (-not $Capability.sspi -or -not $Capability.spnego -or
                    $Route.Authentication -cne 'current_user_proxy_only') { throw 'Sole Negotiate native proxy admission was refused.' }
            }
            $Answer.receipt = @{ backend = 'curl'; stage = 'connect'; failure_provenance = 'verified'; tls_verification = 'enforced' }
            if ($Route.Kind -ceq 'proxy' -and $Destination.Scheme -ceq 'https') {
                $Discovery = $AttemptEngine.DiscoverProxy($Destination, $Route, $Capability, $Selection, $DiscoveryOrdinal)
                if ($Discovery.ready) {
                    # Re-evaluate the complete original URL after the anonymous
                    # child's actual EOF/reap, before current-user credentials.
                    $FreshSelection = Resolve-ErgoptiManagedFreshSelection $Destination
                    $Metrics = $AttemptEngine.InvokeDiscoveredRoute($Destination, $Route, $Method, $SendBody, $SendHeaders, $FreshSelection)
                } else { $Metrics = $Discovery.metrics }
            } else {
                $Metrics = $AttemptEngine.InvokeRoute($Destination, $Route, 'negotiate', $Method, $SendBody, $SendHeaders)
                if ($AttemptEngine.TestNtlmChallenge($Destination, $Route, $Metrics, $Capability)) {
                    $Metrics = $AttemptEngine.InvokeRoute($Destination, $Route, 'ntlm', $Method, $SendBody, $SendHeaders)
                }
            }
            if ($Metrics.exit -eq 0) { break }
            $Answer.receipt.curl_exit = [int]$Metrics.exit
            $Answer.receipt.http_status = $Metrics.status
            $Answer.receipt.proxy_connect_status = $Metrics.connect
            $Answer.receipt.proxy_mode = $(if ($Metrics.proxy_used) { 'selected' } else { 'direct' })
            $Answer.receipt.http_response_source = $(if ($Metrics.connect -eq 407 -and $Metrics.status -eq 0) { 'proxy' } else { 'unavailable' })
            if ($Metrics.connect -ge 400 -and $Metrics.connect -le 599 -and $Metrics.status -eq 0 -and $Metrics.proxy_used) { $Answer.receipt.stage = 'proxy_connect' }
            if ($Metrics.exit -eq 5) { $Answer.receipt.stage = 'proxy_resolve' }
            if ($Metrics.exit -eq 60) { $Answer.receipt.stage = 'tls' }
            $Retry = $Route.Kind -ceq 'proxy' -and $Metrics.proxy_used -and $Metrics.child_quiesced -and
                $Metrics.status -eq 0 -and $Metrics.connect -eq 0 -and $Metrics.delivered -eq 0 -and
                ($Policy.failover.proxy_name_resolution_exits -contains $Metrics.exit -or $Policy.failover.proxy_connect_exits -contains $Metrics.exit)
            if (-not $Retry) { throw 'Native transport refused this request.' }
        }
        if ($null -eq $Metrics) { continue }
        if ($Metrics.exit -ne 0) { throw 'Every admitted route was refused.' }
        if ($Metrics.status -in @(301, 302, 303, 307, 308)) {
            if (-not $Metrics.headers.headers.ContainsKey('location') -or $Redirects -ge $Selection.MaxRedirects) { throw 'Native redirect admission was refused.' }
            $Next = [Uri]::new($Destination, $Metrics.headers.headers.location)
            $Next = Get-ErgoptiDestination $Next.AbsoluteUri
            if ($Destination.Scheme -ceq 'https' -and $Next.Scheme -cne 'https') { throw 'A TLS downgrade redirect was refused.' }
            # A redirect never forwards provider credentials or user payload to
            # another origin. Cross-origin GETs lose all caller headers; unsafe
            # method-preserving redirects refuse before contacting that origin.
            if ($Next.GetLeftPart([UriPartial]::Authority) -cne $OriginalOrigin) {
                if ($Method -cne 'GET' -and $Metrics.status -ne 303) { throw 'A cross-origin payload redirect was refused.' }
                $SendHeaders = $false
            }
            if ($Metrics.status -eq 303 -or ($Method -ceq 'POST' -and $Metrics.status -in @(301, 302))) {
                $Method = 'GET'
                $SendBody = $false
            }
            $Destination = $Next
            $Redirects += 1
            continue
        }
        $null = Get-RemainingBudget
        $Answer.status = $Metrics.status
        $Answer.ok = $true
        $Answer.child_quiesced = $true
        $Answer.receipt = @{}
        break
    }
} catch {
    # Never publish an exception, endpoint, body, header, identity or native stderr.
    $Answer.ok = $false
    if ($null -eq $AttemptEngine -or $AttemptEngine.ChildQuiesced()) { $Answer.child_quiesced = $true }
}
[Console]::Out.WriteLine(($Answer | ConvertTo-Json -Compress -Depth 4))
if (-not $Answer.ok) { exit 1 }
