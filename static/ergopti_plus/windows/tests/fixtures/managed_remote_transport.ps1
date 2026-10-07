# tests/fixtures/managed_remote_transport.ps1
# One owned fixture supplies native TLS, revocation, fixed proxy and PAC services.
param(
    [Parameter(Mandatory = $true)][string]$StatePath,
    [Parameter(Mandatory = $true)][string]$EventPrefix,
    [ValidateSet('Serve', 'ServeUpdater', 'Cleanup')][string]$Mode = 'Serve',
    [string]$OwnedRootThumbprint = '',
    [string]$OwnedRootSubject = ''
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
function Remove-OwnedRoot([string]$Thumbprint, [string]$Subject) {
    if ($Thumbprint -cnotmatch '^[0-9A-F]{40}$' -or $Subject -cnotmatch '^CN=ErgoptiPlus managed-network fixture [0-9a-f]{32}$') {
        throw 'Invalid owned certificate identity.'
    }
    $Store = [Security.Cryptography.X509Certificates.X509Store]::new('Root', 'CurrentUser')
    try {
        $Store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        $Found = @($Store.Certificates | Where-Object { $_.Thumbprint -ceq $Thumbprint })
        if ($Found.Count -gt 1) { throw 'Ambiguous owned certificate identity.' }
        foreach ($Certificate in $Found) {
            if ($Certificate.Subject -cne $Subject) { throw 'Owned certificate subject changed.' }
            $Store.Remove($Certificate)
        }
    } finally { $Store.Close() }
    $Store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
    try {
        if (@($Store.Certificates | Where-Object { $_.Thumbprint -ceq $Thumbprint }).Count -ne 0) {
            throw 'Owned current-user root removal was not acknowledged.'
        }
    } finally { $Store.Close(); $Store.Dispose() }
}
if ($Mode -ceq 'Cleanup') {
    try {
        Remove-OwnedRoot $OwnedRootThumbprint $OwnedRootSubject
        [Console]::Out.WriteLine('OWNED_ROOT_REMOVED')
        exit 0
    } catch {
        [Console]::Out.WriteLine('OWNED_ROOT_REMOVAL_REFUSED')
        exit 1
    }
}
$Fixture = $null
$Events = @()
$RootInstalled = $false
$State = @{ version = 1; state = 'starting'; phase = 'untrusted'; sequence = 0; root_removed = $false; service_stopped = $false }
function Publish-State {
    try {
    if ($null -ne $Fixture) {
        $Fact = $Fixture.ReadServiceFailure()
        if ($Fact.Stage -cne 'none') {
            $State.service_failure_stage = $Fact.Stage
            $State.service_failure_kind = $Fact.Kind
            $State.service_failure_hresult = $Fact.HResult
        }
    }
    } catch { } # Observation cannot suppress the original state write.
    $State.sequence++
    [IO.File]::WriteAllText($StatePath, ($State | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
}
try {
    if ($EventPrefix -cnotmatch '^Local\\ErgoptiPlus\.ManagedNetworkFixture\.[0-9a-f]{32}$') {
        throw 'Invalid owned fixture event prefix.'
    }
    $CurlPath = Join-Path $env:WINDIR 'System32\curl.exe'
    $CurlVersion = & $CurlPath --version
    if ($LASTEXITCODE -ne 0 -or (($CurlVersion -join "`n") -notmatch '\bSchannel\b')) {
        throw 'The actual shipped curl does not use Schannel.'
    }
    $State.curl_schannel = $true
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Threading;

public sealed class ErgoptiManagedRemoteFixture : IDisposable
{
    private readonly List<TcpListener> listeners = new List<TcpListener>();
    private readonly List<Thread> listenersThreads = new List<Thread>();
    private readonly List<Thread> workers = new List<Thread>();
    private readonly List<TcpClient> clients = new List<TcpClient>();
    private readonly object gate = new object();
    // Closed first-failure facts only; the original counters and catches retain ownership.
    private readonly object diagnosticGate = new object();
    public sealed class FailureFact
    {
        public string Stage = "none";
        public string Kind = "none";
        public int HResult;
    }
    private FailureFact firstFailure = new FailureFact();
    private void CaptureServiceFailure(string stage, Exception failure)
    {
        try {
        lock (diagnosticGate) {
            if (firstFailure.Stage != "none") return;
            string kind = "other";
            if (failure is SocketException) kind = "socket";
            else if (failure is System.ComponentModel.Win32Exception) kind = "win32";
            else if (failure is System.Security.Authentication.AuthenticationException) kind = "authentication";
            else if (failure is InvalidDataException) kind = "invalid_data";
            else if (failure is IOException) kind = "io";
            else if (failure is ObjectDisposedException) kind = "disposed";
            else if (failure is InvalidOperationException) kind = "invalid_operation";
            firstFailure = new FailureFact { Stage = stage, Kind = kind, HResult = failure.HResult };
        }
        } catch (Exception) { } // Observation must not replace the original counter or rethrow.
    }
    public FailureFact ReadServiceFailure()
    {
        lock (diagnosticGate) return new FailureFact {
            Stage = firstFailure.Stage, Kind = firstFailure.Kind, HResult = firstFailure.HResult };
    }
    private volatile bool stopping;
    private readonly RSA rootKey;
    private readonly RSA leafKey;
    public readonly X509Certificate2 Root;
    private readonly X509Certificate2 leaf;
    private readonly byte[] crl;
    public readonly int TlsPort;
    public readonly int ProxyPort;
    public readonly int HttpPort;
    public int Requests;
    public int Generations;
    public int ReadyRequests;
    public int ProxyConnects;
    public int PacRequests;
    public int CrlRequests;
    public int FailedTls;
    public int ServiceFailures;
    public int ClosedConnections;
    public readonly int SecondProxyPort;
    public readonly int RefusalProxyPort;
    private readonly bool updater;
    public int DownloadRequests;
    public int DownloadRedirects;
    public int DownloadGood;
    public int DownloadOrigin401;
    public int DownloadOrigin403;
    public int DownloadSmall;
    public int DownloadWrongDigest;
    public int DownloadTruncated;
    public int DownloadSlow;
    public int DownloadCredentials;
    public int SecondProxyConnects;
    public int ProxyRefusals;
    public int BasicCredentials;

    public ErgoptiManagedRemoteFixture(string identity) : this(identity, false) { }
    public ErgoptiManagedRemoteFixture(string identity, bool enableUpdater)
    {
        updater = enableUpdater;
        TcpListener tls = Listen(IPAddress.Loopback);
        TcpListener proxy = Listen(IPAddress.Loopback);
        TcpListener http = Listen(IPAddress.Loopback);
        TlsPort = ((IPEndPoint)tls.LocalEndpoint).Port;
        ProxyPort = ((IPEndPoint)proxy.LocalEndpoint).Port;
        HttpPort = ((IPEndPoint)http.LocalEndpoint).Port;
        rootKey = new RSACng(2048);
        leafKey = new RSACng(2048);
        if (!((RSACng)rootKey).Key.IsEphemeral || !((RSACng)leafKey).Key.IsEphemeral)
            throw new InvalidOperationException("Fixture key lifetime must remain process owned.");
        CertificateRequest rootRequest = new CertificateRequest(
            "CN=ErgoptiPlus managed-network fixture " + identity,
            rootKey, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        rootRequest.CertificateExtensions.Add(new X509BasicConstraintsExtension(true, false, 0, true));
        rootRequest.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.KeyCertSign | X509KeyUsageFlags.CrlSign, true));
        rootRequest.CertificateExtensions.Add(new X509SubjectKeyIdentifierExtension(rootRequest.PublicKey, false));
        DateTimeOffset from = DateTimeOffset.UtcNow.AddMinutes(-5);
        DateTimeOffset until = DateTimeOffset.UtcNow.AddDays(1);
        Root = rootRequest.CreateSelfSigned(from, until);
        CertificateRequest leafRequest = new CertificateRequest("CN=managed-fixture.invalid", leafKey,
            HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        leafRequest.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
        leafRequest.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.KeyEncipherment, true));
        OidCollection usages = new OidCollection(); usages.Add(new Oid("1.3.6.1.5.5.7.3.1"));
        leafRequest.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(usages, true));
        // Reserved DNS name reaches only this owned CONNECT relay, without hosts changes.
        leafRequest.CertificateExtensions.Add(new X509Extension("2.5.29.17",
            Sequence(Tag(0x82, Encoding.ASCII.GetBytes("managed-fixture.invalid"))), false));
        string crlUrl = "http://127.0.0.1:" + HttpPort + "/fixture.crl";
        byte[] distribution = Sequence(Sequence(Tag(0xa0, Tag(0xa0, Tag(0x86, Encoding.ASCII.GetBytes(crlUrl))))));
        leafRequest.CertificateExtensions.Add(new X509Extension("2.5.29.31", distribution, false));
        byte[] serial = new byte[16]; using (RandomNumberGenerator random = RandomNumberGenerator.Create()) random.GetBytes(serial);
        serial[0] &= 0x7f; serial[15] |= 1;
        using (X509Certificate2 issued = leafRequest.Create(Root, from, until, serial))
            leaf = RSACertificateExtensions.CopyWithPrivateKey(issued, leafKey);
        crl = CreateCrl(Root.SubjectName.RawData, rootKey);
        Start(tls, Tls);
        Start(proxy, Proxy);
        Start(http, Http);
        if (updater) {
            TcpListener second = Listen(IPAddress.Loopback);
            TcpListener refusal = Listen(IPAddress.Loopback);
            SecondProxyPort = ((IPEndPoint)second.LocalEndpoint).Port;
            RefusalProxyPort = ((IPEndPoint)refusal.LocalEndpoint).Port;
            Start(second, SecondProxy);
            Start(refusal, RefusalProxy);
        }
    }

    private TcpListener Listen(IPAddress address)
    {
        TcpListener listener = new TcpListener(address, 0); listener.Start(); listeners.Add(listener); return listener;
    }
    private void Start(TcpListener listener, Action<TcpClient> serve)
    {
        Thread accept = new Thread(() => {
            while (!stopping) {
                try {
                    TcpClient client = listener.AcceptTcpClient(); client.ReceiveTimeout = 5000; client.SendTimeout = 5000;
                    Thread worker = new Thread(() => {
                        try { serve(client); }
                        catch (IOException) { Interlocked.Increment(ref ClosedConnections); }
                        catch (SocketException) { Interlocked.Increment(ref ClosedConnections); }
                        catch (ObjectDisposedException) { Interlocked.Increment(ref ClosedConnections); }
                        catch (Exception failure) { CaptureServiceFailure("service_request", failure); Interlocked.Increment(ref ServiceFailures); }
                        finally { client.Close(); lock (gate) clients.Remove(client); }
                    });
                    worker.IsBackground = true;
                    lock (gate) { clients.Add(client); workers.Add(worker); }
                    worker.Start();
                } catch (SocketException failure) { if (!stopping) { CaptureServiceFailure("listener_accept", failure); Interlocked.Increment(ref ServiceFailures); } return; }
                catch (ObjectDisposedException failure) { if (!stopping) { CaptureServiceFailure("listener_accept", failure); Interlocked.Increment(ref ServiceFailures); } return; }
            }
        });
        accept.IsBackground = true; listenersThreads.Add(accept); accept.Start();
    }
    private static string Header(Stream stream)
    {
        StringBuilder result = new StringBuilder();
        while (result.Length < 16384) {
            int one = stream.ReadByte(); if (one < 0) throw new EndOfStreamException();
            result.Append((char)one); if (result.ToString().EndsWith("\r\n\r\n", StringComparison.Ordinal)) return result.ToString();
        }
        throw new InvalidDataException("Fixture header ceiling exceeded.");
    }
    private static void Reply(Stream stream, string type, byte[] body)
    {
        byte[] headers = Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nConnection: close\r\nCache-Control: no-store\r\nContent-Type: " + type + "\r\nContent-Length: " + body.Length + "\r\n\r\n");
        stream.Write(headers, 0, headers.Length); stream.Write(body, 0, body.Length); stream.Flush();
    }
    private void Tls(TcpClient client)
    {
        using (SslStream tls = new SslStream(client.GetStream(), false)) {
            try { tls.AuthenticateAsServer(leaf, false, System.Security.Authentication.SslProtocols.Tls12, true); }
            catch (System.Security.Authentication.AuthenticationException) { Interlocked.Increment(ref FailedTls); return; }
            catch (IOException) { Interlocked.Increment(ref FailedTls); return; }
            catch (Exception failure) { CaptureServiceFailure("tls_authenticate", failure); throw; }
            string header = Header(tls);
            string first = header.Split('\n')[0].Trim();
            if (updater && first.StartsWith("GET /updater/", StringComparison.Ordinal)) {
                Download(tls, header, first); return;
            }
            if (header.IndexOf("Authorization: Bearer managed-network-fixture-token\r\n", StringComparison.OrdinalIgnoreCase) < 0)
                throw new InvalidDataException("Actual production auth header absent.");
            Interlocked.Increment(ref Requests);
            if (first == "GET /v1/models HTTP/1.1") {
                Interlocked.Increment(ref ReadyRequests);
                Reply(tls, "application/json", Encoding.UTF8.GetBytes("{\"data\":[{\"id\":\"fixture\"}]}"));
                return;
            }
            if (first != "POST /v1/chat/completions?marker=managed-network-fixture HTTP/1.1")
                throw new InvalidDataException("Actual production destination mismatch.");
            int length = -1;
            foreach (string line in header.Split('\n')) if (line.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase)) length = Int32.Parse(line.Substring(15).Trim(), CultureInfo.InvariantCulture);
            if (length < 1 || length > 16384) throw new InvalidDataException("Actual production payload absent.");
            byte[] body = new byte[length]; int offset = 0;
            while (offset < length) { int read = tls.Read(body, offset, length-offset); if (read < 1) throw new EndOfStreamException(); offset += read; }
            if (Encoding.UTF8.GetString(body) != "{\"messages\":[],\"stream\":false}") throw new InvalidDataException("Actual production payload mismatch.");
            Interlocked.Increment(ref Generations);
            Reply(tls, "application/json", Encoding.UTF8.GetBytes("{\"choices\":[{\"message\":{\"content\":\"managed-network-ok\"}}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1,\"total_tokens\":2}}"));
        }
    }
    private void Proxy(TcpClient client)
    {
        NetworkStream source = client.GetStream(); string first = Header(source).Split('\n')[0].Trim();
        if (first != "CONNECT managed-fixture.invalid:" + TlsPort + " HTTP/1.1") throw new InvalidDataException("Proxy destination escaped fixture.");
        using (TcpClient destination = new TcpClient()) {
            lock (gate) clients.Add(destination);
            try {
                destination.Connect(IPAddress.Loopback, TlsPort);
                Interlocked.Increment(ref ProxyConnects);
                byte[] accepted = Encoding.ASCII.GetBytes("HTTP/1.1 200 Connection established\r\n\r\n"); source.Write(accepted, 0, accepted.Length);
                NetworkStream target = destination.GetStream();
                Thread inbound = new Thread(() => {
                    try { source.CopyTo(target); }
                    catch (IOException) { Interlocked.Increment(ref ClosedConnections); }
                    catch (ObjectDisposedException) { Interlocked.Increment(ref ClosedConnections); }
                    catch (Exception failure) { CaptureServiceFailure("tunnel_pump", failure); Interlocked.Increment(ref ServiceFailures); }
                    finally { destination.Close(); }
                });
                inbound.IsBackground = true; lock (gate) workers.Add(inbound); inbound.Start();
                try { target.CopyTo(source); } finally { client.Close(); destination.Close(); }
                if (!inbound.Join(3000)) throw new InvalidOperationException("Owned tunnel pump did not settle.");
            } finally { lock (gate) clients.Remove(destination); }
        }
    }

    // Independent fixture bytes: 0..255 repeated 2048 times (524288 bytes).
    // The controller's digest is a fixed external expectation, never obtained
    // from a worker-generated file or receipt.
    private static byte[] DownloadBytes()
    {
        byte[] bytes = new byte[524288];
        for (int i = 0; i < bytes.Length; i++) bytes[i] = (byte)(i % 256);
        return bytes;
    }
    private void Download(SslStream tls, string header, string first)
    {
        Interlocked.Increment(ref DownloadRequests);
        if (header.IndexOf("\r\nAuthorization:", StringComparison.OrdinalIgnoreCase) >= 0 ||
            header.IndexOf("\r\nProxy-Authorization:", StringComparison.OrdinalIgnoreCase) >= 0) {
            Interlocked.Increment(ref DownloadCredentials);
            throw new InvalidDataException("Updater origin received credentials.");
        }
        string origin = "https://managed-fixture.invalid:" + TlsPort;
        if (first == "GET /updater/start HTTP/1.1") {
            Interlocked.Increment(ref DownloadRedirects);
            Status(tls, "302 Found", "Location: " + origin + "/updater/good?marker=staging-fixture\r\n", new byte[0], 0);
        } else if (first == "GET /updater/good?marker=staging-fixture HTTP/1.1") {
            Interlocked.Increment(ref DownloadGood); byte[] bytes = DownloadBytes();
            Status(tls, "200 OK", "", bytes, bytes.Length);
        } else if (first == "GET /updater/401 HTTP/1.1") {
            Interlocked.Increment(ref DownloadOrigin401);
            Status(tls, "401 Unauthorized", "WWW-Authenticate: Basic realm=\"owned-origin-refusal\"\r\n", new byte[0], 0);
        } else if (first == "GET /updater/403 HTTP/1.1") {
            Interlocked.Increment(ref DownloadOrigin403);
            Status(tls, "403 Forbidden", "", new byte[0], 0);
        } else if (first == "GET /updater/small HTTP/1.1") {
            Interlocked.Increment(ref DownloadSmall); byte[] bytes = new byte[32];
            Status(tls, "200 OK", "", bytes, bytes.Length);
        } else if (first == "GET /updater/wrong-digest HTTP/1.1") {
            Interlocked.Increment(ref DownloadWrongDigest); byte[] bytes = DownloadBytes(); bytes[0] ^= 1;
            Status(tls, "200 OK", "", bytes, bytes.Length);
        } else if (first == "GET /updater/truncated HTTP/1.1") {
            Interlocked.Increment(ref DownloadTruncated);
            Status(tls, "200 OK", "", new byte[32], 524288);
        } else if (first == "GET /updater/slow HTTP/1.1") {
            Interlocked.Increment(ref DownloadSlow);
            byte[] headerBytes = Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 524288\r\n\r\n");
            tls.Write(headerBytes, 0, headerBytes.Length); tls.Flush();
            byte[] part = new byte[32];
            for (int index = 0; index < 600 && !stopping; index++) {
                tls.Write(part, 0, part.Length); tls.Flush(); Thread.Sleep(100);
            }
        } else { throw new InvalidDataException("Updater destination escaped fixture."); }
    }
    private static void Status(Stream stream, string status, string extra, byte[] body, int declared)
    {
        byte[] header = Encoding.ASCII.GetBytes("HTTP/1.1 " + status + "\r\nConnection: close\r\nCache-Control: no-store\r\nContent-Type: application/octet-stream\r\n" + extra + "Content-Length: " + declared + "\r\n\r\n");
        stream.Write(header, 0, header.Length); stream.Write(body, 0, body.Length); stream.Flush();
    }
    private void SecondProxy(TcpClient client)
    {
        Interlocked.Increment(ref SecondProxyConnects); Proxy(client);
    }
    private void RefusalProxy(TcpClient client)
    {
        NetworkStream stream = client.GetStream(); string header = Header(stream);
        if (header.Split('\n')[0].Trim() != "CONNECT managed-fixture.invalid:" + TlsPort + " HTTP/1.1")
            throw new InvalidDataException("Refusal relay destination escaped fixture.");
        Interlocked.Increment(ref ProxyRefusals);
        if (header.IndexOf("\r\nProxy-Authorization:", StringComparison.OrdinalIgnoreCase) >= 0) {
            Interlocked.Increment(ref BasicCredentials);
            throw new InvalidDataException("Disallowed Basic relay received credentials.");
        }
        Status(stream, "407 Proxy Authentication Required", "Proxy-Authenticate: Basic realm=\"owned-proxy-refusal\"\r\n", new byte[0], 0);
    }

    private void Http(TcpClient client)
    {
        NetworkStream stream = client.GetStream(); string first = Header(stream).Split('\n')[0].Trim();
        if (first == "GET /fixture.crl HTTP/1.1" || first == "GET /fixture.crl HTTP/1.0") {
            Interlocked.Increment(ref CrlRequests); Reply(stream, "application/pkix-crl", crl); return;
        }
        if (updater && (first == "GET /updater.pac HTTP/1.1" || first == "GET /updater.pac HTTP/1.0")) {
            Interlocked.Increment(ref PacRequests);
            string owned = "https://managed-fixture.invalid:" + TlsPort;
            string updaterScript = "function FindProxyForURL(url,host){" +
                "if(url == '" + owned + "/updater/good?marker=staging-fixture') return 'PROXY 127.0.0.1:" + SecondProxyPort + "';" +
                "if(url == '" + owned + "/updater/407') return 'PROXY 127.0.0.1:" + RefusalProxyPort + "';" +
                "if(url == '" + owned + "/updater/slow' || url == '" + owned + "/updater/start' || url == '" + owned + "/updater/401' || url == '" + owned + "/updater/403' || url == '" + owned + "/updater/small' || url == '" + owned + "/updater/wrong-digest' || url == '" + owned + "/updater/truncated') return 'PROXY 127.0.0.1:" + ProxyPort + "';" +
                "return 'PROXY refused.invalid:9';}";
            Reply(stream, "application/x-ns-proxy-autoconfig", Encoding.UTF8.GetBytes(updaterScript)); return;
        }
        if (first != "GET /proxy.pac HTTP/1.1" && first != "GET /proxy.pac HTTP/1.0") throw new InvalidDataException("HTTP fixture destination mismatch.");
        Interlocked.Increment(ref PacRequests);
        string origin = "https://managed-fixture.invalid:" + TlsPort;
        string script = "function FindProxyForURL(url,host){if(url == '" + origin + "/v1/models' || url == '" + origin + "/v1/chat/completions?marker=managed-network-fixture') return 'PROXY 127.0.0.1:" + ProxyPort + "'; return 'PROXY refused.invalid:9';}";
        Reply(stream, "application/x-ns-proxy-autoconfig", Encoding.UTF8.GetBytes(script));
    }
    private static byte[] Tag(byte tag, byte[] data)
    {
        using (MemoryStream outp = new MemoryStream()) {
            outp.WriteByte(tag);
            if (data.Length < 128) outp.WriteByte((byte)data.Length);
            else { List<byte> length = new List<byte>(); int n=data.Length; while(n>0){length.Insert(0,(byte)(n&255));n>>=8;} outp.WriteByte((byte)(0x80|length.Count));outp.Write(length.ToArray(),0,length.Count); }
            outp.Write(data,0,data.Length); return outp.ToArray();
        }
    }
    private static byte[] Sequence(params byte[][] values)
    {
        using (MemoryStream data = new MemoryStream()) { foreach(byte[] value in values)data.Write(value,0,value.Length); return Tag(0x30,data.ToArray()); }
    }
    private static byte[] CreateCrl(byte[] issuer, RSA signer)
    {
        byte[] algorithm = new byte[] {0x30,0x0d,0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x0b,0x05,0x00};
        byte[] tbs = Sequence(new byte[]{0x02,0x01,0x01}, algorithm, issuer,
            Tag(0x17,Encoding.ASCII.GetBytes(DateTime.UtcNow.AddMinutes(-5).ToString("yyMMddHHmmss'Z'",CultureInfo.InvariantCulture))),
            Tag(0x17,Encoding.ASCII.GetBytes(DateTime.UtcNow.AddDays(1).ToString("yyMMddHHmmss'Z'",CultureInfo.InvariantCulture))));
        byte[] signature=signer.SignData(tbs,HashAlgorithmName.SHA256,RSASignaturePadding.Pkcs1);
        byte[] bitString=new byte[signature.Length+1];Buffer.BlockCopy(signature,0,bitString,1,signature.Length);
        return Sequence(tbs,algorithm,Tag(0x03,bitString));
    }
    public void Dispose()
    {
        stopping=true; foreach(TcpListener listener in listeners) listener.Stop();
        lock(gate) foreach(TcpClient client in clients.ToArray()) client.Close();
        foreach(Thread thread in listenersThreads) if(!thread.Join(3000))throw new InvalidOperationException("Owned fixture accept thread did not settle.");
        Thread[] pending;lock(gate)pending=workers.ToArray();
        foreach(Thread thread in pending) if(!thread.Join(3000))throw new InvalidOperationException("Owned fixture worker did not settle.");
        leaf.Dispose();Root.Dispose();leafKey.Dispose();rootKey.Dispose();
    }
}
'@
    $Identity = $EventPrefix.Substring($EventPrefix.LastIndexOf('.') + 1)
    $Fixture = [ErgoptiManagedRemoteFixture]::new($Identity, ($Mode -ceq 'ServeUpdater'))
    $State.root_thumbprint = $Fixture.Root.Thumbprint
    $State.root_subject = $Fixture.Root.Subject
    $State.tls_port = $Fixture.TlsPort
    $State.proxy_port = $Fixture.ProxyPort
    $State.http_port = $Fixture.HttpPort
    if ($Mode -ceq 'ServeUpdater') {
        $State.second_proxy_port = $Fixture.SecondProxyPort
        $State.refusal_proxy_port = $Fixture.RefusalProxyPort
    }
    $State.state = 'ready'
    foreach ($Name in @('InstallRoot', 'RemoveRoot', 'Observe', 'Shutdown')) {
        $Events += [Threading.EventWaitHandle]::OpenExisting($EventPrefix + '.' + $Name)
    }
    Publish-State
    $Deadline = [DateTime]::UtcNow.AddSeconds(90)
    while ([DateTime]::UtcNow -lt $Deadline) {
        $Choice = [Threading.WaitHandle]::WaitAny([Threading.WaitHandle[]]$Events, 1000)
        if ($Choice -eq 0) {
            $Store = [Security.Cryptography.X509Certificates.X509Store]::new('Root', 'CurrentUser')
            try {
                $Store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
                if (@($Store.Certificates | Where-Object { $_.Thumbprint -ceq $State.root_thumbprint }).Count -ne 0) {
                    throw 'Unique owned root already existed before admission.'
                }
                $PublicRoot = [Security.Cryptography.X509Certificates.X509Certificate2]::new($Fixture.Root.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert))
                try { $Store.Add($PublicRoot) } finally { $PublicRoot.Dispose() }
                $RootInstalled = $true
                if (@($Store.Certificates | Where-Object { $_.Thumbprint -ceq $State.root_thumbprint }).Count -ne 1) {
                    throw 'Unique owned root installation was not acknowledged.'
                }
            } finally { $Store.Close(); $Store.Dispose() }
            $State.phase = 'trusted'
        } elseif ($Choice -eq 1) {
            Remove-OwnedRoot $State.root_thumbprint $State.root_subject
            $RootInstalled = $false
            $State.root_removed = $true
            $State.phase = 'removed'
        } elseif ($Choice -eq 3) { break }
        if ($Choice -ne [Threading.WaitHandle]::WaitTimeout) {
            foreach ($Counter in @('Requests','Generations','ReadyRequests','ProxyConnects','PacRequests','CrlRequests','FailedTls','ServiceFailures','ClosedConnections','DownloadRequests','DownloadRedirects','DownloadGood','DownloadOrigin401','DownloadOrigin403','DownloadSmall','DownloadWrongDigest','DownloadTruncated','DownloadSlow','DownloadCredentials','SecondProxyConnects','ProxyRefusals','BasicCredentials')) {
                $State[$Counter] = $Fixture.$Counter
            }
            Publish-State
        }
    }
} catch {
    $State.state = 'failed'
    $State.failure_type = $_.Exception.GetType().Name
    $State.failure_hresult = $_.Exception.HResult
    $State.service_failure_stage = 'fixture_boundary'
    $State.service_failure_kind = 'other'
    $State.service_failure_hresult = $_.Exception.HResult
} finally {
    try {
        if ($null -ne $Fixture) { $Fixture.Dispose(); $State.service_stopped = $true }
        if ($State.ContainsKey('root_thumbprint')) {
            Remove-OwnedRoot $State.root_thumbprint $State.root_subject
            $RootInstalled = $false
            $State.root_removed = $true
        }
    } catch {
        $State.state = 'failed'
        $State.cleanup_refused = $true
        if (-not $State.ContainsKey('service_failure_stage')) {
            $State.service_failure_stage = 'fixture_cleanup'
            $State.service_failure_kind = 'other'
            $State.service_failure_hresult = $_.Exception.HResult
        }
    }
    foreach ($Event in $Events) { $Event.Dispose() }
    if ($State.state -ne 'failed') { $State.state = 'stopped' }
    try { Publish-State } catch { [Console]::Out.WriteLine('OWNED_FIXTURE_STATE_REFUSED'); exit 1 }
}
if ($State.state -eq 'failed' -or -not $State.root_removed -or -not $State.service_stopped) { exit 1 }
[Console]::Out.WriteLine('OWNED_FIXTURE_STOPPED_ROOT_REMOVED')
