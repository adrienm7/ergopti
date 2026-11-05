# tests/fixtures/native_static_scheme_proxy.ps1
# Native WinHTTP is the oracle for the per-protocol Windows proxy map. One owned
# local receiver and exact native handles retire before any receipt is emitted.
param(
    [Parameter(Mandatory=$true)][string]$RoutesPath,
    [Parameter(Mandatory=$true)][string]$PolicyPath,
    [Parameter(Mandatory=$true)][string]$UpdaterDefaultsPath
)
$ErrorActionPreference='Stop'
Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
public static class StaticSchemeOracle {
 [DllImport("winhttp.dll", CharSet=CharSet.Unicode, SetLastError=true, ExactSpelling=true)] static extern IntPtr WinHttpOpen(string agent,uint access,string proxy,string bypass,uint flags);
 [DllImport("winhttp.dll", CharSet=CharSet.Unicode, SetLastError=true, ExactSpelling=true)] static extern IntPtr WinHttpConnect(IntPtr session,string host,ushort port,uint reserved);
 [DllImport("winhttp.dll", CharSet=CharSet.Unicode, SetLastError=true, ExactSpelling=true)] static extern IntPtr WinHttpOpenRequest(IntPtr connection,string verb,string target,string version,string referer,IntPtr accept,uint flags);
 [DllImport("winhttp.dll", SetLastError=true, ExactSpelling=true)] static extern bool WinHttpSetTimeouts(IntPtr session,int resolve,int connect,int send,int receive);
 [DllImport("winhttp.dll", SetLastError=true, ExactSpelling=true)] static extern bool WinHttpSendRequest(IntPtr request,IntPtr headers,uint headerLength,IntPtr body,uint optionalLength,uint totalLength,UIntPtr context);
 [DllImport("winhttp.dll", SetLastError=true, ExactSpelling=true)] static extern bool WinHttpReceiveResponse(IntPtr request,IntPtr reserved);
 [DllImport("winhttp.dll")] static extern bool WinHttpCloseHandle(IntPtr handle);
 public static bool Send(string host,int port,string proxy) {
  IntPtr s=IntPtr.Zero,c=IntPtr.Zero,r=IntPtr.Zero;
  try { s=WinHttpOpen("ErgoptiStaticSchemeOracle",proxy==null?1u:3u,proxy,null,0);if(s==IntPtr.Zero)throw new Exception("open");
   if(!WinHttpSetTimeouts(s,2000,2000,2000,2000))throw new Exception("timeout");
   c=WinHttpConnect(s,host,(ushort)port,0);if(c==IntPtr.Zero)throw new Exception("connect");
   r=WinHttpOpenRequest(c,"GET","/scheme-oracle",null,null,IntPtr.Zero,0);if(r==IntPtr.Zero)throw new Exception("request");
   return WinHttpSendRequest(r,IntPtr.Zero,0,IntPtr.Zero,0,0,UIntPtr.Zero)&&WinHttpReceiveResponse(r,IntPtr.Zero);
  } finally {bool closed=true;if(r!=IntPtr.Zero&&!WinHttpCloseHandle(r))closed=false;if(c!=IntPtr.Zero&&!WinHttpCloseHandle(c))closed=false;if(s!=IntPtr.Zero&&!WinHttpCloseHandle(s))closed=false;if(!closed)throw new Exception("Native handle close not acknowledged");}
 }
 public static string Probe() {
  IPAddress local=null;
  foreach(IPAddress candidate in Dns.GetHostAddresses(Dns.GetHostName()))
   if(candidate.AddressFamily==AddressFamily.InterNetwork&&!IPAddress.IsLoopback(candidate)){local=candidate;break;}
  if(local==null)throw new Exception("Owned nonloopback IPv4 prerequisite unavailable");
  TcpListener listener=new TcpListener(local,0);listener.Start();int port=((IPEndPoint)listener.LocalEndpoint).Port;
  // A bound, non-listening socket reserves the refusal port without an adoption race.
  Socket refusal=new Socket(AddressFamily.InterNetwork,SocketType.Stream,ProtocolType.Tcp);
  refusal.Bind(new IPEndPoint(IPAddress.Loopback,0));int refusedPort=((IPEndPoint)refusal.LocalEndPoint).Port;
  bool stop=false;int accepted=0;Thread server=new Thread(delegate(){while(!Volatile.Read(ref stop)){if(!listener.Pending()){Thread.Sleep(5);continue;}using(TcpClient client=listener.AcceptTcpClient()){client.ReceiveTimeout=2000;using(NetworkStream stream=client.GetStream()){byte[] buffer=new byte[8192];int used=0;while(used<buffer.Length){int read=stream.Read(buffer,used,buffer.Length-used);if(read==0)break;used+=read;if(Encoding.ASCII.GetString(buffer,0,used).Contains("\r\n\r\n"))break;}byte[] reply=Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK");Interlocked.Increment(ref accepted);stream.Write(reply,0,reply.Length);}}}});server.IsBackground=true;server.Start();
  try {string host=local.ToString();bool direct=Send(host,port,null);bool absent=Send(host,port,"https=127.0.0.1:"+refusedPort);bool matched=Send(host,port,"http=127.0.0.1:"+refusedPort);
   if(!direct||!absent||matched)throw new Exception("Oracle controls refused: direct="+direct+" absent="+absent+" matched="+matched);
   if(accepted!=2)throw new Exception("Owned receiver count mismatch");
   return "NATIVE_STATIC_SCHEME_ORACLE:direct=1 absent_direct=1 matched_refused=1";
  }finally{Volatile.Write(ref stop,true);if(!server.Join(5000))throw new Exception("Owned server did not retire");listener.Stop();refusal.Close();}
 }
}
'@
[Console]::WriteLine([StaticSchemeOracle]::Probe())

. $RoutesPath
$EmptyEnvironment={param($Name) ''}
$HttpDirect=$false
$HttpsDirect=$false
foreach($Scheme in @('http','https')) {
    $Other=if($Scheme -ceq 'http'){'https'}else{'http'}
    $Config=@{Ok=$true;Absent=$false;AutoDetect=$false;PacUrl='';Proxy=($Other+'=proxy.invalid:8080');Bypass='';NativeError=0;FailureOrigin=''}
    $Reader={param($MaximumBytes) $Config}.GetNewClosure()
    $Actual=Resolve-ErgoptiNativeNetworkRoutes -DestinationUrl ($Scheme+'://example.invalid/') `
        -BudgetMs 5000 -ReadConfig $Reader -ReadEnvironment $EmptyEnvironment `
        -PolicyPath $PolicyPath -UpdaterDefaultsPath $UpdaterDefaultsPath
    $Direct=$Actual.Ok -and $Actual.Routes.Count -eq 1 -and
        $Actual.Routes[0].Kind -ceq 'direct' -and $Actual.Routes[0].Endpoint -ceq '' -and
        $Actual.Routes[0].Authentication -ceq 'none'
    if($Scheme -ceq 'http'){$HttpDirect=[bool]$Direct}else{$HttpsDirect=[bool]$Direct}
}
$Receipt=@{schema_version=1;oracle=$true;http_direct=$HttpDirect;https_direct=$HttpsDirect;servers_retired=$true}
[Console]::WriteLine('STATIC_SCHEME_RECEIPT:'+($Receipt|ConvertTo-Json -Compress))
if(-not $HttpDirect -or -not $HttpsDirect){exit 1}
