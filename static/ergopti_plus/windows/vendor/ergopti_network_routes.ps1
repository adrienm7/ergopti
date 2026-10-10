# vendor/ergopti_network_routes.ps1
# Closed native routing admission for updater HttpWebRequest transport.
# Shared inventories define portable policy; WinINet formats remain native inputs.
. (Join-Path $PSScriptRoot 'ergopti_windows_proxy_config.ps1')
. (Join-Path $PSScriptRoot 'ergopti_native_proxy_ex.ps1')
. (Join-Path $PSScriptRoot 'ergopti_network_pac.ps1')

function Test-ErgoptiNetworkInt32 {
    param($Value)
    # JSON integer storage may be Int32 or Int64; never coerce other JSON kinds.
    return (($Value -is [int] -or $Value -is [long]) -and
        $Value -ge [int]::MinValue -and $Value -le [int]::MaxValue)
}

function New-ErgoptiRouteRefusal {
    param([string]$Backend = 'winhttp', [string]$Status = 'unavailable',
        [int]$NativeError = 0, [bool]$ObservedNative = $false, [ValidateSet('win32','winsock','posix')][string]$NativeErrorDomain = 'win32')
    $Receipt = @{ backend = $Backend; stage = 'proxy_resolve';
        failure_provenance = $(if ($ObservedNative) { 'verified' } else { 'unknown' });
        proxy_resolution_status = $Status }
    if ($ObservedNative -and $NativeError -ne 0) {
        $Receipt.native_errno_domain = $NativeErrorDomain
        $Receipt.native_errno = [string]$NativeError
    }
    return @{ Ok = $false; Routes = @(); Receipt = $Receipt }
}

function Get-ErgoptiNetworkPolicy {
    param([Parameter(Mandatory=$true)][string]$Path)
    $Policy = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not (Test-ErgoptiNetworkInt32 $Policy.schema_version) -or $Policy.schema_version -ne 1 -or -not (Test-ErgoptiNetworkInt32 $Policy.max_selections) -or
        $Policy.max_selections -lt 1 -or $Policy.max_selections -gt 4096 -or
        -not (Test-ErgoptiNetworkInt32 $Policy.max_proxy_bytes) -or $Policy.max_proxy_bytes -lt 2 -or
        $Policy.max_proxy_bytes -gt 1048576 -or $Policy.missing_native_capability -cne 'environment' -or
        -not (Test-ErgoptiNetworkInt32 $Policy.redirects.max_hops) -or $Policy.redirects.max_hops -lt 1) {
        throw 'Canonical proxy inventory was refused.'
    }
    foreach ($Inventory in @($Policy.allowed_proxy_schemes,
        $Policy.environment_precedence.http, $Policy.environment_precedence.https,
        $Policy.environment_bypass_precedence,
        $Policy.loopback.dns_hosts, $Policy.loopback.dns_suffixes,
        $Policy.loopback.ipv4_cidrs, $Policy.loopback.ipv6_addresses)) {
        if ($Inventory -isnot [array] -or $Inventory.Count -eq 0) { throw 'Invalid canonical proxy inventory.' }
        $Seen = [Collections.Generic.Dictionary[string,bool]]::new([StringComparer]::Ordinal)
        foreach ($Name in $Inventory) {
            if ($Name -isnot [string] -or $Name -eq '' -or $Seen.ContainsKey($Name)) {
                throw 'Invalid canonical proxy inventory member.'
            }
            $Seen[$Name] = $true
        }
    }
    return $Policy
}

function Get-ErgoptiDestination {
    param([string]$Url)
    [Uri]$Parsed = $null
    if ($Url -match '[\x00-\x20\x7f]' -or -not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$Parsed) -or
        $Parsed.Scheme -notin @('http', 'https') -or $Parsed.Host -eq '' -or
        $Parsed.UserInfo -ne '' -or $Parsed.Fragment -ne '') { throw 'Private destination was refused.' }
    return $Parsed
}

