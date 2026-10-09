# tests/fixtures/curl_proxy_discovery_controls.ps1
# Production discovery/parser/lease bodies, controlled process output and real files.
# These component controls do not claim native SSPI or Schannel qualification.
param([Parameter(Mandatory=$true)][string]$EnginePath,[switch]$PortableClock)
$ErrorActionPreference = 'Stop'
if ($PortableClock) {
    Add-Type 'public static class ErgoptiNativeProxyEx { public static long CurrentTick() { return System.Environment.TickCount64; } }'
} else {
    . (Join-Path ([IO.Path]::GetDirectoryName($EnginePath)) 'ergopti_native_proxy_ex.ps1')
}
$Source = [IO.File]::ReadAllText($EnginePath)
$Tokens = $null; $Errors = $null
$Ast = [Management.Automation.Language.Parser]::ParseInput($Source, [ref]$Tokens, [ref]$Errors)
if ($Errors.Count -ne 0) { throw 'The actual production source did not parse.' }
$Ports = @($Ast.FindAll({ param($Node)
    $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -ceq 'Invoke-OwnedProcess'
}, $true))
if ($Ports.Count -ne 1) { throw 'The exact process output port was not unique.' }
$ControlledPort = @'
function Invoke-OwnedProcess {
    param([string]$Executable, [string]$Arguments, [int]$MaximumOutput)
    $Port = $global:ErgoptiDiscoveryControlPort
    $Port.calls++
    $Port.configs += [IO.File]::ReadAllText($CurlConfig)
    if ($Port.configs[-1].Contains('request = "CONNECT"')) {
        if ($Port.expire_after) { $InputValue.started_tick -= $InputValue.deadline_ms + 1 }
        return @{ exit = $Port.exit; stdout = $Port.response; stderr_empty = $Port.stderr_empty;
            child_quiesced = $Port.quiesced }
    }
    [IO.File]::WriteAllText($InputValue.header_path, "HTTP/1.1 200 OK`r`n`r`n")
    return @{ exit = 0; stdout = '200|200|0|1'; stderr_empty = $true; child_quiesced = $true }
}
'@
$Span = $Ports[0].Extent
$ControlledSource = $Source.Substring(0,$Span.StartOffset) + $ControlledPort + $Source.Substring($Span.EndOffset)
$ExecutableSeam = '$Executable = Join-Path ([Environment]::GetFolderPath(''System'')) ''curl.exe'''
if (($ControlledSource.Split(@($ExecutableSeam),[StringSplitOptions]::None).Count-1) -ne 2) { throw 'The actual executable seams differ.' }
$ControlledSource=$ControlledSource.Replace($ExecutableSeam,'$Executable = "CONTROLLED_NATIVE_CURL"')
. ([ScriptBlock]::Create($ControlledSource))
$Directory = Join-Path ([IO.Path]::GetTempPath()) ('ErgoptiDiscoveryControls-' + [Guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($Directory)
$Count = 0
function Require { param([bool]$Condition,[string]$Name) if (-not $Condition) { throw ('Discovery control refused: ' + $Name) } }
function Refuses { param([scriptblock]$Action) $Refused=$false; try { & $Action | Out-Null } catch { $Refused=$true }; Require $Refused 'required_refusal' }
function New-Control {
    param([string]$Challenge='NTLM',[int]$Status=407)
    $global:ErgoptiDiscoveryControlPort = @{ calls=0; configs=@(); exit=0; stderr_empty=$true; quiesced=$true; expire_after=$false;
        response = "HTTP/1.1 $Status Control`r`n" + $(if($Challenge -ne ''){"Proxy-Authenticate: $Challenge`r`n"}else{''}) + "`r`n$Status|000|0|1" }
    $Parameters = [pscustomobject]@{ started_tick=[ErgoptiNativeProxyEx]::CurrentTick(); deadline_ms=30000; connect_timeout_ms=3000;
        max_response_bytes=1024; max_header_bytes=4096; response_path=(Join-Path $Directory 'body'); header_path=(Join-Path $Directory 'headers');
        body='PRIVATE_BODY'; headers=@(@{name='Authorization';value='PRIVATE_HEADER'}); user_agent='PRIVATE_AGENT'; revocation_best_effort=$false }
    $Payload = Join-Path $Directory 'payload'
    [IO.File]::WriteAllText($Payload,$Parameters.body)
    $Route=@{Kind='proxy';Endpoint='http://127.0.0.1:12345/';Authentication='current_user_proxy_only'}
    return @{ Engine=(New-ErgoptiCurlAttemptEngine $Parameters @{} (Join-Path $Directory 'capability') $Payload (Join-Path $Directory 'config'));
        Parameters=$Parameters; Destination=[Uri]'https://destination.invalid:8443/PRIVATE_PATH?PRIVATE_QUERY'; Route=$Route;
        Selection=@{Ok=$true;CleanupDebt=$false;MaxRoutes=1;MaxRedirects=2;Routes=@($Route)};
        Capability=@{version='8.14.1';sspi=$true;spnego=$true;ntlm=$true} }
}
function Discover { param($C) return $C.Engine.DiscoverProxy($C.Destination,$C.Route,$C.Capability,$C.Selection) }
function Selected { param($C,$Selection) return $C.Engine.InvokeDiscoveredRoute($C.Destination,$C.Route,'POST',$true,$true,$Selection) }
function Body([string]$Source,[string]$Name) {
 $t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($Source,[ref]$t,[ref]$e);if($e.Count){throw 'Actual caller source parser refusal.'}
 $nodes=@($ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq$Name},$true));if($nodes.Count-ne1){throw 'Actual caller helper must be unique.'};return $nodes[0].Extent.Text
}
function Transport([string]$Source) {
 $a=$Source.IndexOf("if (`$Route.Kind -ceq 'proxy' -and `$Destination.Scheme -ceq 'https') {");if($a-lt0){throw 'Actual transport branch missing.'}
 $t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($Source,[ref]$t,[ref]$e)
 $nodes=@($ast.FindAll({param($n)$n-is[Management.Automation.Language.IfStatementAst]-and$n.Extent.StartOffset-eq$a},$true));if($nodes.Count-ne1){throw 'Actual caller branch must be unique.'};$Parent=$nodes[0].Parent;while($null-ne$Parent-and$Parent-isnot[Management.Automation.Language.ForStatementAst]){$Parent=$Parent.Parent};if($null-eq$Parent){throw 'Actual transport ordinal loop missing.'};return $Parent.Extent.Text
}
function Get-RemainingBudget { return $AttemptEngine.GetRemainingBudget() }
function Get-ErgoptiHttpRelay([string]$Endpoint,$Policy){return $Endpoint}
function Test-ErgoptiEnvironmentBypass([Uri]$Destination,[string]$Bypass,$Policy){return $false}
function Test-ErgoptiNetworkInt32($Value){return ($Value-is[int]-or$Value-is[long])-and$Value-ge[int]::MinValue-and$Value-le[int]::MaxValue}
function Resolve-ErgoptiNativeNetworkRoutes([string]$Url,[int]$Budget,$Reader,$Ignored,[string]$PolicyPath,[string]$DefaultsPath){$global:CallerSelections++;Require ($Url-ceq$OriginalUrl-and$Budget-gt0) 'actual_completeURL_original_budget';if($global:CallerChange-and$global:CallerSelections-gt1){return @{Ok=$true;CleanupDebt=$false;MaxRoutes=1;MaxRedirects=2;Routes=@(@{Kind='direct';Endpoint='';Authentication='none'})}};return $C.Selection}

