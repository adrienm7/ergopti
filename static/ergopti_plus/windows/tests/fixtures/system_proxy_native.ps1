# tests/fixtures/system_proxy_native.ps1
# Controlled Windows WinHTTP PAC fixtures; this does not change user settings.
param(
    [Parameter(Mandatory = $true)][string]$WorkerPath,
    [Parameter(Mandatory = $true)][string]$EntryInputPath
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$ProxyNativeDiagnosticStage='source_load'
$Passed=0
# Project only closed exception families and numeric codes; never error text.
function Write-ProxyNativeFailure([System.Management.Automation.ErrorRecord]$Failure) {
    $Exception=$Failure.Exception
    for ($Depth=0; $Depth -lt 8 -and $null -ne $Exception.InnerException; $Depth++) {
        $Exception=$Exception.InnerException
    }
    $Family='other'
    $Code=[long]$Exception.HResult
    if ($Exception -is [System.ComponentModel.Win32Exception]) { $Family='win32';$Code=[long]$Exception.NativeErrorCode }
    elseif ($Exception -is [System.Management.Automation.CommandNotFoundException]) { $Family='command_missing' }
    elseif ($Exception -is [System.IO.IOException]) { $Family='io' }
    elseif ($Exception -is [System.ArgumentException]) { $Family='argument' }
    elseif ($Exception -is [System.InvalidOperationException]) { $Family='invalid_operation' }
    elseif ($Exception -is [System.TimeoutException]) { $Family='timeout' }
    elseif ($Exception -is [System.Management.Automation.RuntimeException]) { $Family='runtime' }
    if ($Code -lt [int]::MinValue -or $Code -gt [int]::MaxValue) { return }
    [Console]::Out.WriteLine('PROXY_NATIVE_DIAG stage='+$script:ProxyNativeDiagnosticStage+' passed='+$script:Passed+' family='+$Family+' code='+$Code.ToString([Globalization.CultureInfo]::InvariantCulture))
    [Console]::Out.Flush()
}
function Write-ProxyEntryFailure([System.Management.Automation.ErrorRecord]$Failure) {
    if ($script:ProxyNativeDiagnosticStage -cne 'entrypoint_input') { return }
    $Sites=@('paths','defaults_read','budget_guard','native_ex_load','private_input','input_write','launch_setup')
    $Site=if ($script:ProxyEntrySite -cin $Sites) {$script:ProxyEntrySite} else {'unknown'}
    $Line=0
    if ($null -ne $Failure.InvocationInfo -and $Failure.InvocationInfo.ScriptLineNumber -is [int] -and
        $Failure.InvocationInfo.ScriptLineNumber -ge 1 -and $Failure.InvocationInfo.ScriptLineNumber -le 8192) {
        $Line=$Failure.InvocationInfo.ScriptLineNumber
    }
    $Error='other'
    $ErrorId=[string]$Failure.FullyQualifiedErrorId
    if ($ErrorId.Length -le 256) {
        switch -CaseSensitive (($ErrorId -split ',')[0]) {
            'Canonical native entrypoint deadline was refused.' {$Error='budget_refused'}
            'COMPILER_ERRORS' {$Error='compiler'}
            'SOURCE_CODE_ERROR' {$Error='compiler'}
            'CannotDefineNewType' {$Error='language_refused'}
            'System.ArgumentException' {if ($Failure.InvocationInfo.MyCommand.Name -ceq 'ConvertFrom-Json') {$Error='json_invalid'}}
            'TYPE_ALREADY_EXISTS' {$Error='type_exists'}
            'TypeNotFound' {$Error='type_missing'}
            'MethodNotFound' {$Error='method_missing'}
            'MethodCountCouldNotFindBest' {$Error='method_overload'}
            'PropertyNotFoundStrict' {$Error='property_missing'}
            'CommandNotFoundException' {$Error='command_missing'}
            'MethodInvocationException' {$Error='method_invocation'}
        }
    }
    $Command='other'
    if ($null -ne $Failure.InvocationInfo -and $null -ne $Failure.InvocationInfo.MyCommand) {
        switch -CaseSensitive ($Failure.InvocationInfo.MyCommand.Name) {
            'Add-Type' {$Command='add_type'}
            'Get-Content' {$Command='get_content'}
            'ConvertFrom-Json' {$Command='convert_json'}
        }
    }
    $Category='unknown'
    if ($null -ne $Failure.CategoryInfo -and [Enum]::IsDefined([Management.Automation.ErrorCategory],$Failure.CategoryInfo.Category)) {
        $Category=([int]$Failure.CategoryInfo.Category).ToString([Globalization.CultureInfo]::InvariantCulture)
    }
    $Language='unknown'
    if ($ExecutionContext.SessionState.LanguageMode -cin @('FullLanguage','ConstrainedLanguage','RestrictedLanguage','NoLanguage')) {
        $Language=[string]$ExecutionContext.SessionState.LanguageMode
    }
    $Compiler='none'
    $ErrorIdToken=''
    if ($Error -ceq 'compiler' -and $Command -ceq 'add_type' -and $ErrorId.Length -le 256) {
        $ErrorIdToken=($ErrorId -split ',')[0]
    }
    if ($ErrorIdToken -cin @('SOURCE_CODE_ERROR','COMPILER_ERRORS')) {
        $CompilerText=[string]$Failure.Exception.Message
        if ($CompilerText.Length -le 8192) {
            $Codes=[regex]::Matches($CompilerText,'(?m)^[^\r\n]{0,512}\berror (CS[0-9]{4}):')
            if ($Codes.Count -eq 1) {$Compiler=$Codes[0].Groups[1].Value}
        }
    }
    $Budget=if ($script:LookupSeconds -is [int]) {'int32'} elseif ($script:LookupSeconds -is [long]) {'int64'}
        elseif ($script:LookupSeconds -is [double]) {'double'} elseif ($null -eq $script:LookupSeconds) {'absent'} else {'other'}
    $Helper=0;$Tick=0
    $Type='ErgoptiNativeProxyEx' -as [type]
    if ($null -ne $Type) {
        $Helper=1
        $Method=$Type.GetMethod('CurrentTick',[Reflection.BindingFlags]::Public -bor [Reflection.BindingFlags]::Static)
        if ($null -ne $Method -and $Method.GetParameters().Length -eq 0 -and $Method.ReturnType -eq [long]) {$Tick=1}
    }
    [Console]::Out.WriteLine('PROXY_ENTRY_DIAG site='+$Site+' line='+$Line+' error='+$Error+' budget='+$Budget+' helper='+$Helper+' tick='+$Tick+' command='+$Command+' category='+$Category+' language='+$Language+' compiler='+$Compiler)
    [Console]::Out.Flush()
}
$ProxyEntrySite='unknown'
$LookupSeconds=$null
try {
$NativePath = Join-Path (Split-Path -Parent $WorkerPath) 'ergopti_native_proxy.ps1'
$Source = Get-Content -LiteralPath $NativePath -Raw -Encoding UTF8
$ProxyNativeDiagnosticStage='source_parse'
$Match = [regex]::Match($Source, "(?s)Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@")
if (-not $Match.Success -or $Match.Groups[1].Value -eq '') { throw 'Canonical native proxy source owner not found.' }
$ProxyNativeDiagnosticStage='native_compile'
Add-Type -TypeDefinition $Match.Groups[1].Value
$ProxyNativeDiagnosticStage='fixture_compile'
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

public sealed class ErgoptiPacFixture : IDisposable
{
    private readonly TcpListener listener;
    private readonly Thread thread;
    private volatile bool stopping;
    public readonly string Url;
    public readonly List<string> Requests = new List<string>();

    public ErgoptiPacFixture()
    {
        listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        int port = ((IPEndPoint)listener.LocalEndpoint).Port;
        Url = "http://127.0.0.1:" + port + "/fixture.pac";
        thread = new Thread(Serve);
        thread.IsBackground = true;
        thread.Start();
    }

    private void Serve()
    {
        while (!stopping)
        {
            try
            {
                using (TcpClient client = listener.AcceptTcpClient())
                using (NetworkStream stream = client.GetStream())
                {
                    client.ReceiveTimeout = 3000;
                    client.SendTimeout = 3000;
                    StringBuilder request = new StringBuilder();
                    byte[] one = new byte[1];
                    while (request.Length < 16384 && !request.ToString().EndsWith("\r\n\r\n"))
                    {
                        if (stream.Read(one, 0, 1) != 1) break;
                        request.Append((char)one[0]);
                    }
                    string line = request.ToString().Split('\n')[0].Trim();
                    lock (Requests) { Requests.Add(line); }
                    bool bad = line.Contains("/bad.pac");
                    bool absent = line.Contains("/missing.pac");
                    string script = bad ? "function FindProxyForURL(url,host) { this is not javascript" :
                        "function FindProxyForURL(url,host) {" +
                        "if (url == 'https://destination.invalid:8443/') return 'PROXY exact.invalid:3128';" +
                        "if (url == 'https://destination.invalid:8443/private?key=fixture-secret') return 'PROXY exact.invalid:3128';" +
                        "if (url == 'http://destination.invalid:8443/private?key=fixture-secret') return 'PROXY scheme.invalid:8080';" +
                        "if (url == 'https://destination.invalid:9443/') return 'PROXY port.invalid:8090';" +
                        "if (url == 'http://destination.invalid:8443/other?key=fixture-secret') return 'PROXY path.invalid:8091';" +
                        "if (url == 'http://destination.invalid:8443/private?key=other-secret') return 'PROXY query.invalid:8092';" +
                        "if (url == 'http://destination.invalid/failover') return 'PROXY first.invalid:80; PROXY second.invalid:80; DIRECT';" +
                        "return 'DIRECT';}";
                    byte[] body = Encoding.UTF8.GetBytes(absent ? "not found" : script);
                    string headers = "HTTP/1.1 " + (absent ? "404 Not Found" : "200 OK") +
                        "\r\nContent-Type: application/x-ns-proxy-autoconfig\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: " + body.Length + "\r\n\r\n";
                    byte[] headerBytes = Encoding.ASCII.GetBytes(headers);
                    stream.Write(headerBytes, 0, headerBytes.Length);
                    stream.Write(body, 0, body.Length);
                }
            }
            catch (Exception)
            {
                if (!stopping) stopping = true;
            }
        }
    }

    public void Dispose()
    {
        stopping = true;
        listener.Stop();
        if (!thread.Join(3000)) throw new Exception("PAC fixture did not retire.");
    }
}
'@
$ProxyNativeDiagnosticStage='abi'
$Passed=0
function Require([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        throw $Message
    }
}
$OptionsSize = [Runtime.InteropServices.Marshal]::SizeOf([type][ErgoptiNativeProxy+AutoProxyOptions])
$ProxySize = [Runtime.InteropServices.Marshal]::SizeOf([type][ErgoptiNativeProxy+ProxyInfo])
Require ($OptionsSize -eq $(if ([IntPtr]::Size -eq 8) { 32 } else { 24 })) 'WinHTTP options ABI mismatch.'
Require ($ProxySize -eq $(if ([IntPtr]::Size -eq 8) { 24 } else { 12 })) 'WinHTTP proxy-info ABI mismatch.'
Require ([Runtime.InteropServices.Marshal]::OffsetOf([type][ErgoptiNativeProxy+AutoProxyOptions], 'AutoConfigUrl').ToInt32() -eq 8) 'WinHTTP URL pointer offset mismatch.'
Require ([Runtime.InteropServices.Marshal]::OffsetOf([type][ErgoptiNativeProxy+ProxyInfo], 'Proxy').ToInt32() -eq [IntPtr]::Size) 'WinHTTP proxy pointer offset mismatch.'
$ProxyNativeDiagnosticStage='server_setup'
$Server = [ErgoptiPacFixture]::new()
$Passed = 0
try {
    $Cases = @(
        @{ url = 'https://destination.invalid:8443/private?key=fixture-secret'; proxy = 'exact.invalid:3128' },
        @{ url = 'http://destination.invalid:8443/private?key=fixture-secret'; proxy = 'scheme.invalid:8080' },
        @{ url = 'https://destination.invalid:9443/private?key=fixture-secret'; proxy = 'port.invalid:8090' },
        @{ url = 'http://destination.invalid:8443/other?key=fixture-secret'; proxy = 'path.invalid:8091' },
        @{ url = 'http://destination.invalid:8443/private?key=other-secret'; proxy = 'query.invalid:8092' }
    )
    $ProxyNativeDiagnosticStage='native_cases'
    foreach ($Probe in $Cases) {
        $ProxyNativeDiagnosticStage='native_call'
        $Result = [ErgoptiNativeProxy]::Resolve($Probe.url, $Server.Url, $false)
        $ProxyNativeDiagnosticStage='native_cases'
        Require ($Result.Ok -and $Result.Kind -ceq 'named_proxy' -and $Result.AccessType -eq 3 -and
            $Result.Proxy -ceq $Probe.proxy -and $Result.NativeError -eq 0) 'Native scheme/port or HTTP full-destination PAC fixture failed.'
        $Passed++
    }
    # Real Windows WinHTTP passes HTTPS scheme/host/port plus root to the PAC;
    # HTTP retains path/query. Preserve both independent native policy controls.
    $ProxyNativeDiagnosticStage='https_scope'
    foreach ($PrivateHttps in @('https://destination.invalid:8443/other?key=fixture-secret',
        'https://destination.invalid:8443/private?key=other-secret')) {
        $ProxyNativeDiagnosticStage='native_call'
        $HttpsReceipt = [ErgoptiNativeProxy]::Resolve($PrivateHttps, $Server.Url, $false)
        $ProxyNativeDiagnosticStage='https_scope'
        Require ($HttpsReceipt.Ok -and $HttpsReceipt.Kind -ceq 'named_proxy' -and
            $HttpsReceipt.AccessType -eq 3 -and $HttpsReceipt.Proxy -ceq 'exact.invalid:3128' -and
            $HttpsReceipt.NativeError -eq 0) 'Native HTTPS privacy scope changed.'
    }
    $Passed++
    $ProxyNativeDiagnosticStage='direct'
    $ProxyNativeDiagnosticStage='native_call'
    $Direct = [ErgoptiNativeProxy]::Resolve('https://destination.invalid/direct', $Server.Url, $false)
    $ProxyNativeDiagnosticStage='direct'
    Require ($Direct.Ok -and $Direct.Kind -ceq 'no_proxy' -and $Direct.AccessType -eq 1 -and
        $Direct.Proxy -ceq '' -and $Direct.NativeError -eq 0) 'PAC DIRECT lacks native acknowledgment.'
    $Passed++
    $ProxyNativeDiagnosticStage='bad_script'
    $ProxyNativeDiagnosticStage='native_call'
    $Bad = [ErgoptiNativeProxy]::Resolve('https://destination.invalid/private', $Server.Url.Replace('fixture.pac', 'bad.pac'), $false)
    $ProxyNativeDiagnosticStage='bad_script'
    Require (-not $Bad.Ok -and $Bad.Kind -ceq 'refused' -and $Bad.NativeError -ne 0) 'Invalid PAC must retain native failure.'
    $Passed++
    $ProxyNativeDiagnosticStage='missing_script'
    $ProxyNativeDiagnosticStage='native_call'
    $Missing = [ErgoptiNativeProxy]::Resolve('https://destination.invalid/private', $Server.Url.Replace('fixture.pac', 'missing.pac'), $false)
    $ProxyNativeDiagnosticStage='missing_script'
    Require (-not $Missing.Ok -and $Missing.Kind -ceq 'refused' -and $Missing.NativeError -ne 0) 'Unavailable configured PAC cannot become direct.'
    $Passed++
    $ProxyNativeDiagnosticStage='failover'
    $ProxyNativeDiagnosticStage='native_call'
    $Failover = [ErgoptiNativeProxy]::Resolve('http://destination.invalid/failover', $Server.Url, $false)
    $ProxyNativeDiagnosticStage='failover'
    Require ($Failover.Ok -and $Failover.Kind -ceq 'named_proxy' -and $Failover.AccessType -eq 3 -and $Failover.NativeError -eq 0) 'Valid multi-proxy PAC did not produce a native named-proxy receipt.'
    if ($Failover.Proxy -ceq 'first.invalid:80') {
        $FailoverRepresentation = 'first_only'
    } elseif ($Failover.Proxy -cmatch '^first\.invalid:80[; ]+second\.invalid:80[; ]*$') {
        $FailoverRepresentation = 'list_two'
    } else {
        throw 'Native PAC returned an unsupported controlled failover representation.'
    }
    # Record the actual closed representation. A first-only API receipt cannot
    # prove equivalent full PAC failover; an explicit list is refused by AHK.
    $Passed++
    # Execute the actual production script entrypoint, not only its native code.
    # The AHK fixture owner retains and removes this private input after its
    # entire Job-owned tree has acknowledged retirement.
    $ProxyNativeDiagnosticStage='entrypoint_input'
    $ProxyEntrySite='paths'
    $VendorRoot=Split-Path -Parent ([IO.Path]::GetFullPath($WorkerPath))
    $SharedRoot=Join-Path (Split-Path -Parent (Split-Path -Parent $VendorRoot)) '_shared'
    $PolicyPath=Join-Path $SharedRoot 'modules/network/proxy_policy.json'
    $DefaultsPath=Join-Path $SharedRoot 'modules/updater/defaults.json'
    $ProxyEntrySite='defaults_read'
    $Defaults=Get-Content -LiteralPath $DefaultsPath -Raw -Encoding UTF8|ConvertFrom-Json
    $LookupSeconds=$Defaults.release_sources.proxy_resolve_timeout_sec
    $ProxyEntrySite='budget_guard'
    Require (($LookupSeconds -is [int] -or $LookupSeconds -is [long]) -and
        $LookupSeconds -ge 1 -and $LookupSeconds -le [int]::MaxValue / 1000) 'Canonical native entrypoint deadline was refused.'
    $ProxyEntrySite='native_ex_load'
    . (Join-Path $VendorRoot 'ergopti_native_proxy_ex.ps1')
    $ProxyEntrySite='private_input'
    $EntryInput = @{ version = 1; auto_detect = $false; pac_url = $Server.Url
        urls = @('https://destination.invalid:8443/private?key=fixture-secret')
        policy_path=$PolicyPath;updater_defaults_path=$DefaultsPath
        deadline_tick=([ErgoptiNativeProxyEx]::CurrentTick()+$LookupSeconds*1000) }
    $ProxyEntrySite='input_write'
    [IO.File]::WriteAllText($EntryInputPath, ($EntryInput | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
    $ProxyEntrySite='launch_setup'
    $Launch = [Diagnostics.ProcessStartInfo]::new()
    $Launch.FileName = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $Launch.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $WorkerPath + '" -InputPath "' + $EntryInputPath + '"'
    $Launch.UseShellExecute = $false
    $Launch.CreateNoWindow = $true
    $Launch.RedirectStandardOutput = $true
    $Launch.RedirectStandardError = $true
    Require (-not $Launch.Arguments.Contains('fixture-secret') -and -not $Launch.Arguments.Contains($Server.Url)) 'Private destinations or PAC URL entered native argv.'
    $Child = [Diagnostics.Process]::new()
    $Child.StartInfo = $Launch
    try {
    $ProxyNativeDiagnosticStage='entrypoint_start'
        Require ($Child.Start()) 'Native production worker did not start.'
    $ProxyNativeDiagnosticStage='entrypoint_wait'
        Require ($Child.WaitForExit(10000)) 'Native production worker exceeded its owned entrypoint budget.'
        $ProxyNativeDiagnosticStage='entrypoint_read'
        $EntryOut = $Child.StandardOutput.ReadToEnd()
        $EntryErr = $Child.StandardError.ReadToEnd()
    $ProxyNativeDiagnosticStage='entrypoint_process'
        Require ($Child.ExitCode -eq 0 -and $EntryErr -ceq '') 'Native production worker entrypoint failed.'
    $ProxyNativeDiagnosticStage='entrypoint_privacy'
        Require (-not $EntryOut.Contains('fixture-secret') -and -not $EntryOut.Contains($Server.Url)) 'Native receipt exposed private input.'
        $ProxyNativeDiagnosticStage='entrypoint_parse'
        $EntryReceipt = $EntryOut | ConvertFrom-Json
    $ProxyNativeDiagnosticStage='entrypoint_frame'
        Require ($EntryReceipt.version -eq 1 -and $EntryReceipt.status -ceq 'completed' -and
            $EntryReceipt.results.Count -eq 1 -and $EntryReceipt.results[0].ok -eq $true -and
            $EntryReceipt.results[0].kind -ceq 'named_proxy' -and $EntryReceipt.results[0].access_type -eq 3 -and
            $EntryReceipt.results[0].proxy -ceq 'exact.invalid:3128' -and $EntryReceipt.results[0].native_error -eq 0) 'Actual private-input native receipt was not acknowledged.'
        $Passed++
    } finally {
        # A still-live descendant remains in the outer AHK Job. Do not mistake
        # Dispose for retirement: the AHK finally must terminate the exact tree.
        try { $Child.Dispose() } catch { $ProxyNativeDiagnosticStage='cleanup';throw }
    }
    $ProxyNativeDiagnosticStage='server_receipt'
    Require ($Server.Requests.Count -ge 3) 'Native PAC server was not contacted for controlled scripts.'
} finally {
    try { $Server.Dispose() } catch { $ProxyNativeDiagnosticStage='cleanup';throw }
}
[Console]::Out.WriteLine("[OBSERVED] native_https_scope=scheme_host_port_root;http_destination=full_url")
[Console]::Out.WriteLine("[OBSERVED] native_failover=$FailoverRepresentation")
[Console]::Out.WriteLine("[OK] $Passed controlled native WinHTTP PAC fixtures and $([IntPtr]::Size * 8)-bit ABI assertions.")
} catch {
    # Keep the actual exception/refusal while exposing no private input or text.
    try { Write-ProxyNativeFailure $_ } catch { }
    try { Write-ProxyEntryFailure $_ } catch { }
    throw
}