function Test-ErgoptiAddressRange {
    param([string]$HostName, [string]$Range)
    $Parts = $Range.Split('/')
    if ($Parts.Count -ne 2 -or $Parts[1] -notmatch '^\d+$') { throw 'Canonical address range was refused.' }
    [Net.IPAddress]$Address = $null
    [Net.IPAddress]$Base = $null
    if (-not [Net.IPAddress]::TryParse($Parts[0], [ref]$Base)) { throw 'Canonical address range was refused.' }
    $Bits = [int]$Parts[1]
    $BaseBytes = $Base.GetAddressBytes()
    if ($BaseBytes.Length -eq 4 -and ($Parts[0] -notmatch '^(?:0|[1-9][0-9]{0,2})(?:\.(?:0|[1-9][0-9]{0,2})){3}$' -or
        $Parts[0] -cne $Base.ToString())) { throw 'Canonical numeric address range was refused.' }
    if ($Bits -lt 0 -or $Bits -gt $BaseBytes.Length * 8) { throw 'Canonical address range was refused.' }
    if (-not [Net.IPAddress]::TryParse($HostName, [ref]$Address)) { return $false }
    $AddressBytes = $Address.GetAddressBytes()
    if ($AddressBytes.Length -ne $BaseBytes.Length) { return $false }
    for ($Index = 0; $Index -lt $BaseBytes.Length; $Index++) {
        $Remain = $Bits - $Index * 8
        $Mask = if ($Remain -ge 8) { 255 } elseif ($Remain -le 0) { 0 } else { (255 -shl (8 - $Remain)) -band 255 }
        if (($BaseBytes[$Index] -band $Mask) -ne ($AddressBytes[$Index] -band $Mask)) { return $false }
    }
    return $true
}

