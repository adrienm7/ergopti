# Scratch-only production routing-helper acceptance: full-URL native PAC and WinHTTP ABI.
# Configuration/environment readers are the only injection boundaries.
param([Parameter(Mandatory=$true)][string]$RoutesPath,
      [Parameter(Mandatory=$true)][string]$PolicyPath,
      [Parameter(Mandatory=$true)][string]$UpdaterDefaultsPath)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$Server=$null
$AuthenticationServer=$null
$SlowServer=$null
$Failed=$false
$ManagedRoutesDiagnosticStage='load_routes'
$ManagedRoutesDiagnosticVector=0
$ManagedRoutesDiagnosticNativeObserved=$false
$ManagedRoutesDiagnosticNativeErrno=0
$ManagedRoutesDiagnosticStatus='unknown'
$ManagedRoutesDiagnosticResultShape='unknown'
$ManagedRoutesDiagnosticOk='unknown'
$ManagedRoutesDiagnosticRouteCount=-1
$ManagedRoutesDiagnosticLimits='unknown'
$ManagedRoutesDiagnosticSingleSource='unknown'
$ManagedRoutesDiagnosticSingleKind='unknown'
$ManagedRoutesDiagnosticAttempted=$false
# Optional fixed observations only; never read exception messages or input metadata.
function Set-ManagedRoutesDiagnosticResult {
    param($Result)
    $script:ManagedRoutesDiagnosticNativeObserved=$false
    $script:ManagedRoutesDiagnosticNativeErrno=0
    $script:ManagedRoutesDiagnosticStatus='unknown'
    $script:ManagedRoutesDiagnosticResultShape='unknown'
    $script:ManagedRoutesDiagnosticOk='unknown'
    $script:ManagedRoutesDiagnosticRouteCount=-1
    $script:ManagedRoutesDiagnosticLimits='unknown'
    $script:ManagedRoutesDiagnosticSingleSource='unknown'
    $script:ManagedRoutesDiagnosticSingleKind='unknown'
    try {
        # Closed scalars from the already-returned result; no route metadata.
        if($null -eq $Result){$script:ManagedRoutesDiagnosticResultShape='null';return}
        if($Result -is [array]){$script:ManagedRoutesDiagnosticResultShape='array';return}
        if($Result -isnot [hashtable]){$script:ManagedRoutesDiagnosticResultShape='other';return}
        $script:ManagedRoutesDiagnosticResultShape='hashtable'
        if($Result['Ok'] -is [bool]) {
            $script:ManagedRoutesDiagnosticOk=$(if($Result['Ok']){'true'}else{'false'})
        }
        if($Result['Routes'] -is [array] -and $Result['Routes'].Count -le 4096) {
            $script:ManagedRoutesDiagnosticRouteCount=$Result['Routes'].Count
        }
        if($Result['Routes'] -is [array] -and $Result['Routes'].Count -eq 1 -and
            $Result['Routes'][0] -is [hashtable]) {
            $Route=$Result['Routes'][0]
            if($Route['Source'] -is [string] -and $Route['Source'] -cin @(
                'loopback','environment','environment_bypass','system_direct','system_bypass',
                'system_config_absent_direct','system_config_absent_bypass','system_proxy',
                'system_config_absent_proxy','wpad_absent_direct','wpad_absent_bypass','wpad_absent_proxy',
                'native_proxy','native_direct','native_bypass')) {
                $script:ManagedRoutesDiagnosticSingleSource=$Route['Source']
            }
            if($Route['Kind'] -is [string] -and $Route['Kind'] -cin @('direct','proxy')) {
                $script:ManagedRoutesDiagnosticSingleKind=$Route['Kind']
            }
        }
        if(($Result['MaxRoutes'] -is [int] -or $Result['MaxRoutes'] -is [long]) -and
            ($Result['MaxRedirects'] -is [int] -or $Result['MaxRedirects'] -is [long])) {
            $script:ManagedRoutesDiagnosticLimits=$(if($Result['MaxRoutes'] -eq 128 -and
                $Result['MaxRedirects'] -eq 50){'match'}else{'mismatch'})
        }
        if($Result.Receipt -isnot [hashtable]){return}
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
        [Console]::Error.WriteLine(('ROUTE_DIAG stage={0} vector={1} native_observed={2} native_errno={3} status={4} result_shape={5} ok={6} route_count={7} limits={8} single_source={9} single_kind={10}' -f
            $script:ManagedRoutesDiagnosticStage,$script:ManagedRoutesDiagnosticVector,
            [int]$script:ManagedRoutesDiagnosticNativeObserved,$script:ManagedRoutesDiagnosticNativeErrno,
            $script:ManagedRoutesDiagnosticStatus,$script:ManagedRoutesDiagnosticResultShape,
            $script:ManagedRoutesDiagnosticOk,$script:ManagedRoutesDiagnosticRouteCount,$script:ManagedRoutesDiagnosticLimits,
            $script:ManagedRoutesDiagnosticSingleSource,$script:ManagedRoutesDiagnosticSingleKind))
    } catch { }
}
try {
    . $RoutesPath
    $ManagedRoutesDiagnosticStage='abi_sizes'
    # Select exactly Marshal.SizeOf(Type), avoiding RuntimeType generic binding.
    $SizeOfType=[Runtime.InteropServices.Marshal].GetMethod('SizeOf',[type[]]@([type]))
    if($null -eq $SizeOfType){throw 'Native ABI mismatch.'}
    $ExpectedSizes=@(
        @{Type=[type][ErgoptiNativeProxyEx+NativeResult];Size=$(if([IntPtr]::Size -eq 8){16}else{8})},
        @{Type=[type][ErgoptiNativeProxyEx+NativeEntry];Size=$(if([IntPtr]::Size -eq 8){32}else{20})},
        @{Type=[type][ErgoptiNativeProxyEx+AsyncResult];Size=$(if([IntPtr]::Size -eq 8){16}else{8})},
        @{Type=[type][ErgoptiWindowsProxyConfig+NativeConfig];Size=$(if([IntPtr]::Size -eq 8){32}else{16})})
    foreach($Expected in $ExpectedSizes) {
        if($SizeOfType.Invoke($null,[object[]]@($Expected.Type)) -ne $Expected.Size){throw 'Native ABI mismatch.'}
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
    private readonly bool drip;
    public readonly int Port;
    public int Requests;
    public int Errors;
    public int Revision;
    public ErgoptiOrderedPacServer() : this(false) { }
    public ErgoptiOrderedPacServer(bool drip)
    {
        this.drip=drip;
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
                    bool shape=header.ToString().StartsWith("GET /shape.pac HTTP/1.");
                    if(!shape && !header.ToString().StartsWith("GET /order.pac HTTP/1."))throw new InvalidDataException();
                    Interlocked.Increment(ref Requests);
                    string first=Revision==0 ? "first.invalid:38101; PROXY second.invalid:38102" : "second.invalid:38102; PROXY first.invalid:38101";
                    string pac="function FindProxyForURL(url,host){"+
                        // Native WinHTTP strips the HTTPS path. That evaluation must not
                        // gate a valid full-URL script whose stripped branch deliberately fails.
                        "if(url=='https://ordered-fixture.invalid:8443/' || url=='https://ordered-fixture.invalid:8443') throw new Error('owned origin-only refusal');"+
                        "if(url=='https://ordered-fixture.invalid:8443/first?marker=private') "+
                        "return 'PROXY "+first+"; DIRECT';"+
                        "if(url=='http://ordered-fixture.invalid:8080/direct-middle') "+
                        "return 'PROXY first.invalid:38101; DIRECT; PROXY second.invalid:38102';"+
                        "if(url=='https://ordered-fixture.invalid/unsupported') return 'SOCKS unsupported.invalid:38103; DIRECT';"+
                        "return 'DIRECT';}";
                    if(shape) pac="function FindProxyForURL(url,host){"+
                        "if(url=='https://ordered-fixture.invalid:8443/first?marker=private') return 'PROXY full.invalid:38104';"+
                        "if(url=='https://ordered-fixture.invalid:8443/first') return 'PROXY path.invalid:38105';"+
                        "if(url=='https://ordered-fixture.invalid:8443/' || url=='https://ordered-fixture.invalid:8443') return 'PROXY origin.invalid:38106';"+
                        "if(url=='http://ordered-fixture.invalid:8443/first?marker=private') return 'PROXY scheme.invalid:38107';"+
                        "return 'PROXY other.invalid:38108';}";
                    byte[] body=Encoding.ASCII.GetBytes(pac);
                    byte[] response=Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nConnection: close\r\nCache-Control: no-store\r\nContent-Type: application/x-ns-proxy-autoconfig\r\nContent-Length: "+body.Length+"\r\n\r\n");
                    stream.Write(response,0,response.Length);
                    if(drip) {
                        // Every native read makes progress before its per-read timeout,
                        // but this body deliberately exceeds the original total lookup budget.
                        for(int index=0;index<body.Length&&!stopped;index++) {
                            stream.Write(body,index,1);stream.Flush();Thread.Sleep(150);
                        }
                    } else {stream.Write(body,0,body.Length);stream.Flush();}
                }
            } catch(SocketException) { if(!stopped&&!drip)Interlocked.Increment(ref Errors); }
            catch(IOException) { if(!stopped&&!drip)Interlocked.Increment(ref Errors); }
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
    $ManagedRoutesDiagnosticStage='slow_lookup'
    $SlowServer=[ErgoptiOrderedPacServer]::new($true)
    $SlowPac='http://127.0.0.1:'+$SlowServer.Port+'/order.pac'
    $SlowReader={param($MaxBytes) @{Ok=$true;Absent=$false;AutoDetect=$false;PacUrl=$SlowPac;Proxy='';Bypass='';NativeError=0;FailureOrigin=''}}.GetNewClosure()
    $SlowClock=[Diagnostics.Stopwatch]::StartNew()
    $SlowAnswer=Resolve-ErgoptiNativeNetworkRoutes -DestinationUrl $Vectors[0].Url -BudgetMs 3000 `
        -ReadConfig $SlowReader -ReadEnvironment $EmptyEnvironment -PolicyPath $PolicyPath -UpdaterDefaultsPath $UpdaterDefaultsPath
    $SlowClock.Stop()
    Set-ManagedRoutesDiagnosticResult $SlowAnswer
    $ManagedRoutesDiagnosticStage='slow_receipt'
    if($SlowAnswer.Ok -or $SlowAnswer.Routes.Count -ne 0 -or $SlowAnswer.CleanupDebt -or
        $SlowClock.ElapsedMilliseconds -gt 3000 -or $SlowServer.Requests -ne 1) {
        throw 'Progressing PAC body escaped its original lookup deadline or owner retirement.'
    }
    $ManagedRoutesDiagnosticStage='slow_owner'
    $SlowServer.Dispose()
    if($SlowServer.Errors -ne 0){throw 'Owned slow PAC receiving service failed.'}
    $SlowServer=$null
    $AfterSlow=Resolve-ErgoptiNativeNetworkRoutes -DestinationUrl $Vectors[0].Url @Common
    if(-not $AfterSlow.Ok -or $AfterSlow.Routes.Count -ne 3 -or
        $AfterSlow.Routes[0].Endpoint -cne 'http://second.invalid:38102/') {
        throw 'A retired PAC deadline owner contaminated the next actual native request.'
    }
    # Actual settings discovery is independently observed without mutating it;
    # an unavailable native reader is a failed qualification, not a synthetic pass.
    $ManagedRoutesDiagnosticStage='pac_auth_lookup'
    . (Join-Path $PSScriptRoot 'pac_ntlm_origin.ps1')
    $AuthenticationServer=[ErgoptiPacNtlmOrigin]::new()
    $AuthenticatedPac='http://127.0.0.1:'+$AuthenticationServer.Port+'/authenticated.pac'
    $AuthenticationReader={param($MaxBytes) @{Ok=$true;Absent=$false;AutoDetect=$false;PacUrl=$AuthenticatedPac;Proxy='';Bypass='';NativeError=0;FailureOrigin=''}}.GetNewClosure()
    $Authenticated=Resolve-ErgoptiNativeNetworkRoutes -DestinationUrl 'https://pac-auth-fixture.invalid:8443/authenticated?marker=private' `
        -BudgetMs 9000 -ReadConfig $AuthenticationReader -ReadEnvironment $EmptyEnvironment -PolicyPath $PolicyPath -UpdaterDefaultsPath $UpdaterDefaultsPath
    Set-ManagedRoutesDiagnosticResult $Authenticated
    $ManagedRoutesDiagnosticStage='pac_auth_receipt'
    if(-not $Authenticated.Ok -or $Authenticated.Routes.Count -ne 2 -or
        $Authenticated.Routes[0].Kind -cne 'proxy' -or $Authenticated.Routes[0].Endpoint -cne 'http://auth-fixture.invalid:38109/' -or
        $Authenticated.Routes[1].Kind -cne 'direct' -or $Authenticated.Routes[1].Endpoint -cne '') {
        throw 'Native current-user PAC authentication/full-URL order was refused.'
    }
    $ManagedRoutesDiagnosticStage='pac_auth_owner'
    $AuthenticationServer.Dispose()
    if(-not $AuthenticationServer.IdentityMatched -or $AuthenticationServer.Bare -lt 1 -or
        $AuthenticationServer.TypeOne -ne 1 -or $AuthenticationServer.TypeThree -ne 1 -or
        $AuthenticationServer.Authenticated -ne 1 -or $AuthenticationServer.Responses -ne 1 -or
        $AuthenticationServer.Active -ne 0 -or $AuthenticationServer.Failures -ne 0 -or
        $AuthenticationServer.OwnedCredentials -ne 0 -or $AuthenticationServer.OwnedContexts -ne 0 -or
        $AuthenticationServer.OwnedTokens -ne 0 -or $AuthenticationServer.OwnedBuffers -ne 0) {
        throw 'Native PAC SSPI identity or physical owner retirement was refused.'
    }
    $AuthenticationServer=$null
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
    if($ManagedRoutesDiagnosticVector -eq 1 -and $ManagedRoutesDiagnosticStage -eq 'vector_receipt' -and $null -ne $Server) {
        # A second genuine native lookup identifies only fixed URL-shape branches.
        # It cannot replace or rescue any of the original full-URL assertions.
        $Shape='unavailable'
        try {
            $Probe=[ErgoptiNativeProxyEx]::Resolve($Vectors[0].Url,
                ('http://127.0.0.1:'+$Server.Port+'/shape.pac'),$false,9000,128,65536)
            if($Probe.Ok -and $Probe.CallbacksRetired -and $Probe.Entries.Count -eq 1 -and $Probe.Entries[0].IsProxy) {
                switch -CaseSensitive ($Probe.Entries[0].ProxyHost) {
                    'full.invalid' {$Shape='full'}
                    'path.invalid' {$Shape='path'}
                    'origin.invalid' {$Shape='origin'}
                    'scheme.invalid' {$Shape='scheme'}
                    'other.invalid' {$Shape='other'}
                }
            }
        } catch { }
        try { [Console]::Error.WriteLine('ROUTE_URL_DIAG shape='+$Shape) } catch { }
    }
    [Console]::Error.WriteLine('Native complete routing acceptance failed.')
} finally {
    if($null -ne $SlowServer){try{$SlowServer.Dispose()}catch{$Failed=$true;[Console]::Error.WriteLine('Owned slow PAC cleanup refused.')}}
    if($null -ne $AuthenticationServer){try{$AuthenticationServer.Dispose()}catch{$Failed=$true;[Console]::Error.WriteLine('Owned native PAC authentication cleanup refused.')}}
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
