# tests/fixtures/native_http_forward_proxy.ps1
# A real forward-only authenticated HTTP proxy controls the wire protocol. The
# destination is an admitted remote HTTP endpoint, distinct from the proxy's
# ephemeral listener port. No origin connection, DNS or machine setting is used.
param(
    [Parameter(Mandatory=$true)][string]$RoutesPath,
    [Parameter(Mandatory=$true)][string]$TransportPath,
    [Parameter(Mandatory=$true)][string]$PolicyPath,
    [Parameter(Mandatory=$true)][string]$UpdaterDefaultsPath
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
. $RoutesPath
. $TransportPath
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
public sealed class ErgoptiForwardOnlyProxy : IDisposable {
    readonly TcpListener listener=new TcpListener(IPAddress.Loopback,0);
    readonly Thread worker;
    readonly object gate=new object();
    TcpClient active;
    volatile bool stopped;
    public int ForwardAllowed, ConnectRefused, Authenticated, Failures;
    public bool Joined;
    public int Port {get{return ((IPEndPoint)listener.LocalEndpoint).Port;}}
    public ErgoptiForwardOnlyProxy() {
        listener.Start();worker=new Thread(Serve);worker.IsBackground=true;worker.Start();
    }
    static string Head(Stream stream) {
        StringBuilder head=new StringBuilder();
        while(head.Length<8192) {
            int next=stream.ReadByte();if(next<0)throw new EndOfStreamException();
            head.Append((char)next);if(head.ToString().EndsWith("\r\n\r\n"))return head.ToString();
        }
        throw new InvalidDataException();
    }
    void Serve() {
        while(!stopped) {
            try {
                using(TcpClient client=listener.AcceptTcpClient()) {
                    lock(gate){active=client;}
                    client.ReceiveTimeout=2000;client.SendTimeout=2000;
                    using(NetworkStream stream=client.GetStream()) {
                        string head=Head(stream);
                        bool auth=false;
                        foreach(string line in head.Split(new string[]{"\r\n"},StringSplitOptions.None))
                            if(line.Equals("Proxy-Authorization: Basic b3duZWQ6Zml4dHVyZQ==",StringComparison.OrdinalIgnoreCase))auth=true;
                        if(auth)Interlocked.Increment(ref Authenticated);
                        bool forward=head.StartsWith("GET http://forward-fixture.invalid/v1/models HTTP/1.1\r\n",StringComparison.Ordinal);
                        bool connect=head.StartsWith("CONNECT forward-fixture.invalid:80 HTTP/1.1\r\n",StringComparison.Ordinal);
                        int status=auth&&forward?200:auth?403:407;
                        if(auth&&forward)Interlocked.Increment(ref ForwardAllowed);
                        if(connect)Interlocked.Increment(ref ConnectRefused);
                        string body=status==200?"OK":"";
                        string extra=status==407?"Proxy-Authenticate: Basic realm=\"owned\"\r\n":"";
                        byte[] response=Encoding.ASCII.GetBytes("HTTP/1.1 "+status+" Owned\r\nContent-Length: "+body.Length+"\r\n"+extra+"Connection: close\r\n\r\n"+body);
                        stream.Write(response,0,response.Length);
                    }
                    lock(gate){active=null;}
                }
            } catch(Exception) {if(!stopped)Interlocked.Increment(ref Failures);}
        }
    }
    public void Dispose() {
        stopped=true;listener.Stop();lock(gate){if(active!=null)active.Close();}
        if(!worker.Join(5000))throw new InvalidOperationException("Owned forward proxy did not join");
        Joined=true;
    }
}
'@
$Directory=Join-Path ([IO.Path]::GetTempPath()) ('ergopti-forward-proxy-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Directory -ErrorAction Stop | Out-Null
$BodyPath=Join-Path $Directory 'body.bin'
$HeaderPath=Join-Path $Directory 'headers.bin'
$Proxy=$null
$Receipt=$null
try {
    $Proxy=[ErgoptiForwardOnlyProxy]::new()
    $Destination=[Uri]'http://forward-fixture.invalid/v1/models'
    $Spec=[ErgoptiWinHttpSpec]::new()
    $Spec.Url=$Destination.AbsoluteUri;$Spec.Method='GET'
    $Spec.ProxyEndpoint='127.0.0.1:'+$Proxy.Port
    $Spec.HeaderNames=[string[]]@('Proxy-Authorization')
    $Spec.HeaderValues=[string[]]@('Basic b3duZWQ6Zml4dHVyZQ==')
    $Spec.ResponsePath=$BodyPath;$Spec.HeaderPath=$HeaderPath
    $Spec.ConnectTimeoutMs=2000;$Spec.BudgetMs=5000;$Spec.ReserveMs=500
    $Spec.MaxResponseBytes=32;$Spec.MaxHeaderBytes=2048
    $Oracle=[ErgoptiWinHttpTransport]::Execute($Spec)
    if(-not $Oracle.Completed -or -not $Oracle.Retired -or $Oracle.Status -ne 200 -or
        $Oracle.Delivered -ne 2 -or [IO.File]::ReadAllText($BodyPath) -cne 'OK' -or
        $Proxy.ForwardAllowed -ne 1 -or $Proxy.Authenticated -ne 1 -or $Proxy.ConnectRefused -ne 0) {
        throw 'The real authenticated absolute-form forward oracle was not received.'
    }
    $Override='http://owned:fixture@127.0.0.1:'+$Proxy.Port
    $Environment={param($Name) if($Name -ceq 'ERGOPTI_PROXY_OVERRIDE'){return $Override};return ''}.GetNewClosure()
    $Selection=Resolve-ErgoptiNativeNetworkRoutes -DestinationUrl $Destination.AbsoluteUri -BudgetMs 10000 `
        -ReadEnvironment $Environment -PolicyPath $PolicyPath -UpdaterDefaultsPath $UpdaterDefaultsPath
    if(-not $Selection.Ok -or $Selection.Routes.Count -ne 1 -or $Selection.Routes[0].Kind -cne 'proxy') {
        throw 'The actual remote HTTP override route was not admitted.'
    }
    $InputValue=[pscustomobject]@{
        started_tick=[ErgoptiWinHttpTransport]::CurrentTick();deadline_ms=10000;connect_timeout_ms=2000
        max_response_bytes=32;max_header_bytes=2048;response_path=$BodyPath;header_path=$HeaderPath
        revocation_best_effort=$false;headers=@();body=''
    }
    $Answer=@{child_quiesced=$true}
    $Engine=New-ErgoptiWinHttpAttemptEngine $InputValue $Answer
    $Actual=$Engine.InvokeRoute($Destination,$Selection.Routes[0],'GET',$false,$true)
    $Success=$Actual.completed -and $Actual.status -eq 200 -and $Actual.delivered -eq 2 -and
        [IO.File]::ReadAllText($BodyPath) -ceq 'OK'
    if(-not $Actual.child_quiesced -or -not $Engine.ChildQuiesced()) {throw 'The native forwarding attempt did not retire.'}
    if($Proxy.Authenticated -ne 2 -or ($Proxy.ForwardAllowed+$Proxy.ConnectRefused) -ne 2 -or $Proxy.Failures -ne 0) {
        throw 'The owned proxy did not observe exactly two authenticated protocol controls.'
    }
    $Receipt=@{schema_version=1;oracle_status=$Oracle.Status;oracle_body_exact=$true
        route_admitted=$true;target_port=$Destination.Port;settings_proxy_ephemeral=($Proxy.Port -ne $Destination.Port)
        actual_status=$Actual.status;actual_body_exact=[bool]$Success
        forwarded=$Proxy.ForwardAllowed;connect_refused=$Proxy.ConnectRefused
        authenticated=$Proxy.Authenticated;proxy_failures=$Proxy.Failures;native_retired=$true}
} finally {
    if($null -ne $Proxy){$Proxy.Dispose()}
    foreach($Path in @($BodyPath,$HeaderPath)){if([IO.File]::Exists($Path)){[IO.File]::Delete($Path)}}
    [IO.Directory]::Delete($Directory,$false)
}
if($null -eq $Receipt -or -not $Proxy.Joined){throw 'The forward proxy has no closed terminal receipt.'}
$Receipt.proxy_joined=$true
[Console]::WriteLine('HTTP_FORWARD_PROXY_RECEIPT:'+($Receipt|ConvertTo-Json -Compress))
if(-not $Receipt.actual_body_exact -or $Receipt.proxy_failures -ne 0){exit 1}
