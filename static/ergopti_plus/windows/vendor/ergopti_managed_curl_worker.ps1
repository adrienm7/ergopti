# vendor/ergopti_managed_curl_worker.ps1
# One request-owned Job contains discovery, capability observation and transport.
param([Parameter(Mandatory=$true)][string]$InputPath)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Answer = @{ schema_version = 1; ok = $false; status = 0; child_quiesced = $false;
    receipt = @{ backend = 'curl'; stage = 'connect'; failure_provenance = 'unknown' } }
$Child = $null

function Get-RemainingBudget {
    $Remaining = Get-NativeRemainingBudget
    if ($Remaining -le 0) { throw 'The original request budget expired.' }
    return $Remaining
}

function Get-NativeRemainingBudget {
    $Now = [ErgoptiNativeProxyEx]::CurrentTick()
    if ($Now -lt $InputValue.started_tick) { throw 'The native request clock moved backwards.' }
    return [int][Math]::Max(0, $InputValue.deadline_ms - ($Now - $InputValue.started_tick))
}

function ConvertTo-CurlLiteral {
    param([string]$Value)
    if ($Value -match '[\x00-\x1f\x7f-\x9f]') { throw 'A private curl scalar was refused.' }
    return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
}

function Invoke-OwnedProcess {
    param([string]$Executable, [string]$Arguments, [int]$MaximumOutput)
    $Start = [Diagnostics.ProcessStartInfo]::new()
    $Start.FileName = $Executable
    $Start.Arguments = $Arguments
    $Start.UseShellExecute = $false
    $Start.CreateNoWindow = $true
    $Start.RedirectStandardOutput = $true
    $Start.RedirectStandardError = $true
    $Start.StandardOutputEncoding = [Text.Encoding]::UTF8
    $Start.StandardErrorEncoding = [Text.Encoding]::UTF8
    $script:Child = [Diagnostics.Process]::new()
    $script:Child.StartInfo = $Start
    $Result = $null
    try {
        $null = Get-RemainingBudget
        if (-not $script:Child.Start()) { throw 'The owned native child did not start.' }
        $Stdout = $script:Child.StandardOutput.ReadToEndAsync()
        $Stderr = $script:Child.StandardError.ReadToEndAsync()
        if (-not $script:Child.WaitForExit((Get-RemainingBudget))) { throw 'The owned child exhausted its original budget.' }
        if (-not $Stdout.Wait((Get-RemainingBudget)) -or -not $Stderr.Wait((Get-RemainingBudget))) {
            throw 'The native pipes did not close within the original budget.'
        }
        if ($Stdout.Result.Length -gt $MaximumOutput -or $Stderr.Result.Length -gt 8192) {
            throw 'The native receipt exceeded its bound.'
        }
        $Result = @{ exit = $script:Child.ExitCode; stdout = $Stdout.Result;
            stderr_empty = ($Stderr.Result.Length -eq 0); child_quiesced = $true }
    } finally {
        $Retired = $false
        try {
            if (-not $script:Child.HasExited) { $script:Child.Kill() }
            $Remaining = Get-NativeRemainingBudget
            $Retired = $script:Child.WaitForExit($Remaining)
        } catch { $Retired = $false }
        if ($Retired) {
            $script:Child.Dispose()
            $script:Child = $null
        } else {
            $Answer.child_quiesced = $false
            throw 'The exact native child has unacknowledged retirement.'
        }
    }
    return $Result
}

