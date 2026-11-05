# tests/fixtures/native_winhttp_ipv6_host.ps1
# Independent WinHTTP calls compare IPv6 server-name spellings at one owned proxy.
param([Parameter(Mandatory=$true)][string]$TransportPath)
$ErrorActionPreference='Stop'
. $TransportPath
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
public sealed class Ipv6HostResult {
 public bool Completed, BodyExact, Closed;
 public uint Status;
 public int Error;
 public string Stage="open";
}
public sealed class Ipv6HostPeer : IDisposable {
 readonly TcpListener listener=new TcpListener(IPAddress.Loopback,0);
 readonly Thread worker;
 readonly object gate=new object();
 volatile bool stopped;
 TcpClient active;
 public int Dns, Bracketed, Unbracketed, Actual, Failures;
 public bool Joined;
 public int Port {get{return ((IPEndPoint)listener.LocalEndpoint).Port;}}
 public Ipv6HostPeer(){listener.Start();worker=new Thread(Serve);worker.IsBackground=true;worker.Start();}
 static string Head(Stream stream){StringBuilder head=new StringBuilder();while(head.Length<8192){int next=stream.ReadByte();if(next<0)throw new EndOfStreamException();head.Append((char)next);if(head.ToString().EndsWith("\r\n\r\n"))return head.ToString();}throw new InvalidDataException();}
 void Serve(){while(!stopped){try{using(TcpClient client=listener.AcceptTcpClient()){lock(gate){active=client;}client.ReceiveTimeout=3000;client.SendTimeout=3000;using(NetworkStream stream=client.GetStream()){
  string head=Head(stream),agent="";foreach(string line in head.Split(new string[]{"\r\n"},StringSplitOptions.None))if(line.StartsWith("User-Agent: ",StringComparison.OrdinalIgnoreCase))agent=line.Substring(12);
  string host=agent=="ErgoptiIPv6Oracle-dns"?"ipv6-oracle.invalid":"[2001:db8::123]";
  bool target=head.StartsWith("GET http://"+host+"/v1/models HTTP/1.1\r\n",StringComparison.Ordinal)||head.StartsWith("GET http://"+host+":80/v1/models HTTP/1.1\r\n",StringComparison.Ordinal);
  if(!target)throw new InvalidDataException("Owned absolute target refused");string body;
  switch(agent){case "ErgoptiIPv6Oracle-dns":body="DC";Interlocked.Increment(ref Dns);break;case "ErgoptiIPv6Oracle-bracketed":body="BR";Interlocked.Increment(ref Bracketed);break;case "ErgoptiIPv6Oracle-unbracketed":body="UN";Interlocked.Increment(ref Unbracketed);break;case "ErgoptiIPv6Oracle-actual":body="AC";Interlocked.Increment(ref Actual);break;default:throw new InvalidDataException("Owned agent refused");}
  byte[] response=Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n"+body);stream.Write(response,0,response.Length);
 }lock(gate){active=null;}}}catch(Exception){if(!stopped)Interlocked.Increment(ref Failures);}}}
 public void Dispose(){stopped=true;listener.Stop();lock(gate){if(active!=null)active.Close();}if(!worker.Join(5000))throw new InvalidOperationException("Owned IPv6 host peer did not join");Joined=true;}
}
public static class Ipv6HostOracle {
 [DllImport("winhttp.dll",CharSet=CharSet.Unicode,ExactSpelling=true,SetLastError=true)] static extern IntPtr WinHttpOpen(string agent,uint access,string proxy,string bypass,uint flags);
 [DllImport("winhttp.dll",CharSet=CharSet.Unicode,ExactSpelling=true,SetLastError=true)] static extern IntPtr WinHttpConnect(IntPtr session,string host,ushort port,uint reserved);
 [DllImport("winhttp.dll",CharSet=CharSet.Unicode,ExactSpelling=true,SetLastError=true)] static extern IntPtr WinHttpOpenRequest(IntPtr connection,string method,string target,string version,string referer,IntPtr accept,uint flags);
 [DllImport("winhttp.dll",ExactSpelling=true,SetLastError=true)] static extern bool WinHttpSetTimeouts(IntPtr session,int resolve,int connect,int send,int receive);
 [DllImport("winhttp.dll",ExactSpelling=true,SetLastError=true)] static extern bool WinHttpSendRequest(IntPtr request,IntPtr headers,uint headerLength,IntPtr body,uint optionalLength,uint totalLength,UIntPtr context);
 [DllImport("winhttp.dll",ExactSpelling=true,SetLastError=true)] static extern bool WinHttpReceiveResponse(IntPtr request,IntPtr reserved);
 [DllImport("winhttp.dll",CharSet=CharSet.Unicode,ExactSpelling=true,SetLastError=true)] static extern bool WinHttpQueryHeaders(IntPtr request,uint level,string name,out uint value,ref uint bytes,IntPtr index);
 [DllImport("winhttp.dll",ExactSpelling=true,SetLastError=true)] static extern bool WinHttpReadData(IntPtr request,[Out] byte[] buffer,uint count,out uint read);
 [DllImport("winhttp.dll",ExactSpelling=true,SetLastError=true)] static extern bool WinHttpCloseHandle(IntPtr handle);
 public static Ipv6HostResult Send(string host,int proxyPort,string label,string expected){
  Ipv6HostResult result=new Ipv6HostResult();IntPtr session=IntPtr.Zero,connection=IntPtr.Zero,request=IntPtr.Zero;
  try{
   session=WinHttpOpen("ErgoptiIPv6Oracle-"+label,3,"127.0.0.1:"+proxyPort,null,0);if(session==IntPtr.Zero){result.Error=Marshal.GetLastWin32Error();return result;}
   result.Stage="timeouts";if(!WinHttpSetTimeouts(session,1500,1500,1500,1500)){result.Error=Marshal.GetLastWin32Error();return result;}
   result.Stage="connect";connection=WinHttpConnect(session,host,80,0);if(connection==IntPtr.Zero){result.Error=Marshal.GetLastWin32Error();return result;}
   result.Stage="open_request";request=WinHttpOpenRequest(connection,"GET","/v1/models",null,null,IntPtr.Zero,0);if(request==IntPtr.Zero){result.Error=Marshal.GetLastWin32Error();return result;}
   result.Stage="send";if(!WinHttpSendRequest(request,IntPtr.Zero,0,IntPtr.Zero,0,0,UIntPtr.Zero)){result.Error=Marshal.GetLastWin32Error();return result;}
   result.Stage="receive";if(!WinHttpReceiveResponse(request,IntPtr.Zero)){result.Error=Marshal.GetLastWin32Error();return result;}
   result.Stage="status";uint bytes=4,status;if(!WinHttpQueryHeaders(request,19u|0x20000000u,null,out status,ref bytes,IntPtr.Zero)){result.Error=Marshal.GetLastWin32Error();return result;}result.Status=status;
   result.Stage="read";byte[] body=new byte[3];int used=0;while(used<body.Length){byte[] buffer=new byte[body.Length-used];uint read;if(!WinHttpReadData(request,buffer,(uint)buffer.Length,out read)){result.Error=Marshal.GetLastWin32Error();return result;}if(read==0)break;Buffer.BlockCopy(buffer,0,body,used,(int)read);used+=(int)read;}
   result.Completed=true;result.BodyExact=used==2&&Encoding.ASCII.GetString(body,0,used)==expected;result.Stage="complete";return result;
  }finally{bool closed=true;if(request!=IntPtr.Zero&&!WinHttpCloseHandle(request))closed=false;if(connection!=IntPtr.Zero&&!WinHttpCloseHandle(connection))closed=false;if(session!=IntPtr.Zero&&!WinHttpCloseHandle(session))closed=false;result.Closed=closed;}
 }
}
'@
function Get-Ipv6HostObservation($Result) {
    return @{completed=$Result.Completed;status=$Result.Status;body_exact=$Result.BodyExact
        native_error=$Result.Error;stage=$Result.Stage;closed=$Result.Closed}
}
function Test-Ipv6HostSuccess($Result) {
    return $Result.Completed -and $Result.Status -eq 200 -and $Result.BodyExact -and $Result.Closed
}
$Directory=Join-Path ([IO.Path]::GetTempPath()) ('ergopti-ipv6-host-'+[Guid]::NewGuid().ToString('N'))
$DirectoryCreated=$false;$Peer=$null;$Refusal=$null;$Actual=$null;$Receipt=$null
$BodyPath=Join-Path $Directory 'body.bin';$HeaderPath=Join-Path $Directory 'headers.bin'
try {
    New-Item -ItemType Directory -Path $Directory -ErrorAction Stop | Out-Null
    $DirectoryCreated=$true
    $Peer=[Ipv6HostPeer]::new()
    $Refusal=[Net.Sockets.Socket]::new([Net.Sockets.AddressFamily]::InterNetwork,[Net.Sockets.SocketType]::Stream,[Net.Sockets.ProtocolType]::Tcp)
    $Refusal.Bind([Net.IPEndPoint]::new([Net.IPAddress]::Loopback,0))
    $RefusedPort=([Net.IPEndPoint]$Refusal.LocalEndPoint).Port
    $Destination=[Uri]'http://[2001:db8::123]/v1/models'
    $Dns=[Ipv6HostOracle]::Send('ipv6-oracle.invalid',$Peer.Port,'dns','DC')
    $Bracketed=[Ipv6HostOracle]::Send('[2001:db8::123]',$Peer.Port,'bracketed','BR')
    $Unbracketed=[Ipv6HostOracle]::Send('2001:db8::123',$Peer.Port,'unbracketed','UN')
    $AcceptedHost=if(Test-Ipv6HostSuccess $Bracketed){'[2001:db8::123]'}elseif(Test-Ipv6HostSuccess $Unbracketed){'2001:db8::123'}else{'ipv6-oracle.invalid'}
    $Refused=[Ipv6HostOracle]::Send($AcceptedHost,$RefusedPort,'refused','RF')
    $Spec=[ErgoptiWinHttpSpec]::new()
    $Spec.Url=$Destination.AbsoluteUri;$Spec.Method='GET';$Spec.UserAgent='ErgoptiIPv6Oracle-actual'
    $Spec.ProxyEndpoint='127.0.0.1:'+$Peer.Port;$Spec.ResponsePath=$BodyPath;$Spec.HeaderPath=$HeaderPath
    $Spec.ConnectTimeoutMs=1500;$Spec.BudgetMs=5000;$Spec.ReserveMs=1000;$Spec.MaxResponseBytes=8;$Spec.MaxHeaderBytes=2048
    $Actual=[ErgoptiWinHttpTransport]::Execute($Spec)
    $ActualExact=$Actual.Completed -and $Actual.Status -eq 200 -and $Actual.Delivered -eq 2 -and [IO.File]::ReadAllText($BodyPath) -ceq 'AC'
    $Receipt=@{schema_version=1;uri_fields=@{host=$Destination.Host;dns_safe_host=$Destination.DnsSafeHost;idn_host=$Destination.IdnHost}
        dns=(Get-Ipv6HostObservation $Dns);bracketed=(Get-Ipv6HostObservation $Bracketed)
        unbracketed=(Get-Ipv6HostObservation $Unbracketed);refusing_proxy=(Get-Ipv6HostObservation $Refused)
        ipv6_spelling_accepted=((Test-Ipv6HostSuccess $Bracketed) -or (Test-Ipv6HostSuccess $Unbracketed))
        actual=@{completed=$Actual.Completed;status=$Actual.Status;body_exact=[bool]$ActualExact
            native_error=$Actual.NativeError;stage=$Actual.Stage;failure=$Actual.Failure;diagnostic=$Actual.Diagnostic;retired=$Actual.Retired}}
} finally {
    if($null -ne $Peer){$Peer.Dispose()}
    if($null -ne $Refusal){$Refusal.Close()}
    if($DirectoryCreated -and ($null -eq $Actual -or $Actual.Retired)) {
        foreach($Path in @($BodyPath,$HeaderPath)){if([IO.File]::Exists($Path)){[IO.File]::Delete($Path)}}
        [IO.Directory]::Delete($Directory,$false)
    }
}
if($null -eq $Receipt -or -not $Peer.Joined){throw 'The IPv6 host oracle has no joined terminal receipt.'}
$Receipt.peer_joined=$true;$Receipt.peer_failures=$Peer.Failures
$Receipt.wire_dns=$Peer.Dns;$Receipt.wire_bracketed=$Peer.Bracketed
$Receipt.wire_unbracketed=$Peer.Unbracketed;$Receipt.wire_actual=$Peer.Actual
[Console]::WriteLine('WINHTTP_IPV6_HOST_RECEIPT:'+($Receipt|ConvertTo-Json -Compress -Depth 5))
if(-not $Receipt.actual.body_exact -or -not $Receipt.actual.retired){exit 1}
