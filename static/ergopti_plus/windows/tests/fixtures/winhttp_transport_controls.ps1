# tests/fixtures/winhttp_transport_controls.ps1
# Real WinHTTP against owned loopback services: nothing here touches the internet
# or the machine trust store. TLS success needs a trusted root and therefore
# belongs to the native CA fixtures; this file proves the TLS refusal path with an
# untrusted self-signed certificate. Prints one "CONTROL <name>" line per control
# that held and the final "WINHTTP_TRANSPORT_CONTROLS:<count>" line.
param(
    [Parameter(Mandatory = $true)][string]$TransportPath,
    [Parameter(Mandatory = $true)][string]$SchemaPath
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. $TransportPath

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
    public X509Certificate2 Certificate;
    public int SlowBodyBytes = 1000000;
    public int HugeBodyBytes = 1048576;
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

$Passed = 0
function Require([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ('CONTROL FAILED: ' + $Message) }
}
function Pass([string]$Name) { $script:Passed++; [Console]::Out.WriteLine('CONTROL ' + $Name) }

$Schema = Get-Content -LiteralPath $SchemaPath -Raw -Encoding UTF8 | ConvertFrom-Json
$Work = Join-Path ([IO.Path]::GetTempPath()) ('ergopti_winhttp_controls_' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($Work) | Out-Null
$Servers = New-Object Collections.Generic.List[object]

function New-Server([string]$Mode, [string[]]$Responses = @(), [hashtable]$Properties = @{}) {
    $Server = New-Object ErgoptiWinHttpTestServer
    $Server.Mode = $Mode
    $Server.Responses = $Responses
    foreach ($Name in $Properties.Keys) { $Server.$Name = $Properties[$Name] }
    $Server.Start()
    $Servers.Add($Server)
    return $Server
}

function New-Engine([int]$Budget = 6000, [long]$Max = 1048576, [int]$MaxHeader = 65536, $Headers = @(), [string]$Body = '') {
    $Answer = @{ child_quiesced = $true }
    $Input = [pscustomobject]@{
        started_tick = [ErgoptiWinHttpTransport]::CurrentTick(); deadline_ms = $Budget; connect_timeout_ms = 2000
        max_response_bytes = $Max; max_header_bytes = $MaxHeader
        response_path = (Join-Path $Work 'response.bin'); header_path = (Join-Path $Work 'headers.txt')
        revocation_best_effort = $true; headers = $Headers; body = $Body; user_agent = 'ErgoptiPlus-Controls/1.0'
    }
    return @{ Engine = (New-ErgoptiWinHttpAttemptEngine $Input $Answer); Answer = $Answer; Input = $Input }
}

function Get-Route([string]$Kind, $Server = $null) {
    if ($Kind -ceq 'direct') { return @{ Kind = 'direct'; Endpoint = ''; Authentication = 'none' } }
    return @{ Kind = 'proxy'; Endpoint = ('http://127.0.0.1:' + $Server.Port + '/'); Authentication = 'current_user_proxy_only' }
}

# Every receipt must stay inside the closed inventory of the shared schema.
function Assert-ClosedReceipt([hashtable]$Receipt) {
    foreach ($Key in $Receipt.Keys) {
        $Field = $Schema.fields.PSObject.Properties[$Key]
        Require ($null -ne $Field) ('Receipt field is outside the closed inventory: ' + $Key)
        if ($Field.Value.type -ceq 'string' -and $null -ne $Field.Value.values) {
            Require ($Field.Value.values -ccontains [string]$Receipt[$Key]) ('Receipt value is outside the closed enum: ' + $Key)
        }
        if ($Field.Value.type -ceq 'integer') { Require ($Receipt[$Key] -is [int]) ('Receipt integer expected: ' + $Key) }
    }
}

$Ok200 = "HTTP/1.1 200 OK`r`nContent-Length: 5`r`nX-Test: yes`r`nConnection: close`r`n`r`nhello"
try {
    # --- direct requests ---------------------------------------------------
    $Server = New-Server 'static' @($Ok200)
    $Context = New-Engine -Headers @([pscustomobject]@{ name = 'X-Empty'; value = '' }, [pscustomobject]@{ name = 'Authorization'; value = 'Bearer owned-secret' },
        [pscustomobject]@{ name = 'X-Full'; value = 'v' })
    $Metrics = $Context.Engine.InvokeRoute([Uri]('http://127.0.0.1:' + $Server.Port + '/a/b?c=d%20e'), (Get-Route 'direct'), 'GET', $false, $true)
    Require ($Metrics.completed -and $Metrics.status -eq 200 -and $Metrics.delivered -eq 5 -and $Metrics.child_quiesced) 'Direct GET did not complete with a retired native state.'
    Require ([IO.File]::ReadAllText((Join-Path $Work 'response.bin')) -ceq 'hello') 'Direct GET body bytes changed.'
    Require ($Metrics.headers.headers['x-test'] -ceq 'yes') 'Response headers were not parsed.'
    $Wire = $Server.Requests[0]
    Require ($Wire.StartsWith('GET /a/b?c=d%20e HTTP/1.1')) 'The exact request target was not preserved.'
    Require ($Wire -match '(?m)^X-Empty: ?\r?$') 'An empty header was not sent.'
    Require ($Wire -match '(?m)^Authorization: Bearer') 'The caller header was not sent.'
    Require ($Wire -match '(?m)^User-Agent: ErgoptiPlus-Controls/1.0') 'The caller user agent was not sent.'
    Require ($Context.Engine.ChildQuiesced()) 'The engine did not report quiescence.'
    Pass 'direct_get_exact_target_headers_and_body'

    $Server = New-Server 'static' @("HTTP/1.1 201 Created`r`nContent-Length: 2`r`nConnection: close`r`n`r`nok")
    $Payload = '{"text":"caf' + [char]0xE9 + ' ' + [char]0x20AC + '"}'
    $Context = New-Engine -Headers @([pscustomobject]@{ name = 'Content-Type'; value = 'application/json' }) -Body $Payload
    $Metrics = $Context.Engine.InvokeRoute([Uri]('http://127.0.0.1:' + $Server.Port + '/post'), (Get-Route 'direct'), 'POST', $true, $true)
    Require ($Metrics.completed -and $Metrics.status -eq 201) 'POST did not complete.'
    Require ($Server.Requests[0] -match "Content-Length: $([Text.Encoding]::UTF8.GetByteCount($Payload))") 'POST did not send the exact UTF-8 byte length.'
    Pass 'post_sends_exact_utf8_body_length'

    $Server = New-Server 'static' @("HTTP/1.1 302 Found`r`nLocation: https://elsewhere.invalid/next`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
    $Context = New-Engine
    $Metrics = $Context.Engine.InvokeRoute([Uri]('http://127.0.0.1:' + $Server.Port + '/r'), (Get-Route 'direct'), 'GET', $false, $true)
    Require ($Metrics.completed -and $Metrics.status -eq 302 -and $Metrics.headers.headers['location'] -ceq 'https://elsewhere.invalid/next') 'A redirect was not surfaced untouched.'
    Require ($Server.Requests.Count -eq 1 -and $Server.Connections -eq 1) 'The transport followed a redirect on its own.'
    Pass 'redirects_are_surfaced_never_followed'

    # --- bounds ------------------------------------------------------------
    $Server = New-Server 'static' @("HTTP/1.1 200 OK`r`nContent-Length: 20`r`nConnection: close`r`n`r`n01234567890123456789")
    $Context = New-Engine -Max 10
    $Metrics = $Context.Engine.InvokeRoute([Uri]('http://127.0.0.1:' + $Server.Port + '/'), (Get-Route 'direct'), 'GET', $false, $true)
    Require (-not $Metrics.completed -and $Metrics.failure -ceq 'oversize') 'A declared oversize body was accepted.'
    Pass 'declared_oversize_refused_before_reading'

    $Server = New-Server 'hugebody'
    $Context = New-Engine -Max 100000
    $Metrics = $Context.Engine.InvokeRoute([Uri]('http://127.0.0.1:' + $Server.Port + '/'), (Get-Route 'direct'), 'GET', $false, $true)
    Require (-not $Metrics.completed -and $Metrics.failure -ceq 'oversize' -and $Metrics.child_quiesced) 'An undeclared oversize body was accepted.'
    Require (([IO.FileInfo]::new((Join-Path $Work 'response.bin'))).Length -le 100000) 'Bytes beyond the bound reached the file.'
    Pass 'undeclared_oversize_stops_the_stream_at_the_bound'

    $Server = New-Server 'static' @("HTTP/1.1 200 OK`r`nX-Pad: " + ('x' * 4000) + "`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
    $Context = New-Engine -MaxHeader 1024
    $Metrics = $Context.Engine.InvokeRoute([Uri]('http://127.0.0.1:' + $Server.Port + '/'), (Get-Route 'direct'), 'GET', $false, $true)
    Require (-not $Metrics.completed -and $Metrics.failure -ceq 'oversize') 'Oversized response headers were accepted.'
    Pass 'oversized_headers_refused'

    # --- budget and cancellation -------------------------------------------
    $Server = New-Server 'hang'
    $Context = New-Engine -Budget 1800
    $Clock = [Diagnostics.Stopwatch]::StartNew()
    $Metrics = $Context.Engine.InvokeRoute([Uri]('http://127.0.0.1:' + $Server.Port + '/'), (Get-Route 'direct'), 'GET', $false, $true)
    Require (-not $Metrics.completed -and $Metrics.failure -ceq 'deadline' -and $Metrics.child_quiesced) 'A silent server did not end at the deadline with retired handles.'
    Require ($Clock.ElapsedMilliseconds -lt 2600) 'The deadline was not enforced inside the original budget.'
    Pass 'silent_server_ends_at_the_deadline_with_retired_handles'

    $Server = New-Server 'slowbody'
    $Context = New-Engine -Budget 1800
    $Clock = [Diagnostics.Stopwatch]::StartNew()
    $Metrics = $Context.Engine.InvokeRoute([Uri]('http://127.0.0.1:' + $Server.Port + '/'), (Get-Route 'direct'), 'GET', $false, $true)
    Require (-not $Metrics.completed -and $Metrics.failure -ceq 'deadline' -and $Metrics.child_quiesced) 'A slow body was not cancelled at the deadline.'
    Require ($Clock.ElapsedMilliseconds -lt 2600) 'A slow body outlived the original budget.'
    Pass 'slow_body_is_cancelled_at_the_deadline'

    # --- failure classification --------------------------------------------
    $Listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $Listener.Start(); $ClosedPort = $Listener.LocalEndpoint.Port; $Listener.Stop()
    $Context = New-Engine
    $Metrics = $Context.Engine.InvokeRoute([Uri]('http://127.0.0.1:' + $ClosedPort + '/'), (Get-Route 'direct'), 'GET', $false, $true)
    Require (-not $Metrics.completed -and $Metrics.failure -ceq 'connect' -and $Metrics.native_error -eq 12029) 'A refused direct connection was misclassified.'
    $Receipt = $Context.Engine.GetFailureReceipt($Metrics, [Uri]('http://127.0.0.1:' + $ClosedPort + '/'))
    Assert-ClosedReceipt $Receipt
    Require ($Receipt.backend -ceq 'winhttp' -and $Receipt.stage -ceq 'connect' -and $Receipt.native_errno_domain -ceq 'win32' -and $Receipt.native_errno -ceq '12029') 'The direct connect receipt changed.'
    Require (-not $Context.Engine.TestFailover($Metrics, (Get-Route 'direct'))) 'A direct failure was offered as a proxy failover.'
    Pass 'refused_direct_connection_has_a_closed_receipt_and_no_failover'

    $DeadRoute = @{ Kind = 'proxy'; Endpoint = ('http://127.0.0.1:' + $ClosedPort + '/'); Authentication = 'current_user_proxy_only' }
    $Metrics = $Context.Engine.InvokeRoute([Uri]'http://origin.invalid/x', $DeadRoute, 'GET', $false, $true)
    Require (-not $Metrics.completed -and $Metrics.failure -ceq 'proxy_connect' -and $Metrics.proxy_used) 'A refused proxy was misclassified.'
    Require ($Context.Engine.TestFailover($Metrics, $DeadRoute)) 'A refused proxy before any byte must allow the next route.'
    $Metrics.delivered = 3
    Require (-not $Context.Engine.TestFailover($Metrics, $DeadRoute)) 'Failover was allowed after bytes moved.'
    Pass 'refused_proxy_before_any_byte_allows_ordered_failover'

    $UnresolvedRoute = @{ Kind = 'proxy'; Endpoint = 'http://no-such-proxy.invalid:3128/'; Authentication = 'current_user_proxy_only' }
    $Metrics = $Context.Engine.InvokeRoute([Uri]'http://origin.invalid/x', $UnresolvedRoute, 'GET', $false, $true)
    Require (-not $Metrics.completed -and $Metrics.failure -ceq 'proxy_name_resolution') 'An unresolvable proxy was misclassified.'
    Require ($Context.Engine.TestFailover($Metrics, $UnresolvedRoute)) 'An unresolvable proxy must allow the next route.'
    $Receipt = $Context.Engine.GetFailureReceipt($Metrics, [Uri]'http://origin.invalid/x')
    Assert-ClosedReceipt $Receipt
    Require ($Receipt.stage -ceq 'proxy_resolve' -and $Receipt.proxy_resolution_status -ceq 'unavailable') 'The proxy resolution receipt changed.'
    Pass 'unresolvable_proxy_has_a_closed_receipt_and_allows_failover'

    $Metrics = $Context.Engine.InvokeRoute([Uri]'http://no-such-origin.invalid/x', (Get-Route 'direct'), 'GET', $false, $true)
    Require (-not $Metrics.completed -and $Metrics.failure -ceq 'connect' -and $Metrics.native_error -eq 12007 -and -not $Context.Engine.TestFailover($Metrics, (Get-Route 'direct'))) 'An unresolvable origin was misclassified.'
    Pass 'unresolvable_origin_is_a_connect_failure'

    # --- proxy authentication ----------------------------------------------
    $Basic = New-Server 'proxy_basic'
    $Context = New-Engine
    $Route = Get-Route 'proxy' $Basic
    $Metrics = $Context.Engine.InvokeRoute([Uri]'http://origin.invalid/x', $Route, 'GET', $false, $true)
    Require ($Metrics.completed -and $Metrics.status -eq 407 -and $Metrics.proxy_answered) 'A Basic-only proxy was not left unanswered.'
    Require ($Basic.ProxyAuthorizations -eq 0 -and $Basic.BasicAttempts -eq 0) 'Credentials were sent to a Basic-only proxy.'
    $Receipt = $Context.Engine.GetFailureReceipt($Metrics, [Uri]'http://origin.invalid/x')
    Assert-ClosedReceipt $Receipt
    Require ($Receipt.stage -ceq 'http' -and $Receipt.http_status -eq 407 -and $Receipt.http_response_source -ceq 'proxy' -and $Receipt.proxy_mode -ceq 'selected') 'The proxy-407 receipt changed.'
    Pass 'basic_only_proxy_gets_no_credentials'

    $Origin = New-Server 'origin_sspi' @() @{ Package = 'NTLM'; OriginMode = $true; AdvertiseNegotiate = $true }
    $Context = New-Engine
    $Metrics = $Context.Engine.InvokeRoute([Uri]('http://127.0.0.1:' + $Origin.Port + '/secret'), (Get-Route 'direct'), 'GET', $false, $true)
    Require ($Metrics.completed -and $Metrics.status -eq 401) 'A direct origin 401 was not returned as is.'
    Require ($Origin.OriginAuthorizations -eq 0 -and $Origin.Requests.Count -eq 1 -and $Origin.Type1 -eq 0 -and $Origin.Authenticated -eq 0) `
        ('A direct origin challenge was answered. authorizations=' + $Origin.OriginAuthorizations + ' requests=' + $Origin.Requests.Count)
    Pass 'direct_origin_challenge_is_never_answered'

    $Behind = New-Server 'proxy_sspi' @() @{ Package = 'NTLM'; ChallengeOriginAfterProxy = $true }
    $Context = New-Engine
    $Metrics = $Context.Engine.InvokeRoute([Uri]'http://origin.invalid/secret', (Get-Route 'proxy' $Behind), 'GET', $false, $true)
    Require ($Metrics.completed -and $Metrics.status -eq 401) 'The origin 401 behind an authenticated proxy was not returned as is.'
    Require ($Behind.Authenticated -eq 1 -and $Behind.OriginAuthorizations -eq 0) `
        ('The user identity reached the origin behind the proxy. authorizations=' + $Behind.OriginAuthorizations + ' wire=' + ($Behind.Requests -join '|'))
    Pass 'origin_challenge_behind_an_authenticated_proxy_is_never_answered'

    $Ntlm = New-Server 'proxy_sspi' @() @{ Package = 'NTLM' }
    $Context = New-Engine
    $Route = Get-Route 'proxy' $Ntlm
    $Metrics = $Context.Engine.InvokeRoute([Uri]'http://origin.invalid/x', $Route, 'GET', $false, $true)
    Require ($Metrics.completed -and $Metrics.status -eq 200) 'An NTLM-only proxy was not authenticated with the current user.'
    Require ([IO.File]::ReadAllText((Join-Path $Work 'response.bin')) -ceq 'proxied-authenticated') 'The authenticated NTLM response body changed.'
    Require ($Ntlm.Type1 -eq 1 -and $Ntlm.Type3 -eq 1 -and $Ntlm.Authenticated -eq 1 -and $Ntlm.IdentityMatched -and $Ntlm.Failure -ceq '') 'The NTLM exchange was not one Type1, one Type3 for the current user.'
    Pass 'ntlm_only_proxy_authenticates_the_current_user_over_winhttp'

    $Spnego = New-Server 'proxy_sspi' @() @{ Package = 'Negotiate'; AdvertiseNegotiate = $true }
    $Context = New-Engine
    $Route = Get-Route 'proxy' $Spnego
    $Metrics = $Context.Engine.InvokeRoute([Uri]'http://origin.invalid/x', $Route, 'GET', $false, $true)
    Require ($Metrics.completed -and $Metrics.status -eq 200) 'A Negotiate proxy was not authenticated with the current user.'
    Require ($Spnego.Authenticated -eq 1 -and $Spnego.IdentityMatched -and $Spnego.Failure -ceq '') 'The Negotiate exchange did not authenticate the current user.'
    Pass 'negotiate_proxy_authenticates_the_current_user_over_winhttp'

    # --- TLS through an authenticating proxy --------------------------------
    $Certificate = [ErgoptiWinHttpTestServer]::NewUntrustedCertificate()
    $Tls = New-Server 'tls' @($Ok200) @{ Certificate = $Certificate }
    $Context = New-Engine
    $TlsUrl = [Uri]('https://127.0.0.1:' + $Tls.Port + '/secure')
    $Metrics = $Context.Engine.InvokeRoute($TlsUrl, (Get-Route 'direct'), 'GET', $false, $true)
    Require (-not $Metrics.completed -and $Metrics.failure -ceq 'tls' -and $Metrics.tls_status -ceq 'untrusted_certificate' -and $Metrics.child_quiesced) ('An untrusted certificate was not refused as untrusted. ' + ($Metrics | ConvertTo-Json -Compress -Depth 3) + ' flags=' + $Tls.Failure)
    Require ($Tls.Requests.Count -eq 0) 'An untrusted certificate reached the HTTP handler.'
    $Receipt = $Context.Engine.GetFailureReceipt($Metrics, $TlsUrl)
    Assert-ClosedReceipt $Receipt
    Require ($Receipt.stage -ceq 'tls' -and $Receipt.tls_verification -ceq 'enforced' -and $Receipt.tls_status -ceq 'untrusted_certificate' -and $Receipt.failure_provenance -ceq 'verified') 'The certificate receipt changed.'
    Pass 'untrusted_certificate_is_refused_with_a_closed_receipt'

    # WinHTTP never proxies a loopback address, so the tunnel targets a name; the
    # owned proxy ignores it and tunnels every CONNECT to the owned TLS service.
    $NamedTlsUrl = [Uri]('https://tls-origin.invalid:' + $Tls.Port + '/secure')
    $Tunnel = New-Server 'proxy_sspi' @() @{ Package = 'NTLM'; TunnelPort = $Tls.Port }
    $Route = Get-Route 'proxy' $Tunnel
    $Metrics = $Context.Engine.InvokeRoute($NamedTlsUrl, $Route, 'GET', $false, $true)
    Require ($Tunnel.Authenticated -eq 1 -and $Tunnel.IdentityMatched -and $Tunnel.Type1 -eq 1 -and $Tunnel.Type3 -eq 1) 'The CONNECT tunnel was not authenticated with the current user.'
    Require (-not $Metrics.completed -and $Metrics.failure -ceq 'tls' -and $Metrics.tls_status -ceq 'untrusted_certificate') 'The certificate was not verified inside the authenticated tunnel.'
    Require ($Tls.Requests.Count -eq 0) 'An untrusted certificate reached the HTTP handler through the tunnel.'
    Pass 'connect_tunnel_authenticates_then_still_verifies_the_certificate'

    $Deny = New-Server 'connect_deny'
    $Route = Get-Route 'proxy' $Deny
    $Metrics = $Context.Engine.InvokeRoute($NamedTlsUrl, $Route, 'GET', $false, $true)
    Require ($Metrics.completed -and $Metrics.status -eq 403 -and $Metrics.proxy_answered) 'A refused CONNECT was not attributed to the proxy.'
    $Receipt = $Context.Engine.GetFailureReceipt($Metrics, $NamedTlsUrl)
    Assert-ClosedReceipt $Receipt
    Require ($Receipt.stage -ceq 'proxy_connect' -and $Receipt.proxy_connect_status -eq 403 -and $Receipt.http_response_source -ceq 'proxy') 'The CONNECT refusal receipt changed.'
    Pass 'connect_refusal_is_attributed_to_the_proxy'

    # --- capability --------------------------------------------------------
    $Capability = (New-Engine).Engine.ObserveCapability()
    Require ($Capability.tls_backend -ceq 'schannel' -and $Capability.sspi -and $Capability.spnego -and $Capability.ntlm) 'The observed capability does not list the integrated schemes.'
    Pass 'capability_is_observed_from_the_installed_providers'

    [Console]::Out.WriteLine('WINHTTP_TRANSPORT_CONTROLS:' + $Passed)
} finally {
    foreach ($Server in $Servers) { $Server.Dispose() }
    try { [IO.Directory]::Delete($Work, $true) } catch { }
}
