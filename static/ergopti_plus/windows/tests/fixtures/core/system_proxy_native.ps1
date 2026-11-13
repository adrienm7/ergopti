# tests/fixtures/core/system_proxy_native.ps1
# Controlled PAC fixtures through the production worker; this does not change user settings.
param(
    [Parameter(Mandatory = $true)][string]$WorkerPath,
    [Parameter(Mandatory = $true)][string]$EntryInputPath
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$ProxyNativeDiagnosticStage='fixture_compile'
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
function Require([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        throw $Message
    }
}
$ProxyNativeDiagnosticStage='server_setup'
$Server = [ErgoptiPacFixture]::new()
$Passed = 0
try {
    # Everything below runs the production worker entrypoint, not only its native
    # code. The AHK fixture owner retains and removes this private input after its
    # entire Job-owned tree has acknowledged retirement.
    $ProxyNativeDiagnosticStage='entrypoint_input'
    $ProxyEntrySite='paths'
    $VendorRoot=Split-Path -Parent ([IO.Path]::GetFullPath($WorkerPath))
    $SharedRoot=Join-Path (Split-Path -Parent (Split-Path -Parent $VendorRoot)) '_shared'
    $PolicyPath=Join-Path $SharedRoot 'core/network/data/proxy_policy.json'
    $DefaultsPath=Join-Path $SharedRoot 'updater/data/defaults.json'
    $ProxyEntrySite='defaults_read'
    $Defaults=Get-Content -LiteralPath $DefaultsPath -Raw -Encoding UTF8|ConvertFrom-Json
    $LookupSeconds=$Defaults.release_sources.proxy_resolve_timeout_sec
    $ProxyEntrySite='budget_guard'
    Require (($LookupSeconds -is [int] -or $LookupSeconds -is [long]) -and
        $LookupSeconds -ge 1 -and $LookupSeconds -le [int]::MaxValue / 1000) 'Canonical native entrypoint deadline was refused.'
    $ProxyEntrySite='native_ex_load'
    . (Join-Path $VendorRoot 'ergopti_native_proxy_ex.ps1')
    # One worker run over one private input file. Returns its parsed receipt.
    function Invoke-ProxyWorker([string]$PacUrl, [string[]]$Urls) {
        $script:ProxyNativeDiagnosticStage='entrypoint_input'
        $script:ProxyEntrySite='private_input'
        $EntryInput = @{ version = 1; auto_detect = $false; pac_url = $PacUrl; urls = $Urls
            policy_path=$PolicyPath;updater_defaults_path=$DefaultsPath
            deadline_tick=([ErgoptiNativeProxyEx]::CurrentTick()+$LookupSeconds*1000) }
        $script:ProxyEntrySite='input_write'
        [IO.File]::WriteAllText($EntryInputPath, ($EntryInput | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
        $script:ProxyEntrySite='launch_setup'
        $Launch = [Diagnostics.ProcessStartInfo]::new()
        $Launch.FileName = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $Launch.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $WorkerPath + '" -InputPath "' + $EntryInputPath + '"'
        $Launch.UseShellExecute = $false
        $Launch.CreateNoWindow = $true
        $Launch.RedirectStandardOutput = $true
        $Launch.RedirectStandardError = $true
        Require (-not $Launch.Arguments.Contains('fixture-secret') -and -not $Launch.Arguments.Contains($PacUrl)) 'Private destinations or PAC URL entered native argv.'
        $Child = [Diagnostics.Process]::new()
        $Child.StartInfo = $Launch
        try {
            $script:ProxyNativeDiagnosticStage='entrypoint_start'
            Require ($Child.Start()) 'Native production worker did not start.'
            $script:ProxyNativeDiagnosticStage='entrypoint_wait'
            Require ($Child.WaitForExit(10000)) 'Native production worker exceeded its owned entrypoint budget.'
            $script:ProxyNativeDiagnosticStage='entrypoint_read'
            $EntryOut = $Child.StandardOutput.ReadToEnd()
            $EntryErr = $Child.StandardError.ReadToEnd()
            $script:ProxyNativeDiagnosticStage='entrypoint_process'
            Require ($EntryErr -ceq '') 'Native production worker entrypoint failed.'
            $script:ProxyNativeDiagnosticStage='entrypoint_privacy'
            Require (-not $EntryOut.Contains('fixture-secret') -and -not $EntryOut.Contains($PacUrl)) 'Native receipt exposed private input.'
            $script:ProxyNativeDiagnosticStage='entrypoint_parse'
            return ($EntryOut | ConvertFrom-Json)
        } finally {
            # A still-live descendant remains in the outer AHK Job. Do not mistake
            # Dispose for retirement: the AHK finally must terminate the exact tree.
            try { $Child.Dispose() } catch { $script:ProxyNativeDiagnosticStage='cleanup';throw }
        }
    }
    $Cases = @(
        @{ url = 'https://destination.invalid:8443/private?key=fixture-secret'; proxy = 'exact.invalid:3128' },
        @{ url = 'http://destination.invalid:8443/private?key=fixture-secret'; proxy = 'scheme.invalid:8080' },
        @{ url = 'http://destination.invalid:8443/other?key=fixture-secret'; proxy = 'path.invalid:8091' },
        @{ url = 'http://destination.invalid:8443/private?key=other-secret'; proxy = 'query.invalid:8092' },
        @{ url = 'https://destination.invalid/direct'; proxy = '' }
    )
    $Named = Invoke-ProxyWorker $Server.Url @($Cases | ForEach-Object { $_.url })
    $ProxyNativeDiagnosticStage='entrypoint_frame'
    Require ($Named.version -eq 1 -and $Named.status -ceq 'completed' -and $Named.results.Count -eq $Cases.Count) 'Actual private-input native receipt was not acknowledged.'
    for ($Index = 0; $Index -lt $Cases.Count; $Index++) {
        $Item = $Named.results[$Index]
        $Expected = if ($Cases[$Index].proxy -eq '') { @{ kind = 'no_proxy'; access = 1 } } else { @{ kind = 'named_proxy'; access = 3 } }
        Require ($Item.ok -eq $true -and $Item.kind -ceq $Expected.kind -and $Item.access_type -eq $Expected.access -and
            $Item.proxy -ceq $Cases[$Index].proxy -and $Item.native_error -eq 0) 'The PAC decision did not follow the full destination.'
        $Passed++
    }
    foreach ($Broken in @('bad.pac', 'missing.pac')) {
        $Failed = Invoke-ProxyWorker $Server.Url.Replace('fixture.pac', $Broken) @('https://destination.invalid/private')
        $ProxyNativeDiagnosticStage='entrypoint_frame'
        Require ($Failed.results.Count -eq 1 -and -not $Failed.results[0].ok -and $Failed.results[0].kind -ceq 'refused') 'An unusable configured PAC cannot become direct.'
        $Passed++
    }
    $ProxyNativeDiagnosticStage='server_receipt'
    Require ($Server.Requests.Count -ge 3) 'Native PAC server was not contacted for controlled scripts.'
} finally {
    try { $Server.Dispose() } catch { $ProxyNativeDiagnosticStage='cleanup';throw }
}
[Console]::Out.WriteLine("[OK] $Passed controlled native PAC worker fixtures.")
} catch {
    # Keep the actual exception/refusal while exposing no private input or text.
    try { Write-ProxyNativeFailure $_ } catch { }
    try { Write-ProxyEntryFailure $_ } catch { }
    throw
}
