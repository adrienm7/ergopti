# tests/fixtures/system_proxy_retirement.ps1
# Execute the unchanged legacy worker with controlled native dependency ports.
# This proves protocol retirement admission; real native PAC has a separate fixture.
param([Parameter(Mandatory=$true)][string]$WorkerPath,
      [string]$PowerShellExecutable=(Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell/v1.0/powershell.exe'))
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$Root=Join-Path ([IO.Path]::GetTempPath()) ('ergopti-legacy-retirement-'+[Guid]::NewGuid().ToString('N'))
$Utf8=[Text.UTF8Encoding]::new($false,$true)
$Failed=$false
$Child=$null
$DiagnosticControl=0
$DiagnosticStage='prepare'
$DiagnosticExit=-999
$DiagnosticOut=-1
$DiagnosticErr=-1
$DiagnosticRawFlags=$null
function Get-ErgoptiLegacyRawContractFlags {
    param($Item,[string]$ExpectedRaw)
    $Values=@{}
    foreach($Name in @('ok','kind','access_type','proxy','bypass','native_error')) {
        $Property=$Item.PSObject.Properties[$Name]
        $Values[$Name]=if($null -ne $Property){$Property.Value}else{$null}
    }
    $OkBool=$Values.ok -is [bool]
    $KindText=$Values.kind -is [string]
    $AccessInteger=($Values.access_type -is [int] -or $Values.access_type -is [long])
    $ProxyText=$Values.proxy -is [string]
    $BypassText=$Values.bypass -is [string]
    $NativeInteger=($Values.native_error -is [int] -or $Values.native_error -is [long])
    # Emit fixed booleans only. Never project a relay, URI, token or source value.
    return @{
        ok_bool=[int]$OkBool;ok_true=[int]($OkBool -and $Values.ok -eq $true)
        kind_text=[int]$KindText;kind_named=[int]($KindText -and $Values.kind -ceq 'named_proxy')
        access_integer=[int]$AccessInteger;access_three=[int]($AccessInteger -and $Values.access_type -eq 3)
        proxy_text=[int]$ProxyText;proxy_literal=[int]($ProxyText -and $Values.proxy -ceq $ExpectedRaw)
        proxy_legacy_ipv6_literal=[int]($ProxyText -and $Values.proxy -ceq '[2001:0DB8:0000:0000:0000:0000:0000:0001]:3129')
        bypass_text=[int]$BypassText;bypass_empty=[int]($BypassText -and $Values.bypass -ceq '')
        native_integer=[int]$NativeInteger;native_zero=[int]($NativeInteger -and $Values.native_error -eq 0)
    }
}
function Get-ErgoptiRetirementSourceHash {
    param([string]$Path)
    # The isolated native caller disables module auto-loading. Hash the held
    # source stream with the runtime API rather than an optional shell command.
    $Stream=$null
    $Algorithm=$null
    try {
        $Stream=[IO.File]::OpenRead($Path)
        $Algorithm=[Security.Cryptography.SHA256]::Create()
        return [BitConverter]::ToString($Algorithm.ComputeHash($Stream)).Replace('-','')
    } finally {
        if($null -ne $Algorithm){$Algorithm.Dispose()}
        if($null -ne $Stream){$Stream.Dispose()}
    }
}
try {
    $null=[IO.Directory]::CreateDirectory($Root)
    $Source=[IO.File]::ReadAllBytes($WorkerPath)
    $ControlledPorts=@'
Add-Type -TypeDefinition 'public static class ErgoptiNetworkPac { public static long CurrentTick() { return 1000; } }'
function Get-ErgoptiNetworkPolicy {param($Path) @{}}
function Test-ErgoptiNetworkInt32 {param($Value) ($Value -is [int] -or $Value -is [long])}
function Resolve-ErgoptiFullUrlPac {
    param($DestinationUrl,$PacUrl,$AutoDetect,$Deadline,$Policy)
    $CountPath=Join-Path $PSScriptRoot 'count.txt'
    $Count=0
    if(Test-Path -LiteralPath $CountPath){$Count=[int][IO.File]::ReadAllText($CountPath)}
    $Count++;[IO.File]::WriteAllText($CountPath,[string]$Count)
    $DebtAt=[int][IO.File]::ReadAllText((Join-Path $PSScriptRoot 'debt_at.txt'))
    $Proxy=if($DestinationUrl.EndsWith('/proxy')){'PROXY raw-fixture.invalid:3128'}elseif($DestinationUrl.EndsWith('/ipv6')){
        'PROXY [2001:db8::1]:3129'}else{'DIRECT'}
    @{OwnersRetired=($Count -ne $DebtAt);Ok=$true;Kind='pac_routes';Proxy=$Proxy;NativeError=0}
}
function ConvertFrom-ErgoptiPacRoutes {
    param($Value,$Policy)
    if($Value -ceq 'PROXY raw-fixture.invalid:3128'){return ,@(@{Kind='proxy';Endpoint='http://raw-fixture.invalid:3128/'})}
    if($Value -ceq 'PROXY [2001:db8::1]:3129'){return ,@(@{Kind='proxy';Endpoint='http://[2001:db8::1]:3129/'})}
    return ,@(@{Kind='direct';Endpoint=''})
}
'@
    $Controls=@(@{DebtAt=1;Calls=1;Exit=1;Status='refused';Results=0},
        @{DebtAt=2;Calls=2;Exit=1;Status='refused';Results=0},
        @{DebtAt=0;Calls=3;Exit=0;Status='completed';Results=3},
        @{DebtAt=0;Calls=1;Exit=0;Status='completed';Results=1;Proxy=$true;Raw='raw-fixture.invalid:3128'},
        @{DebtAt=0;Calls=1;Exit=0;Status='completed';Results=1;Proxy=$true;Ipv6=$true;Raw='[2001:db8::1]:3129'})
    foreach($Control in $Controls) {
        $DiagnosticControl++
        $DiagnosticStage='prepare_control'
        $DiagnosticExit=-999;$DiagnosticOut=-1;$DiagnosticErr=-1;$DiagnosticRawFlags=$null
        $Case=Join-Path $Root ([Guid]::NewGuid().ToString('N'))
        $null=[IO.Directory]::CreateDirectory($Case)
        $Worker=Join-Path $Case 'worker.ps1'
        [IO.File]::WriteAllBytes($Worker,$Source)
        if((Get-ErgoptiRetirementSourceHash -Path $Worker) -cne
            (Get-ErgoptiRetirementSourceHash -Path $WorkerPath)) {
            throw 'Production worker source identity was not preserved.'
        }
        [IO.File]::WriteAllText((Join-Path $Case 'ergopti_network_routes.ps1'),$ControlledPorts,$Utf8)
        [IO.File]::WriteAllText((Join-Path $Case 'debt_at.txt'),[string]$Control.DebtAt,$Utf8)
        $Defaults=Join-Path $Case 'defaults.json'
        [IO.File]::WriteAllText($Defaults,'{"release_sources":{"proxy_resolve_timeout_sec":10}}',$Utf8)
        $Input=Join-Path $Case 'input.json'
        $Urls=if($Control.ContainsKey('Ipv6') -and $Control.Ipv6){@('https://legacy-fixture.invalid/ipv6')}elseif($Control.ContainsKey('Proxy') -and $Control.Proxy){@('https://legacy-fixture.invalid/proxy')}else{
            @('https://legacy-fixture.invalid/a','https://legacy-fixture.invalid/b','https://legacy-fixture.invalid/c')}
        $Record=@{version=1;auto_detect=$false;pac_url='http://pac-fixture.invalid/order.pac';
            urls=@($Urls);
            policy_path=(Join-Path $Case 'policy.json');updater_defaults_path=$Defaults;deadline_tick=2000}
        [IO.File]::WriteAllText($Input,($Record|ConvertTo-Json -Depth 4 -Compress),$Utf8)
        if($Worker.Contains('"') -or $Input.Contains('"')){throw 'Owned fixture argument authority was refused.'}
        $Start=[Diagnostics.ProcessStartInfo]::new($PowerShellExecutable)
        $Start.UseShellExecute=$false;$Start.CreateNoWindow=$true
        $Start.RedirectStandardOutput=$true;$Start.RedirectStandardError=$true
        $Start.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$Worker+'" -InputPath "'+$Input+'"'
        $Clock=[Diagnostics.Stopwatch]::StartNew()
        $DiagnosticStage='start_child'
        $Child=[Diagnostics.Process]::Start($Start)
        $Output=$Child.StandardOutput.ReadToEndAsync()
        $ErrorOutput=$Child.StandardError.ReadToEndAsync()
        $DiagnosticStage='child_exit'
        if(-not $Child.WaitForExit(10000)){throw 'Owned protocol control exceeded its process budget.'}
        $Remaining=[int][Math]::Max(0,10000-$Clock.ElapsedMilliseconds)
        if(-not $Output.Wait($Remaining)){throw 'Owned protocol stdout did not retire.'}
        $Remaining=[int][Math]::Max(0,10000-$Clock.ElapsedMilliseconds)
        if(-not $ErrorOutput.Wait($Remaining)){throw 'Owned protocol stderr did not retire.'}
        $DiagnosticExit=$Child.ExitCode
        $DiagnosticOut=if($Output.Result.Length -le 8192){$Output.Result.Length}else{-1}
        $DiagnosticErr=if($ErrorOutput.Result.Length -le 8192){$ErrorOutput.Result.Length}else{-1}
        $DiagnosticStage='process_receipt'
        if($Output.Result.Length -gt 8192 -or $ErrorOutput.Result -cne '' -or $Child.ExitCode -ne $Control.Exit) {
            throw 'Closed protocol process result was refused.'
        }
        $DiagnosticStage='frame_parse'
        $Frame=$Output.Result|ConvertFrom-Json
        $DiagnosticStage='call_count'
        $Calls=[IO.File]::ReadAllText((Join-Path $Case 'count.txt'))
        $DiagnosticStage='frame_contract'
        if($Calls -cne [string]$Control.Calls -or $Frame.version -ne 1 -or
            $Frame.status -cne $Control.Status -or $Frame.results -isnot [array] -or
            $Frame.results.Count -ne $Control.Results) {
            throw 'Legacy worker started after native debt or published a partial completed receipt.'
        }
        $DiagnosticStage='raw_proxy_contract'
        if($Control.ContainsKey('Proxy') -and $Control.Proxy) {
            $DiagnosticRawFlags=Get-ErgoptiLegacyRawContractFlags $Frame.results[0] $Control.Raw
        }
        if($Control.ContainsKey('Proxy') -and $Control.Proxy -and ($Frame.results[0].ok -ne $true -or
            $Frame.results[0].kind -cne 'named_proxy' -or $Frame.results[0].access_type -ne 3 -or
            $Frame.results[0].proxy -cne $Control.Raw -or
            $Frame.results[0].bypass -cne '' -or $Frame.results[0].native_error -ne 0)) {
            throw 'Legacy raw proxy receipt contract changed.'
        }
        $Child.Dispose();$Child=$null
    }
    [Console]::Out.WriteLine('[OK] legacy proxy protocol: first/second native debt refuse whole receipt; normal three-URL and raw host/IPv6 relay controls preserved')
} catch {
    $Failed=$true
    $Cause='other'
    $CauseLine=0
    if($null -ne $_.InvocationInfo) {
        $CauseLine=[int]$_.InvocationInfo.ScriptLineNumber
        if($CauseLine -lt 0 -or $CauseLine -gt 4096){$CauseLine=0}
        if($_.FullyQualifiedErrorId -like 'CommandNotFound*' -and
            $_.InvocationInfo.InvocationName -ceq 'Get-FileHash') {$Cause='get_file_hash_command_missing'}
    }
    if($_.FullyQualifiedErrorId -ceq 'PropertyNotFoundStrict') {$Cause='optional_control_property_missing'}
    if($_.Exception.Message -ceq 'Production worker source identity was not preserved.') {$Cause='source_identity_mismatch'}
    # Only enumerated source causes and bounded line/control scalars reach CI.
    try {[Console]::Out.WriteLine('::notice title=Windows legacy PAC closed cause::control='+$DiagnosticControl+
        ' stage='+$DiagnosticStage+' cause='+$Cause+' line='+$CauseLine)} catch { }
    try {[Console]::Error.WriteLine('RETIREMENT_DIAG control='+$DiagnosticControl+' stage='+$DiagnosticStage+' child_exit='+$DiagnosticExit+' stdout_units='+$DiagnosticOut+' stderr_units='+$DiagnosticErr)} catch { }
    if($null -ne $DiagnosticRawFlags) {
        try {
            $Flags='RETIREMENT_RAW_FLAGS control='+$DiagnosticControl+' schema=1'
            foreach($Name in @('ok_bool','ok_true','kind_text','kind_named','access_integer','access_three',
                'proxy_text','proxy_literal','proxy_legacy_ipv6_literal','bypass_text','bypass_empty',
                'native_integer','native_zero')) {
                $Flags+=' '+$Name+'='+[string]$DiagnosticRawFlags[$Name]
            }
            [Console]::Error.WriteLine($Flags)
        } catch { }
    }
    [Console]::Error.WriteLine('Legacy proxy retirement protocol failed.')
} finally {
    if($null -ne $Child) {
        try {
            if(-not $Child.HasExited){$Child.Kill()}
            if(-not $Child.WaitForExit(1000)){throw 'Owned protocol process did not physically retire.'}
            $Child.Dispose()
        } catch {$Failed=$true;[Console]::Error.WriteLine('Owned protocol process cleanup refused.')}
    }
    try {if([IO.Directory]::Exists($Root)){[IO.Directory]::Delete($Root,$true)}}
    catch {$Failed=$true;[Console]::Error.WriteLine('Owned protocol scratch cleanup refused.')}
}
if($Failed){exit 1}