function Get-OwnedCurlCapability {
    $Request = @{ schema_version = 1; budget_ms = (Get-RemainingBudget) }
    [IO.File]::WriteAllText($CapabilityInput, ($Request | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
    # Inputs contain only the budget; URL, identity, tokens and body never enter argv.
    $Executable = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
    $Args = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $InputValue.capability_path +
        '" -InputPath "' + $CapabilityInput + '"'
    $Observed = Invoke-OwnedProcess $Executable $Args 8192
    if ($Observed.exit -ne 0 -or -not $Observed.stderr_empty) { throw 'Native curl capability observation was refused.' }
    $Receipt = $Observed.stdout | ConvertFrom-Json
    if ($Receipt.schema_version -ne 1 -or $Receipt.state -cne 'ready' -or $Receipt.backend -cne 'curl' -or
        $Receipt.child_quiesced -isnot [bool] -or -not $Receipt.child_quiesced -or
        $Receipt.capability.tls_backend -cne 'schannel' -or
        $Receipt.capability.sspi -isnot [bool] -or $Receipt.capability.spnego -isnot [bool] -or
        $Receipt.capability.ntlm -isnot [bool]) {
        throw 'Actual native Schannel capability was not acknowledged.'
    }
    return $Receipt.capability
}

function Read-TransportHeaders {
    if (-not [IO.File]::Exists($InputValue.header_path) -or
        ([IO.FileInfo]::new($InputValue.header_path)).Length -gt $InputValue.max_header_bytes) {
        throw 'Native response headers were absent or exceeded their bound.'
    }
    $Blocks = [IO.File]::ReadAllText($InputValue.header_path, [Text.Encoding]::UTF8).Replace("`r`n", "`n").Split(@("`n`n"), [StringSplitOptions]::None)
    $Result = @{ status = 0; headers = @{}; connect_challenges = @() }
    foreach ($Block in $Blocks) {
        $Lines = $Block.Split("`n")
        if ($Lines.Count -eq 0 -or $Lines[0] -notmatch '^HTTP/\S+\s+([0-9]{3})(?:\s|$)') { continue }
        $Status = [int]$Matches[1]
        $Headers = @{}
        $Challenges = @()
        foreach ($Line in $Lines) {
            $Colon = $Line.IndexOf(':')
            if ($Colon -lt 1) { continue }
            $Name = $Line.Substring(0, $Colon).ToLowerInvariant()
            $Value = $Line.Substring($Colon + 1).Trim()
            if ($Value -match '[\x00-\x1f\x7f]') { throw 'Native response header syntax was refused.' }
            $Headers[$Name] = $Value
            if ($Name -ceq 'proxy-authenticate') { $Challenges += $Value }
        }
        if ($Status -eq 407) { $Result.connect_challenges = @($Challenges) }
        $Result.status = $Status
        $Result.headers = $Headers
    }
    return $Result
}

function Invoke-CurlRoute {
    param([Uri]$Destination, $Route, [string]$Authentication, [string]$Method, [bool]$SendBody, [bool]$SendHeaders)
    $Budget = Get-RemainingBudget
    $Lines = @(('url = ' + (ConvertTo-CurlLiteral $Destination.AbsoluteUri)),
        ('request = ' + (ConvertTo-CurlLiteral $Method)), 'silent', 'show-error',
        ('max-time = ' + ($Budget / 1000.0).ToString('F3', [Globalization.CultureInfo]::InvariantCulture)),
        ('connect-timeout = ' + ([Math]::Min($InputValue.connect_timeout_ms, $Budget) / 1000.0).ToString('F3', [Globalization.CultureInfo]::InvariantCulture)),
        ('max-filesize = ' + $InputValue.max_response_bytes),
        ('dump-header = ' + (ConvertTo-CurlLiteral $InputValue.header_path)),
        ('output = ' + (ConvertTo-CurlLiteral $InputValue.response_path)),
        ('write-out = ' + (ConvertTo-CurlLiteral '%{http_code}|%{http_connect}|%{size_download}|%{proxy_used}')),
        ('proxy = ' + (ConvertTo-CurlLiteral $Route.Endpoint)), 'noproxy = ""')
    if ($InputValue.revocation_best_effort) { $Lines += 'ssl-revoke-best-effort' }
    if ($Route.Kind -ceq 'proxy') {
        if ($Authentication -cnotin @('negotiate', 'ntlm')) { throw 'The proxy authentication scheme was refused.' }
        $Lines += 'proxy-' + $Authentication
        $Lines += 'proxy-user = ":"'
    }
    if ($SendHeaders) {
        foreach ($Header in $InputValue.headers) {
            $Lines += 'header = ' + (ConvertTo-CurlLiteral ($Header.name + ': ' + $Header.value))
        }
    }
    if ($SendBody -and $InputValue.body -ne '') {
        $Lines += 'data-binary = ' + (ConvertTo-CurlLiteral ('@' + $PayloadPath))
    }
    [IO.File]::WriteAllText($CurlConfig, ($Lines -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
    # Clear each attempt's private response before the child starts. A preceding
    # child's exact exit and pipes have already been acknowledged by this owner.
    [IO.File]::WriteAllBytes($InputValue.response_path, [byte[]]@())
    [IO.File]::WriteAllBytes($InputValue.header_path, [byte[]]@())
    $Executable = Join-Path ([Environment]::GetFolderPath('System')) 'curl.exe'
    $Observed = Invoke-OwnedProcess $Executable ('--disable --config "' + $CurlConfig + '"') 1024
    if ($Observed.stdout -notmatch '^([0-9]{3})\|([0-9]{3})\|([0-9]+)\|([01])$') {
        throw 'Native transport metrics were absent or malformed.'
    }
    $Metrics = @{ exit = $Observed.exit; status = [int]$Matches[1]; connect = [int]$Matches[2];
        delivered = [int64]$Matches[3]; proxy_used = ($Matches[4] -ceq '1'); child_quiesced = $Observed.child_quiesced }
    if (([IO.FileInfo]::new($InputValue.response_path)).Length -ne $Metrics.delivered -or
        $Metrics.delivered -gt $InputValue.max_response_bytes) { throw 'Native response byte accounting was refused.' }
    $Metrics.headers = Read-TransportHeaders
    return $Metrics
}

function Test-CausalNtlmChallenge {
    param([Uri]$Destination, $Route, $Metrics, $Capability)
    if ($Destination.Scheme -cne 'https' -or $Route.Kind -cne 'proxy' -or
        -not $Metrics.child_quiesced -or -not $Metrics.proxy_used -or
        $Metrics.connect -ne 407 -or $Metrics.status -ne 0 -or $Metrics.delivered -ne 0 -or
        $Capability.ntlm -isnot [bool] -or -not $Capability.ntlm) { return $false }
    $Ntlm = $false
    foreach ($Challenge in $Metrics.headers.connect_challenges) {
        # Parse the bounded actual CONNECT response, not an origin401 or a
        # guessed proxy target. No token or identity is retained in the receipt.
        if ($Challenge -cmatch '^(?i:NTLM)(?: [A-Za-z0-9+/]+={0,2})?$') { $Ntlm = $true; continue }
        if ($Challenge -match '^Negotiate(?:\s|$)') { return $false }
        if ($Challenge -match '^(Basic|Digest)(?:\s|$)') { continue }
        return $false
    }
    return $Ntlm
}

try {
    $InputValue = Get-Content -LiteralPath $InputPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($InputValue.schema_version -ne 1 -or $InputValue.budget_ms -isnot [int] -or $InputValue.budget_ms -lt 1 -or
        ($InputValue.started_tick -isnot [int] -and $InputValue.started_tick -isnot [long]) -or $InputValue.started_tick -lt 0 -or
        $InputValue.deadline_ms -isnot [int] -or $InputValue.deadline_ms -lt 1 -or
        $InputValue.request_id -isnot [string] -or $InputValue.request_id -cnotmatch '^[0-9]+_[0-9]+$' -or
        $InputValue.method -cnotin @('GET', 'POST', 'DELETE') -or $InputValue.body -isnot [string] -or
        $InputValue.headers -isnot [array] -or $InputValue.max_response_bytes -isnot [int] -or
        $InputValue.max_response_bytes -lt 1 -or $InputValue.max_header_bytes -isnot [int] -or
        $InputValue.max_header_bytes -lt 1 -or $InputValue.connect_timeout_ms -isnot [int] -or
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
    $null = Get-RemainingBudget
    $Policy = Get-ErgoptiNetworkPolicy $InputValue.policy_path
    $Destination = Get-ErgoptiDestination $InputValue.url
    $OriginalOrigin = $Destination.GetLeftPart([UriPartial]::Authority)
    $Method = $InputValue.method
    $SendBody = $true
    $SendHeaders = $true
    $Capability = $null
    $TransportAdmitted = $false
    $Redirects = 0
    while ($true) {
        $Answer.receipt = @{ backend = 'curl'; stage = 'proxy_resolve'; failure_provenance = 'unknown' }
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
        $Metrics = $null
        if ($null -eq $Capability) {
            # OS trust belongs to DIRECT requests too. SSPI/SPNEGO admission is
            # required separately only when a proxy route is actually attempted.
            $Capability = Get-OwnedCurlCapability
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
        foreach ($Route in $Selection.Routes) {
            if ($Route.Kind -cnotin @('direct', 'proxy')) { throw 'A native route kind was refused.' }
            if ($Route.Kind -ceq 'proxy') {
                if (-not $Capability.sspi -or -not $Capability.spnego -or
                    $Route.Authentication -cne 'current_user_proxy_only') { throw 'Sole Negotiate native proxy admission was refused.' }
            }
            $Answer.receipt = @{ backend = 'curl'; stage = 'connect'; failure_provenance = 'verified'; tls_verification = 'enforced' }
            $Metrics = Invoke-CurlRoute $Destination $Route 'negotiate' $Method $SendBody $SendHeaders
            if (Test-CausalNtlmChallenge $Destination $Route $Metrics $Capability) {
                $Metrics = Invoke-CurlRoute $Destination $Route 'ntlm' $Method $SendBody $SendHeaders
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
    if ($null -eq $Child) { $Answer.child_quiesced = $true }
}
[Console]::Out.WriteLine(($Answer | ConvertTo-Json -Compress -Depth 4))
if (-not $Answer.ok) { exit 1 }
