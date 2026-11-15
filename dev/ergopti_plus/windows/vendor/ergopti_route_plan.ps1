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
# 4. The Lua (_shared/core/network/engine/route_plan.lua), Go and shell twins answer
#    the same vectors (_shared/tests/corpus/network/route_plan_vectors.json),
#    replayed here by tools/test/test-windows-route-plan.cjs.
# 5. Windows PowerShell 5.1 syntax only: the driver runs on the stock host.
# 6. The owned daemon's PAC list is walked like a browser, as on Linux: a relay
#    followed by another entry is kept only when the caller's probe reaches it.
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
		[Parameter(Mandatory = $true)][scriptblock]$ReadEnvironment,
		[Parameter(Mandatory = $true)][scriptblock]$Probe)
	if ($Origins.Count -eq 0) { return @{ Ok = $false; Reason = $script:ErgoptiRoutePlanEmpty } }
	$Entries = New-Object System.Collections.ArrayList
	$OverrideDirect = $false
	foreach ($Origin in $Origins) {
		$Answer = & $Resolve $Origin
		if ($null -eq $Answer -or $Answer.Ok -ne $true -or @($Answer.Routes).Count -eq 0) {
			return @{ Ok = $false; Reason = 'route-lookup-refused' }
		}
		# The daemon has no failover, so the PAC list is walked here as Linux does:
		# a relay followed by another entry is kept only when $Probe reaches it
		# (a TCP connect within the shared probe deadline); otherwise the next
		# entry is tried. The last entry is kept unprobed, nothing follows it.
		$Routes = @($Answer.Routes)
		$First = $Routes[$Routes.Count - 1]
		for ($At = 0; $At -lt $Routes.Count - 1; $At++) {
			$Candidate = $Routes[$At]
			# DIRECT, an override and a relay the user exported are kept as named.
			if ($Candidate.Kind -cne 'proxy' -or $Candidate.Endpoint -isnot [string] -or $Candidate.Source -ceq 'override' -or
					$script:ErgoptiOwnedInheritedSources -ccontains $Candidate.Source) {
				$First = $Candidate
				break
			}
			if ((& $Probe $Candidate.Endpoint) -eq $true) {
				$First = $Candidate
				break
			}
		}
		if ($script:ErgoptiOwnedInheritedSources -ccontains $First.Source) {
			return @{ Ok = $true; Mode = 'inherit'; Proxy = ''; Environment = [ordered]@{} }
		}
		if ($First.Source -ceq 'override' -and $First.Kind -ceq 'direct') { $OverrideDirect = $true }
		if ($First.Kind -ceq 'direct') { $Route = 'direct' }
		elseif ($First.Kind -ceq 'proxy' -and $First.Endpoint -is [string]) {
			# Relays are normalized absolute URIs ("http://host:port/"); the plan takes host:port.
			# An override names its real relay: the daemon reads https, socks and credentials
			# from its environment itself, and a loopback hop would die with this process.
			$Route = $(if ($First -is [hashtable] -and $First.ContainsKey('Relay')) { $First.Relay } else { $First.Endpoint -replace '/$', '' })
		} else { return @{ Ok = $false; Reason = $script:ErgoptiRoutePlanInvalid } }
		[void]$Entries.Add(@{ origin = $Origin; route = $Route })
	}
	$Plan = New-ErgoptiRoutePlan @($Entries)
	if (-not $Plan.Ok) { return @{ Ok = $false; Reason = $Plan.Reason } }
	$Environment = [ordered]@{}
	if ($Plan.Proxy -ceq 'direct') {
		# A direct override also beats a relay the daemon would inherit from the user.
		if ($OverrideDirect) { $Environment[$script:ErgoptiOwnedBypassVariable] = '*' }
		return @{ Ok = $true; Mode = 'direct'; Proxy = ''; Environment = $Environment }
	}
	$Environment[$script:ErgoptiOwnedProxyVariable] = $Plan.Proxy
	if ($Plan.NoProxy -cne '') {
		# The user's own bypass entries are kept ahead of the origins sent direct
		$Current = & $ReadEnvironment $script:ErgoptiOwnedBypassVariable
		$Environment[$script:ErgoptiOwnedBypassVariable] = $(if ($Current -isnot [string] -or $Current -ceq '') {
			$Plan.NoProxy } else { $Current + ',' + $Plan.NoProxy })
	}
	return @{ Ok = $true; Mode = 'relay'; Proxy = $Plan.Proxy; Environment = $Environment }
}

