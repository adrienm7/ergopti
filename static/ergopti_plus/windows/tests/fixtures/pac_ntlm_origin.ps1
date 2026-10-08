# tests/fixtures/pac_ntlm_origin.ps1
# Native Windows HTTP401 PAC authentication, separate from CONNECT proxy authority.
# Definitions only: the receiving owner must dispose and verify exact counters.
if (-not ('ErgoptiPacNtlmOrigin' -as [type])) {
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
public sealed class ErgoptiPacNtlmOrigin : IDisposable {
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
    [DllImport("secur32.dll")] static extern int QuerySecurityContextToken(ref Handle context, out IntPtr token);
    [DllImport("secur32.dll")] static extern int DeleteSecurityContext(ref Handle context);
    [DllImport("secur32.dll")] static extern int FreeCredentialsHandle(ref Handle credential);
    [DllImport("secur32.dll")] static extern int FreeContextBuffer(IntPtr buffer);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
    // WinSDK SecInvalidateHandle/SecIsValidHandle use both ULONG_PTR(-1)
    // fields; a zero field is not by itself an invalid SSPI handle.
    static Handle InvalidHandle() { return new Handle { Lower=new IntPtr(-1), Upper=new IntPtr(-1) }; }
    static bool ValidHandle(Handle handle) { return handle.Lower!=new IntPtr(-1) && handle.Upper!=new IntPtr(-1); }
    readonly TcpListener listener = new TcpListener(IPAddress.Loopback, 0);
    readonly object gate = new object();
    readonly List<TcpClient> clients = new List<TcpClient>();
    readonly List<Thread> workers = new List<Thread>();
    readonly SecurityIdentifier expectedUser;
    readonly Thread acceptor;
    volatile bool stopping;
    public int Port { get { return ((IPEndPoint)listener.LocalEndpoint).Port; } }
    public int Bare, TypeOne, TypeThree, Authenticated, Failures, Active;
    public int OwnedCredentials, OwnedContexts, OwnedTokens, OwnedBuffers, Responses;
    public bool IdentityMatched;
    public int SecurityStatus;
    public string FailureStage="none";
    public ErgoptiPacNtlmOrigin() {
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
        return "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: NTLM"+
            (token==null ? "" : " "+token)+"\r\n"+
            "Content-Length: 0\r\nCache-Control: no-store\r\nConnection: "+(close ? "close" : "keep-alive")+"\r\n\r\n";
    }
    byte[] AcceptToken(ref Handle credential, ref Handle context, ref bool hasContext,
        byte[] token, List<Handle> owners, out bool complete) {
        IntPtr inputData=IntPtr.Zero,inputBuffer=IntPtr.Zero,outputBuffer=IntPtr.Zero,providerOutput=IntPtr.Zero;
        try {
            inputData=Marshal.AllocHGlobal(token.Length);Interlocked.Increment(ref OwnedBuffers);
            inputBuffer=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(Buffer)));Interlocked.Increment(ref OwnedBuffers);
            outputBuffer=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(Buffer)));Interlocked.Increment(ref OwnedBuffers);
            Marshal.Copy(token,0,inputData,token.Length);
            Marshal.StructureToPtr(new Buffer { Size=token.Length,Type=2,Data=inputData },inputBuffer,false);
            Marshal.StructureToPtr(new Buffer { Size=0,Type=2,Data=IntPtr.Zero },outputBuffer,false);
            Descriptor input=new Descriptor { Version=0,Count=1,Buffers=inputBuffer };
            Descriptor output=new Descriptor { Version=0,Count=1,Buffers=outputBuffer };
            Handle next=InvalidHandle(); int flags; long expiry;
            int status=hasContext ? AcceptNext(ref credential,ref context,ref input,0x900,0x10,ref next,ref output,out flags,out expiry) :
                AcceptFirst(ref credential,IntPtr.Zero,ref input,0x900,0x10,ref next,ref output,out flags,out expiry);
            Buffer buffer=(Buffer)Marshal.PtrToStructure(outputBuffer,typeof(Buffer)); providerOutput=buffer.Data;
            if(providerOutput!=IntPtr.Zero)Interlocked.Increment(ref OwnedBuffers);
            // SecInvalidateHandle/SecIsValidHandle follow the actual WinSDK sentinel contract.
            bool returned=next.Lower!=new IntPtr(-1)&&next.Upper!=new IntPtr(-1);
            if(returned) {
                bool alreadyOwned=false;
                foreach(Handle lease in owners)if(lease.Lower==next.Lower&&lease.Upper==next.Upper){alreadyOwned=true;break;}
                if(!alreadyOwned){owners.Add(next);Interlocked.Increment(ref OwnedContexts);}
                context=next;hasContext=true;
            }
            if(status!=0&&status!=0x90312||!returned) {
                SecurityStatus=status;FailureStage="accept_context";
                throw new InvalidOperationException("Native PAC identity acceptance refused.");
            }
            complete=status==0;
            if(buffer.Size<0 || buffer.Size>65536 || (buffer.Size>0 && providerOutput==IntPtr.Zero))
                throw new InvalidDataException("Native SSPI token exceeded its bound.");
            byte[] result=new byte[buffer.Size];
            if(result.Length>0) Marshal.Copy(providerOutput,result,0,result.Length);
            return result;
        } finally {
            Array.Clear(token,0,token.Length);
            if(inputData!=IntPtr.Zero)for(int n=0;n<token.Length;n++)Marshal.WriteByte(inputData,n,0);
            if(providerOutput!=IntPtr.Zero) {
                if(FreeContextBuffer(providerOutput)!=0)Interlocked.Increment(ref Failures);
                else Interlocked.Decrement(ref OwnedBuffers);
            }
            if(outputBuffer!=IntPtr.Zero){Marshal.FreeHGlobal(outputBuffer);Interlocked.Decrement(ref OwnedBuffers);}
            if(inputBuffer!=IntPtr.Zero){Marshal.FreeHGlobal(inputBuffer);Interlocked.Decrement(ref OwnedBuffers);}
            if(inputData!=IntPtr.Zero){Marshal.FreeHGlobal(inputData);Interlocked.Decrement(ref OwnedBuffers);}
        }
    }
    bool SameUser(ref Handle context) {
        IntPtr token=IntPtr.Zero;
        int status=QuerySecurityContextToken(ref context,out token);
        if(token!=IntPtr.Zero)Interlocked.Increment(ref OwnedTokens);
        try {
            if(status!=0||token==IntPtr.Zero){SecurityStatus=status;FailureStage="context_token";return false;}
            using(WindowsIdentity identity=new WindowsIdentity(token)){return expectedUser.Equals(identity.User);}
        } finally {
            if(token!=IntPtr.Zero){if(!CloseHandle(token))Interlocked.Increment(ref Failures);else Interlocked.Decrement(ref OwnedTokens);}
        }
    }
    void Serve(TcpClient client) {
        Interlocked.Increment(ref Active);
        Handle credential=InvalidHandle(), context=InvalidHandle();
        bool hasCredential=false, hasContext=false;
        List<Handle> contexts=new List<Handle>();
        try {
            client.ReceiveTimeout=10000; client.SendTimeout=10000;
            NetworkStream stream=client.GetStream();
            for(int round=0;round<4;round++) {
                string header=ReadHeader(stream);
                string[] lines=header.Split(new string[]{"\r\n"},StringSplitOptions.None);
                if(lines[0]!="GET /authenticated.pac HTTP/1.1"&&lines[0]!="GET /authenticated.pac HTTP/1.0")
                    throw new InvalidDataException("Unexpected owned PAC target.");
                string authorization=null;
                foreach(string line in lines) {
                    if(line.StartsWith("Proxy-Authorization:",StringComparison.OrdinalIgnoreCase))
                        throw new InvalidDataException("PAC origin cannot receive proxy credentials.");
                    if(line.StartsWith("Authorization:",StringComparison.OrdinalIgnoreCase)) {
                        if(authorization!=null) throw new InvalidDataException("Duplicate authentication.");
                        authorization=line.Substring(line.IndexOf(':')+1).Trim();
                    }
                }
                if(authorization==null) {
                    Interlocked.Increment(ref Bare); Write(stream,Challenge(null,true)); return;
                }
                if(!authorization.StartsWith("NTLM ",StringComparison.OrdinalIgnoreCase) || authorization.Length>90000)
                    throw new InvalidDataException("Unexpected PAC authentication scheme.");
                byte[] token=Convert.FromBase64String(authorization.Substring(5));
                if(token.Length<12 || Encoding.ASCII.GetString(token,0,8)!="NTLMSSP\0")
                    throw new InvalidDataException("Unexpected native authentication token.");
                int type=BitConverter.ToInt32(token,8);
                if(!hasContext && type!=1 || hasContext && type!=3) throw new InvalidDataException("Native exchange order changed.");
                if(type==1) Interlocked.Increment(ref TypeOne); else Interlocked.Increment(ref TypeThree);
                if(!hasCredential) {
                    long expiry;
                    int status=AcquireCredentialsHandle(null,"NTLM",2,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,IntPtr.Zero,ref credential,out expiry);
                    hasCredential=ValidHandle(credential);
                    if(hasCredential)Interlocked.Increment(ref OwnedCredentials);
                    if(status!=0 || !hasCredential) { SecurityStatus=status; FailureStage="acquire_credentials";
                        throw new InvalidOperationException("Native inbound credentials refused."); }
                }
                bool complete;
                byte[] output=AcceptToken(ref credential,ref context,ref hasContext,token,contexts,out complete);
                if(!complete) {
                    try { Write(stream,Challenge(Convert.ToBase64String(output),false)); }
                    finally { Array.Clear(output,0,output.Length); }
                    continue;
                }
                Array.Clear(output,0,output.Length);
                if(!SameUser(ref context)) { if(FailureStage=="none") FailureStage="identity_match";
                    throw new InvalidOperationException("Authenticated identity differs from current user."); }
                IdentityMatched=true; Interlocked.Increment(ref Authenticated);
                string pac="function FindProxyForURL(url,host){if(url==='https://pac-auth-fixture.invalid:8443/authenticated?marker=private') return 'PROXY auth-fixture.invalid:38109; DIRECT'; throw new Error('owned URL boundary');}";
                byte[] body=Encoding.UTF8.GetBytes(pac);
                Write(stream,"HTTP/1.1 200 OK\r\nContent-Type: application/x-ns-proxy-autoconfig\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: "+body.Length+"\r\n\r\n");
                stream.Write(body,0,body.Length);stream.Flush();Interlocked.Increment(ref Responses);
                return;
            }
            throw new InvalidDataException("Native exchange exceeded its bound.");
        } catch { if(!stopping) Interlocked.Increment(ref Failures); }
        finally {
            client.Close();
            foreach(Handle lease in contexts) { Handle owned=lease;if(DeleteSecurityContext(ref owned)!=0)Interlocked.Increment(ref Failures);else Interlocked.Decrement(ref OwnedContexts); }
            if(hasCredential) { if(FreeCredentialsHandle(ref credential)!=0)Interlocked.Increment(ref Failures); else Interlocked.Decrement(ref OwnedCredentials); }
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
        if(!retired || Active!=0 || OwnedContexts!=0 || OwnedCredentials!=0 || OwnedTokens!=0 || OwnedBuffers!=0) throw new InvalidOperationException("Owned native PAC authentication retained retirement debt.");
    }
}
'@ -ErrorAction Stop
}
