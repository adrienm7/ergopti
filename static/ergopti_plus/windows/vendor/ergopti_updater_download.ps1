# vendor/ergopti_updater_download.ps1
# Download mechanics for the private tree-owned updater staging process.
# Route policy is supplied by the canonical network owner, once per exact URL.
# Defines only a native clock and functions; no input, request or file operation
# happens on load. It never publishes raw exceptions.
if (-not ('ErgoptiUpdaterMonotonicClock' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ErgoptiUpdaterMonotonicClock
{
    [DllImport("kernel32.dll", ExactSpelling = true)]
    public static extern UInt64 GetTickCount64();
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool CreateDirectoryW(string path, IntPtr security);
}
'@ -ErrorAction Stop
}

function Get-ErgoptiUpdaterNativeException {
    param([Exception]$Exception)
    while ($Exception -is [System.Management.Automation.MethodInvocationException] -and
        $null -ne $Exception.InnerException) {
        $Exception = $Exception.InnerException
    }
    return $Exception
}

function Get-ErgoptiUpdaterFailureReceipt {
    param([Exception]$Exception, [hashtable]$State)
    if ($State.Receipt -is [hashtable] -and $State.Receipt.Count -ne 0) {
        return $State.Receipt
    }
    $Native = Get-ErgoptiUpdaterNativeException $Exception
    $Stage = if ($State.Stage -in @('proxy_resolve', 'connect', 'http', 'tls',
        'file_read', 'file_write', 'file_create', 'file_remove')) { $State.Stage } else { 'connect' }
    $Receipt = @{ backend = 'dotnet'; stage = $Stage; failure_provenance = 'unknown' }
    if ($State.Stage -in @('file_read', 'file_write', 'file_create', 'file_remove')) {
        $Receipt.stage = $State.Stage
        if ($Native -is [ComponentModel.Win32Exception] -and $Native.NativeErrorCode -gt 0) {
            $Receipt.failure_provenance = 'verified'
            $Receipt.native_errno_domain = 'win32'
            $Receipt.native_errno = [string]$Native.NativeErrorCode
            return $Receipt
        }
        if ($Native -is [System.IO.IOException] -or
            $Native -is [UnauthorizedAccessException]) {
            # HRESULT_FROM_WIN32, not every managed IOException's low word.
            $Bits = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$Native.HResult), 0)
            if (($Bits -band 4294901760) -eq 2147942400) {
                $Receipt.failure_provenance = 'verified'
                $Receipt.native_errno_domain = 'win32'
                $Receipt.native_errno = [string]($Bits -band 65535)
            }
        }
        return $Receipt
    }
    if ($Native -is [System.Net.WebException]) {
        # Preserve the documented typed status without inventing an OS errno.
        if ([Enum]::IsDefined([System.Net.WebExceptionStatus], $Native.Status)) {
            $Receipt.dotnet_web_status = [string]$Native.Status
        }
        if ($Native.Status -eq [System.Net.WebExceptionStatus]::TrustFailure) {
            $Receipt.stage = 'tls'
            $Receipt.failure_provenance = 'verified'
            $Receipt.tls_verification = 'enforced'
            $Receipt.tls_status = 'untrusted_certificate'
        } elseif ($Native.Status -eq [System.Net.WebExceptionStatus]::SecureChannelFailure) {
            $Receipt.stage = 'tls'
            $Receipt.tls_verification = 'enforced'
        } elseif ($Native.Response -is [System.Net.HttpWebResponse]) {
            $Receipt.stage = 'http'
            $Receipt.failure_provenance = 'verified'
            $Receipt.http_status = [int]$Native.Response.StatusCode
            $Receipt.http_response_source = 'unavailable'
        }
    }
    return $Receipt
}