# Whether a relay of a PAC list ("http://host:port/") accepts a TCP connection
# within TimeoutMs: the browser-like walk keeps a relay only when it answers.
# Any refusal, timeout or malformed address is $false.
function Test-ErgoptiRelayReachable {
	param([Parameter(Mandatory = $true)][string]$Relay,
		[Parameter(Mandatory = $true)][ValidateRange(1, 600000)][int]$TimeoutMs)
	$Uri = $null
	if (-not [Uri]::TryCreate($Relay, [UriKind]::Absolute, [ref]$Uri) -or $Uri.Port -le 0) { return $false }
	$Client = New-Object System.Net.Sockets.TcpClient
	try {
		$Pending = $Client.ConnectAsync($Uri.DnsSafeHost, $Uri.Port)
		if (-not $Pending.Wait($TimeoutMs)) { return $false }
		return $Client.Connected
	} catch { return $false }
	finally { $Client.Dispose() }
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

# The local sign-in relay's command line and answers, the twin of the shared
# core/network/engine/proxy_auth_relay_core.lua (docs/design/proxy-auth-relay.md): pure policy, with
# reasons and statuses that never carry a URL, host, header or token.

# The upstream the relay may sign in to, '' when it does not apply: only a plain
# http relay without credentials can be signed in to.
function New-ErgoptiRelayUpstream {
	param([AllowNull()]$Proxy)
	if ($Proxy -isnot [string] -or $Proxy -cnotmatch '^http://([A-Za-z0-9.\-]+):([0-9]{1,5})/?\z') { return '' }
	$RelayHost = $Matches[1].ToLowerInvariant()
	$RelayPort = [int]$Matches[2]
	if ($RelayHost.Length -gt 253 -or $RelayHost.Contains('..') -or $RelayPort -lt 1 -or $RelayPort -gt 65535) { return '' }
	return 'http://' + $RelayHost + ':' + $RelayPort
}

function New-ErgoptiRelayProbeArguments {
	param([Parameter(Mandatory = $true)][string]$Upstream, [Parameter(Mandatory = $true)][string]$Authority,
		[Parameter(Mandatory = $true)][ValidateRange(1, 2147483647)][int]$DialMs,
		[Parameter(Mandatory = $true)][ValidateRange(1, 2147483647)][int]$HandshakeMs)
	if ((New-ErgoptiRelayUpstream $Upstream) -cne $Upstream -or $Authority -cnotmatch '^[A-Za-z0-9.\-]+:[0-9]+\z') {
		throw 'The relay probe requires a plain upstream and authority.'
	}
	return "probe --upstream $Upstream --authority $Authority --dial-timeout-ms $DialMs --handshake-timeout-ms $HandshakeMs"
}

# The relay's arguments up to and including the "--" before its child.
function New-ErgoptiRelayRunPrefix {
	param([Parameter(Mandatory = $true)][string]$Upstream, [Parameter(Mandatory = $true)][string]$Variable,
		[Parameter(Mandatory = $true)][ValidateRange(1, 2147483647)][int]$DialMs,
		[Parameter(Mandatory = $true)][ValidateRange(1, 2147483647)][int]$HandshakeMs,
		[Parameter(Mandatory = $true)][ValidateRange(1, 2147483647)][int]$IdleMs)
	if ((New-ErgoptiRelayUpstream $Upstream) -cne $Upstream -or $Variable -cnotmatch '^[A-Za-z_][A-Za-z0-9_]*\z') {
		throw 'The relay run requires a plain upstream and variable.'
	}
	return "run --upstream $Upstream --variable $Variable --dial-timeout-ms $DialMs --handshake-timeout-ms $HandshakeMs --idle-timeout-ms $IdleMs --"
}

# Reads a finished probe against the decoded proxy_auth_relay.json. Anything
# else, or an exit that does not match its line, is 'relay_unavailable', never a
# silent direct start. Returns @{ Status; Scheme } or @{ Status = 'refused'; Reason }.
function Read-ErgoptiRelayProbe {
	param([AllowNull()]$ExitCode, [AllowNull()]$Stdout, [Parameter(Mandatory = $true)]$Contract)
	$Unavailable = @{ Status = 'refused'; Reason = 'relay_unavailable' }
	if ($ExitCode -isnot [int] -or $Stdout -isnot [string]) { return $Unavailable }
	$Exits = $Contract.exit_codes
	if ($Stdout -cmatch '^\{"schema":1,"status":"not_needed"\}\r?\n?\z') {
		if ($ExitCode -ne $Exits.ok) { return $Unavailable }
		return @{ Status = 'not_needed' }
	}
	if ($Stdout -cmatch '^\{"schema":1,"status":"required","scheme":"([a-z]+)"\}\r?\n?\z') {
		$Scheme = $Matches[1]
		if ($ExitCode -ne $Exits.ok -or @($Contract.schemes) -cnotcontains $Scheme) { return $Unavailable }
		return @{ Status = 'required'; Scheme = $Scheme }
	}
	if ($Stdout -cmatch '^\{"schema":1,"status":"refused","reason":"([a-z_]+)"\}\r?\n?\z') {
		$Reason = $Matches[1]
		$Known = @($Contract.refusals.PSObject.Properties | ForEach-Object { $_.Name })
		if (($ExitCode -ne $Exits.refused -and $ExitCode -ne $Exits.invalid_arguments) -or
			$Known -cnotcontains $Reason -or $Reason -ceq 'relay_unavailable') { return $Unavailable }
		return @{ Status = 'refused'; Reason = $Reason }
	}
	return $Unavailable
}