function Test-ErgoptiLoopback {
    param([Uri]$Destination, $Policy)
    $HostName = $Destination.DnsSafeHost.Trim('[', ']').TrimEnd('.').ToLowerInvariant()
    if ($Policy.loopback.dns_hosts -contains $HostName) { return $true }
    foreach ($Suffix in $Policy.loopback.dns_suffixes) {
        if ($HostName.Length -gt $Suffix.Length -and $HostName.EndsWith($Suffix, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    foreach ($Range in $Policy.loopback.ipv4_cidrs) {
        if (Test-ErgoptiAddressRange $HostName $Range) { return $true }
    }
    [Net.IPAddress]$Address = $null
    if ([Net.IPAddress]::TryParse($HostName, [ref]$Address)) {
        foreach ($Name in $Policy.loopback.ipv6_addresses) {
            [Net.IPAddress]$Candidate = $null
            if (-not [Net.IPAddress]::TryParse($Name, [ref]$Candidate)) { throw 'Canonical loopback address was refused.' }
            if ($Address.Equals($Candidate)) { return $true }
        }
    }
    return $false
}

function Get-ErgoptiHttpRelay {
    param([string]$Value, $Policy)
    if ($Value -eq '' -or [Text.Encoding]::UTF8.GetByteCount($Value) -gt $Policy.max_proxy_bytes -or
        $Value -match '[\x00-\x20\x7f]') { throw 'Private relay was refused.' }
    if ($Value -notmatch '^[A-Za-z][A-Za-z0-9+.-]*://') { $Value = 'http://' + $Value }
    [Uri]$Proxy = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$Proxy) -or
        $Policy.allowed_proxy_schemes -cnotcontains $Proxy.Scheme -or
        # .NET Framework HttpWebRequest supports this admitted transport only.
        $Proxy.Scheme -cne 'http' -or $Proxy.Host -eq '' -or $Proxy.UserInfo -ne '' -or
        $Proxy.Port -lt 1 -or $Proxy.Port -gt 65535 -or $Proxy.Query -ne '' -or
        $Proxy.Fragment -ne '' -or $Proxy.AbsolutePath -ne '/') { throw 'Private relay capability was refused.' }
    return $Proxy.AbsoluteUri
}

function Test-ErgoptiEnvironmentBypass {
    param([Uri]$Destination, [string]$Bypass, $Policy)
    if ([Text.Encoding]::UTF8.GetByteCount($Bypass) -gt $Policy.max_proxy_bytes) { throw 'Environment bypass bound was refused.' }
    # This is transport-level curl NO_PROXY syntax. Unsupported tokens refuse
    # admission rather than producing an implicit DIRECT fallback.
    $HostName = $Destination.DnsSafeHost.Trim('[', ']').TrimEnd('.').ToLowerInvariant()
    $Matched = $false
    foreach ($Part in $Bypass.Split(',')) {
        $Pattern = $Part.Trim().ToLowerInvariant()
        if ($Pattern -eq '') { continue }
        if ($Pattern -eq '*') { $Matched = $true; continue }
        if ($Pattern -match '[\x00-\x20\x7f@?#%\\\[\]]' -or $Pattern.Contains('*')) { throw 'Environment bypass capability was refused.' }
        if ($Pattern.Contains('/')) {
            if (Test-ErgoptiAddressRange $HostName $Pattern) { $Matched = $true }
            continue
        }
        [Net.IPAddress]$Address = $null
        $Numeric = $Pattern.Trim('[', ']')
        if ([Net.IPAddress]::TryParse($Numeric, [ref]$Address)) {
            # IPAddress accepts historical IPv4 aliases that curl NO_PROXY does
            # not necessarily interpret alike. Refuse them rather than bypass.
            if ($Address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and
                ($Numeric -notmatch '^(?:0|[1-9][0-9]{0,2})(?:\.(?:0|[1-9][0-9]{0,2})){3}$' -or
                $Numeric -cne $Address.ToString())) { throw 'Environment numeric bypass was refused.' }
            [Net.IPAddress]$Target = $null
            if ([Net.IPAddress]::TryParse($HostName, [ref]$Target) -and $Target.Equals($Address)) { $Matched = $true }
            continue
        }
        if ($Pattern -notmatch '^\.?[a-z0-9_-]+(?:\.[a-z0-9_-]+)*\.?$') {
            throw 'Environment bypass capability was refused.'
        }
        $Pattern = $Pattern.TrimStart('.').TrimEnd('.')
        if ($HostName -ceq $Pattern -or $HostName.EndsWith('.' + $Pattern, [StringComparison]::Ordinal)) { $Matched = $true }
    }
    return $Matched
}

function Get-ErgoptiStaticRoutes {
    param([Uri]$Destination, $Config, $Policy, [string]$Source)
    $HostName = $Destination.DnsSafeHost.Trim('[', ']').ToLowerInvariant()
    $Bypassed = $false
    foreach ($Part in ($Config.Bypass -split '[;, ]+')) {
        $Pattern = $Part.Trim().ToLowerInvariant()
        if ($Pattern -eq '') { continue }
        if ($Pattern -eq '<local>') {
            if (-not $HostName.Contains('.')) { $Bypassed = $true }
        } elseif ($Pattern -match '^[a-z0-9.*_-]+$') {
            $Expression = '^' + [Regex]::Escape($Pattern).Replace('\*', '.*') + '$'
            if ($HostName -match $Expression) { $Bypassed = $true }
        } else { throw 'WinINet bypass capability was refused.' }
    }
    if ($Config.Proxy -eq '' -or $Bypassed) {
        return ,@(@{ Kind = 'direct'; Endpoint = ''; Authentication = 'none'; Source = $Source + $(if ($Bypassed) { '_bypass' } else { '_direct' }) })
    }
    $Specific = @()
    $Generic = @()
    $SeenSchemes = @{}
    foreach ($Part in ($Config.Proxy -split '[; ]+')) {
        if ($Part -eq '') { continue }
        $Endpoint = $Part
        $Name = ''
        if ($Part -match '^([A-Za-z]+)=(.+)$') {
            $Name = $Matches[1].ToLowerInvariant()
            $Endpoint = $Matches[2]
            if ($Name -notin @('http', 'https') -or $SeenSchemes.ContainsKey($Name)) { throw 'WinINet scheme map was refused.' }
            $SeenSchemes[$Name] = $true
        }
        $Relay = Get-ErgoptiHttpRelay $Endpoint $Policy
        if ($Name -eq $Destination.Scheme) { $Specific += $Relay }
        elseif ($Name -eq '') { $Generic += $Relay }
    }
    $Chosen = @(if ($Specific.Count -gt 0) { $Specific } else { $Generic })
    if ($Chosen.Count -ne 1) { throw 'WinINet static route capability was refused.' }
    return ,@(@{ Kind = 'proxy'; Endpoint = [string]$Chosen[0]; Source = $Source + '_proxy'; Authentication = 'current_user_proxy_only' })
}

function Get-ErgoptiProxyConfigIdentity {
    param($Config)
    if ($Config.Ok -isnot [bool] -or -not $Config.Ok -or $Config.Absent -isnot [bool] -or $Config.AutoDetect -isnot [bool] -or
        $Config.PacUrl -isnot [string] -or $Config.Proxy -isnot [string] -or $Config.Bypass -isnot [string]) {
        throw 'Native current-user configuration was refused.'
    }
    return (@($Config.Absent, $Config.AutoDetect, $Config.PacUrl, $Config.Proxy, $Config.Bypass) | ConvertTo-Json -Compress)
}

function Resolve-ErgoptiNativeNetworkRoutes {
    param([string]$DestinationUrl, [int]$BudgetMs, [scriptblock]$ReadConfig = $null,
        [scriptblock]$ReadEnvironment = $null,
        [string]$PolicyPath = '', [string]$UpdaterDefaultsPath = '')
    $Clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        if ($PolicyPath -eq '' -or $UpdaterDefaultsPath -eq '') { throw 'Canonical private policy paths are required.' }
        $Policy = Get-ErgoptiNetworkPolicy $PolicyPath
        $Defaults = Get-Content -LiteralPath $UpdaterDefaultsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $LookupBudget = $Defaults.release_sources.proxy_resolve_timeout_sec
        if (-not (Test-ErgoptiNetworkInt32 $LookupBudget) -or $LookupBudget -le 0 -or $LookupBudget -gt [int]::MaxValue / 1000) {
            throw 'Canonical proxy lookup budget was refused.'
        }
        $LookupBudget *= 1000
        $Destination = Get-ErgoptiDestination $DestinationUrl
        if ($BudgetMs -le 0 -or $Clock.ElapsedMilliseconds -ge $BudgetMs) { return New-ErgoptiRouteRefusal }
        if (Test-ErgoptiLoopback $Destination $Policy) {
            if ($Clock.ElapsedMilliseconds -ge $BudgetMs) { return New-ErgoptiRouteRefusal }
            return @{ Ok = $true; MaxRoutes = $Policy.max_selections; MaxRedirects = $Policy.redirects.max_hops; Routes = @(@{ Kind = 'direct'; Endpoint = ''; Source = 'loopback'; Authentication = 'none' }) }
        }
        if ($null -eq $ReadEnvironment) { $ReadEnvironment = { param($Name) [Environment]::GetEnvironmentVariable($Name, 'Process') } }
        foreach ($Name in $Policy.environment_precedence.($Destination.Scheme)) {
            $Value = & $ReadEnvironment $Name
            if ($null -ne $Value -and $Value -isnot [string]) { return New-ErgoptiRouteRefusal 'dotnet' 'invalid_configuration' }
            if ($Value -ne '' -and $null -ne $Value) {
                $Endpoint = Get-ErgoptiHttpRelay $Value $Policy
                $Bypass = ''
                foreach ($BypassName in $Policy.environment_bypass_precedence) {
                    $Candidate = & $ReadEnvironment $BypassName
                    if ($null -ne $Candidate -and $Candidate -isnot [string]) { throw 'Explicit environment bypass was refused.' }
                    if ($null -ne $Candidate -and $Candidate -ne '') { $Bypass = $Candidate; break }
                }
                if ($Bypass -isnot [string]) { throw 'Explicit environment bypass was refused.' }
                if ($Clock.ElapsedMilliseconds -ge $BudgetMs) { return New-ErgoptiRouteRefusal }
                $EnvironmentBypassed = Test-ErgoptiEnvironmentBypass $Destination $Bypass $Policy
                if ($Clock.ElapsedMilliseconds -ge $BudgetMs) { return New-ErgoptiRouteRefusal }
                if ($EnvironmentBypassed) {
                    return @{ Ok = $true; MaxRoutes = $Policy.max_selections; MaxRedirects = $Policy.redirects.max_hops; Routes = @(@{ Kind = 'direct'; Endpoint = ''; Source = 'environment_bypass'; Authentication = 'none' }) }
                }
                return @{ Ok = $true; MaxRoutes = $Policy.max_selections; MaxRedirects = $Policy.redirects.max_hops; Routes = @(@{ Kind = 'proxy'; Endpoint = $Endpoint;
                    Source = 'environment'; Authentication = 'current_user_proxy_only' }) }
            }
        }
        if ($null -eq $ReadConfig) { $ReadConfig = { param($MaxBytes) [ErgoptiWindowsProxyConfig]::Read($MaxBytes) } }
        while ($Clock.ElapsedMilliseconds -lt $BudgetMs) {
            $Config = & $ReadConfig $Policy.max_proxy_bytes
            if ($null -eq $Config -or $Config.Ok -ne $true) {
                return New-ErgoptiRouteRefusal 'wininet' 'unavailable' $Config.NativeError ($Config.FailureOrigin -ceq 'native')
            }
            $Identity = Get-ErgoptiProxyConfigIdentity $Config
            if ($Config.PacUrl -eq '' -and -not $Config.AutoDetect) {
                $StaticSource = if ($Config.Absent) { 'system_config_absent' } else { 'system' }
                $Routes = Get-ErgoptiStaticRoutes $Destination $Config $Policy $StaticSource
            } else {
                if ($Config.PacUrl -ne '') { $null = Get-ErgoptiDestination $Config.PacUrl }
                $Remaining = [int][Math]::Min($LookupBudget, $BudgetMs - $Clock.ElapsedMilliseconds)
                if ($Remaining -lt 1500) { return New-ErgoptiRouteRefusal }
                $Native = Resolve-ErgoptiFullUrlPac -DestinationUrl $DestinationUrl -PacUrl $Config.PacUrl -AutoDetect $Config.AutoDetect `
                    -Deadline ([ErgoptiNetworkPac]::CurrentTick() + $Remaining) -Policy $Policy
                if (-not $Native.OwnersRetired) {
                    $Status = if ($Config.PacUrl -ne '') { 'pac_failed' } else { 'wpad_failed' }
                    $Refusal = New-ErgoptiRouteRefusal $Native.Backend $Status $Native.NativeError ($Native.FailureOrigin -ceq 'native') $(if($Native.NativeErrorDomain -cin @('win32','winsock','posix')){$Native.NativeErrorDomain}else{'win32'})
                    $Refusal.CleanupDebt = $true
                    return $Refusal
                }
                if ($Native.Kind -ceq 'no_auto_proxy' -and $Native.NativeError -eq 12180 -and
                    $Config.PacUrl -eq '' -and $Config.AutoDetect) {
                    $Routes = Get-ErgoptiStaticRoutes $Destination $Config $Policy 'wpad_absent'
                } elseif (-not $Native.Ok -or $Native.Kind -cne 'pac_routes') {
                    $Status = if ($Config.PacUrl -ne '') { 'pac_failed' } else { 'wpad_failed' }
                    return New-ErgoptiRouteRefusal $Native.Backend $Status $Native.NativeError ($Native.FailureOrigin -ceq 'native') $(if($Native.NativeErrorDomain -cin @('win32','winsock','posix')){$Native.NativeErrorDomain}else{'win32'})
                } else {
                    $Routes = ConvertFrom-ErgoptiPacRoutes $Native.Proxy $Policy
                }
            }
            $Current = & $ReadConfig $Policy.max_proxy_bytes
            if ((Get-ErgoptiProxyConfigIdentity $Current) -cne $Identity) { continue }
            if ($Clock.ElapsedMilliseconds -ge $BudgetMs) { return New-ErgoptiRouteRefusal }
            return @{ Ok = $true; MaxRoutes = $Policy.max_selections; MaxRedirects = $Policy.redirects.max_hops; Routes = @($Routes) }
        }
    } catch {
        # Raw input and managed/native exception text may contain credentials.
        return New-ErgoptiRouteRefusal 'wininet' 'invalid_configuration'
    }
    return New-ErgoptiRouteRefusal
}