function Get-ErgoptiUpdaterRemainingMilliseconds {
    param([int64]$StartedTick, [int]$DeadlineMs, [hashtable]$State = $null)
    $NowTick = [ErgoptiUpdaterMonotonicClock]::GetTickCount64()
    if ($StartedTick -le 0 -or $NowTick -lt $StartedTick -or $DeadlineMs -le 0) {
        throw [ArgumentException]::new('Original updater monotonic deadline was refused.')
    }
    $Remaining = [int64]$DeadlineMs - ([int64]$NowTick - $StartedTick)
    if ($Remaining -le 0) {
        if ($null -ne $State) { $State.Reason = 'deadline' }
        throw [TimeoutException]::new('Updater download deadline expired.')
    }
    return [int][Math]::Min($Remaining, [int]::MaxValue)
}

function Add-ErgoptiUpdaterCleanupDebt {
    param([hashtable]$State, [string]$Resource, [string]$Stage, [Exception]$Exception)
    if (-not $State.ContainsKey('CleanupDebt')) { $State.CleanupDebt = @() }
    $CleanState = @{ Stage = $Stage; Receipt = @{} }
    $State.CleanupDebt += @{ resource = $Resource;
        receipt = (Get-ErgoptiUpdaterFailureReceipt $Exception $CleanState) }
}

function Close-ErgoptiUpdaterResource {
    param([IDisposable]$Resource, [string]$Name, [string]$Stage, [hashtable]$State)
    if ($null -eq $Resource) { return }
    try { $Resource.Dispose() } catch {
        # The primary error remains unchanged. The parent's private Job owner
        # must physically retire this process before publishing any retry.
        Add-ErgoptiUpdaterCleanupDebt $State $Name $Stage $_.Exception
    }
}

function Assert-ErgoptiUpdaterDestination {
    param([Uri]$Destination)
    if (-not $Destination.IsAbsoluteUri -or $Destination.Scheme -ne 'https' -or
        $Destination.UserInfo -ne '' -or $Destination.Fragment -ne '') {
        throw [ArgumentException]::new('Updater destination was refused.')
    }
}

function New-ErgoptiUpdaterProxyCredentials {
    param([Parameter(Mandatory = $true)][Uri]$ProxyUri)
    # Automatic .NET authentication cannot prove the guarded curl NTLM boundary.
    $Credentials = [System.Net.CredentialCache]::new()
    $Credentials.Add($ProxyUri, 'Negotiate', [System.Net.CredentialCache]::DefaultNetworkCredentials)
    return ,$Credentials
}

