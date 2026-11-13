# tests/fixtures/core/native_relay_hop_branches.ps1
# Independent owned protocol peers qualify real RelayHop CONNECT and SOCKS paths.
param(
    [Parameter(Mandatory=$true)][string]$RoutesPath,
    [Parameter(Mandatory=$true)][string]$PolicyPath,
    [switch]$Ipv6Upstream,
    [string]$TransportPath='',
    [string]$UpdaterDefaultsPath=''
)
$ErrorActionPreference='Stop'
. $RoutesPath
$Policy=Get-ErgoptiNetworkPolicy $PolicyPath
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
public sealed class RelayDefaultClientObservation {
 public string FamilyBefore="", FamilyAfter="", Stage="construct", FailureType="";
 public int NativeError;
 public bool Connected, BodyExact, Closed, DualMode;
}
public sealed class RelayBranchPeer : IDisposable {
 const string Host="hop-component.invalid";
 const string Ipv4Authority="192.0.2.123:18080";
 const string Auth="Proxy-Authorization: Basic b3duZWQ6Zml4dHVyZQ==";
 readonly TcpListener listener;
 readonly Thread worker;
 readonly object gate=new object();
 readonly bool socks;
 volatile bool stopped;
 TcpClient active;
 public int Connections, Authenticated, Requests, Failures, DomainFrames, Ipv4Frames;
 public bool Joined;
 public int Port {get{return ((IPEndPoint)listener.LocalEndpoint).Port;}}
 public bool StrictIpv6 {get{return listener.Server.AddressFamily==AddressFamily.InterNetworkV6&&!listener.Server.DualMode&&((IPEndPoint)listener.LocalEndpoint).Address.Equals(IPAddress.IPv6Loopback);}}
 public bool Exclusive {get{return listener.Server.ExclusiveAddressUse;}}
 public RelayBranchPeer(bool socks) : this(socks,false,0) { }
 public RelayBranchPeer(bool socks,bool ipv6) : this(socks,ipv6,0) { }
 public RelayBranchPeer(bool socks,bool ipv6,int port) {
  this.socks=socks;listener=new TcpListener(ipv6?IPAddress.IPv6Loopback:IPAddress.Loopback,port);
  try{listener.Server.ExclusiveAddressUse=true;if(ipv6)listener.Server.DualMode=false;listener.Start();worker=new Thread(Serve);worker.IsBackground=true;worker.Start();}
  catch{listener.Stop();throw;}
 }
 static void Require(bool value){if(!value)throw new InvalidDataException("Owned protocol control refused");}
 static void Write(Stream stream,string value){byte[] bytes=Encoding.ASCII.GetBytes(value);stream.Write(bytes,0,bytes.Length);}
 static byte[] Read(Stream stream,int count){byte[] bytes=new byte[count];int offset=0;while(offset<count){int got=stream.Read(bytes,offset,count-offset);if(got<=0)throw new EndOfStreamException();offset+=got;}return bytes;}
 static void Send(Stream stream,byte[] bytes){stream.Write(bytes,0,bytes.Length);}
 static string Head(Stream stream){StringBuilder head=new StringBuilder();while(head.Length<8192){int next=stream.ReadByte();if(next<0)throw new EndOfStreamException();head.Append((char)next);if(head.ToString().EndsWith("\r\n\r\n"))return head.ToString();}throw new InvalidDataException();}
 static string Request(bool ipv4){return "GET /control HTTP/1.1\r\nHost: "+(ipv4?Ipv4Authority:Host)+"\r\nConnection: close\r\n\r\n";}
 static void Reply(Stream stream,string body){Write(stream,"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n"+body);}
 static void CheckReply(Stream stream,string body){string head=Head(stream);Require(head.StartsWith("HTTP/1.1 200 ",StringComparison.Ordinal));Require(head.Contains("Content-Length: 2\r\n"));Require(Encoding.ASCII.GetString(Read(stream,2))==body);}
 static void SocksClient(Stream stream,bool ipv4){
  Send(stream,new byte[]{5,2,0,2});byte[] method=Read(stream,2);Require(method[0]==5&&method[1]==2);
  Send(stream,new byte[]{1,5,111,119,110,101,100,7,102,105,120,116,117,114,101});byte[] login=Read(stream,2);Require(login[0]==1&&login[1]==0);
  if(ipv4)Send(stream,new byte[]{5,1,0,1,192,0,2,123,70,160});
  else{byte[] host=Encoding.ASCII.GetBytes(Host);MemoryStream request=new MemoryStream();Send(request,new byte[]{5,1,0,3,(byte)host.Length});Send(request,host);Send(request,new byte[]{0,80});Send(stream,request.ToArray());}
  byte[] reply=Read(stream,10);Require(reply[0]==5&&reply[1]==0&&reply[3]==1);
 }
 string SocksServer(Stream stream){
  byte[] greeting=Read(stream,2);Require(greeting[0]==5);byte[] methods=Read(stream,greeting[1]);Require(Array.IndexOf(methods,(byte)2)>=0);Send(stream,new byte[]{5,2});
  Require(Read(stream,1)[0]==1);string user=Encoding.ASCII.GetString(Read(stream,Read(stream,1)[0]));string password=Encoding.ASCII.GetString(Read(stream,Read(stream,1)[0]));Require(user=="owned"&&password=="fixture");Interlocked.Increment(ref Authenticated);Send(stream,new byte[]{1,0});
  byte[] connect=Read(stream,4);Require(connect[0]==5&&connect[1]==1&&connect[2]==0);string expectedHost;
  if(connect[3]==3){string host=Encoding.ASCII.GetString(Read(stream,Read(stream,1)[0]));byte[] port=Read(stream,2);Require(host==Host&&port[0]==0&&port[1]==80);Interlocked.Increment(ref DomainFrames);expectedHost=Host;}
  else{Require(connect[3]==1);byte[] authority=Read(stream,6);Require(authority[0]==192&&authority[1]==0&&authority[2]==2&&authority[3]==123&&authority[4]==70&&authority[5]==160);Interlocked.Increment(ref Ipv4Frames);expectedHost=Ipv4Authority;}
  Interlocked.Increment(ref Connections);Send(stream,new byte[]{5,0,0,1,127,0,0,1,0,0});return expectedHost;
 }
 void HttpServer(Stream stream){
  string head=Head(stream);Require(head.StartsWith("CONNECT "+Host+":443 HTTP/1.1\r\n",StringComparison.Ordinal));int headers=0;
  foreach(string line in head.Split(new string[]{"\r\n"},StringSplitOptions.None)){if(line.StartsWith("Proxy-Authorization:",StringComparison.OrdinalIgnoreCase)){Require(line.Equals(Auth,StringComparison.OrdinalIgnoreCase));headers++;}}
  Require(headers==1);Interlocked.Increment(ref Authenticated);Interlocked.Increment(ref Connections);Write(stream,"HTTP/1.1 200 Connection Established\r\n\r\n");
 }
 void Serve(){while(!stopped){try{using(TcpClient client=listener.AcceptTcpClient()){lock(gate){active=client;}client.ReceiveTimeout=3000;client.SendTimeout=3000;using(NetworkStream stream=client.GetStream()){
  string expectedHost=Host;if(socks)expectedHost=SocksServer(stream);else HttpServer(stream);string request=Head(stream);Require(request.StartsWith("GET /control HTTP/1.1\r\n",StringComparison.Ordinal));Require(request.Contains("\r\nHost: "+expectedHost+"\r\n"));Interlocked.Increment(ref Requests);Reply(stream,socks?"SC":"HC");
 }lock(gate){active=null;}}}catch(Exception){if(!stopped)Interlocked.Increment(ref Failures);}}}
 public static void Oracle(int port,bool socks,bool ipv4){Oracle(port,socks,ipv4,false);}
 public static void Oracle(int port,bool socks,bool ipv4,bool ipv6Proxy){using(TcpClient client=new TcpClient(ipv6Proxy?AddressFamily.InterNetworkV6:AddressFamily.InterNetwork)){client.Connect(ipv6Proxy?IPAddress.IPv6Loopback:IPAddress.Loopback,port);client.ReceiveTimeout=5000;client.SendTimeout=5000;using(NetworkStream stream=client.GetStream()){
  if(socks)SocksClient(stream,ipv4);else{Write(stream,"CONNECT "+Host+":443 HTTP/1.1\r\nHost: "+Host+":443\r\n"+Auth+"\r\n\r\n");Require(Head(stream).StartsWith("HTTP/1.1 200 ",StringComparison.Ordinal));}Write(stream,Request(ipv4));CheckReply(stream,socks?"SC":"HC");
 }}}
 // Use the same default constructor and string BeginConnect as production.
 // The outer exact Job bounds EndConnect if the host violates its local premise.
 public static RelayDefaultClientObservation DefaultClient(int port){return ClientProbe("::1",port,false);}
 public static RelayDefaultClientObservation DualClient(string host,int port){return ClientProbe(host,port,true);}
 static RelayDefaultClientObservation ClientProbe(string host,int port,bool dual){
  RelayDefaultClientObservation result=new RelayDefaultClientObservation();TcpClient client=null;
  try{client=dual?new TcpClient(AddressFamily.InterNetworkV6):new TcpClient();if(dual)client.Client.DualMode=true;result.DualMode=dual&&client.Client.DualMode;result.FamilyBefore=client.Client.AddressFamily.ToString();result.Stage="begin_connect";
   IAsyncResult pending=client.BeginConnect(host,port,null,null);result.Stage="end_connect";client.EndConnect(pending);result.Connected=true;
   client.ReceiveTimeout=5000;client.SendTimeout=5000;result.Stage="protocol";
   using(NetworkStream stream=client.GetStream()){SocksClient(stream,false);Write(stream,Request(false));CheckReply(stream,"SC");result.BodyExact=true;}result.Stage="complete";
  }catch(Exception error){Exception cause=error.GetBaseException();result.FailureType=cause.GetType().Name;SocketException socket=cause as SocketException;if(socket!=null)result.NativeError=socket.NativeErrorCode;}
  finally{if(client!=null){try{result.FamilyAfter=client.Client==null?"absent":client.Client.AddressFamily.ToString();}catch(ObjectDisposedException){result.FamilyAfter="closed";}finally{client.Close();result.Closed=true;}}}
  return result;
 }
 public static void ThroughHop(string endpoint,bool connect,bool ipv4){Uri hop=new Uri(endpoint);using(TcpClient client=new TcpClient(AddressFamily.InterNetwork)){client.Connect(IPAddress.Loopback,hop.Port);client.ReceiveTimeout=5000;client.SendTimeout=5000;using(NetworkStream stream=client.GetStream()){
  if(connect){Write(stream,"CONNECT "+Host+":443 HTTP/1.1\r\nHost: "+Host+":443\r\n\r\n");Require(Head(stream).StartsWith("HTTP/1.1 200 ",StringComparison.Ordinal));Write(stream,Request(false));}
  else{string target=ipv4?Ipv4Authority:Host;Write(stream,"GET http://"+target+"/control HTTP/1.1\r\nHost: "+target+"\r\nConnection: close\r\n\r\n");}
  CheckReply(stream,connect?"HC":"SC");
 }}}
 public void Dispose(){stopped=true;listener.Stop();lock(gate){if(active!=null)active.Close();}if(!worker.Join(5000))throw new InvalidOperationException("Owned branch peer did not join");Joined=true;}
}
'@
# This alternate mode reuses the canonical protocol peer; only its upstream
# listener family changes. Every real route uses native HTTP to the same DNS URL.
function Invoke-Ipv6RelayUpstreamControl {
    if($TransportPath -ceq '' -or $UpdaterDefaultsPath -ceq ''){throw 'The native upstream probe requires explicit transport and defaults sources.'}
    . $TransportPath
    $Directory=Join-Path ([IO.Path]::GetTempPath()) ('ergopti-ipv6-upstream-'+[Guid]::NewGuid().ToString('N'))
    $Created=$false;$Ipv4Peer=$null;$Ipv6Peer=$null;$DnsIpv6Peer=$null;$Ipv4Oracle=$false;$Ipv6Oracle=$false
    $Ipv6Strict=$false;$DnsPairOwned=$false;$DnsOnlyOwned=$false;$DualIpv4=$null;$DualIpv6=$null;$DualDns=$null;$Witness=$null;$DnsWitness=$null;$DnsIpv4Loopback=$false;$Subject=$null;$DefaultClient=$null;$SetupFailure=@{};$script:RelayIpv6NativeDebt=$false
    function Invoke-UpstreamNative($Override,$BodyPath,$HeaderPath) {
        $ReadEnvironment={param($Name) if($Name -ceq 'ERGOPTI_PROXY_OVERRIDE'){return $Override};return ''}.GetNewClosure()
        $Destination=[Uri]'http://hop-component.invalid/control'
        $Selection=Resolve-ErgoptiNativeNetworkRoutes -DestinationUrl $Destination.AbsoluteUri -BudgetMs 20000 `
            -ReadEnvironment $ReadEnvironment -PolicyPath $PolicyPath -UpdaterDefaultsPath $UpdaterDefaultsPath
        if(-not $Selection.Ok -or $Selection.Routes.Count -ne 1 -or $Selection.Routes[0].Kind -cne 'proxy') {
            throw 'The actual IPv6 upstream probe route was not admitted.'
        }
        $InputValue=[pscustomobject]@{started_tick=[ErgoptiWinHttpTransport]::CurrentTick();deadline_ms=20000;connect_timeout_ms=2000
            max_response_bytes=16;max_header_bytes=2048;response_path=$BodyPath;header_path=$HeaderPath
            revocation_best_effort=$false;headers=@();body=''}
        $Answer=@{child_quiesced=$true};$Engine=New-ErgoptiWinHttpAttemptEngine $InputValue $Answer
        $Metrics=$Engine.InvokeRoute($Destination,$Selection.Routes[0],'GET',$false,$true)
        $Exact=$Metrics.completed -and $Metrics.status -eq 200 -and $Metrics.delivered -eq 2 -and [IO.File]::ReadAllText($BodyPath) -ceq 'SC'
        $Retired=[bool]$Metrics.child_quiesced -and [bool]$Engine.ChildQuiesced()
        if(-not $Retired){$script:RelayIpv6NativeDebt=$true}
        return @{route_admitted=$true;completed=$Metrics.completed;status=$Metrics.status;body_exact=[bool]$Exact
            native_error=$Metrics.native_error;stage=$Metrics.stage;failure=$Metrics.failure;diagnostic=$Metrics.diagnostic;retired=$Retired}
    }
    function Get-UpstreamPeerObservation($Peer) {
        if($null -eq $Peer){return @{created=$false}}
        return @{created=$true;connections=$Peer.Connections;authenticated=$Peer.Authenticated
            requests=$Peer.Requests;domain_frames=$Peer.DomainFrames;ipv4_frames=$Peer.Ipv4Frames;failures=$Peer.Failures;joined=$Peer.Joined}
    }
    try {
        New-Item -ItemType Directory -Path $Directory -ErrorAction Stop | Out-Null
        $Created=$true;$BodyPath=Join-Path $Directory 'body.bin';$HeaderPath=Join-Path $Directory 'headers.bin'
        $Ipv4Peer=[RelayBranchPeer]::new($true)
        [RelayBranchPeer]::Oracle($Ipv4Peer.Port,$true,$false)
        $Ipv4Oracle=$true
        $Witness=Invoke-UpstreamNative ('socks5h://owned:fixture@127.0.0.1:'+$Ipv4Peer.Port) $BodyPath $HeaderPath
        if(-not $Witness.retired){throw 'The IPv4 witness retained native callback debt.'}
        # Own both possible localhost endpoints at one exclusive port before DNS.
        $DnsIpv6Peer=[RelayBranchPeer]::new($true,$true,$Ipv4Peer.Port)
        $DnsPairOwned=$Ipv4Peer.Exclusive -and $DnsIpv6Peer.Exclusive -and $DnsIpv6Peer.StrictIpv6 -and $DnsIpv6Peer.Port -eq $Ipv4Peer.Port
        if(-not $DnsPairOwned){throw 'The DNS witness could not own both exact loopback endpoints.'}
        $DnsAddresses=[Net.Dns]::GetHostAddresses('localhost')
        foreach($Address in $DnsAddresses) {
            if(-not $Address.Equals([Net.IPAddress]::Loopback) -and -not $Address.Equals([Net.IPAddress]::IPv6Loopback)){throw 'The DNS witness resolved outside its two exact owned addresses.'}
            if($Address.Equals([Net.IPAddress]::Loopback)){$DnsIpv4Loopback=$true}
        }
        $DnsOnlyOwned=$DnsAddresses.Count -gt 0
        if(-not $DnsOnlyOwned -or -not $DnsIpv4Loopback){throw 'The DNS proxy witness lacks its exact owned IPv4 address.'}
        $DualIpv4=[RelayBranchPeer]::DualClient('127.0.0.1',$Ipv4Peer.Port)
        $DualIpv6=[RelayBranchPeer]::DualClient('::1',$DnsIpv6Peer.Port)
        $DualDns=[RelayBranchPeer]::DualClient('localhost',$Ipv4Peer.Port)
        $DnsWitness=Invoke-UpstreamNative ('socks5h://owned:fixture@localhost:'+$Ipv4Peer.Port) $BodyPath $HeaderPath
        if(-not $DnsWitness.retired){throw 'The DNS witness retained native callback debt.'}
        $Ipv6Peer=[RelayBranchPeer]::new($true,$true)
        $Ipv6Strict=$Ipv6Peer.StrictIpv6
        [RelayBranchPeer]::Oracle($Ipv6Peer.Port,$true,$false,$true)
        $Ipv6Oracle=$true
        $DefaultClient=[RelayBranchPeer]::DefaultClient($Ipv6Peer.Port)
        $Subject=Invoke-UpstreamNative ('socks5h://owned:fixture@[::1]:'+$Ipv6Peer.Port) $BodyPath $HeaderPath
    } catch {
        $Cause=$_.Exception.GetBaseException()
        $SetupFailure=@{type=$Cause.GetType().Name}
        if($Cause -is [Net.Sockets.SocketException]){$SetupFailure.socket_error=$Cause.NativeErrorCode}
    } finally {
        if($null -ne $Ipv4Peer){$Ipv4Peer.Dispose()}
        if($null -ne $Ipv6Peer){$Ipv6Peer.Dispose()}
        if($null -ne $DnsIpv6Peer){$DnsIpv6Peer.Dispose()}
        if($Created -and -not $script:RelayIpv6NativeDebt) {
            foreach($Path in @($BodyPath,$HeaderPath)){if([IO.File]::Exists($Path)){[IO.File]::Delete($Path)}}
            [IO.Directory]::Delete($Directory,$false)
        }
    }
    function Get-ClientObservation($Client) {
        if($null -eq $Client){return @{observed=$false}}
        return @{observed=$true;family_before=$Client.FamilyBefore;family_after=$Client.FamilyAfter;dual_mode=$Client.DualMode
            stage=$Client.Stage;error_type=$Client.FailureType;native_error=$Client.NativeError
            connected=$Client.Connected;body_exact=$Client.BodyExact;closed=$Client.Closed}
    }
    $Constructor=Get-ClientObservation $DefaultClient
    $Ipv4Observation=Get-UpstreamPeerObservation $Ipv4Peer
    $DnsIpv6Observation=Get-UpstreamPeerObservation $DnsIpv6Peer
    $DnsPair=@{}
    foreach($Name in @('connections','authenticated','requests','domain_frames','failures')) {
        $DnsPair[$Name]=[int]$Ipv4Observation[$Name]+[int]$DnsIpv6Observation[$Name]
    }
    $Receipt=@{schema_version=1;ipv4_oracle=$Ipv4Oracle;ipv6_oracle=$Ipv6Oracle;ipv6_listener_strict=$Ipv6Strict
        ps_edition=[string]$PSVersionTable.PSEdition;ps_major=$PSVersionTable.PSVersion.Major;clr_major=[Environment]::Version.Major
        tcpclient_assembly=[Net.Sockets.TcpClient].Assembly.GetName().Name;default_constructor=$Constructor
        dual_controls=@{ipv4=(Get-ClientObservation $DualIpv4);ipv6=(Get-ClientObservation $DualIpv6);dns=(Get-ClientObservation $DualDns)}
        dns_pair_owned=$DnsPairOwned;dns_only_owned_addresses=$DnsOnlyOwned;dns_pair=$DnsPair
        dns_ipv4_loopback=$DnsIpv4Loopback;setup_failure=$SetupFailure;witness=$Witness;dns_witness=$DnsWitness;subject=$Subject
        ipv4_peer=$Ipv4Observation;dns_ipv6_peer=$DnsIpv6Observation;ipv6_peer=(Get-UpstreamPeerObservation $Ipv6Peer)}
    [Console]::WriteLine('IPV6_RELAY_UPSTREAM_RECEIPT:'+($Receipt|ConvertTo-Json -Compress -Depth 5))
    return $null -ne $Subject -and $Subject.completed -and $Subject.status -eq 200 -and $Subject.body_exact -and $Subject.retired
}
if($Ipv6Upstream) {
    if(-not (Invoke-Ipv6RelayUpstreamControl)){exit 1}
    exit 0
}
$Http=$null;$Socks=$null;$Receipt=$null
try {
    $Http=[RelayBranchPeer]::new($false)
    $Socks=[RelayBranchPeer]::new($true)
    [RelayBranchPeer]::Oracle($Http.Port,$false,$false)
    [RelayBranchPeer]::Oracle($Socks.Port,$true,$false)
    [RelayBranchPeer]::Oracle($Socks.Port,$true,$true)
    $HttpEndpoint=Resolve-ErgoptiRelayEndpoint ('http://owned:fixture@127.0.0.1:'+$Http.Port) $Policy
    $SocksEndpoint=Resolve-ErgoptiRelayEndpoint ('socks5h://owned:fixture@127.0.0.1:'+$Socks.Port) $Policy
    [RelayBranchPeer]::ThroughHop($HttpEndpoint,$true,$false)
    [RelayBranchPeer]::ThroughHop($SocksEndpoint,$false,$false)
    [RelayBranchPeer]::ThroughHop($SocksEndpoint,$false,$true)
    foreach($Case in @(@{Peer=$Http;Expected=2},@{Peer=$Socks;Expected=4})) {
        $Peer=$Case.Peer;$Expected=$Case.Expected
        if($Peer.Connections -ne $Expected -or $Peer.Authenticated -ne $Expected -or $Peer.Requests -ne $Expected -or $Peer.Failures -ne 0) {
            throw 'The exact branch peers did not observe both authenticated protocol controls.'
        }
    }
    if($script:ErgoptiRelayHops.Count -ne 2){throw 'The actual resolver did not retain exactly two production hops.'}
    $Receipt=@{schema_version=1;independent_oracles=3;actual_hops=2;http_connect=2;http_authenticated=2;http_requests=2
        socks_connect=4;socks_authenticated=4;socks_requests=4;domain_frames=$Socks.DomainFrames;ipv4_explicit_frames=$Socks.Ipv4Frames;peer_failures=0;component_bodies_exact=$true}
} finally {
    if($null -ne $Http){$Http.Dispose()}
    if($null -ne $Socks){$Socks.Dispose()}
}
if($null -eq $Receipt -or -not $Http.Joined -or -not $Socks.Joined){throw 'The branch peers have no closed terminal receipt.'}
$Receipt.fixture_peers_joined=$true
[Console]::WriteLine('RELAY_HOP_BRANCH_RECEIPT:'+($Receipt|ConvertTo-Json -Compress))
