# tests/fixtures/artifact_ntlm_proxy.ps1
# Actual Windows SSPI accepts current-user NTLM before tunnelling to owned TLS.
param(
    [Parameter(Mandatory = $true)][string]$StatePath,
    [Parameter(Mandatory = $true)][string]$StopEvent,
    [Parameter(Mandatory = $true)][int]$TlsPort,
    [ValidateSet('NtlmOnly', 'NegotiatePresent')][string]$ChallengeMode = 'NtlmOnly'
)
$ErrorActionPreference = 'Stop'
if ($StopEvent -cnotmatch '^Local\\ErgoptiPlus\.ArtifactNtlm\.[0-9a-f]{32}$' -or
    $TlsPort -lt 1 -or $TlsPort -gt 65535) { throw 'Invalid owned NTLM fixture identity.' }
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Threading;
public sealed class ErgoptiArtifactNtlmProxy : IDisposable {
    [StructLayout(LayoutKind.Sequential)] struct Handle { public IntPtr Lower, Upper; }
    [StructLayout(LayoutKind.Sequential)] struct Buffer { public int Size, Type; public IntPtr Data; }
    [StructLayout(LayoutKind.Sequential)] struct Descriptor { public int Version, Count; public IntPtr Buffers; }
    [DllImport("secur32.dll", CharSet=CharSet.Unicode)] static extern int AcquireCredentialsHandle(
        string principal, string package, int use, IntPtr logon, IntPtr authentication,
        IntPtr callback, IntPtr argument, out Handle credential, out long expiry);
    [DllImport("secur32.dll", EntryPoint="AcceptSecurityContext")] static extern int AcceptFirst(
        ref Handle credential, IntPtr context, ref Descriptor input, int flags, int representation,
        out Handle result, ref Descriptor output, out int attributes, out long expiry);
    [DllImport("secur32.dll", EntryPoint="AcceptSecurityContext")] static extern int AcceptNext(
        ref Handle credential, ref Handle context, ref Descriptor input, int flags, int representation,
        out Handle result, ref Descriptor output, out int attributes, out long expiry);
    [DllImport("secur32.dll")] static extern int QuerySecurityContextToken(ref Handle context, out IntPtr token);
    [DllImport("secur32.dll")] static extern int DeleteSecurityContext(ref Handle context);
    [DllImport("secur32.dll")] static extern int FreeCredentialsHandle(ref Handle credential);
    [DllImport("secur32.dll")] static extern int FreeContextBuffer(IntPtr buffer);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
    readonly TcpListener listener = new TcpListener(IPAddress.Loopback, 0);
    readonly object gate = new object();
    readonly List<TcpClient> clients = new List<TcpClient>();
    readonly List<Thread> workers = new List<Thread>();
    readonly int targetPort;
    readonly bool advertiseNegotiate;
    readonly SecurityIdentifier expectedUser;
    readonly Thread acceptor;
    volatile bool stopping;
    public int Port { get { return ((IPEndPoint)listener.LocalEndpoint).Port; } }
    public int Bare, TypeOne, TypeThree, Authenticated, Negotiate, Failures, Active;
    public bool IdentityMatched;
    public int SecurityStatus;
    public string FailureStage="none";
    public ErgoptiArtifactNtlmProxy(int port, bool negotiate) {
        targetPort=port; advertiseNegotiate=negotiate;
        using (WindowsIdentity current=WindowsIdentity.GetCurrent()) { expectedUser=current.User; }
        if (expectedUser==null) throw new InvalidOperationException("Missing current-user identity.");
        listener.Start();
        acceptor=new Thread(Accept); acceptor.IsBackground=true; acceptor.Start();
    }
    void Accept() {
        try {
            while (!stopping) {
                TcpClient client=listener.AcceptTcpClient();
                Thread worker=new Thread(delegate() { Serve(client); }); worker.IsBackground=true;
                lock(gate) {
                    if(workers.Count>=64) { client.Close(); throw new InvalidDataException("Owned fixture connection bound exceeded."); }
                    clients.Add(client); workers.Add(worker);
                }
                worker.Start();
            }
        } catch { if (!stopping) Interlocked.Increment(ref Failures); }
    }
    string ReadHeader(NetworkStream stream) {
        MemoryStream bytes=new MemoryStream();
        try {
            for(int n=0;n<16384;n++) {
                int value=stream.ReadByte(); if(value<0) throw new EndOfStreamException();
                bytes.WriteByte((byte)value);
                if(bytes.Length>=4) {
                    byte[] data=bytes.GetBuffer(); int k=(int)bytes.Length;
                    if(data[k-4]==13 && data[k-3]==10 && data[k-2]==13 && data[k-1]==10)
                        return Encoding.ASCII.GetString(data,0,k);
                }
            }
            throw new InvalidDataException("Bounded CONNECT header refused.");
        } finally { bytes.Dispose(); }
    }
    void Write(NetworkStream stream, string value) {
        byte[] bytes=Encoding.ASCII.GetBytes(value); stream.Write(bytes,0,bytes.Length); stream.Flush();
    }
    string Challenge(string token, bool close) {
        return "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: NTLM"+
            (token==null ? "" : " "+token)+"\r\n"+
            (advertiseNegotiate ? "Proxy-Authenticate: Negotiate\r\n" : "")+
            "Content-Length: 0\r\nConnection: "+(close ? "close" : "keep-alive")+"\r\n\r\n";
    }
    byte[] AcceptToken(ref Handle credential, ref Handle context, ref bool hasContext,
        byte[] token, out bool complete) {
        IntPtr inputData=Marshal.AllocHGlobal(token.Length);
        IntPtr inputBuffer=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(Buffer)));
        IntPtr outputBuffer=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(Buffer)));
        IntPtr providerOutput=IntPtr.Zero;
        try {
            Marshal.Copy(token,0,inputData,token.Length);
            Marshal.StructureToPtr(new Buffer { Size=token.Length,Type=2,Data=inputData },inputBuffer,false);
            Marshal.StructureToPtr(new Buffer { Size=0,Type=2,Data=IntPtr.Zero },outputBuffer,false);
            Descriptor input=new Descriptor { Version=0,Count=1,Buffers=inputBuffer };
            Descriptor output=new Descriptor { Version=0,Count=1,Buffers=outputBuffer };
            Handle next; int flags; long expiry;
            int status=hasContext ? AcceptNext(ref credential,ref context,ref input,0x900,0x10,out next,ref output,out flags,out expiry) :
                AcceptFirst(ref credential,IntPtr.Zero,ref input,0x900,0x10,out next,ref output,out flags,out expiry);
            // A failed native call may still allocate an output token. Capture
            // its pointer before interpreting status so every branch frees it.
            Buffer buffer=(Buffer)Marshal.PtrToStructure(outputBuffer,typeof(Buffer)); providerOutput=buffer.Data;
            // CONNECTION and ALLOCATE_MEMORY bind this exchange to its socket.
            if(status!=0 && status!=0x90312) { SecurityStatus=status; FailureStage="accept_context"; throw new InvalidOperationException("Native SSPI acceptance refused."); }
            context=next; hasContext=true; complete=status==0;
            if(buffer.Size<0 || buffer.Size>65536 || (buffer.Size>0 && providerOutput==IntPtr.Zero))
                throw new InvalidDataException("Native SSPI token exceeded its bound.");
            byte[] result=new byte[buffer.Size];
            if(result.Length>0) Marshal.Copy(providerOutput,result,0,result.Length);
            return result;
        } finally {
            Array.Clear(token,0,token.Length);
            for(int n=0;n<token.Length;n++) Marshal.WriteByte(inputData,n,0);
            if(providerOutput!=IntPtr.Zero && FreeContextBuffer(providerOutput)!=0) Interlocked.Increment(ref Failures);
            Marshal.FreeHGlobal(outputBuffer); Marshal.FreeHGlobal(inputBuffer); Marshal.FreeHGlobal(inputData);
        }
    }
    bool SameUser(ref Handle context) {
        IntPtr token;
        int status=QuerySecurityContextToken(ref context,out token);
        if(status!=0 || token==IntPtr.Zero) { SecurityStatus=status; FailureStage="context_token"; return false; }
        try {
            using(WindowsIdentity identity=new WindowsIdentity(token)) { return expectedUser.Equals(identity.User); }
        } finally { if(!CloseHandle(token)) Interlocked.Increment(ref Failures); }
    }
    void Serve(TcpClient client) {
        Interlocked.Increment(ref Active);
        Handle credential=new Handle(), context=new Handle();
        bool hasCredential=false, hasContext=false;
        TcpClient upstream=null;
        try {
            client.ReceiveTimeout=10000; client.SendTimeout=10000;
            NetworkStream stream=client.GetStream();
            for(int round=0;round<4;round++) {
                string header=ReadHeader(stream);
                string[] lines=header.Split(new string[]{"\r\n"},StringSplitOptions.None);
                if(lines[0]!="CONNECT managed-fixture.invalid:"+targetPort+" HTTP/1.1")
                    throw new InvalidDataException("Unexpected owned CONNECT target.");
                string authorization=null;
                foreach(string line in lines) {
                    if(line.StartsWith("Proxy-Authorization:",StringComparison.OrdinalIgnoreCase)) {
                        if(authorization!=null) throw new InvalidDataException("Duplicate authentication.");
                        authorization=line.Substring(line.IndexOf(':')+1).Trim();
                    }
                }
                if(authorization==null) {
                    Interlocked.Increment(ref Bare); Write(stream,Challenge(null,true)); return;
                }
                if(authorization.StartsWith("Negotiate ",StringComparison.OrdinalIgnoreCase)) {
                    Interlocked.Increment(ref Negotiate); Write(stream,Challenge(null,true)); return;
                }
                if(!authorization.StartsWith("NTLM ",StringComparison.OrdinalIgnoreCase) || authorization.Length>90000)
                    throw new InvalidDataException("Unexpected proxy authentication scheme.");
                byte[] token=Convert.FromBase64String(authorization.Substring(5));
                if(token.Length<12 || Encoding.ASCII.GetString(token,0,8)!="NTLMSSP\0")
                    throw new InvalidDataException("Unexpected native authentication token.");
                int type=BitConverter.ToInt32(token,8);
                if(!hasContext && type!=1 || hasContext && type!=3) throw new InvalidDataException("Native exchange order changed.");
                if(type==1) Interlocked.Increment(ref TypeOne); else Interlocked.Increment(ref TypeThree);
                if(!hasCredential) {
                    long expiry;
                    int status=AcquireCredentialsHandle(null,"NTLM",2,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,out credential,out expiry);
                    if(status!=0) { SecurityStatus=status; FailureStage="acquire_credentials";
                        throw new InvalidOperationException("Native inbound credentials refused."); }
                    hasCredential=true;
                }
                bool complete;
                byte[] output=AcceptToken(ref credential,ref context,ref hasContext,token,out complete);
                if(!complete) {
                    try { Write(stream,Challenge(Convert.ToBase64String(output),false)); }
                    finally { Array.Clear(output,0,output.Length); }
                    continue;
                }
                Array.Clear(output,0,output.Length);
                if(!SameUser(ref context)) { if(FailureStage=="none") FailureStage="identity_match";
                    throw new InvalidOperationException("Authenticated identity differs from current user."); }
                IdentityMatched=true; Interlocked.Increment(ref Authenticated);
                upstream=new TcpClient(); upstream.Connect(IPAddress.Loopback,targetPort);
                lock(gate) { clients.Add(upstream); }
                Write(stream,"HTTP/1.1 200 Connection Established\r\n\r\n");
                NetworkStream remote=upstream.GetStream();
                Thread reverse=new Thread(delegate() {
                    try { remote.CopyTo(stream); } catch { if(!stopping) Interlocked.Increment(ref Failures); }
                    finally { client.Close(); }
                }); reverse.IsBackground=true;
                lock(gate) { workers.Add(reverse); } reverse.Start();
                try { stream.CopyTo(remote); } catch(IOException) { } finally { upstream.Close(); }
                if(!reverse.Join(1000)) throw new InvalidOperationException("Owned tunnel receiver did not retire.");
                return;
            }
            throw new InvalidDataException("Native exchange exceeded its bound.");
        } catch { if(!stopping) Interlocked.Increment(ref Failures); }
        finally {
            if(upstream!=null) upstream.Close(); client.Close();
            if(hasContext && DeleteSecurityContext(ref context)!=0) Interlocked.Increment(ref Failures);
            if(hasCredential && FreeCredentialsHandle(ref credential)!=0) Interlocked.Increment(ref Failures);
            Interlocked.Decrement(ref Active);
        }
    }
    public void Dispose() {
        stopping=true; listener.Stop();
        lock(gate) { foreach(TcpClient client in clients) client.Close(); }
        Stopwatch deadline=Stopwatch.StartNew();
        bool retired=acceptor.Join(3000);
        Thread[] owned;
        lock(gate) { owned=workers.ToArray(); }
        foreach(Thread worker in owned) {
            int remaining=(int)Math.Max(0,3000-deadline.ElapsedMilliseconds);
            if(!worker.Join(remaining)) retired=false;
        }
        if(!retired || Active!=0) throw new InvalidOperationException("Owned native proxy threads retained retirement debt.");
    }
}
'@
$Proxy = $null
$Stop = $null
$State = @{schema_version=1;state='starting';active=0;failures=0}
function Publish {
    if ($null -ne $Proxy) {
        $State.bare=$Proxy.Bare; $State.type_one=$Proxy.TypeOne; $State.type_three=$Proxy.TypeThree
        $State.authenticated=$Proxy.Authenticated; $State.negotiate=$Proxy.Negotiate
        $State.identity_matched=$Proxy.IdentityMatched; $State.active=$Proxy.Active; $State.failures=$Proxy.Failures
        $State.security_status=$Proxy.SecurityStatus; $State.failure_stage=$Proxy.FailureStage
    }
    $Pending=$StatePath+'.pending'
    [IO.File]::WriteAllText($Pending,($State|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
    if([IO.File]::Exists($StatePath)){[IO.File]::Delete($StatePath)}
    [IO.File]::Move($Pending,$StatePath)
}
try {
    $Stop=[Threading.EventWaitHandle]::OpenExisting($StopEvent)
    $Proxy=[ErgoptiArtifactNtlmProxy]::new($TlsPort,($ChallengeMode -ceq 'NegotiatePresent'))
    $State.port=$Proxy.Port; $State.state='ready'; Publish
    while(-not $Stop.WaitOne(100)){Publish}
    $Proxy.Dispose(); $State.state='stopped'; Publish
    if($State.active -ne 0 -or $State.failures -ne 0){throw 'Native fixture did not close cleanly.'}
    [Console]::Out.WriteLine('OWNED_SSPI_PROXY_STOPPED')
} catch {
    $State.state='failed'; Publish
    [Console]::Out.WriteLine('OWNED_SSPI_PROXY_REFUSED')
    exit 1
} finally {
    if($null -ne $Proxy){$Proxy.Dispose()}
    if($null -ne $Stop){$Stop.Dispose()}
}
