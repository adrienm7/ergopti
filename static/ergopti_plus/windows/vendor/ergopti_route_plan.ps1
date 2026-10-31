# vendor/ergopti_route_plan.ps1

# ==============================================================================
# MODULE: Shared Per-Origin Route Plan (Windows)
# DESCRIPTION:
# Turns the route a native lookup named for each origin of a download client
# into the one environment a client without a PAC engine can honor: a single
# relay plus a bypass list of the origins the lookup sent direct. Pure policy;
# the caller supplies the lookups and exports the result.
#
# FEATURES & RATIONALE:
# 1. An environment-driven client (the owned Ollama daemon) holds one relay,
#    so two different relays for the origins of one download are refused
#    instead of silently sending a host through the wrong one.
# 2. A redirect re-evaluates its own target: a host the plan never looked up
#    is refused, because its route is unknown and a guess may leak it.
# 3. Refusals are a closed enum; neither a URL nor a relay address ever
#    appears in a reason.
# 4. The Lua (_shared/lua/network/route_plan.lua), Go and shell twins answer
#    the same vectors (_shared/tests/corpus/network/route_plan_vectors.json),
#    replayed here by tools/test/test-windows-route-plan.cjs.
# 5. Windows PowerShell 5.1 syntax only: the driver runs on the stock host.
# ==============================================================================

Set-StrictMode -Version 2.0





# ===================================
# ===================================
# ======= 1/ Constants ==============
# ===================================
# ===================================

# The closed refusal reasons
$script:ErgoptiRoutePlanEmpty = 'route-plan-empty'
$script:ErgoptiRoutePlanInvalid = 'route-plan-invalid'
$script:ErgoptiRoutePlanConflict = 'route-plan-conflict'
$script:ErgoptiRoutePlanUnplannedHost = 'route-plan-unplanned-host'

# Relay schemes an exported HTTPS_PROXY may carry: the ones every
# environment-driven client honors (Go net/http, reqwest)
$script:ErgoptiRoutePlanRelaySchemes = @('http', 'https', 'socks5', 'socks5h')





# ===================================
# ===================================
# ======= 2/ Validation =============
# ===================================
# ===================================

# Normalizes a DNS host: lowercase, no trailing dot, plain label characters.
# Returns $null for a host no plan may name.
function ConvertTo-ErgoptiRoutePlanHost {
	param([string]$HostName)
	$Normalized = $HostName.ToLowerInvariant() -replace '\.$', ''
	if ($Normalized -ceq '' -or $Normalized.Length -gt 253 -or
		$Normalized -cmatch '[^a-z0-9.\-]' -or $Normalized.Contains('..')) { return $null }
	return $Normalized
}

# Parses a plain https origin (no path, query, port or credentials).
function Get-ErgoptiRoutePlanOriginHost {
	param($Origin)
	if ($Origin -isnot [string]) { return $null }
	if ($Origin -cnotmatch '^https://([^/?#@:\s]+)$') { return $null }
	return ConvertTo-ErgoptiRoutePlanHost $Matches[1]
}

# Accepts "direct" or an exportable relay with a port. A userinfo keeps only
# RFC 3986 characters, so an apostrophe in it must be percent-encoded.
function Test-ErgoptiRoutePlanRoute {
	param($Route)
	if ($Route -is [string] -and $Route -ceq 'direct') { return $true }
	if ($Route -isnot [string]) { return $false }
	if ($Route -cnotmatch '^([a-z][a-z0-9]*)://(.+)$') { return $false }
	$Scheme = $Matches[1]
	$Rest = $Matches[2]
	if ($script:ErgoptiRoutePlanRelaySchemes -cnotcontains $Scheme) { return $false }
	$Address = $Rest
	if ($Rest -cmatch '^([^@]*)@(.*)$') {
		$UserInfo = $Matches[1]
		$Address = $Matches[2]
		if ($UserInfo -ceq '' -or $UserInfo -cmatch '[^A-Za-z0-9._~%!$&()*+,;=:\-]') { return $false }
	}
	if ($Address -cnotmatch '^([^/\s@]+):([0-9]+)$') { return $false }
	$HostPart = $Matches[1]
	$PortText = $Matches[2]
	if ($PortText.Length -gt 5) { return $false }
	$Port = [int]$PortText
	if ($Port -lt 1 -or $Port -gt 65535) { return $false }
	if ($HostPart.StartsWith('[')) { return $HostPart -cmatch '^\[[0-9A-Fa-f:]+\]$' }
	return $HostPart -cnotmatch '[^A-Za-z0-9._\-]'
}





# ===================================
# ===================================
# ======= 3/ Plan ===================
# ===================================
# ===================================

