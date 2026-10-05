# tests/fixtures/system_proxy_native.ps1
# Controlled Windows WinHTTP PAC fixtures; this does not change user settings.
param(
    [Parameter(Mandatory = $true)][string]$WorkerPath,
    [Parameter(Mandatory = $true)][string]$EntryInputPath
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Source = Get-Content -LiteralPath $WorkerPath -Raw -Encoding UTF8
$Match = [regex]::Match($Source, "(?s)Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@")
if (-not $Match.Success -or $Match.Groups[1].Value -eq '') { throw 'Native worker source owner not found.' }
Add-Type -TypeDefinition $Match.Groups[1].Value
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
                        "if (url == 'https://destination.invalid:8443/private?key=fixture-secret') return 'PROXY exact.invalid:3128';" +
                        "if (url == 'http://destination.invalid:8443/private?key=fixture-secret') return 'PROXY scheme.invalid:8080';" +
                        "if (url == 'https://destination.invalid:9443/private?key=fixture-secret') return 'PROXY port.invalid:8090';" +
                        "if (url == 'https://destination.invalid:8443/other?key=fixture-secret') return 'PROXY path.invalid:8091';" +
                        "if (url == 'https://destination.invalid:8443/private?key=other-secret') return 'PROXY query.invalid:8092';" +
                        "if (url == 'https://destination.invalid/failover') return 'PROXY first.invalid:80; PROXY second.invalid:80; DIRECT';" +
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
    if (-not $Condition) { throw $Message }
}
$OptionsSize = [Runtime.InteropServices.Marshal]::SizeOf([type][ErgoptiNativeProxy+AutoProxyOptions])
$ProxySize = [Runtime.InteropServices.Marshal]::SizeOf([type][ErgoptiNativeProxy+ProxyInfo])
Require ($OptionsSize -eq $(if ([IntPtr]::Size -eq 8) { 32 } else { 24 })) 'WinHTTP options ABI mismatch.'
Require ($ProxySize -eq $(if ([IntPtr]::Size -eq 8) { 24 } else { 12 })) 'WinHTTP proxy-info ABI mismatch.'
Require ([Runtime.InteropServices.Marshal]::OffsetOf([type][ErgoptiNativeProxy+AutoProxyOptions], 'AutoConfigUrl').ToInt32() -eq 8) 'WinHTTP URL pointer offset mismatch.'
Require ([Runtime.InteropServices.Marshal]::OffsetOf([type][ErgoptiNativeProxy+ProxyInfo], 'Proxy').ToInt32() -eq [IntPtr]::Size) 'WinHTTP proxy pointer offset mismatch.'
$Server = [ErgoptiPacFixture]::new()
$Passed = 0
try {
    $Cases = @(
        @{ url = 'https://destination.invalid:8443/private?key=fixture-secret'; proxy = 'exact.invalid:3128' },
        @{ url = 'http://destination.invalid:8443/private?key=fixture-secret'; proxy = 'scheme.invalid:8080' },
        @{ url = 'https://destination.invalid:9443/private?key=fixture-secret'; proxy = 'port.invalid:8090' },
        @{ url = 'https://destination.invalid:8443/other?key=fixture-secret'; proxy = 'path.invalid:8091' },
        @{ url = 'https://destination.invalid:8443/private?key=other-secret'; proxy = 'query.invalid:8092' }
    )
    foreach ($Probe in $Cases) {
        $Result = [ErgoptiNativeProxy]::Resolve($Probe.url, $Server.Url, $false)
        Require ($Result.Ok -and $Result.Kind -ceq 'named_proxy' -and $Result.AccessType -eq 3 -and
            $Result.Proxy -ceq $Probe.proxy -and $Result.NativeError -eq 0) 'Native exact-destination PAC fixture failed.'
        $Passed++
    }
    $Direct = [ErgoptiNativeProxy]::Resolve('https://destination.invalid/direct', $Server.Url, $false)
    Require ($Direct.Ok -and $Direct.Kind -ceq 'no_proxy' -and $Direct.AccessType -eq 1 -and
        $Direct.Proxy -ceq '' -and $Direct.NativeError -eq 0) 'PAC DIRECT lacks native acknowledgment.'
    $Passed++
    $Bad = [ErgoptiNativeProxy]::Resolve('https://destination.invalid/private', $Server.Url.Replace('fixture.pac', 'bad.pac'), $false)
    Require (-not $Bad.Ok -and $Bad.Kind -ceq 'refused' -and $Bad.NativeError -ne 0) 'Invalid PAC must retain native failure.'
    $Passed++
    $Missing = [ErgoptiNativeProxy]::Resolve('https://destination.invalid/private', $Server.Url.Replace('fixture.pac', 'missing.pac'), $false)
    Require (-not $Missing.Ok -and $Missing.Kind -ceq 'refused' -and $Missing.NativeError -ne 0) 'Unavailable configured PAC cannot become direct.'
    $Passed++
    $Failover = [ErgoptiNativeProxy]::Resolve('https://destination.invalid/failover', $Server.Url, $false)
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
    $EntryInput = @{ version = 1; auto_detect = $false; pac_url = $Server.Url
        urls = @('https://destination.invalid:8443/private?key=fixture-secret') }
    [IO.File]::WriteAllText($EntryInputPath, ($EntryInput | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
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
        Require ($Child.Start()) 'Native production worker did not start.'
        Require ($Child.WaitForExit(10000)) 'Native production worker exceeded its owned entrypoint budget.'
        $EntryOut = $Child.StandardOutput.ReadToEnd()
        $EntryErr = $Child.StandardError.ReadToEnd()
        Require ($Child.ExitCode -eq 0 -and $EntryErr -ceq '') 'Native production worker entrypoint failed.'
        Require (-not $EntryOut.Contains('fixture-secret') -and -not $EntryOut.Contains($Server.Url)) 'Native receipt exposed private input.'
        $EntryReceipt = $EntryOut | ConvertFrom-Json
        Require ($EntryReceipt.version -eq 1 -and $EntryReceipt.status -ceq 'completed' -and
            $EntryReceipt.results.Count -eq 1 -and $EntryReceipt.results[0].ok -eq $true -and
            $EntryReceipt.results[0].kind -ceq 'named_proxy' -and $EntryReceipt.results[0].access_type -eq 3 -and
            $EntryReceipt.results[0].proxy -ceq 'exact.invalid:3128' -and $EntryReceipt.results[0].native_error -eq 0) 'Actual private-input native receipt was not acknowledged.'
        $Passed++
    } finally {
        # A still-live descendant remains in the outer AHK Job. Do not mistake
        # Dispose for retirement: the AHK finally must terminate the exact tree.
        $Child.Dispose()
    }
    Require ($Server.Requests.Count -ge 3) 'Native PAC server was not contacted for controlled scripts.'
} finally {
    $Server.Dispose()
}
[Console]::Out.WriteLine("[OBSERVED] native_failover=$FailoverRepresentation")
[Console]::Out.WriteLine("[OK] $Passed controlled native WinHTTP PAC fixtures and $([IntPtr]::Size * 8)-bit ABI assertions.")
