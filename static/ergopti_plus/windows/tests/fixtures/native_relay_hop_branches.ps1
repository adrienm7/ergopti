# tests/fixtures/native_relay_hop_branches.ps1
# Independent owned protocol peers qualify real RelayHop CONNECT and SOCKS paths.
param(
    [Parameter(Mandatory=$true)][string]$RoutesPath,
    [Parameter(Mandatory=$true)][string]$PolicyPath
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
public sealed class RelayBranchPeer : IDisposable {
 const string Host="hop-component.invalid";
 const string Ipv4Authority="192.0.2.123:18080";
 const string Auth="Proxy-Authorization: Basic b3duZWQ6Zml4dHVyZQ==";
 readonly TcpListener listener=new TcpListener(IPAddress.Loopback,0);
 readonly Thread worker;
 readonly object gate=new object();
 readonly bool socks;
 volatile bool stopped;
 TcpClient active;
 public int Connections, Authenticated, Requests, Failures, DomainFrames, Ipv4Frames;
 public bool Joined;
 public int Port {get{return ((IPEndPoint)listener.LocalEndpoint).Port;}}
 public RelayBranchPeer(bool socks) {
  this.socks=socks;listener.Start();worker=new Thread(Serve);worker.IsBackground=true;worker.Start();
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
 public static void Oracle(int port,bool socks,bool ipv4){using(TcpClient client=new TcpClient(AddressFamily.InterNetwork)){client.Connect(IPAddress.Loopback,port);client.ReceiveTimeout=5000;client.SendTimeout=5000;using(NetworkStream stream=client.GetStream()){
  if(socks)SocksClient(stream,ipv4);else{Write(stream,"CONNECT "+Host+":443 HTTP/1.1\r\nHost: "+Host+":443\r\n"+Auth+"\r\n\r\n");Require(Head(stream).StartsWith("HTTP/1.1 200 ",StringComparison.Ordinal));}Write(stream,Request(ipv4));CheckReply(stream,socks?"SC":"HC");
 }}}
 public static void ThroughHop(string endpoint,bool connect,bool ipv4){Uri hop=new Uri(endpoint);using(TcpClient client=new TcpClient(AddressFamily.InterNetwork)){client.Connect(IPAddress.Loopback,hop.Port);client.ReceiveTimeout=5000;client.SendTimeout=5000;using(NetworkStream stream=client.GetStream()){
  if(connect){Write(stream,"CONNECT "+Host+":443 HTTP/1.1\r\nHost: "+Host+":443\r\n\r\n");Require(Head(stream).StartsWith("HTTP/1.1 200 ",StringComparison.Ordinal));Write(stream,Request(false));}
  else{string target=ipv4?Ipv4Authority:Host;Write(stream,"GET http://"+target+"/control HTTP/1.1\r\nHost: "+target+"\r\nConnection: close\r\n\r\n");}
  CheckReply(stream,connect?"HC":"SC");
 }}}
 public void Dispose(){stopped=true;listener.Stop();lock(gate){if(active!=null)active.Close();}if(!worker.Join(5000))throw new InvalidOperationException("Owned branch peer did not join");Joined=true;}
}
'@
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
