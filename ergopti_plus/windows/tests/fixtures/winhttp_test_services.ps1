# tests/fixtures/winhttp_test_services.ps1
# Scripted loopback services for real-WinHTTP controls: a static or scripted HTTP origin, a
# silent or slow origin, a Basic-only proxy, an SSPI NTLM/Negotiate proxy or origin that
# authenticates the current user through the actual security package, a CONNECT tunnel and
# a TLS origin with an untrusted self-signed certificate. Dot-source it; it defines the
# ErgoptiWinHttpTestServer class only and starts nothing.
if (-not ('ErgoptiWinHttpTestServer' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Security.Principal;
using System.Text;
using System.Threading;

// Scripted loopback service. Every mode is a closed behaviour; the request log
// keeps header names and the authentication scheme only, never a token.
public sealed class ErgoptiWinHttpTestServer : IDisposable
{
    [StructLayout(LayoutKind.Sequential)] struct SecHandle { public IntPtr Lower, Upper; }
    [StructLayout(LayoutKind.Sequential)] struct SecBuffer { public int Size, Type; public IntPtr Data; }
    [StructLayout(LayoutKind.Sequential)] struct SecBufferDesc { public int Version, Count; public IntPtr Buffers; }
    [DllImport("secur32.dll", CharSet = CharSet.Unicode)] static extern int AcquireCredentialsHandle(
        string principal, string package, int use, IntPtr logon, IntPtr authentication,
        IntPtr callback, IntPtr argument, ref SecHandle credential, out long expiry);
    [DllImport("secur32.dll", EntryPoint = "AcceptSecurityContext")] static extern int AcceptFirst(
        ref SecHandle credential, IntPtr context, ref SecBufferDesc input, int flags, int representation,
        ref SecHandle result, ref SecBufferDesc output, out int attributes, out long expiry);
    [DllImport("secur32.dll", EntryPoint = "AcceptSecurityContext")] static extern int AcceptNext(
        ref SecHandle credential, ref SecHandle context, ref SecBufferDesc input, int flags, int representation,
        ref SecHandle result, ref SecBufferDesc output, out int attributes, out long expiry);
    [DllImport("secur32.dll")] static extern int QuerySecurityContextToken(ref SecHandle context, ref IntPtr token);
    [DllImport("secur32.dll")] static extern int DeleteSecurityContext(ref SecHandle context);
    [DllImport("secur32.dll")] static extern int FreeCredentialsHandle(ref SecHandle credential);
    [DllImport("secur32.dll")] static extern int FreeContextBuffer(IntPtr buffer);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);

    public readonly TcpListener Listener = new TcpListener(IPAddress.Loopback, 0);
    public string Mode = "static";
    public string[] Responses = new string[0];
    public string Package = "NTLM";
    public bool AdvertiseNegotiate;
    // True: the service plays an origin server (401 / Authorization) instead of a proxy.
    public bool OriginMode;
    // After the proxy accepted the identity, the origin behind it challenges too.
    public bool ChallengeOriginAfterProxy;
    public int TunnelPort;
    // When set, GET /ordered.pac answers this proxy auto-configuration script.
    public string PacScript;
    public X509Certificate2 Certificate;
    public int SlowBodyBytes = 1000000;
    public int HugeBodyBytes = 1048576;
    public byte[] BinaryBody = new byte[0];
    public readonly List<string> Requests = new List<string>();
    public int Connections, Type1, Type3, SpnegoLegs, Authenticated, ProxyAuthorizations, BasicAttempts, OriginAuthorizations;
    public bool IdentityMatched;
    public string Failure = "";
    volatile bool stopping;
    readonly List<TcpClient> clients = new List<TcpClient>();
    readonly object gate = new object();
    Thread acceptor;
    int cursor;

    public int Port { get { return ((IPEndPoint)Listener.LocalEndpoint).Port; } }

    public void Start()
    {
        Listener.Start();
        acceptor = new Thread(Accept);
        acceptor.IsBackground = true;
        acceptor.Start();
    }

    void Accept()
    {
        while (!stopping)
        {
            TcpClient client;
            try { client = Listener.AcceptTcpClient(); } catch (Exception) { return; }
            lock (gate) { clients.Add(client); Connections++; }
            Thread worker = new Thread(delegate() { Serve(client); });
            worker.IsBackground = true;
            worker.Start();
        }
    }

    static string ReadHead(Stream stream)
    {
        MemoryStream bytes = new MemoryStream();
        while (bytes.Length < 65536)
        {
            int value = stream.ReadByte();
            if (value < 0) return null;
            bytes.WriteByte((byte)value);
            if (bytes.Length >= 4)
            {
                byte[] data = bytes.GetBuffer();
                int k = (int)bytes.Length;
                if (data[k - 4] == 13 && data[k - 3] == 10 && data[k - 2] == 13 && data[k - 1] == 10)
                    return Encoding.ASCII.GetString(data, 0, k);
            }
        }
        return null;
    }

    static int ContentLength(string head)
    {
        foreach (string line in head.Split(new string[] { "\r\n" }, StringSplitOptions.None))
            if (line.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase))
                return int.Parse(line.Substring(15).Trim());
        return 0;
    }

    static string Header(string head, string name)
    {
        foreach (string line in head.Split(new string[] { "\r\n" }, StringSplitOptions.None))
            if (line.StartsWith(name + ":", StringComparison.OrdinalIgnoreCase)) return line.Substring(name.Length + 1).Trim();
        return null;
    }

    string Sanitize(string head)
    {
        StringBuilder text = new StringBuilder();
        foreach (string line in head.Split(new string[] { "\r\n" }, StringSplitOptions.None))
        {
            if (line.Length == 0) continue;
            if (line.StartsWith("Proxy-Authorization:", StringComparison.OrdinalIgnoreCase) ||
                line.StartsWith("Authorization:", StringComparison.OrdinalIgnoreCase))
            {
                int colon = line.IndexOf(':');
                string value = line.Substring(colon + 1).Trim();
                int space = value.IndexOf(' ');
                text.Append(line.Substring(0, colon)).Append(": ").Append(space < 0 ? value : value.Substring(0, space)).Append("\r\n");
            }
            else text.Append(line).Append("\r\n");
        }
        return text.ToString();
    }

    void Record(string head)
    {
        lock (gate)
        {
            Requests.Add(Sanitize(head));
            if (Header(head, "Proxy-Authorization") != null) ProxyAuthorizations++;
            string proxyAuth = Header(head, "Proxy-Authorization");
            if (proxyAuth != null && proxyAuth.StartsWith("Basic", StringComparison.OrdinalIgnoreCase)) BasicAttempts++;
            if (Header(head, "Authorization") != null) OriginAuthorizations++;
        }
    }

    static void Write(Stream stream, string text)
    {
        byte[] bytes = Encoding.ASCII.GetBytes(text);
        stream.Write(bytes, 0, bytes.Length);
        stream.Flush();
    }

    void Serve(TcpClient client)
    {
        try
        {
            client.ReceiveTimeout = 15000;
            client.SendTimeout = 15000;
            Stream stream = client.GetStream();
            if (Mode == "tls")
            {
                SslStream tls = new SslStream(stream, false);
                tls.AuthenticateAsServer(Certificate, false, SslProtocols.Tls12, false);
                stream = tls;
                ServeHttp(stream, client);
                return;
            }
            ServeHttp(stream, client);
        }
        catch (Exception) { /* A refused handshake or a closed peer ends this connection only. */ }
    }

    void ServeHttp(Stream stream, TcpClient client)
    {
        SecHandle credential = Invalid(), context = Invalid();
        bool hasCredential = false, hasContext = false;
        try
        {
            while (!stopping)
            {
                string head = ReadHead(stream);
                if (head == null) return;
                int length = ContentLength(head);
                for (int index = 0; index < length; index++) if (stream.ReadByte() < 0) return;
                Record(head);
                if (PacScript != null && head.StartsWith("GET /ordered.pac ", StringComparison.Ordinal))
                {
                    // The proxy auto-configuration file is served to anyone, unauthenticated.
                    byte[] script = Encoding.UTF8.GetBytes(PacScript);
                    Write(stream, "HTTP/1.1 200 OK\r\nConnection: close\r\nCache-Control: no-store\r\nContent-Type: application/x-ns-proxy-autoconfig\r\nContent-Length: " + script.Length + "\r\n\r\n");
                    stream.Write(script, 0, script.Length);
                    stream.Flush();
                    return;
                }
                switch (Mode)
                {
                    case "static":
                    case "tls":
                    case "origin401":
                        {
                            string response;
                            lock (gate) { response = Responses[cursor++ % Responses.Length]; }
                            Write(stream, response);
                            if (response.IndexOf("Connection: close") >= 0) return;
                            break;
                        }
                    case "binary":
                        {
                            Write(stream, "HTTP/1.1 200 OK\r\nContent-Length: " + BinaryBody.Length + "\r\nConnection: close\r\n\r\n");
                            stream.Write(BinaryBody, 0, BinaryBody.Length);
                            stream.Flush();
                            return;
                        }
                    case "hang":
                        Thread.Sleep(60000);
                        return;
                    case "slowbody":
                        Write(stream, "HTTP/1.1 200 OK\r\nContent-Length: " + SlowBodyBytes + "\r\nConnection: close\r\n\r\n");
                        for (int sent = 0; sent < SlowBodyBytes && !stopping; sent++) { stream.WriteByte(65); stream.Flush(); Thread.Sleep(40); }
                        return;
                    case "hugebody":
                        {
                            Write(stream, "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n");
                            byte[] chunk = new byte[16384];
                            for (int index = 0; index < chunk.Length; index++) chunk[index] = 66;
                            for (int sent = 0; sent < HugeBodyBytes; sent += chunk.Length) stream.Write(chunk, 0, chunk.Length);
                            stream.Flush();
                            return;
                        }
                    case "proxy_basic":
                        Write(stream, "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"owned\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                        return;
                    case "connect_deny":
                        Write(stream, "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                        return;
                    case "origin_sspi":
                    case "proxy_sspi":
                        if (!ServeSspi(stream, client, head, ref credential, ref context, ref hasCredential, ref hasContext)) return;
                        break;
                    default:
                        throw new InvalidOperationException("Unknown owned mode.");
                }
            }
        }
        catch (Exception failure)
        {
            if (!stopping && Failure == "") Failure = failure.GetType().Name;
        }
        finally
        {
            if (hasContext) DeleteSecurityContext(ref context);
            if (hasCredential) FreeCredentialsHandle(ref credential);
        }
    }

    static SecHandle Invalid() { return new SecHandle { Lower = new IntPtr(-1), Upper = new IntPtr(-1) }; }

    string Challenge(string token)
    {
        string field = OriginMode ? "WWW-Authenticate: " : "Proxy-Authenticate: ";
        StringBuilder text = new StringBuilder(OriginMode
            ? "HTTP/1.1 401 Unauthorized\r\n" : "HTTP/1.1 407 Proxy Authentication Required\r\n");
        if (token != null) text.Append(field).Append(Package).Append(' ').Append(token).Append("\r\n");
        else
        {
            if (Package == "Negotiate") text.Append(field).Append("Negotiate\r\n");
            text.Append(field).Append("NTLM\r\n");
            if (AdvertiseNegotiate && Package != "Negotiate") text.Append(field).Append("Negotiate\r\n");
        }
        text.Append("Content-Length: 0\r\nConnection: keep-alive\r\n\r\n");
        return text.ToString();
    }

    // Returns false when the connection must end.
    bool ServeSspi(Stream stream, TcpClient client, string head, ref SecHandle credential, ref SecHandle context,
        ref bool hasCredential, ref bool hasContext)
    {
        string authorization = Header(head, OriginMode ? "Authorization" : "Proxy-Authorization");
        if (authorization == null) { Write(stream, Challenge(null)); return true; }
        int space = authorization.IndexOf(' ');
        string scheme = space < 0 ? authorization : authorization.Substring(0, space);
        if (!string.Equals(scheme, Package, StringComparison.OrdinalIgnoreCase) || space < 0)
        {
            // The client chose another scheme than the one this owned proxy accepts.
            lock (gate) { if (Failure == "") Failure = "scheme_" + scheme; }
            Write(stream, Challenge(null));
            return false;
        }
        byte[] token = Convert.FromBase64String(authorization.Substring(space + 1));
        bool complete;
        byte[] output = Accept(ref credential, ref context, ref hasCredential, ref hasContext, token, out complete);
        if (Package == "NTLM")
        {
            int type = token.Length >= 12 ? BitConverter.ToInt32(token, 8) : 0;
            lock (gate) { if (type == 1) Type1++; else if (type == 3) Type3++; }
        }
        else lock (gate) { SpnegoLegs++; }
        if (!complete)
        {
            Write(stream, Challenge(Convert.ToBase64String(output)));
            return true;
        }
        if (!SameUser(ref context)) { lock (gate) { Failure = "identity"; } return false; }
        lock (gate) { Authenticated++; IdentityMatched = true; }
        string target = head.Substring(0, head.IndexOf("\r\n"));
        if (target.StartsWith("CONNECT ", StringComparison.Ordinal))
        {
            Write(stream, "HTTP/1.1 200 Connection established\r\n\r\n");
            Tunnel(stream);
            return false;
        }
        if (ChallengeOriginAfterProxy)
        {
            Write(stream, "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: NTLM\r\nWWW-Authenticate: Negotiate\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            return false;
        }
        string body = OriginMode ? "origin-authenticated" : "proxied-authenticated";
        Write(stream, "HTTP/1.1 200 OK\r\nContent-Length: " + body.Length + "\r\nConnection: close\r\n\r\n" + body);
        return false;
    }

    void Tunnel(Stream client)
    {
        using (TcpClient upstream = new TcpClient())
        {
            upstream.Connect(IPAddress.Loopback, TunnelPort);
            Stream remote = upstream.GetStream();
            Thread reverse = new Thread(delegate()
            {
                try { remote.CopyTo(client); client.Flush(); } catch (Exception) { }
            });
            reverse.IsBackground = true;
            reverse.Start();
            try { client.CopyTo(remote); } catch (Exception) { }
            try { upstream.Client.Shutdown(SocketShutdown.Send); } catch (Exception) { }
            reverse.Join(2000);
        }
    }

    byte[] Accept(ref SecHandle credential, ref SecHandle context, ref bool hasCredential, ref bool hasContext,
        byte[] token, out bool complete)
    {
        IntPtr inputData = IntPtr.Zero, inputBuffer = IntPtr.Zero, outputBuffer = IntPtr.Zero, providerOutput = IntPtr.Zero;
        try
        {
            if (!hasCredential)
            {
                long expiry;
                // SECPKG_CRED_INBOUND: this side accepts the client's token.
                int acquired = AcquireCredentialsHandle(null, Package, 1, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, ref credential, out expiry);
                if (acquired != 0) throw new InvalidOperationException("acquire_credentials");
                hasCredential = true;
            }
            inputData = Marshal.AllocHGlobal(token.Length);
            inputBuffer = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(SecBuffer)));
            outputBuffer = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(SecBuffer)));
            Marshal.Copy(token, 0, inputData, token.Length);
            Marshal.StructureToPtr(new SecBuffer { Size = token.Length, Type = 2, Data = inputData }, inputBuffer, false);
            Marshal.StructureToPtr(new SecBuffer { Size = 0, Type = 2, Data = IntPtr.Zero }, outputBuffer, false);
            SecBufferDesc input = new SecBufferDesc { Version = 0, Count = 1, Buffers = inputBuffer };
            SecBufferDesc output = new SecBufferDesc { Version = 0, Count = 1, Buffers = outputBuffer };
            SecHandle next = Invalid();
            int flags; long contextExpiry;
            int status = hasContext
                ? AcceptNext(ref credential, ref context, ref input, 0x900, 0x10, ref next, ref output, out flags, out contextExpiry)
                : AcceptFirst(ref credential, IntPtr.Zero, ref input, 0x900, 0x10, ref next, ref output, out flags, out contextExpiry);
            SecBuffer produced = (SecBuffer)Marshal.PtrToStructure(outputBuffer, typeof(SecBuffer));
            providerOutput = produced.Data;
            if (next.Lower != new IntPtr(-1) && next.Upper != new IntPtr(-1))
            {
                if (hasContext && (context.Lower != next.Lower || context.Upper != next.Upper)) DeleteSecurityContext(ref context);
                context = next;
                hasContext = true;
            }
            // 0x90312 = SEC_I_CONTINUE_NEEDED; any other non-zero status refuses.
            if (status != 0 && status != 0x90312) throw new InvalidOperationException("accept_context");
            complete = status == 0;
            byte[] result = new byte[produced.Size];
            if (result.Length > 0) Marshal.Copy(providerOutput, result, 0, result.Length);
            return result;
        }
        finally
        {
            if (providerOutput != IntPtr.Zero) FreeContextBuffer(providerOutput);
            if (outputBuffer != IntPtr.Zero) Marshal.FreeHGlobal(outputBuffer);
            if (inputBuffer != IntPtr.Zero) Marshal.FreeHGlobal(inputBuffer);
            if (inputData != IntPtr.Zero) Marshal.FreeHGlobal(inputData);
        }
    }

    static bool SameUser(ref SecHandle context)
    {
        IntPtr token = IntPtr.Zero;
        try
        {
            if (QuerySecurityContextToken(ref context, ref token) != 0 || token == IntPtr.Zero) return false;
            using (WindowsIdentity identity = new WindowsIdentity(token))
            using (WindowsIdentity current = WindowsIdentity.GetCurrent())
                return current.User.Equals(identity.User);
        }
        finally { if (token != IntPtr.Zero) CloseHandle(token); }
    }

    // A self-signed certificate whose root nobody trusts: a verifying client
    // must refuse it. The key container is temporary and dies with the object.
    public static X509Certificate2 NewUntrustedCertificate()
    {
        RSACryptoServiceProvider rsa = new RSACryptoServiceProvider(2048);
        CertificateRequest request = new CertificateRequest("CN=ergopti-winhttp-untrusted", rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        // The name matches the loopback host, so only the missing trust is wrong.
        SubjectAlternativeNameBuilder names = new SubjectAlternativeNameBuilder();
        names.AddIpAddress(IPAddress.Loopback);
        names.AddDnsName("tls-origin.invalid");
        request.CertificateExtensions.Add(names.Build());
        X509Certificate2 self = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-5), DateTimeOffset.UtcNow.AddDays(1));
        byte[] pfx = self.Export(X509ContentType.Pfx, "owned");
        return new X509Certificate2(pfx, "owned");
    }

    public void Dispose()
    {
        stopping = true;
        try { Listener.Stop(); } catch (Exception) { }
        lock (gate) { foreach (TcpClient client in clients) { try { client.Close(); } catch (Exception) { } } }
    }
}
'@ -ErrorAction Stop -ReferencedAssemblies System.Core
}
