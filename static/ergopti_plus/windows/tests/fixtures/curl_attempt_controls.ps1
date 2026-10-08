# tests/fixtures/curl_attempt_controls.ps1
# Calls actual factory helpers with literal observations; no native handshake is claimed.
param([Parameter(Mandatory = $true)][string]$EnginePath)
$ErrorActionPreference = 'Stop'
. $EnginePath
if (-not ('ErgoptiNativeProxyEx' -as [type])) {
    Add-Type -TypeDefinition @'
public static class ErgoptiNativeProxyEx {
    public static long Tick = 2000;
    public static long CurrentTick() { return Tick; }
}
'@
}
function Require([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:Passed++
}
$Passed = 0
$OneInput = [pscustomobject]@{started_tick = [long]1000; deadline_ms = 5000}
$TwoInput = [pscustomobject]@{started_tick = [long]1900; deadline_ms = 1000}
$One = New-ErgoptiCurlAttemptEngine $OneInput @{} 'one.capability' 'one.payload' 'one.config'
$Two = New-ErgoptiCurlAttemptEngine $TwoInput @{} 'two.capability' 'two.payload' 'two.config'
Require ($One.GetRemainingBudget() -eq 4000) 'First model clock did not retain its own deadline.'
Require ($Two.GetRemainingBudget() -eq 900) 'Second model clock leaked the first operation.'
$OneInput.deadline_ms = 6000
Require ($One.GetRemainingBudget() -eq 5000 -and $Two.GetRemainingBudget() -eq 900) 'Factory references were aliased across operations.'
Require ($One.ChildQuiesced() -and $Two.ChildQuiesced()) 'Factory construction started a child.'
Require ($null -eq $One.PSObject.Properties['Child']) 'Factory exposed private child authority.'
$UnknownRefused = $false
try { $One.InvokeOwnedProcess('forbidden', '', 1) } catch { $UnknownRefused = $true }
Require $UnknownRefused 'Unexported native child entry point was callable.'
$Destination = [Uri]'https://origin.invalid/exact/path?q=kept'
$Route = @{Kind = 'proxy'; Endpoint = 'http://127.0.0.1:1234'}
$Capability = @{ntlm = $true}
function New-Metrics {
    return @{child_quiesced = $true; proxy_used = $true; connect = 407; status = 0;
        delivered = [long]0; headers = @{connect_challenges = @('NTLM')}}
}
Require ($One.TestNtlmChallenge($Destination, $Route, (New-Metrics), $Capability)) 'Literal bare NTLM CONNECT challenge must qualify.'
foreach ($Challenge in @('NTLM TlRMTVNTUAABAAAA', 'NTLM', 'ntlm')) {
    $Metrics = New-Metrics
    $Metrics.headers.connect_challenges = @('Basic realm="fixture"', $Challenge)
    Require ($One.TestNtlmChallenge($Destination, $Route, $Metrics, $Capability)) 'Allowed literal NTLM challenge was rejected.'
}
foreach ($Case in @('http', 'direct', 'child', 'child_type', 'proxy', 'proxy_type', 'connect', 'status', 'bytes', 'feature', 'type', 'negotiate', 'malformed')) {
    $Uri = $Destination
    $Selected = $Route.Clone()
    $Native = $Capability.Clone()
    $Metrics = New-Metrics
    switch ($Case) {
        'http' {$Uri = [Uri]'http://origin.invalid/exact/path'}
        'direct' {$Selected.Kind = 'direct'}
        'child' {$Metrics.child_quiesced = $false}
        'child_type' {$Metrics.child_quiesced = 'true'}
        'proxy' {$Metrics.proxy_used = $false}
        'proxy_type' {$Metrics.proxy_used = 'true'}
        'connect' {$Metrics.connect = 403}
        'status' {$Metrics.status = 401}
        'bytes' {$Metrics.delivered = 1}
        'feature' {$Native.ntlm = $false}
        'type' {$Native.ntlm = 'true'}
        'negotiate' {$Metrics.headers.connect_challenges = @('NTLM', 'Negotiate')}
        'malformed' {$Metrics.headers.connect_challenges = @('NTLM !not-a-token!')}
    }
    Require (-not $One.TestNtlmChallenge($Uri, $Selected, $Metrics, $Native)) ('Unsafe literal fallback was admitted: ' + $Case)
}
# Compile the exact privately used bounded pipe reader without starting a child.
# StringReader controls prove its memory/EOF policy, not Windows pipe scheduling.
$Source = Get-Content -LiteralPath $EnginePath -Raw -Encoding UTF8
$PipeSource = ([regex]::Match($Source, '(?s)Add-Type -TypeDefinition @''\n(.*?)\n''@')).Groups[1].Value
Require ($PipeSource.Length -gt 500) 'The actual bounded pipe reader source is missing.'
Add-Type -TypeDefinition $PipeSource
foreach ($Case in @(
    @{text='';maximum=1;refused=$false},
    @{text='abcd';maximum=4;refused=$false},
    @{text='éΩ😀';maximum=4;refused=$false},
    @{text='abcde';maximum=4;refused=$true},
    @{text=('x' * 1048576);maximum=1024;refused=$true}
)) {
    $Reader = [IO.StringReader]::new($Case.text)
    $Refused = $false
    try {
        $Task = [ErgoptiBoundedCurlPipe]::Read($Reader, $Case.maximum)
        try { $null = $Task.GetAwaiter().GetResult() } catch { $Refused = $true }
        Require ($Refused -eq $Case.refused -and $Task.IsCompleted -and $Reader.Peek() -eq -1 -and
            ($Refused -or $Task.Result -ceq $Case.text)) 'Actual bounded reader failed its independent scalar/overflow/EOF control.'
    } finally { $Reader.Dispose() }
}
[Console]::Out.WriteLine('CURL_ATTEMPT_MODEL_CONTROLS:' + $Passed)