try {
    foreach ($Pair in @(@('NTLM','ntlm'),@('Negotiate','negotiate'),@('NTLM, Negotiate','negotiate'),@('Basic realm="PRIVATE_REALM", NTLM','ntlm'),@('Negotiate, Digest realm="PRIVATE,REALM", nonce="PRIVATE_NONCE"','negotiate'),@("NTLM`r`nProxy-Authenticate: Negotiate",'negotiate'),@('', 'none'))) {
        $C=New-Control $Pair[0] $(if($Pair[1]-ceq'none'){200}else{407})
        $D=Discover $C
        Require ($D.ready -and $D.authentication -ceq $Pair[1] -and $D.metrics.connect -eq 0) 'separate_discovery_domain'
        Require ($global:ErgoptiDiscoveryControlPort.configs[0] -notmatch 'PRIVATE_|(?m)^(proxy-user|proxy-negotiate|proxy-ntlm|header|data-binary|user-agent)\s*=') 'anonymous_only'
        $null=Selected $C $C.Selection
        $Config=$global:ErgoptiDiscoveryControlPort.configs[1]
        Require ($Config.Contains('https://destination.invalid:8443/PRIVATE_PATH?PRIVATE_QUERY') -and $Config.Contains('request = "POST"') -and $Config.Contains('PRIVATE_HEADER') -and $Config.Contains('data-binary = ')) 'original_selected_request'
        if ($Pair[1]-ceq'none') { Require ($Config -notmatch '(?m)^proxy-(user|negotiate|ntlm)') 'no_unsolicited_credentials' }
        else { Require ($Config.Contains('proxy-'+$Pair[1]) -and $Config.Contains('proxy-user = ":"')) 'exact_advertised_scheme' }
        Refuses { Selected $C $C.Selection }
        Refuses { Discover $C }
        Refuses { $C.Engine.InvokeRoute($C.Destination,$C.Route,'ntlm','POST',$true,$true) }
        Require ($global:ErgoptiDiscoveryControlPort.calls -eq 2) 'max_two_children_no_downgrade'
        $Count++
    }
    foreach ($Challenge in @('Basic realm="private"','FOREIGN','NTLM AAAA','NTLM,',"NTLM`r`nProxy-Authenticate: FOREIGN")) {
        $C=New-Control $Challenge; Refuses { Discover $C }; Require ($global:ErgoptiDiscoveryControlPort.calls -eq 1) 'no_foreign_successor'; $Count++
    }
    foreach ($Status in @(401,302)) { $C=New-Control 'NTLM' $Status; Refuses { Discover $C }; $Count++ }
    $C=New-Control 'NTLM' 200; Refuses { Discover $C }; $Count++
    foreach ($Change in @('endpoint','order','cleanup','url','expiry')) {
        $C=New-Control; $null=Discover $C
        $Fresh=@{Ok=$true;CleanupDebt=$false;MaxRoutes=1;MaxRedirects=2;Routes=@($C.Route)}
        switch ($Change) {
            'endpoint' { $Fresh.Routes=@(@{Kind='proxy';Endpoint='http://127.0.0.1:12346/';Authentication='current_user_proxy_only'}) }
            'order' { $Fresh.MaxRoutes=2; $Fresh.Routes=@(@{Kind='direct';Endpoint='';Authentication='none'},$C.Route) }
            'cleanup' { $Fresh.CleanupDebt=$true }
            'url' { $C.Destination=[Uri]'https://destination.invalid:8443/foreign' }
            'expiry' { $C.Parameters.started_tick -= 30001 }
        }
        Refuses { Selected $C $Fresh }; Refuses { Selected $C $C.Selection }
        Require ($global:ErgoptiDiscoveryControlPort.calls -eq 1) 'fresh_route_or_deadline_refusal_before_credentials'; $Count++
    }
    $C=New-Control; $C.Capability.version='7.88.1'; Refuses { Discover $C }; Require ($global:ErgoptiDiscoveryControlPort.calls -eq 0) 'old_capability_no_synthetic_proxy_used'; $Count++
    $C=New-Control; $global:ErgoptiDiscoveryControlPort.expire_after=$true; Refuses { Discover $C }; Require ($global:ErgoptiDiscoveryControlPort.calls -eq 1) 'no_budget_refresh'; $Count++
    $C=New-Control; $global:ErgoptiDiscoveryControlPort.quiesced=$false; Refuses { Discover $C }; Require ($global:ErgoptiDiscoveryControlPort.calls -eq 1) 'exact_child_fence'; $Count++
    $C=New-Control; $global:ErgoptiDiscoveryControlPort.response="HTTP/1.1 407 Control`r`nProxy-Authenticate: NTLM`r`n`r`n200|000|0|1"; Refuses { Discover $C }; $Count++
    foreach($Exit in @(5,7)) {
        $C=New-Control; $global:ErgoptiDiscoveryControlPort.exit=$Exit; $global:ErgoptiDiscoveryControlPort.response='000|000|0|1'; $global:ErgoptiDiscoveryControlPort.stderr_empty=$false
        $D=Discover $C; Require (-not $D.ready -and $D.metrics.exit -eq $Exit -and $D.metrics.status -eq 0 -and $D.metrics.connect -eq 0 -and $D.metrics.delivered -eq 0 -and $D.metrics.proxy_used -and $D.metrics.child_quiesced) 'actual_literal_failover_domain'; Refuses { Selected $C $C.Selection }; $Count++
    }
    $C=New-Control; $global:ErgoptiDiscoveryControlPort.response="HTTP/1.1 407 Control`r`nProxy-Authenticate: NTLM`r`nX-Foreign: " + ('x'*4096) + "`r`n`r`n407|000|0|1"; Refuses { Discover $C }; $Count++
    $C=New-Control; $C.Selection.MaxRoutes=2; $C.Selection.Routes=@($C.Route,$C.Route)
    $global:ErgoptiDiscoveryControlPort.exit=7; $global:ErgoptiDiscoveryControlPort.response='000|000|0|1'; $global:ErgoptiDiscoveryControlPort.stderr_empty=$false
    $D=$C.Engine.DiscoverProxy($C.Destination,$C.Route,$C.Capability,$C.Selection,0)
    Require (-not $D.ready -and $D.metrics.exit -eq 7) 'duplicate_first_literal_connect_refusal'
    Refuses { $C.Engine.DiscoverProxy($C.Destination,$C.Route,$C.Capability,$C.Selection,0) }
    $global:ErgoptiDiscoveryControlPort.exit=0; $global:ErgoptiDiscoveryControlPort.stderr_empty=$true
    $global:ErgoptiDiscoveryControlPort.response="HTTP/1.1 407 Control`r`nProxy-Authenticate: NTLM`r`n`r`n407|000|0|1"
    $D=$C.Engine.DiscoverProxy($C.Destination,$C.Route,$C.Capability,$C.Selection,1)
    Require ($D.ready -and $D.authentication -ceq 'ntlm') 'duplicate_distinct_canonical_ordinal'
    $null=Selected $C $C.Selection
    Require ($global:ErgoptiDiscoveryControlPort.calls -eq 3) 'same_endpoint_original_bounded_order'
    $Count++
    foreach ($Urls in @(@('https://destination.invalid:8443/A','https://destination.invalid:8443/a'),
        @('https://destination.invalid:8443/A?key=A','https://destination.invalid:8443/A?key=a'))) {
        $C=New-Control; $C.Destination=[Uri]$Urls[0]
        $D=Discover $C; Require $D.ready 'original_case_sensitive_destination'
        $null=Selected $C $C.Selection
        Refuses { Discover $C }
        $C.Destination=[Uri]$Urls[1]
        $D=Discover $C; Require $D.ready 'distinct_path_or_query_case_after_retirement'
        $null=Selected $C $C.Selection
        Refuses { Discover $C }
        $C.Destination=[Uri]$Urls[0]
        Refuses { Discover $C }
        Require ($global:ErgoptiDiscoveryControlPort.calls -eq 4) 'two_children_each_exact_url_no_replay'
        Require ($global:ErgoptiDiscoveryControlPort.configs[1].Contains($Urls[0]) -and
            $global:ErgoptiDiscoveryControlPort.configs[3].Contains($Urls[1])) 'selected_urls_keep_original_case'
        $Count++
    }
    Require ($Count -eq 30) 'closed_case_floor'
    $Root=[IO.Path]::GetDirectoryName($EnginePath)
$Policy=@{max_selections=1;redirects=@{max_hops=2};selected_proxy_bypass='environment';environment_bypass_precedence=@('ERGOPTI_DISCOVERY_CONTROL_UNUSED')}
$CallerCount=0
foreach($Pair in @(@('ergopti_managed_curl_worker.ps1','Resolve-ErgoptiManagedFreshSelection'),@('ergopti_updater_download.ps1','Resolve-ErgoptiArtifactFreshSelection'))){
 $Source=[IO.File]::ReadAllText((Join-Path $Root $Pair[0]));. ([ScriptBlock]::Create((Body $Source $Pair[1])));$Branch=[ScriptBlock]::Create((Transport $Source))
 foreach($Change in @($false,$true)){
  $C=New-Control;$Engine=$AttemptEngine=$C.Engine;$Destination=$C.Destination;$OriginalUrl=$Destination.AbsoluteUri;$Route=$C.Route;$Capability=$C.Capability;$Method='POST';$SendBody=$SendHeaders=$true;$Answer=@{};$State=@{};$global:CallerSelections=0;$global:CallerChange=$Change
  $InputValue=$C.Parameters;$InputValue|Add-Member fixed_proxy $null;$InputValue|Add-Member settings_override $null;$InputValue|Add-Member policy_path 'CONTROLLED_POLICY';$InputValue|Add-Member defaults_path 'CONTROLLED_DEFAULTS'
  $ResolveRoutes={param($Url,$Budget)Resolve-ErgoptiNativeNetworkRoutes $Url $Budget $null $null '' ''};$ReadEnvironment={param($Name)return ''}
  $Selection=&$Pair[1] $Destination
  if($Change){Refuses { & $Branch };Require ($global:ErgoptiDiscoveryControlPort.calls-eq1) 'actual_caller_fresh_route_no_credentials'}
  else{. $Branch;Require ($Metrics.exit-eq0-and$global:ErgoptiDiscoveryControlPort.calls-eq2) 'actual_caller_selected_success'}
  Require ($global:CallerSelections-eq2) 'actual_caller_fresh_selector_not_recursion';$CallerCount++
 }
}
    Require ($CallerCount -eq 4) 'actual_both_caller_case_floor'
    'CURL_PROXY_DISCOVERY_CONTROLLED_PORTS:34'
} finally {
    Remove-Variable -Name ErgoptiDiscoveryControlPort -Scope Global -ErrorAction SilentlyContinue
    foreach($Name in @('body','headers','payload','config','capability')) {
        $Path=Join-Path $Directory $Name
        if([IO.File]::Exists($Path)){[IO.File]::Delete($Path)}
    }
    [IO.Directory]::Delete($Directory,$false)
}
