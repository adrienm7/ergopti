# Scratch-only production routing-helper acceptance: actual WinHTTP Ex/PAC.
# Configuration/environment readers are the only injection boundaries.
param([Parameter(Mandatory=$true)][string]$RoutesPath,
      [Parameter(Mandatory=$true)][string]$PolicyPath,
      [Parameter(Mandatory=$true)][string]$UpdaterDefaultsPath)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$Server=$null
$Failed=$false
$ManagedRoutesDiagnosticStage='load_routes'
$ManagedRoutesDiagnosticVector=0
$ManagedRoutesDiagnosticNativeObserved=$false
$ManagedRoutesDiagnosticNativeErrno=0
$ManagedRoutesDiagnosticStatus='unknown'
$ManagedRoutesDiagnosticAttempted=$false
# Optional fixed observations only; never read exception messages or input metadata.
function Set-ManagedRoutesDiagnosticResult {
    param($Result)
    $script:ManagedRoutesDiagnosticNativeObserved=$false
    $script:ManagedRoutesDiagnosticNativeErrno=0
    $script:ManagedRoutesDiagnosticStatus='unknown'
    try {
        if($Result -isnot [hashtable] -or $Result.Receipt -isnot [hashtable]){return}
        $Receipt=$Result.Receipt
        if($Receipt.proxy_resolution_status -is [string] -and
            $Receipt.proxy_resolution_status -cin @('unavailable','invalid_configuration','pac_failed','wpad_failed')) {
            $script:ManagedRoutesDiagnosticStatus=$Receipt.proxy_resolution_status
        }
        if($Receipt.failure_provenance -cne 'verified' -or $Receipt.native_errno_domain -cne 'win32' -or
            $Receipt.native_errno -isnot [string] -or $Receipt.native_errno -notmatch '^-?(?:0|[1-9][0-9]{0,9})$'){return}
        [int]$Code=0
        if([int]::TryParse($Receipt.native_errno,[ref]$Code)) {
            $script:ManagedRoutesDiagnosticNativeObserved=$true
            $script:ManagedRoutesDiagnosticNativeErrno=$Code
        }
    } catch { }
}
function Write-ManagedRoutesDiagnostic {
    if($script:ManagedRoutesDiagnosticAttempted){return}
    $script:ManagedRoutesDiagnosticAttempted=$true
    try {
        [Console]::Error.WriteLine(('ROUTE_DIAG stage={0} vector={1} native_observed={2} native_errno={3} status={4}' -f
            $script:ManagedRoutesDiagnosticStage,$script:ManagedRoutesDiagnosticVector,
            [int]$script:ManagedRoutesDiagnosticNativeObserved,$script:ManagedRoutesDiagnosticNativeErrno,
            $script:ManagedRoutesDiagnosticStatus))
    } catch { }
}
try {
    . $RoutesPath
    $ManagedRoutesDiagnosticStage='abi_sizes'
    $ExpectedSizes=@(
        @{Type=[type][ErgoptiNativeProxyEx+NativeResult];Size=$(if([IntPtr]::Size -eq 8){16}else{8})},
        @{Type=[type][ErgoptiNativeProxyEx+NativeEntry];Size=$(if([IntPtr]::Size -eq 8){32}else{20})},
        @{Type=[type][ErgoptiNativeProxyEx+AsyncResult];Size=$(if([IntPtr]::Size -eq 8){16}else{8})},
        @{Type=[type][ErgoptiWindowsProxyConfig+NativeConfig];Size=$(if([IntPtr]::Size -eq 8){32}else{16})})
    foreach($Expected in $ExpectedSizes) {
        if([Runtime.InteropServices.Marshal]::SizeOf($Expected.Type) -ne $Expected.Size){throw 'Native ABI mismatch.'}
    }
    $ManagedRoutesDiagnosticStage='compile_server'
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
public sealed class ErgoptiOrderedPacServer : IDisposable
{
    private readonly TcpListener listener;
    private readonly Thread thread;
    private volatile bool stopped;
    public readonly int Port;
    public int Requests;
    public int Errors;
    public int Revision;
    public ErgoptiOrderedPacServer()
    {
        listener=new TcpListener(IPAddress.Loopback,0); listener.Start();
        Port=((IPEndPoint)listener.LocalEndpoint).Port;
        thread=new Thread(Serve); thread.IsBackground=true; thread.Start();
    }
    private void Serve()
    {
        while(!stopped) {
            try {
                using(TcpClient client=listener.AcceptTcpClient()) {
                    client.ReceiveTimeout=3000; client.SendTimeout=3000;
                    Stream stream=client.GetStream(); StringBuilder header=new StringBuilder();
                    while(header.Length<16384) {
                        int one=stream.ReadByte(); if(one<0)throw new EndOfStreamException();
                        header.Append((char)one); if(header.ToString().EndsWith("\r\n\r\n"))break;
                    }
                    if(!header.ToString().StartsWith("GET /order.pac HTTP/1."))throw new InvalidDataException();
                    Interlocked.Increment(ref Requests);
                    string first=Revision==0 ? "first.invalid:38101; PROXY second.invalid:38102" : "second.invalid:38102; PROXY first.invalid:38101";
                    string pac="function FindProxyForURL(url,host){"+
                        "if(url=='https://ordered-fixture.invalid:8443/first?marker=private') "+
                        "return 'PROXY "+first+"; DIRECT';"+
                        "if(url=='http://ordered-fixture.invalid:8080/direct-middle') "+
                        "return 'PROXY first.invalid:38101; DIRECT; PROXY second.invalid:38102';"+
                        "if(url=='https://ordered-fixture.invalid/unsupported') return 'SOCKS unsupported.invalid:38103; DIRECT';"+
                        "return 'DIRECT';}";
                    byte[] body=Encoding.ASCII.GetBytes(pac);
                    byte[] response=Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nConnection: close\r\nCache-Control: no-store\r\nContent-Type: application/x-ns-proxy-autoconfig\r\nContent-Length: "+body.Length+"\r\n\r\n");
                    stream.Write(response,0,response.Length);stream.Write(body,0,body.Length);stream.Flush();
                }
            } catch(SocketException) { if(!stopped)Interlocked.Increment(ref Errors); }
            catch(ObjectDisposedException) { if(!stopped)Interlocked.Increment(ref Errors); }
            catch(Exception) { Interlocked.Increment(ref Errors); }
        }
    }
    public void Dispose()
    {
        stopped=true;listener.Stop();
        if(!thread.Join(3500))throw new InvalidOperationException("Owned PAC fixture thread did not settle.");
    }
}
'@

    $ManagedRoutesDiagnosticStage='start_server'
    $Server=[ErgoptiOrderedPacServer]::new()
    $Pac='http://127.0.0.1:'+$Server.Port+'/order.pac'
    $Reader={param($MaxBytes) @{Ok=$true;Absent=$false;AutoDetect=$false;PacUrl=$Pac;Proxy='';Bypass='';NativeError=0;FailureOrigin=''}}.GetNewClosure()
    $EmptyEnvironment={param($Name) ''}
    $Common=@{BudgetMs=9000;ReadConfig=$Reader;ReadEnvironment=$EmptyEnvironment;PolicyPath=$PolicyPath;UpdaterDefaultsPath=$UpdaterDefaultsPath}
    $Vectors=@(
        @{Url='https://ordered-fixture.invalid:8443/first?marker=private';Endpoints=@('http://first.invalid:38101/','http://second.invalid:38102/','')},
        @{Url='http://ordered-fixture.invalid:8080/direct-middle';Endpoints=@('http://first.invalid:38101/','','http://second.invalid:38102/')},
        @{Url='https://ordered-fixture.invalid/direct-only';Endpoints=@('')})
    foreach($Vector in $Vectors) {
        $ManagedRoutesDiagnosticVector++
        $ManagedRoutesDiagnosticStage='vector_lookup'
        Set-ManagedRoutesDiagnosticResult $null
        $Result=Resolve-ErgoptiNativeNetworkRoutes -DestinationUrl $Vector.Url @Common
        Set-ManagedRoutesDiagnosticResult $Result
        $ManagedRoutesDiagnosticStage='vector_receipt'
        if($Result.Ok -isnot [bool] -or -not $Result.Ok -or $Result.Routes.Count -ne $Vector.Endpoints.Count -or
            $Result.MaxRoutes -ne 128 -or $Result.MaxRedirects -ne 50){throw 'Complete routing receipt was refused.'}
        $ManagedRoutesDiagnosticStage='vector_order'
        for($Index=0;$Index -lt $Vector.Endpoints.Count;$Index++) {
            $Route=$Result.Routes[$Index]
            $Endpoint=$Vector.Endpoints[$Index]
            if($Route.Endpoint -cne $Endpoint -or $Route.Kind -cne $(if($Endpoint -eq ''){'direct'}else{'proxy'}) -or
                $Route.Authentication -cne $(if($Endpoint -eq ''){'none'}else{'current_user_proxy_only'})){throw 'Ordered route/authentication identity mismatch.'}
        }
    }
    # The identical config URL now serves different PAC bytes. Strict lookup has
    # no application or WinHTTP PAC cache; all native routes must be refreshed.
    $Server.Revision=1
    $ManagedRoutesDiagnosticVector=0
    $ManagedRoutesDiagnosticStage='fresh_lookup'
    Set-ManagedRoutesDiagnosticResult $null
    $Changed=Resolve-ErgoptiNativeNetworkRoutes -DestinationUrl $Vectors[0].Url @Common
    Set-ManagedRoutesDiagnosticResult $Changed
    $ManagedRoutesDiagnosticStage='fresh_order'
    if(-not $Changed.Ok -or $Changed.Routes[0].Endpoint -cne 'http://second.invalid:38102/' -or
        $Changed.Routes[1].Endpoint -cne 'http://first.invalid:38101/'){throw 'Dynamic PAC bytes were lifetime-cached.'}
    $ManagedRoutesDiagnosticStage='unsupported_lookup'
    Set-ManagedRoutesDiagnosticResult $null
    $Refused=Resolve-ErgoptiNativeNetworkRoutes -DestinationUrl 'https://ordered-fixture.invalid/unsupported' @Common
    Set-ManagedRoutesDiagnosticResult $Refused
    $ManagedRoutesDiagnosticStage='unsupported_receipt'
    if($Refused.Ok -or $Refused.Routes.Count -ne 0 -or $Refused.Receipt.stage -cne 'proxy_resolve'){throw 'Unsupported full-list entry silently fell back to DIRECT.'}
    # Actual settings discovery is independently observed without mutating it;
    # an unavailable native reader is a failed qualification, not a synthetic pass.
    $ManagedRoutesDiagnosticStage='settings_read'
    Set-ManagedRoutesDiagnosticResult $null
    $Actual=[ErgoptiWindowsProxyConfig]::Read(65536)
    $ManagedRoutesDiagnosticStage='settings_receipt'
    if(-not $Actual.Ok -or $Actual.AutoDetect -isnot [bool] -or $Actual.PacUrl -isnot [string]){throw 'Actual current-user settings could not be observed.'}
    $ManagedRoutesDiagnosticStage='server_receipt'
    if($Server.Requests -lt 5 -or $Server.Errors -ne 0){throw 'Owned native PAC service did not qualify.'}
    [Console]::Out.WriteLine('[OK] production routing helper: complete PAC order, DIRECT, dynamic freshness, unsupported-list refusal, real settings read')
} catch {
    $Failed=$true
    Write-ManagedRoutesDiagnostic
    [Console]::Error.WriteLine('Native complete routing acceptance failed.')
} finally {
    if($null -ne $Server) {
        try{$Server.Dispose()}catch{
            if(-not $Failed){
                $ManagedRoutesDiagnosticStage='cleanup'
                Set-ManagedRoutesDiagnosticResult $null
                Write-ManagedRoutesDiagnostic
            }
            $Failed=$true;[Console]::Error.WriteLine('Owned PAC service did not retire.')
        }
    }
}
if($Failed){exit 1}
