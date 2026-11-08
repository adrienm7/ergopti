# tests/fixtures/native_ipv6_http_socks.ps1
# An admitted HTTP IPv6 destination traverses the actual owned SOCKS5h hop.
param(
    [Parameter(Mandatory=$true)][string]$RoutesPath,
    [Parameter(Mandatory=$true)][string]$TransportPath,
    [Parameter(Mandatory=$true)][string]$PolicyPath,
    [Parameter(Mandatory=$true)][string]$UpdaterDefaultsPath,
    [ValidateSet(80,18080)][int]$TargetPort=80
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
public sealed class ErgoptiIpv6SocksOracle : IDisposable {
    readonly TcpListener listener=new TcpListener(IPAddress.Loopback,0);
    readonly Thread worker;
    readonly object gate=new object();
    readonly int targetPort;
    readonly ManualResetEvent controlsDone=new ManualResetEvent(false);
    TcpClient active;volatile bool stopped;
    public int Greetings, ConnectFrames, Requests, EarlyClose, Failures;
    public bool Joined;
    public int Port {get{return ((IPEndPoint)listener.LocalEndpoint).Port;}}
    public int TargetPort {get{return targetPort;}}
    public ErgoptiIpv6SocksOracle(int targetPort){this.targetPort=targetPort;listener.Start();worker=new Thread(Serve);worker.IsBackground=true;worker.Start();}
    static byte[] Exact(Stream stream,int count) {
        byte[] data=new byte[count];int used=0;
        while(used<count){int n=stream.Read(data,used,count-used);if(n==0)throw new EndOfStreamException();used+=n;}
        return data;
    }
    static string Head(Stream stream) {
        StringBuilder head=new StringBuilder();
        while(head.Length<8192){int n=stream.ReadByte();if(n<0)throw new EndOfStreamException();head.Append((char)n);if(head.ToString().EndsWith("\r\n\r\n"))return head.ToString();}
        throw new InvalidDataException();
    }
    static void Write(Stream stream,byte[] data){stream.Write(data,0,data.Length);}
    public bool IndependentOracle() {
        using(TcpClient client=new TcpClient()) {
            client.ReceiveTimeout=3000;client.SendTimeout=3000;client.Connect(IPAddress.Loopback,Port);
            using(NetworkStream stream=client.GetStream()) {
                Write(stream,new byte[]{5,1,0});byte[] choice=Exact(stream,2);
                if(choice[0]!=5||choice[1]!=0)return false;
                byte[] request=new byte[22];request[0]=5;request[1]=1;request[3]=4;
                Buffer.BlockCopy(IPAddress.Parse("2001:db8::123").GetAddressBytes(),0,request,4,16);request[20]=(byte)(targetPort>>8);request[21]=(byte)(targetPort&255);
                Write(stream,request);byte[] reply=Exact(stream,10);
                if(reply[0]!=5||reply[1]!=0||reply[3]!=1)return false;
                Write(stream,Encoding.ASCII.GetBytes("GET /v1/models HTTP/1.1\r\nHost: [2001:db8::123]"+(targetPort==80?"":":"+targetPort)+"\r\nConnection: close\r\n\r\n"));
                string head=Head(stream);
                return head.StartsWith("HTTP/1.1 200 ",StringComparison.Ordinal)&&head.Contains("Content-Length: 2\r\n")&&Encoding.ASCII.GetString(Exact(stream,2))=="OK";
            }
        }
    }
    void Serve() {
        int completed=0;
        while(!stopped) {
            try {
                using(TcpClient client=listener.AcceptTcpClient()) {
                    lock(gate){active=client;}
                    client.ReceiveTimeout=3000;client.SendTimeout=3000;
                    using(NetworkStream stream=client.GetStream()) {
                        byte[] hello=Exact(stream,2);if(hello[0]!=5||hello[1]<1||hello[1]>16)throw new InvalidDataException();
                        byte[] methods=Exact(stream,hello[1]);if(Array.IndexOf(methods,(byte)0)<0)throw new InvalidDataException();
                        Interlocked.Increment(ref Greetings);Write(stream,new byte[]{5,0});
                        byte[] frame;
                        try{frame=Exact(stream,4);}catch(EndOfStreamException){Interlocked.Increment(ref EarlyClose);continue;}
                        if(frame[0]!=5||frame[1]!=1||frame[2]!=0||frame[3]!=4)throw new InvalidDataException();
                        byte[] authority=Exact(stream,18),expected=IPAddress.Parse("2001:db8::123").GetAddressBytes();
                        for(int i=0;i<16;i++)if(authority[i]!=expected[i])throw new InvalidDataException();
                        if(authority[16]!=(byte)(targetPort>>8)||authority[17]!=(byte)(targetPort&255))throw new InvalidDataException();
                        Interlocked.Increment(ref ConnectFrames);Write(stream,new byte[]{5,0,0,1,127,0,0,1,0,0});
                        if(!Head(stream).StartsWith("GET /v1/models HTTP/1.1\r\n",StringComparison.Ordinal))throw new InvalidDataException();
                        Interlocked.Increment(ref Requests);
                        Write(stream,Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK"));
                    }
                }
            }catch(Exception){if(!stopped)Interlocked.Increment(ref Failures);}
            finally{lock(gate){active=null;}if(Interlocked.Increment(ref completed)>=2)controlsDone.Set();}
        }
    }
    public bool WaitControls(){return controlsDone.WaitOne(3000);}
    public void Dispose(){stopped=true;listener.Stop();lock(gate){if(active!=null)active.Close();}if(!worker.Join(5000))throw new InvalidOperationException("Owned SOCKS receiver did not join");Joined=true;controlsDone.Dispose();}
}
'@
# Only closed transport fields and counters from this static fixture are public.
# Headers, endpoints, payloads and exception messages never enter this projection.
function Write-Ipv6SocksDiagnostic($Phase,$Peer,$Metrics,$ActualRetired,$EngineRetired,$ControlsDone,$FailureReceipt) {
    $Diagnostic=[ordered]@{schema_version=1;phase=$Phase;actual_child_quiesced=$ActualRetired
        engine_child_quiesced=$EngineRetired;controls_done_observed=$ControlsDone;failure_receipt=$FailureReceipt}
    if($null -ne $Metrics) {
        $Diagnostic.actual_completed=[bool]$Metrics.completed
        $Diagnostic.actual_status=[int]$Metrics.status
        $Diagnostic.actual_delivered=[int64]$Metrics.delivered
        $Diagnostic.native_failure=[string]$Metrics.failure
        $Diagnostic.native_stage=[string]$Metrics.stage
        $Diagnostic.native_error=[int]$Metrics.native_error
        $Diagnostic.native_diagnostic=[string]$Metrics.diagnostic
        $Diagnostic.proxy_used=[bool]$Metrics.proxy_used
        $Diagnostic.proxy_answered=[bool]$Metrics.proxy_answered
    }
    if($null -ne $Peer) {
        $Diagnostic.target_port=$Peer.TargetPort;$Diagnostic.greetings=$Peer.Greetings;$Diagnostic.connect_frames=$Peer.ConnectFrames
        $Diagnostic.requests=$Peer.Requests;$Diagnostic.early_close=$Peer.EarlyClose
        $Diagnostic.proxy_failures=$Peer.Failures;$Diagnostic.proxy_joined=$Peer.Joined
    }
    [Console]::WriteLine('IPV6_HTTP_SOCKS_DIAGNOSTIC:'+($Diagnostic|ConvertTo-Json -Compress -Depth 4))
}
$Directory=Join-Path ([IO.Path]::GetTempPath()) ('ergopti-ipv6-socks-'+[Guid]::NewGuid().ToString('N'))
$DirectoryCreated=$false
$BodyPath=Join-Path $Directory 'body.bin';$HeaderPath=Join-Path $Directory 'headers.bin'
$Proxy=$null;$Receipt=$null;$Actual=$null
$ActualRetired=$null;$EngineRetired=$null;$ControlsDone=$null;$FailureReceipt=@{}
try {
    New-Item -ItemType Directory -Path $Directory -ErrorAction Stop | Out-Null
    $DirectoryCreated=$true
    $Proxy=[ErgoptiIpv6SocksOracle]::new($TargetPort)
    if(-not $Proxy.IndependentOracle()){throw 'The independent IPv6 SOCKS CONNECT and HTTP response did not qualify.'}
    $PortSuffix=if($TargetPort -eq 80){''}else{':'+$TargetPort}
    $Destination=[Uri]('http://[2001:db8::123]'+$PortSuffix+'/v1/models')
    $Override='socks5h://127.0.0.1:'+$Proxy.Port
    $Environment={param($Name) if($Name -ceq 'ERGOPTI_PROXY_OVERRIDE'){return $Override};return ''}.GetNewClosure()
    $Selection=Resolve-ErgoptiNativeNetworkRoutes -DestinationUrl $Destination.AbsoluteUri -BudgetMs 10000 `
        -ReadEnvironment $Environment -PolicyPath $PolicyPath -UpdaterDefaultsPath $UpdaterDefaultsPath
    if(-not $Selection.Ok -or $Selection.Routes.Count -ne 1 -or $Selection.Routes[0].Kind -cne 'proxy'){throw 'The admitted IPv6 HTTP destination did not reach its real SOCKS override.'}
    $InputValue=[pscustomobject]@{started_tick=[ErgoptiWinHttpTransport]::CurrentTick();deadline_ms=10000;connect_timeout_ms=2000
        max_response_bytes=32;max_header_bytes=2048;response_path=$BodyPath;header_path=$HeaderPath
        revocation_best_effort=$false;headers=@();body=''}
    $Answer=@{child_quiesced=$true};$Engine=New-ErgoptiWinHttpAttemptEngine $InputValue $Answer
    $Actual=$Engine.InvokeRoute($Destination,$Selection.Routes[0],'GET',$false,$true)
    # Observe each boundary even when another boundary failed: short-circuiting
    # these calls would hide whether the actual request reached the SOCKS peer.
    $ActualRetired=[bool]$Actual.child_quiesced
    $EngineRetired=[bool]$Engine.ChildQuiesced()
    $ControlsDone=[bool]$Proxy.WaitControls()
    if(-not $Actual.completed -or $Actual.proxy_answered){$FailureReceipt=$Engine.GetFailureReceipt($Actual,$Destination)}
    Write-Ipv6SocksDiagnostic 'before_assert' $Proxy $Actual $ActualRetired $EngineRetired $ControlsDone $FailureReceipt
    if(-not $ActualRetired -or -not $EngineRetired -or -not $ControlsDone){throw 'Native attempt or exact SOCKS protocol controls did not retire.'}
    if($Proxy.Greetings -ne 2 -or $Proxy.Failures -ne 0){throw 'Both private SOCKS controls did not qualify.'}
    $Success=$Actual.completed -and $Actual.status -eq 200 -and $Actual.delivered -eq 2 -and [IO.File]::ReadAllText($BodyPath) -ceq 'OK'
    $Receipt=@{schema_version=1;oracle_status=200;oracle_body_exact=$true;route_admitted=$true
        target_port=$Destination.Port;actual_status=$Actual.status;actual_body_exact=[bool]$Success
        greetings=$Proxy.Greetings;connect_frames=$Proxy.ConnectFrames;requests=$Proxy.Requests
        early_close=$Proxy.EarlyClose;proxy_failures=$Proxy.Failures;native_retired=$true}
} finally {
    Write-Ipv6SocksDiagnostic 'before_dispose' $Proxy $Actual $ActualRetired $EngineRetired $ControlsDone $FailureReceipt
    if($null -ne $Proxy){
        $Proxy.Dispose()
        Write-Ipv6SocksDiagnostic 'after_join' $Proxy $Actual $ActualRetired $EngineRetired $ControlsDone $FailureReceipt
    }
    if($DirectoryCreated) {
        foreach($Path in @($BodyPath,$HeaderPath)){if([IO.File]::Exists($Path)){[IO.File]::Delete($Path)}}
        [IO.Directory]::Delete($Directory,$false)
    }
}
if($null -eq $Receipt -or -not $Proxy.Joined){throw 'The IPv6 SOCKS probe has no closed terminal receipt.'}
$Receipt.proxy_joined=$true
[Console]::WriteLine('IPV6_HTTP_SOCKS_RECEIPT:'+($Receipt|ConvertTo-Json -Compress))
if(-not $Receipt.actual_body_exact){exit 1}