function Invoke-ErgoptiUpdaterDownload {
    param(
        [System.Net.HttpWebRequest]$InitialRequest,
        [string]$NewExe,
        [int]$TimeoutMs,
        [hashtable]$State,
        [scriptblock]$ResolveRoutes,
        [int]$DeadlineMs,
        [int64]$StartedTick
    )
    if ($null -eq $ResolveRoutes -or $TimeoutMs -le 0 -or $DeadlineMs -le 0 -or $StartedTick -le 0) {
        throw [ArgumentException]::new('Canonical updater routing owner is unavailable.')
    }
    $Destination = $InitialRequest.RequestUri
    $MaximumHops = $null
    $Response = $null
    $Input = $null
    $Output = $null
    try {
        $null = Get-ErgoptiUpdaterRemainingMilliseconds $StartedTick $DeadlineMs $State
        $State.Stage = 'file_create'
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($NewExe)) | Out-Null
        $State.Stage = 'file_remove'
        [IO.File]::Delete($NewExe)
        $Hop = 0
        while ($true) {
            Assert-ErgoptiUpdaterDestination $Destination
            $State.Stage = 'proxy_resolve'
            $Remaining = Get-ErgoptiUpdaterRemainingMilliseconds $StartedTick $DeadlineMs $State
            $Selection = & $ResolveRoutes $Destination.AbsoluteUri $Remaining
            if ($null -ne $Selection -and $Selection.CleanupDebt -is [bool] -and
                $Selection.CleanupDebt) {
                # This is native resolver retirement debt, not a filesystem or
                # HTTP receipt resource. The parent's owned Job remains the fence.
                $State.NativeCleanupDebt = $true
            }
            if ($null -eq $Selection -or $Selection.Ok -isnot [bool] -or
                -not $Selection.Ok -or $Selection.Routes -isnot [array] -or
                $Selection.Routes.Count -eq 0 -or
                ($Selection.MaxRoutes -isnot [int] -and $Selection.MaxRoutes -isnot [long]) -or
                $Selection.MaxRoutes -le 0 -or $Selection.MaxRoutes -gt [int]::MaxValue -or
                $Selection.Routes.Count -gt $Selection.MaxRoutes -or
                ($Selection.MaxRedirects -isnot [int] -and $Selection.MaxRedirects -isnot [long]) -or
                $Selection.MaxRedirects -lt 0 -or $Selection.MaxRedirects -gt [int]::MaxValue) {
                # Only a canonical, validated receipt can name a resolver cause.
                if ($null -ne $Selection -and $Selection.Receipt -is [hashtable]) {
                    $State.Receipt = $Selection.Receipt
                }
                throw [InvalidOperationException]::new('Canonical updater route was refused.')
            }
            if ($null -eq $MaximumHops) { $MaximumHops = $Selection.MaxRedirects }
            elseif ($MaximumHops -ne $Selection.MaxRedirects) {
                throw [InvalidOperationException]::new('Updater route policy changed during the operation.')
            }
            # Admit the whole ordered native list before using any entry. The
            # transport cannot reinterpret SOCKS or HTTPS proxies as direct.
            foreach ($Route in $Selection.Routes) {
                if ($Route.Kind -isnot [string] -or $Route.Kind -cnotin @('direct', 'proxy') -or
                    $Route.Endpoint -isnot [string]) {
                    throw [ArgumentException]::new('Updater route descriptor was refused.')
                }
                if ($Route.Kind -eq 'direct') {
                    if ($Route.Endpoint -ne '') { throw [ArgumentException]::new('Invalid direct route.') }
                } else {
                    if ($Route.Authentication -isnot [string] -or
                        $Route.Authentication -cne 'current_user_proxy_only') {
                        throw [NotSupportedException]::new('Updater proxy authentication policy was refused.')
                    }
                    [Uri]$Endpoint = $null
                    if (-not [Uri]::TryCreate($Route.Endpoint, [UriKind]::Absolute, [ref]$Endpoint) -or
                        $Endpoint.Scheme -ne 'http' -or $Endpoint.UserInfo -ne '' -or
                        $Endpoint.AbsolutePath -ne '/' -or $Endpoint.Query -ne '' -or
                        $Endpoint.Fragment -ne '') {
                        throw [NotSupportedException]::new('Updater proxy protocol was refused.')
                    }
                }
            }
            for ($RouteIndex = 0; $RouteIndex -lt $Selection.Routes.Count; $RouteIndex++) {
                $Route = $Selection.Routes[$RouteIndex]
                $Request = if ($Hop -eq 0 -and $RouteIndex -eq 0) {
                    $InitialRequest
                } else {
                    [System.Net.HttpWebRequest]::Create($Destination)
                }
                $Request.Method = 'GET'
                $Request.UserAgent = 'ErgoptiPlus-Updater/1.0'
                $Request.AllowAutoRedirect = $false
                $Request.UseDefaultCredentials = $false
                $Request.Credentials = $null
                $Request.PreAuthenticate = $false
                $Request.KeepAlive = $false
                $Request.Pipelined = $false
                $Request.ConnectionGroupName = 'ErgoptiUpdater.' + [Guid]::NewGuid().ToString('N')
                $Request.Proxy = $null
                if ($Route.Kind -eq 'proxy') {
                    $ProxyUri = [Uri]$Route.Endpoint
                    $Proxy = [System.Net.WebProxy]::new($ProxyUri, $false)
                    $Credentials = New-ErgoptiUpdaterProxyCredentials $ProxyUri
                    $Proxy.Credentials = $Credentials
                    $Request.Proxy = $Proxy
                }
                $Remaining = Get-ErgoptiUpdaterRemainingMilliseconds $StartedTick $DeadlineMs $State
                $Request.Timeout = [Math]::Min($Remaining, $TimeoutMs)
                $Request.ReadWriteTimeout = [Math]::Min($Remaining, $TimeoutMs)
                $State.Stage = 'connect'
                try {
                    $Response = $Request.GetResponse()
                    break
                } catch {
                    $Failure = $_
                    $Native = Get-ErgoptiUpdaterNativeException $Failure.Exception
                    # This GET-only retry does not claim zero previously sent
                    # bytes or CONNECT provenance under .NET's internal auth.
                    # HTTP, TLS/authentication and body failures stay terminal.
                    $RetryableGetConnection = $Native -is [System.Net.WebException] -and
                        $null -eq $Native.Response -and $Native.Status -in @(
                            [System.Net.WebExceptionStatus]::NameResolutionFailure,
                            [System.Net.WebExceptionStatus]::ProxyNameResolutionFailure,
                            [System.Net.WebExceptionStatus]::ConnectFailure)
                    $AbortFailed = $false
                    try { $Request.Abort() } catch {
                        $State.Receipt = Get-ErgoptiUpdaterFailureReceipt $Native $State
                        Add-ErgoptiUpdaterCleanupDebt $State 'request' 'connect' $_.Exception
                        $AbortFailed = $true
                    }
                    if ($AbortFailed -or -not $RetryableGetConnection -or $RouteIndex + 1 -eq $Selection.Routes.Count) {
                        if ($Native -is [System.Net.WebException] -and $null -ne $Native.Response) {
                            $State.Receipt = Get-ErgoptiUpdaterFailureReceipt $Native $State
                            Close-ErgoptiUpdaterResource $Native.Response 'response' 'http' $State
                        }
                        throw $Failure
                    }
                }
            }
            if ($null -eq $Response) { throw [InvalidOperationException]::new('No updater response.') }
            $State.Stage = 'http'
            $Status = [int]$Response.StatusCode
            if ($Status -in @(301, 302, 303, 307, 308)) {
                $Location = $Response.Headers['Location']
                if ($Hop -eq $MaximumHops -or [string]::IsNullOrEmpty($Location) -or
                    $Location -match '[\x00-\x1f\x7f]') {
                    throw [InvalidOperationException]::new('Updater redirect was refused.')
                }
                $Next = [Uri]::new($Destination, $Location)
                Assert-ErgoptiUpdaterDestination $Next
                $Response.Dispose()
                $Response = $null
                $Destination = $Next
                $Hop++
                continue
            }
            if ($Status -ne 200) {
                $State.Receipt = @{ backend = 'dotnet'; stage = 'http';
                    failure_provenance = 'verified'; http_status = $Status;
                    http_response_source = 'unavailable' }
                throw [InvalidOperationException]::new('Updater response was refused.')
            }
            break
        }
        $ExpectedSize = [int64]$Response.ContentLength
        $State.Stage = 'connect'
        $Input = $Response.GetResponseStream()
        $null = Get-ErgoptiUpdaterRemainingMilliseconds $StartedTick $DeadlineMs $State
        $State.Stage = 'file_create'
        $Output = [IO.File]::Open($NewExe, [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write, [IO.FileShare]::None)
        $Bytes = New-Object byte[] 65536
        while ($true) {
            $State.Stage = 'connect'
            $Remaining = Get-ErgoptiUpdaterRemainingMilliseconds $StartedTick $DeadlineMs $State
            $Input.ReadTimeout = [Math]::Min($Remaining, $TimeoutMs)
            $Count = $Input.Read($Bytes, 0, $Bytes.Length)
            $null = Get-ErgoptiUpdaterRemainingMilliseconds $StartedTick $DeadlineMs $State
            if ($Count -eq 0) { break }
            $State.Stage = 'file_write'
            $Output.Write($Bytes, 0, $Count)
        }
        $State.Stage = 'file_write'
        $null = Get-ErgoptiUpdaterRemainingMilliseconds $StartedTick $DeadlineMs $State
        $Output.Flush($true)
        $null = Get-ErgoptiUpdaterRemainingMilliseconds $StartedTick $DeadlineMs $State
        $Output.Dispose()
        $Output = $null
        $State.Stage = 'connect'
        $Input.Dispose()
        $Input = $null
        $State.Stage = 'http'
        $Response.Dispose()
        $Response = $null
        $null = Get-ErgoptiUpdaterRemainingMilliseconds $StartedTick $DeadlineMs $State
        return $ExpectedSize
    } catch {
        # Freeze actual failing-operation provenance before cleanup can fail.
        $State.Receipt = Get-ErgoptiUpdaterFailureReceipt $_.Exception $State
        throw
    } finally {
        # Retirement must not turn a network failure into a file-write receipt.
        Close-ErgoptiUpdaterResource $Output 'output' 'file_write' $State
        Close-ErgoptiUpdaterResource $Input 'input' 'connect' $State
        Close-ErgoptiUpdaterResource $Response 'response' 'http' $State
    }
}