# Builds a plan from the ordered lookups of one client's origins.
# Entries: an array of @{ origin = "https://host"; route = "direct"|relay }.
# Returns @{ Ok = $true; Proxy; NoProxy; Hosts } or @{ Ok = $false; Reason }.
function New-ErgoptiRoutePlan {
	param($Entries)
	if ($null -eq $Entries -or @($Entries).Count -eq 0) {
		return @{ Ok = $false; Reason = $script:ErgoptiRoutePlanEmpty }
	}
	$Order = New-Object System.Collections.ArrayList
	foreach ($Entry in @($Entries)) {
		$HostName = $null
		$Route = $null
		if ($Entry -is [Collections.IDictionary]) {
			$HostName = Get-ErgoptiRoutePlanOriginHost $Entry['origin']
			$Route = $Entry['route']
		} elseif ($null -ne $Entry -and $Entry.PSObject.Properties['origin'] -and $Entry.PSObject.Properties['route']) {
			$HostName = Get-ErgoptiRoutePlanOriginHost $Entry.origin
			$Route = $Entry.route
		}
		if ($null -eq $HostName -or -not (Test-ErgoptiRoutePlanRoute $Route)) {
			return @{ Ok = $false; Reason = $script:ErgoptiRoutePlanInvalid }
		}
		[void]$Order.Add(@{ Host = $HostName; Route = $Route })
	}
	$Hosts = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
	$Direct = New-Object System.Collections.ArrayList
	$Proxy = $null
	foreach ($Item in $Order) {
		if ($Hosts.ContainsKey($Item.Host)) {
			if ($Hosts[$Item.Host] -cne $Item.Route) {
				return @{ Ok = $false; Reason = $script:ErgoptiRoutePlanConflict }
			}
			continue
		}
		$Hosts[$Item.Host] = $Item.Route
		if ($Item.Route -ceq 'direct') {
			[void]$Direct.Add($Item.Host)
		} elseif ($null -ne $Proxy -and $Proxy -cne $Item.Route) {
			return @{ Ok = $false; Reason = $script:ErgoptiRoutePlanConflict }
		} else {
			$Proxy = $Item.Route
		}
	}
	return @{
		Ok = $true
		Proxy = $(if ($null -eq $Proxy) { 'direct' } else { $Proxy })
		NoProxy = $(if ($null -eq $Proxy) { '' } else { $Direct -join ',' })
		Hosts = $Hosts
	}
}

# Re-evaluates one redirect target against a settled plan.
# Returns @{ Ok = $true; Route = "proxy"|"direct" } or @{ Ok = $false; Reason }.
function Resolve-ErgoptiRoutePlanRedirect {
	param([Parameter(Mandatory = $true)]$Plan, $Url)
	$Refused = @{ Ok = $false; Reason = $script:ErgoptiRoutePlanInvalid }
	if ($Url -isnot [string] -or $Url -cmatch '[\x00-\x1F\x7F\s\\]') { return $Refused }
	if ($Url -cnotmatch '^https://([^/?#]*)') { return $Refused }
	$Authority = ($Matches[1] -replace '^.*@', '') -replace ':[0-9]+$', ''
	if ($Authority -ceq '') { return $Refused }
	$HostName = ConvertTo-ErgoptiRoutePlanHost $Authority
	if ($null -eq $HostName) { return $Refused }
	if (-not $Plan.Hosts.ContainsKey($HostName)) {
		return @{ Ok = $false; Reason = $script:ErgoptiRoutePlanUnplannedHost }
	}
	return @{ Ok = $true; Route = $(if ($Plan.Hosts[$HostName] -ceq 'direct') { 'direct' } else { 'proxy' }) }
}





# ===================================
# ===================================
# ======= 4/ Owned Daemon ===========
# ===================================
# ===================================

# The relay variable the owned Ollama daemon (Go net/http) reads for its HTTPS
# registry and blob traffic, and its bypass variable. Linux writes NO_PROXY and
# no_proxy; Windows environment names are case-insensitive, so they are one.
$script:ErgoptiOwnedProxyVariable = 'HTTPS_PROXY'
$script:ErgoptiOwnedBypassVariable = 'NO_PROXY'

# Route sources that mean the user's exported relay already covers the daemon,
# which inherits it: nothing is looked up or overridden.
$script:ErgoptiOwnedInheritedSources = @('environment', 'environment_bypass')

