# tests/fixtures/artifact_ntlm_proxy.ps1
# Actual Windows SSPI accepts current-user NTLM before tunnelling to owned TLS.
param(
    [Parameter(Mandatory = $true)][string]$StatePath,
    [Parameter(Mandatory = $true)][string]$StopEvent,
    [Parameter(Mandatory = $true)][int]$TlsPort,
    [ValidateSet('NtlmOnly', 'NegotiatePresent')][string]$ChallengeMode = 'NtlmOnly',
    [switch]$ServeRemotePac
)
$ErrorActionPreference = 'Stop'
$StartupStage = 'identity'
try {
if ($StopEvent -cnotmatch '^Local\\ErgoptiPlus\.ArtifactNtlm\.[0-9a-f]{32}$' -or
    $TlsPort -lt 1 -or $TlsPort -gt 65535) { throw 'Invalid owned NTLM fixture identity.' }
$StartupStage = 'compile'
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
        IntPtr callback, IntPtr argument, ref Handle credential, out long expiry);
    [DllImport("secur32.dll", EntryPoint="AcceptSecurityContext")] static extern int AcceptFirst(
        ref Handle credential, IntPtr context, ref Descriptor input, int flags, int representation,
        ref Handle result, ref Descriptor output, out int attributes, out long expiry);
    [DllImport("secur32.dll", EntryPoint="AcceptSecurityContext")] static extern int AcceptNext(
        ref Handle credential, ref Handle context, ref Descriptor input, int flags, int representation,
        ref Handle result, ref Descriptor output, out int attributes, out long expiry);
    [DllImport("secur32.dll")] static extern int QuerySecurityContextToken(ref Handle context, ref IntPtr token);
    [DllImport("secur32.dll")] static extern int DeleteSecurityContext(ref Handle context);
    [DllImport("secur32.dll")] static extern int FreeCredentialsHandle(ref Handle credential);
    [DllImport("secur32.dll")] static extern int FreeContextBuffer(IntPtr buffer);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
    // WinSDK SecInvalidateHandle/SecIsValidHandle use both ULONG_PTR(-1)
    // fields; a zero field is not by itself an invalid SSPI handle.
    static Handle InvalidHandle() { return new Handle { Lower=new IntPtr(-1), Upper=new IntPtr(-1) }; }
    static bool ValidHandle(Handle handle) { return handle.Lower!=new IntPtr(-1) && handle.Upper!=new IntPtr(-1); }
    public static int HandleControls() {
        // Literal SDK sentinel controls do not claim native SSPI allocation.
        if(ValidHandle(InvalidHandle())) throw new InvalidDataException("SDK-invalid sentinel was admitted.");
        if(ValidHandle(new Handle { Lower=new IntPtr(-1), Upper=IntPtr.Zero })) throw new InvalidDataException("Invalid lower sentinel was admitted.");
        if(ValidHandle(new Handle { Lower=IntPtr.Zero, Upper=new IntPtr(-1) })) throw new InvalidDataException("Invalid upper sentinel was admitted.");
        if(!ValidHandle(new Handle { Lower=IntPtr.Zero, Upper=IntPtr.Zero })) throw new InvalidDataException("Zero SSPI handle was guessed invalid.");
        if(!ValidHandle(new Handle { Lower=new IntPtr(17), Upper=new IntPtr(23) })) throw new InvalidDataException("Literal SDK-valid handle was refused.");
        return 5;
    }
    readonly TcpListener listener = new TcpListener(IPAddress.Loopback, 0);
    readonly object gate = new object();
    readonly List<TcpClient> clients = new List<TcpClient>();
    readonly List<Thread> workers = new List<Thread>();
    readonly int targetPort;
    readonly bool advertiseNegotiate;
    readonly bool serveRemotePac;
    readonly int closedPort;
    readonly Socket refusedRoute;
    readonly SecurityIdentifier expectedUser;
    readonly Thread acceptor;
    volatile bool stopping;
    public int Port { get { return ((IPEndPoint)listener.LocalEndpoint).Port; } }
    public int Bare, TypeOne, TypeThree, Authenticated, Negotiate, Failures, Active, PacRequests;
    public bool IdentityMatched, RefusedRouteVerified;
    public int SecurityStatus;
    public string FailureStage="none";
    public sealed class FailureObservation {
        public readonly string Site, Family, Operation;
        public readonly int Code, TargetCloseState;
        public readonly bool StopRequested;
        public FailureObservation(string site, string family, int code, string operation, int targetCloseState, bool stopRequested) {
            Site=site; Family=family; Code=code; Operation=operation;
            TargetCloseState=targetCloseState; StopRequested=stopRequested;
        }
    }
    FailureObservation firstFailure;
    public FailureObservation FirstFailure { get { return Interlocked.CompareExchange(ref firstFailure,null,null); } }
    void ObserveCode(string site, string family, int code, string operation="none", int targetCloseState=0, bool stopRequested=false) {
        try { Interlocked.CompareExchange(ref firstFailure,new FailureObservation(site,family,code,operation,targetCloseState,stopRequested),null); }
        catch { /* Optional observation cannot affect the original failure counter. */ }
    }
    void ObserveException(string site, Exception failure, string operation="none", int targetCloseState=0, bool stopRequested=false) {
        try {
            SocketException socket=failure as SocketException;
            if(socket==null && failure is IOException) socket=failure.InnerException as SocketException;
            string family=socket!=null ? "winsock" : failure is IOException ? "io" :
                failure is InvalidOperationException ? "invalid_operation" :
                failure is ArgumentException ? "argument" : "other";
            int code=socket!=null ? socket.NativeErrorCode : failure.HResult;
            ObserveCode(site,family,code,operation,targetCloseState,stopRequested);
        } catch { /* No raw exception, provider data or retry authority is published. */ }
    }
    public ErgoptiArtifactNtlmProxy(int port, bool negotiate) : this(port,negotiate,false) { }
    public ErgoptiArtifactNtlmProxy(int port, bool negotiate, bool pac) {
        targetPort=port; advertiseNegotiate=negotiate; serveRemotePac=pac;
        try {
            if(pac) {
                // Keep this first route exclusively bound without Listen. It
                // refuses TCP while other fixture listeners cannot reuse it.
                refusedRoute=new Socket(AddressFamily.InterNetwork,SocketType.Stream,ProtocolType.Tcp);
                refusedRoute.ExclusiveAddressUse=true;
                refusedRoute.Bind(new IPEndPoint(IPAddress.Loopback,0));
                closedPort=((IPEndPoint)refusedRoute.LocalEndPoint).Port;
                using(TcpClient probe=new TcpClient()) {
                    try {
                        probe.Connect(IPAddress.Loopback,closedPort);
                        throw new InvalidOperationException("The owned first PAC route did not refuse TCP.");
                    } catch(SocketException failure) {
                        if(failure.SocketErrorCode!=SocketError.ConnectionRefused) throw;
                        RefusedRouteVerified=true;
                    }
                }
            }
            using (WindowsIdentity current=WindowsIdentity.GetCurrent()) { expectedUser=current.User; }
            if (expectedUser==null) throw new InvalidOperationException("Missing current-user identity.");
            listener.Start();
            acceptor=new Thread(Accept); acceptor.IsBackground=true; acceptor.Start();
        } catch {
            listener.Stop();
            if(refusedRoute!=null) refusedRoute.Dispose();
            throw;
        }
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
        } catch(Exception failure) { if (!stopping) {
            ObserveException("accept",failure); Interlocked.Increment(ref Failures);
        } }
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
        IntPtr inputData=IntPtr.Zero, inputBuffer=IntPtr.Zero, outputBuffer=IntPtr.Zero;
        IntPtr providerOutput=IntPtr.Zero;
        try {
            // Each allocation joins ownership before the next allocation can
            // fail; the finally also covers partial buffer construction.
            inputData=Marshal.AllocHGlobal(token.Length);
            inputBuffer=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(Buffer)));
            outputBuffer=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(Buffer)));
            Marshal.Copy(token,0,inputData,token.Length);
            Marshal.StructureToPtr(new Buffer { Size=token.Length,Type=2,Data=inputData },inputBuffer,false);
            Marshal.StructureToPtr(new Buffer { Size=0,Type=2,Data=IntPtr.Zero },outputBuffer,false);
            Descriptor input=new Descriptor { Version=0,Count=1,Buffers=inputBuffer };
            Descriptor output=new Descriptor { Version=0,Count=1,Buffers=outputBuffer };
            Handle next=InvalidHandle(); int flags; long expiry;
            int status=hasContext ? AcceptNext(ref credential,ref context,ref input,0x900,0x10,ref next,ref output,out flags,out expiry) :
                AcceptFirst(ref credential,IntPtr.Zero,ref input,0x900,0x10,ref next,ref output,out flags,out expiry);
            // A failed native call may still allocate an output token. Capture
            // its pointer before interpreting status so every branch frees it.
            Buffer buffer=(Buffer)Marshal.PtrToStructure(outputBuffer,typeof(Buffer)); providerOutput=buffer.Data;
            // Account any SDK-valid returned context before interpreting status.
            // Ref output starts invalid, so an untouched failed native call
            // cannot fabricate retirement authority from a zero-initialized out.
            if(ValidHandle(next)) {
                if(hasContext && (context.Lower!=next.Lower || context.Upper!=next.Upper)) {
                    int retirement=DeleteSecurityContext(ref context);
                    if(retirement!=0) { ObserveCode("delete_replaced_context","sspi",retirement); Interlocked.Increment(ref Failures); }
                }
                context=next; hasContext=true;
            }
            // CONNECTION and ALLOCATE_MEMORY bind this exchange to its socket.
            if(status!=0 && status!=0x90312) { SecurityStatus=status; FailureStage="accept_context";
                if(!stopping) ObserveCode("accept_context","sspi",status);
                throw new InvalidOperationException("Native SSPI acceptance refused."); }
            if(!hasContext) throw new InvalidOperationException("Native SSPI accepted without a context.");
            complete=status==0;
            if(buffer.Size<0 || buffer.Size>65536 || (buffer.Size>0 && providerOutput==IntPtr.Zero))
                throw new InvalidDataException("Native SSPI token exceeded its bound.");
            byte[] result=new byte[buffer.Size];
            if(result.Length>0) Marshal.Copy(providerOutput,result,0,result.Length);
            return result;
        } finally {
            Array.Clear(token,0,token.Length);
            if(inputData!=IntPtr.Zero) {
                for(int n=0;n<token.Length;n++) Marshal.WriteByte(inputData,n,0);
            }
            if(providerOutput!=IntPtr.Zero) {
                int retirement=FreeContextBuffer(providerOutput);
                if(retirement!=0) { ObserveCode("free_context_buffer","sspi",retirement); Interlocked.Increment(ref Failures); }
            }
            if(outputBuffer!=IntPtr.Zero) Marshal.FreeHGlobal(outputBuffer);
            if(inputBuffer!=IntPtr.Zero) Marshal.FreeHGlobal(inputBuffer);
            if(inputData!=IntPtr.Zero) Marshal.FreeHGlobal(inputData);
        }
    }
    bool SameUser(ref Handle context) {
        IntPtr token=IntPtr.Zero;
        try {
            int status=QuerySecurityContextToken(ref context,ref token);
            if(status!=0 || token==IntPtr.Zero) { SecurityStatus=status; FailureStage="context_token";
                if(status!=0 && !stopping) ObserveCode("context_token","sspi",status);
                return false; }
            using(WindowsIdentity identity=new WindowsIdentity(token)) { return expectedUser.Equals(identity.User); }
        } finally {
            // Account any token actually returned by the native call even
            // when its status refuses identity publication.
            if(token!=IntPtr.Zero && !CloseHandle(token)) {
                int retirement=Marshal.GetLastWin32Error();
                ObserveCode("close_context_token","win32",retirement); Interlocked.Increment(ref Failures);
            }
        }
    }
    // CopyTo merges reader and writer failures. Keep the same bounded chunk,
    // EOF and failure behavior while recording which actual operation refused.
    static void CopyResponse(Stream remote, Stream client, Action<string,Exception> failed) {
        string operation="read";
        try {
            byte[] buffer=new byte[81920];
            while(true) {
                operation="read"; int count=remote.Read(buffer,0,buffer.Length);
                if(count==0) return;
                operation="write"; client.Write(buffer,0,count);
            }
        } catch(Exception failure) { failed(operation,failure); }
    }
    // Request EOF finishes only the send direction. Closing the receive
    // direction here interrupts our own still-active response reader.
    static void CopyRequestAndRetireResponse(Stream stream, Stream remote, TcpClient upstream, Thread reverse, Action<string> reached) {
        reached("forward_request");
        try { stream.CopyTo(remote); } catch(IOException) { }
        finally {
            reached("half_close_request"); upstream.Client.Shutdown(SocketShutdown.Send);
            // An earlier non-IO copy failure must retain its original site.
            reached("forward_request");
        }
        reached("join_receiver");
        if(!reverse.Join(1000)) throw new InvalidOperationException("Owned tunnel receiver did not retire.");
    }
    void Serve(TcpClient client) {
        Interlocked.Increment(ref Active);
        Handle credential=InvalidHandle(), context=InvalidHandle();
        bool hasCredential=false, hasContext=false;
        TcpClient upstream=null;
        int targetCloseState=0;
        string site="configure_client";
        try {
            client.ReceiveTimeout=10000; client.SendTimeout=10000;
            site="get_client_stream"; NetworkStream stream=client.GetStream();
            for(int round=0;round<4;round++) {
                site="read_header"; string header=ReadHeader(stream);
                site="parse_header";
                string[] lines=header.Split(new string[]{"\r\n"},StringSplitOptions.None);
                if(serveRemotePac && lines[0]=="GET /remote-ordered.pac HTTP/1.1") {
                    string destination="https://managed-fixture.invalid:"+targetPort+"/v1/chat/completions?marker=managed-network-fixture";
                    string script="function FindProxyForURL(url,host){if(url==='"+destination+"')return 'PROXY 127.0.0.1:"+
                        closedPort+"; PROXY 127.0.0.1:"+Port+"; DIRECT';return 'DIRECT';}";
                    site="write_pac"; byte[] bytes=Encoding.UTF8.GetBytes(script);
                    Write(stream,"HTTP/1.1 200 OK\r\nConnection: close\r\nCache-Control: no-store\r\nContent-Type: application/x-ns-proxy-autoconfig\r\nContent-Length: "+bytes.Length+"\r\n\r\n");
                    stream.Write(bytes,0,bytes.Length); stream.Flush();
                    Interlocked.Increment(ref PacRequests); return;
                }
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
                    Interlocked.Increment(ref Bare); site="write_challenge"; Write(stream,Challenge(null,true)); return;
                }
                if(authorization.StartsWith("Negotiate ",StringComparison.OrdinalIgnoreCase)) {
                    Interlocked.Increment(ref Negotiate); site="write_challenge"; Write(stream,Challenge(null,true)); return;
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
                    // AcceptSecurityContext requires SECPKG_CRED_INBOUND (1), not the
                    // outbound credential direction used by an SSPI client.
                    site="acquire_credentials";
                    int status=AcquireCredentialsHandle(null,"NTLM",1,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,ref credential,out expiry);
                    hasCredential=ValidHandle(credential);
                    if(status!=0 || !hasCredential) { SecurityStatus=status; FailureStage="acquire_credentials";
                        // Preserve the exact return from this call, not the
                        // generic HRESULT of the existing managed refusal.
                        if(status!=0 && !stopping) ObserveCode("acquire_credentials","sspi",status);
                        throw new InvalidOperationException("Native inbound credentials refused."); }
                }
                bool complete;
                site="accept_context";
                byte[] output=AcceptToken(ref credential,ref context,ref hasContext,token,out complete);
                if(!complete) {
                    try { site="write_challenge"; Write(stream,Challenge(Convert.ToBase64String(output),false)); }
                    finally { Array.Clear(output,0,output.Length); }
                    continue;
                }
                Array.Clear(output,0,output.Length);
                site="identity_match";
                if(!SameUser(ref context)) { if(FailureStage=="none") FailureStage="identity_match";
                    throw new InvalidOperationException("Authenticated identity differs from current user."); }
                IdentityMatched=true; Interlocked.Increment(ref Authenticated);
                site="connect_target"; upstream=new TcpClient(); upstream.Connect(IPAddress.Loopback,targetPort);
                site="register_target"; lock(gate) { clients.Add(upstream); }
                site="write_tunnel"; Write(stream,"HTTP/1.1 200 Connection Established\r\n\r\n");
                site="get_target_stream"; NetworkStream remote=upstream.GetStream();
                site="start_receiver"; Thread reverse=new Thread(delegate() {
                    try { CopyResponse(remote,stream,delegate(string operation, Exception failure) {
                        bool stopRequested=stopping;
                        int closeState=Interlocked.CompareExchange(ref targetCloseState,0,0);
                        if(!stopRequested) {
                            ObserveException("forward_response",failure,operation,closeState,stopRequested);
                            Interlocked.Increment(ref Failures);
                        }
                    }); }
                    finally { client.Close(); }
                }); reverse.IsBackground=true;
                lock(gate) { workers.Add(reverse); } reverse.Start();
                CopyRequestAndRetireResponse(stream,remote,upstream,reverse,delegate(string value) { site=value; });
                return;
            }
            throw new InvalidDataException("Native exchange exceeded its bound.");
        } catch(Exception failure) { if(!stopping) {
            ObserveException(site,failure); Interlocked.Increment(ref Failures);
        } }
        finally {
            if(upstream!=null) {
                Interlocked.Exchange(ref targetCloseState,1);
                upstream.Close();
                Interlocked.Exchange(ref targetCloseState,2);
            }
            client.Close();
            if(hasContext) {
                int retirement=DeleteSecurityContext(ref context);
                if(retirement!=0) { ObserveCode("delete_context","sspi",retirement); Interlocked.Increment(ref Failures); }
            }
            if(hasCredential) {
                int retirement=FreeCredentialsHandle(ref credential);
                if(retirement!=0) { ObserveCode("free_credentials","sspi",retirement); Interlocked.Increment(ref Failures); }
            }
            Interlocked.Decrement(ref Active);
        }
    }
    public void Dispose() {
        stopping=true; listener.Stop();
        if(refusedRoute!=null) refusedRoute.Dispose();
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
$StartupStage = 'sentinel'
$Proxy = $null
$Stop = $null
$State = @{schema_version=1;state='starting';active=0;failures=0;handle_controls=[ErgoptiArtifactNtlmProxy]::HandleControls()}
function Publish {
    if ($null -ne $Proxy) {
        $State.bare=$Proxy.Bare; $State.type_one=$Proxy.TypeOne; $State.type_three=$Proxy.TypeThree
        $State.authenticated=$Proxy.Authenticated; $State.negotiate=$Proxy.Negotiate
        $State.identity_matched=$Proxy.IdentityMatched; $State.active=$Proxy.Active; $State.failures=$Proxy.Failures
        $State.security_status=$Proxy.SecurityStatus; $State.failure_stage=$Proxy.FailureStage; $State.pac_requests=$Proxy.PacRequests
        $State.refused_route_verified=$Proxy.RefusedRouteVerified
        # Read one immutable snapshot; concurrent workers cannot mix observations.
        $Observation=$Proxy.FirstFailure
        if ($null -eq $Observation) {
            $State.first_failure_site='none'; $State.first_failure_family='none'; $State.first_failure_code=0
            $State.first_failure_operation='none'; $State.first_failure_stop_requested=0; $State.first_failure_target_close_state=0
        } else {
            $State.first_failure_site=$Observation.Site; $State.first_failure_family=$Observation.Family; $State.first_failure_code=$Observation.Code
            $State.first_failure_operation=$Observation.Operation; $State.first_failure_stop_requested=[int]$Observation.StopRequested
            $State.first_failure_target_close_state=$Observation.TargetCloseState
        }
    }
    $Pending=$StatePath+'.pending'
    [IO.File]::WriteAllText($Pending,($State|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
    if([IO.File]::Exists($StatePath)){[IO.File]::Delete($StatePath)}
    [IO.File]::Move($Pending,$StatePath)
}
$StartupStage = 'service'
try {
    $Stop=[Threading.EventWaitHandle]::OpenExisting($StopEvent)
    $Proxy=[ErgoptiArtifactNtlmProxy]::new($TlsPort,($ChallengeMode -ceq 'NegotiatePresent'),[bool]$ServeRemotePac)
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
} catch {
    # A failure before the normal state owner must remain observable. Never
    # overwrite a state already published by that owner or publish raw errors.
    $StartupFailure = $_
    $StartupStream = $null
    try {
        $CompilerCode = [regex]::Match($StartupFailure.Exception.Message, '\bCS[0-9]{4}\b').Value
        $StartupReceipt = @{schema_version=1;state='failed';active=0;failures=1;
            handle_controls=0;startup_stage=$StartupStage;compiler_code=$CompilerCode}
        $StartupBytes = [Text.Encoding]::UTF8.GetBytes(($StartupReceipt | ConvertTo-Json -Compress))
        $StartupStream = [IO.File]::Open($StatePath, [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write, [IO.FileShare]::None)
        $StartupStream.Write($StartupBytes, 0, $StartupBytes.Length)
        $StartupStream.Flush($true)
    } catch {
        # Keep the original startup failure even if its passive receipt refuses.
    } finally {
        if ($null -ne $StartupStream) { try { $StartupStream.Dispose() } catch { } }
    }
    throw $StartupFailure
}