# Release assets use the same owned curl attempt and causal authentication fence
# as HTTP requests. The legacy .NET function remains an explicitly selected path.
function Invoke-ErgoptiUpdaterCurlDownload {
    param(
        [Uri]$Destination, [string]$NewExe, [int]$TimeoutMs, [hashtable]$State,
        [scriptblock]$ResolveRoutes, [int]$DeadlineMs, [int64]$StartedTick,
        [int64]$AuthenticatedSize, [string]$PolicyPath, [string]$DefaultsPath,
        [scriptblock]$ReadEnvironment = $null
    )
    if ($AuthenticatedSize -le 0 -or $AuthenticatedSize -gt [int]::MaxValue -or
        $null -eq $ResolveRoutes -or $TimeoutMs -le 0) {
        throw [ArgumentException]::new('Authenticated artifact transport admission was refused.')
    }
    Assert-ErgoptiUpdaterDestination $Destination
    $Policy = Get-ErgoptiNetworkPolicy $PolicyPath
    $Defaults = Get-Content -LiteralPath $DefaultsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $Limits = $Defaults.archive_transfer.transport
    if (-not (Test-ErgoptiNetworkInt32 $Limits.max_header_bytes) -or
        $Limits.max_header_bytes -lt 1 -or $Limits.max_header_bytes -gt [int]::MaxValue -or $Limits.revocation_best_effort -isnot [bool]) {
        throw [ArgumentException]::new('Canonical artifact transport limits were refused.')
    }
    if ($Policy.selected_proxy_bypass -cne 'environment') {
        throw [ArgumentException]::new('Canonical selected-proxy bypass policy was refused.')
    }
    if ($null -eq $ReadEnvironment) {
        $ReadEnvironment = { param($Name) [Environment]::GetEnvironmentVariable($Name, 'Process') }
    }
    $Directory = $null
    $ParentOwnedCapture = $false
    $Engine = $null
    $Input = $null
    $Output = $null
    $Answer = @{ child_quiesced = $false }
    try {
        $null = Get-ErgoptiUpdaterRemainingMilliseconds $StartedTick $DeadlineMs $State
        $State.Stage = 'file_create'
        $Parent = [IO.Path]::GetDirectoryName($NewExe)
        [IO.Directory]::CreateDirectory($Parent) | Out-Null
        if ($State.ContainsKey('OwnedCaptureDirectory')) {
            $CaptureCandidate = $State.OwnedCaptureDirectory
            if ($CaptureCandidate -isnot [string] -or $CaptureCandidate -eq '' -or
                [IO.Path]::GetDirectoryName($CaptureCandidate) -cne $Parent -or
                [IO.Path]::GetFileName($CaptureCandidate) -cnotmatch '^curl\.[0-9a-f]{32}$' -or
                -not [IO.Directory]::Exists($CaptureCandidate)) {
                throw [ArgumentException]::new('Parent-owned artifact capture was refused.')
            }
            foreach ($Name in @('artifact.bin', 'headers.bin', 'capability.json', 'transport.conf')) {
                if (-not [IO.File]::Exists((Join-Path $CaptureCandidate $Name))) {
                    throw [ArgumentException]::new('Parent-owned artifact capture file was absent.')
                }
            }
            $ParentOwnedCapture = $true
        } else {
            $CaptureCandidate = Join-Path $Parent ('curl.' + [Guid]::NewGuid().ToString('N'))
            if (-not [ErgoptiUpdaterMonotonicClock]::CreateDirectoryW($CaptureCandidate, [IntPtr]::Zero)) {
                throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error())
            }
        }
        $Directory = $CaptureCandidate
        $Parameters = [pscustomobject]@{
            started_tick = $StartedTick; deadline_ms = $DeadlineMs;
            max_response_bytes = $AuthenticatedSize; max_header_bytes = $Limits.max_header_bytes;
            connect_timeout_ms = $TimeoutMs; revocation_best_effort = $Limits.revocation_best_effort;
            response_path = (Join-Path $Directory 'artifact.bin'); header_path = (Join-Path $Directory 'headers.bin');
            capability_path = (Join-Path $PSScriptRoot 'ergopti_curl_capabilities_worker.ps1');
            headers = @(); body = ''; user_agent = 'ErgoptiPlus-Updater/1.0'
        }
        . (Join-Path $PSScriptRoot 'ergopti_curl_attempt.ps1')
        $Engine = New-ErgoptiCurlAttemptEngine $Parameters $Answer (Join-Path $Directory 'capability.json') `
            (Join-Path $Directory 'payload.bin') (Join-Path $Directory 'transport.conf')
        $Capability = $null
        function Resolve-ErgoptiArtifactFreshSelection {
            param([Uri]$Destination)
            $Selection = & $ResolveRoutes $Destination.AbsoluteUri $Engine.GetRemainingBudget()
            if ($null -ne $Selection -and $Selection.CleanupDebt -is [bool] -and $Selection.CleanupDebt) {
                $State.NativeCleanupDebt = $true
                throw [InvalidOperationException]::new('Native routing has retained retirement debt.')
            }
            if ($null -eq $Selection -or $Selection.Ok -isnot [bool] -or -not $Selection.Ok -or
                $Selection.Routes -isnot [array] -or $Selection.Routes.Count -lt 1 -or
                -not (Test-ErgoptiNetworkInt32 $Selection.MaxRoutes) -or $Selection.MaxRoutes -lt 1 -or
                $Selection.Routes.Count -gt $Selection.MaxRoutes -or
                -not (Test-ErgoptiNetworkInt32 $Selection.MaxRedirects) -or $Selection.MaxRedirects -lt 0) {
                if ($null -ne $Selection -and $Selection.Receipt -is [hashtable]) { $State.Receipt = $Selection.Receipt }
                throw [InvalidOperationException]::new('Canonical artifact routing was refused.')
            }
            # Admit the whole list before preparing credentials for any route.
            foreach ($Route in $Selection.Routes) {
                if ($Route.Kind -cnotin @('direct', 'proxy') -or $Route.Endpoint -isnot [string]) {
                    throw [ArgumentException]::new('Artifact route descriptor was refused.')
                }
                if ($Route.Kind -ceq 'direct') {
                    if ($Route.Endpoint -cne '') { throw 'Invalid artifact direct route.' }
                } elseif ($Route.Authentication -cne 'current_user_proxy_only' -or
                    (Get-ErgoptiHttpRelay $Route.Endpoint $Policy) -cne $Route.Endpoint) {
                    throw [ArgumentException]::new('Artifact proxy route was refused.')
                }
            }
            $Bypass = ''
            foreach ($Name in $Policy.environment_bypass_precedence) {
                $Value = & $ReadEnvironment $Name
                if ($null -ne $Value -and $Value -ne '') { $Bypass = $Value; break }
            }
            if (Test-ErgoptiEnvironmentBypass $Destination $Bypass $Policy) {
                $Selection.Routes = @(@{ Kind = 'direct'; Endpoint = ''; Authentication = 'none' })
            }
            return $Selection
        }
        $MaximumHops = $null
        $Hop = 0
        while ($true) {
            Assert-ErgoptiUpdaterDestination $Destination
            $State.Stage = 'proxy_resolve'
            $State.Receipt = @{}
            $Selection = Resolve-ErgoptiArtifactFreshSelection $Destination
            if ($null -eq $MaximumHops) { $MaximumHops = $Selection.MaxRedirects }
            elseif ($MaximumHops -ne $Selection.MaxRedirects) { throw 'Artifact routing policy changed.' }
            if ($null -eq $Capability) {
                $State.Stage = 'connect'
                $Capability = $Engine.ObserveCapability()
                if ([version]$Capability.version -lt [version]'8.7.0') { throw 'Native proxy-use evidence is unavailable.' }
                # Capability observation may outlast a settings revision. Resolve
                # the complete URL afresh before the first credential-bearing child.
                continue
            }
            $Metrics = $null
            for ($DiscoveryOrdinal = 0; $DiscoveryOrdinal -lt $Selection.Routes.Count; $DiscoveryOrdinal++) {
                $Route = $Selection.Routes[$DiscoveryOrdinal]
                if ($Route.Kind -ceq 'proxy' -and (-not $Capability.sspi -or -not $Capability.spnego)) {
                    throw 'The actual native proxy authentication features are unavailable.'
                }
                $State.Stage = 'connect'
                $State.Receipt = @{ backend = 'curl'; stage = 'connect'; failure_provenance = 'unknown'; tls_verification = 'enforced' }
                if ($Route.Kind -ceq 'proxy' -and $Destination.Scheme -ceq 'https') {
                    $Discovery = $Engine.DiscoverProxy($Destination, $Route, $Capability, $Selection, $DiscoveryOrdinal)
                    if ($Discovery.ready) {
                        $FreshSelection = Resolve-ErgoptiArtifactFreshSelection $Destination
                        $Metrics = $Engine.InvokeDiscoveredRoute($Destination, $Route, 'GET', $false, $false, $FreshSelection)
                    } else { $Metrics = $Discovery.metrics }
                } else {
                    $Metrics = $Engine.InvokeRoute($Destination, $Route, 'negotiate', 'GET', $false, $false)
                    if ($Engine.TestNtlmChallenge($Destination, $Route, $Metrics, $Capability)) {
                        $Metrics = $Engine.InvokeRoute($Destination, $Route, 'ntlm', 'GET', $false, $false)
                    }
                }
                $State.Receipt.failure_provenance = 'verified'
                if ($Metrics.exit -eq 0) { break }
                $State.Receipt.curl_exit = [int]$Metrics.exit
                $State.Receipt.http_status = $Metrics.status
                $State.Receipt.proxy_connect_status = $Metrics.connect
                $State.Receipt.proxy_mode = $(if ($Metrics.proxy_used) { 'selected' } else { 'direct' })
                $State.Receipt.http_response_source = $(if ($Metrics.connect -eq 407 -and $Metrics.status -eq 0) { 'proxy' } else { 'unavailable' })
                if ($Metrics.connect -ge 400 -and $Metrics.connect -le 599 -and $Metrics.status -eq 0 -and $Metrics.proxy_used) {
                    $State.Receipt.stage = 'proxy_connect'
                }
                if ($Metrics.exit -eq 5) { $State.Receipt.stage = 'proxy_resolve' }
                if ($Metrics.exit -in @(35, 60, 77, 83)) { $State.Receipt.stage = 'tls' }
                $Retry = $Route.Kind -ceq 'proxy' -and $Metrics.proxy_used -and $Metrics.child_quiesced -and
                    $Metrics.status -eq 0 -and $Metrics.connect -eq 0 -and $Metrics.delivered -eq 0 -and
                    ($Policy.failover.proxy_name_resolution_exits -contains $Metrics.exit -or $Policy.failover.proxy_connect_exits -contains $Metrics.exit)
                if (-not $Retry) { throw [InvalidOperationException]::new('Artifact transport was refused.') }
            }
            if ($null -eq $Metrics -or $Metrics.exit -ne 0 -or -not $Engine.ChildQuiesced()) {
                throw [InvalidOperationException]::new('All artifact routes were refused.')
            }
            if ($Metrics.status -in @(301, 302, 303, 307, 308)) {
                if ($Hop -ge $MaximumHops -or -not $Metrics.headers.headers.ContainsKey('location')) { throw 'Artifact redirect was refused.' }
                $Destination = [Uri]::new($Destination, $Metrics.headers.headers.location)
                Assert-ErgoptiUpdaterDestination $Destination
                $Hop++
                continue
            }
            if ($Metrics.status -ne 200) {
                $State.Receipt = @{ backend = 'curl'; stage = 'http'; failure_provenance = 'verified';
                    http_status = $Metrics.status; http_response_source = 'unavailable' }
                throw [InvalidOperationException]::new('Artifact HTTP response was refused.')
            }
            if ($Metrics.delivered -ne $AuthenticatedSize) {
                $State.Reason = 'verify'
                throw [InvalidOperationException]::new('Authenticated artifact size mismatch.')
            }
            break
        }
        $State.Receipt = @{}
        $State.Stage = 'file_read'
        $Input = [IO.File]::Open($Parameters.response_path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        if ($Input.Length -ne $AuthenticatedSize) { $State.Reason = 'verify'; throw 'Captured artifact size changed.' }
        $State.Stage = 'file_create'
        $Output = [IO.File]::Open($NewExe, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $State.StagedExecutableOwned = $true
        $Bytes = New-Object byte[] 65536
        $Copied = [int64]0
        while ($true) {
            $null = $Engine.GetRemainingBudget()
            $State.Stage = 'file_read'
            $Count = $Input.Read($Bytes, 0, $Bytes.Length)
            $null = $Engine.GetRemainingBudget()
            if ($Count -eq 0) { break }
            $State.Stage = 'file_write'
            $Output.Write($Bytes, 0, $Count)
            $Copied += $Count
        }
        if ($Copied -ne $AuthenticatedSize) { $State.Reason = 'verify'; throw 'Artifact copy size mismatch.' }
        $State.Stage = 'file_write'
        $Output.Flush($true)
        $null = $Engine.GetRemainingBudget()
        $Output.Dispose(); $Output = $null
        $State.Stage = 'file_read'
        $Input.Dispose(); $Input = $null
        $null = $Engine.GetRemainingBudget()
        return $AuthenticatedSize
    } catch {
        if ($null -ne $Engine -and -not $Engine.ChildQuiesced()) { $State.NativeCleanupDebt = $true }
        if ($null -ne $Engine -and $Engine.GetNativeRemainingBudget() -le 0) { $State.Reason = 'deadline' }
        $State.Receipt = Get-ErgoptiUpdaterFailureReceipt $_.Exception $State
        throw
    } finally {
        Close-ErgoptiUpdaterResource $Output 'output' 'file_write' $State
        Close-ErgoptiUpdaterResource $Input 'input' 'file_read' $State
        if ($null -ne $Directory -and -not $ParentOwnedCapture) {
            if ($null -ne $Engine -and -not $Engine.ChildQuiesced()) {
                $State.NativeCleanupDebt = $true
            } else {
                try { [IO.Directory]::Delete($Directory, $true) }
                catch { Add-ErgoptiUpdaterCleanupDebt $State 'artifact_capture' 'file_remove' $_.Exception }
            }
        }
        if ($State.NativeCleanupDebt -or $State.CleanupDebt.Count -ne 0) {
            # A finally failure supersedes a pending successful return; the
            # parent's Job must close before it publishes a retry or successor.
            throw [InvalidOperationException]::new('Artifact resources have unacknowledged retirement.')
        }
    }
}