# Builds the proxy environment of the owned daemon from one native lookup per
# origin of route_origins.json "ollama". Resolve is called as
# & $Resolve $OriginUrl and answers like Resolve-ErgoptiNativeNetworkRoutes;
# ReadEnvironment as & $ReadEnvironment $Name.
# Returns @{ Ok = $true; Mode = 'inherit'|'direct'|'relay'; Proxy; Environment }
# or @{ Ok = $false; Reason } with a closed reason, never a URL.
function Get-ErgoptiOwnedProxyEnvironment {
	param([Parameter(Mandatory = $true)][string[]]$Origins,
		[Parameter(Mandatory = $true)][scriptblock]$Resolve,
		[Parameter(Mandatory = $true)][scriptblock]$ReadEnvironment)
	if ($Origins.Count -eq 0) { return @{ Ok = $false; Reason = $script:ErgoptiRoutePlanEmpty } }
	$Entries = New-Object System.Collections.ArrayList
	foreach ($Origin in $Origins) {
		$Answer = & $Resolve $Origin
		if ($null -eq $Answer -or $Answer.Ok -ne $true -or @($Answer.Routes).Count -eq 0) {
			return @{ Ok = $false; Reason = 'route-lookup-refused' }
		}
		# The daemon has no failover: only the first selection is used
		$First = @($Answer.Routes)[0]
		if ($script:ErgoptiOwnedInheritedSources -ccontains $First.Source) {
			return @{ Ok = $true; Mode = 'inherit'; Proxy = ''; Environment = [ordered]@{} }
		}
		if ($First.Kind -ceq 'direct') { $Route = 'direct' }
		elseif ($First.Kind -ceq 'proxy' -and $First.Endpoint -is [string]) {
			# Relays are normalized absolute URIs ("http://host:port/"); the plan takes host:port
			$Route = $First.Endpoint -replace '/$', ''
		} else { return @{ Ok = $false; Reason = $script:ErgoptiRoutePlanInvalid } }
		[void]$Entries.Add(@{ origin = $Origin; route = $Route })
	}
	$Plan = New-ErgoptiRoutePlan @($Entries)
	if (-not $Plan.Ok) { return @{ Ok = $false; Reason = $Plan.Reason } }
	$Environment = [ordered]@{}
	if ($Plan.Proxy -ceq 'direct') { return @{ Ok = $true; Mode = 'direct'; Proxy = ''; Environment = $Environment } }
	$Environment[$script:ErgoptiOwnedProxyVariable] = $Plan.Proxy
	if ($Plan.NoProxy -cne '') {
		# The user's own bypass entries are kept ahead of the origins sent direct
		$Current = & $ReadEnvironment $script:ErgoptiOwnedBypassVariable
		$Environment[$script:ErgoptiOwnedBypassVariable] = $(if ($Current -isnot [string] -or $Current -ceq '') {
			$Plan.NoProxy } else { $Current + ',' + $Plan.NoProxy })
	}
	return @{ Ok = $true; Mode = 'relay'; Proxy = $Plan.Proxy; Environment = $Environment }
}

# Asks a plain http relay for a tunnel to Target ("host:443") without any
# credential, the way the daemon will. Returns 'open', 'windows_login' (the
# relay demands NTLM, Negotiate or Kerberos, which the daemon cannot answer),
# 'credentials' (another scheme the daemon holds no secret for), 'refused'
# (another status) or 'unreachable'. Only the login answers stop a pull: the
# others reach the daemon, which reports them itself.
function Test-ErgoptiRelayTunnel {
	param([Parameter(Mandatory = $true)][string]$Relay,
		[Parameter(Mandatory = $true)][string]$Target,
		[Parameter(Mandatory = $true)][ValidateRange(1, 600000)][int]$TimeoutMs)
	if ($Relay -cnotmatch '^http://([A-Za-z0-9.\-]+|\[[0-9A-Fa-f:]+\]):([0-9]{1,5})$') {
		throw 'Only a plain http relay can be probed.'
	}
	$RelayHost = $Matches[1].Trim('[', ']')
	$RelayPort = [int]$Matches[2]
	if ($Target -cnotmatch '^[a-z0-9.\-]+:[0-9]{1,5}$') { throw 'The tunnel target must be host:port.' }
	$Client = New-Object System.Net.Sockets.TcpClient
	try {
		$Connect = $Client.BeginConnect($RelayHost, $RelayPort, $null, $null)
		if (-not $Connect.AsyncWaitHandle.WaitOne($TimeoutMs)) { return 'unreachable' }
		try { $Client.EndConnect($Connect) } catch { return 'unreachable' }
		$Stream = $Client.GetStream()
		$Stream.ReadTimeout = $TimeoutMs
		$Stream.WriteTimeout = $TimeoutMs
		$Request = [Text.Encoding]::ASCII.GetBytes("CONNECT $Target HTTP/1.1`r`nHost: $Target`r`n`r`n")
		$Stream.Write($Request, 0, $Request.Length)
		# The status line and headers, bounded: nothing past them is read
		$Head = New-Object System.Text.StringBuilder
		$Byte = New-Object byte[] 1
		while ($Head.Length -lt 16384 -and -not $Head.ToString().EndsWith("`r`n`r`n")) {
			try { $Read = $Stream.Read($Byte, 0, 1) } catch { return 'unreachable' }
			if ($Read -le 0) { break }
			[void]$Head.Append([char]$Byte[0])
		}
		$Lines = $Head.ToString() -split "`r`n"
		if ($Lines[0] -cnotmatch '^HTTP/1\.[01] ([0-9]{3})') { return 'refused' }
		$Status = [int]$Matches[1]
		if ($Status -eq 200) { return 'open' }
		if ($Status -ne 407) { return 'refused' }
		foreach ($Line in $Lines) {
			if ($Line -match '^Proxy-Authenticate:\s*(NTLM|Negotiate|Kerberos)\b') { return 'windows_login' }
		}
		return 'credentials'
	} finally { $Client.Close() }
}
