# vendor/ergopti_network_routes.ps1
# Closed native routing admission for updater HttpWebRequest transport.
# Shared inventories define portable policy; WinINet formats remain native inputs.
. (Join-Path $PSScriptRoot 'ergopti_windows_proxy_config.ps1')
. (Join-Path $PSScriptRoot 'ergopti_native_proxy_ex.ps1')
. (Join-Path $PSScriptRoot 'ergopti_network_pac.ps1')

function Test-ErgoptiNetworkInt32 {
    param($Value)
    # JSON integer storage may be Int32 or Int64; never coerce other JSON kinds.
    return (($Value -is [int] -or $Value -is [long]) -and
        $Value -ge [int]::MinValue -and $Value -le [int]::MaxValue)
}

function New-ErgoptiRouteRefusal {
    param([string]$Backend = 'winhttp', [string]$Status = 'unavailable',
        [int]$NativeError = 0, [bool]$ObservedNative = $false, [ValidateSet('win32','winsock','posix')][string]$NativeErrorDomain = 'win32')
    $Receipt = @{ backend = $Backend; stage = 'proxy_resolve';
        failure_provenance = $(if ($ObservedNative) { 'verified' } else { 'unknown' });
        proxy_resolution_status = $Status }
    if ($ObservedNative -and $NativeError -ne 0) {
        $Receipt.native_errno_domain = $NativeErrorDomain
        $Receipt.native_errno = [string]$NativeError
    }
    return @{ Ok = $false; Routes = @(); Receipt = $Receipt }
}

# Closed lookup stage of a PAC or WPAD that could not be used; never route text.
function Get-ErgoptiPacFailureStage {
    param($Native)
    if ($Native.Backend -ceq 'winhttp') { return 'native_wpad_discovery' }
    if ($Native.FailureOrigin -ceq 'pac_download') { return 'native_pac_download' }
    if ($Native.FailureOrigin -ceq 'application_budget') { return 'native_proxy_budget' }
    if ($Native.Backend -ceq 'native_socket') { return 'native_pac_evaluation' }
    return 'native_proxy_lookup'
}

# proxy_policy.json pac_unavailable_fallback owns which stages go direct. A PAC
# that answered is a route decision and never reaches this: its list is followed,
# and a relay it names that then fails is not retried direct.
function New-ErgoptiPacDirectFallback {
    param($Policy, [string]$Stage)
    if ($Policy.pac_unavailable_fallback.route -cne 'direct' -or
        $Policy.pac_unavailable_fallback.stages -cnotcontains $Stage) { return $null }
    return @{ Ok = $true; MaxRoutes = $Policy.max_selections; MaxRedirects = $Policy.redirects.max_hops; PacFallbackStage = $Stage;
        Routes = @(@{ Kind = 'direct'; Endpoint = ''; Source = 'pac_unavailable_direct'; Authentication = 'none' }) }
}

function Get-ErgoptiNetworkPolicy {
    param([Parameter(Mandatory=$true)][string]$Path)
    $Policy = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not (Test-ErgoptiNetworkInt32 $Policy.schema_version) -or $Policy.schema_version -ne 1 -or -not (Test-ErgoptiNetworkInt32 $Policy.max_selections) -or
        $Policy.max_selections -lt 1 -or $Policy.max_selections -gt 4096 -or
        -not (Test-ErgoptiNetworkInt32 $Policy.max_proxy_bytes) -or $Policy.max_proxy_bytes -lt 2 -or
        $Policy.max_proxy_bytes -gt 1048576 -or $Policy.missing_native_capability -cne 'environment' -or
        -not (Test-ErgoptiNetworkInt32 $Policy.redirects.max_hops) -or $Policy.redirects.max_hops -lt 1) {
        throw 'Canonical proxy inventory was refused.'
    }
    foreach ($Inventory in @($Policy.allowed_proxy_schemes,
        $Policy.environment_precedence.http, $Policy.environment_precedence.https,
        $Policy.environment_bypass_precedence, $Policy.pac_unavailable_fallback.stages,
        $Policy.loopback.dns_hosts, $Policy.loopback.dns_suffixes,
        $Policy.loopback.ipv4_cidrs, $Policy.loopback.ipv6_addresses)) {
        if ($Inventory -isnot [array] -or $Inventory.Count -eq 0) { throw 'Invalid canonical proxy inventory.' }
        $Seen = [Collections.Generic.Dictionary[string,bool]]::new([StringComparer]::Ordinal)
        foreach ($Name in $Inventory) {
            if ($Name -isnot [string] -or $Name -eq '' -or $Seen.ContainsKey($Name)) {
                throw 'Invalid canonical proxy inventory member.'
            }
            $Seen[$Name] = $true
        }
    }
    return $Policy
}

function Get-ErgoptiDestination {
    param([string]$Url)
    [Uri]$Parsed = $null
    if ($Url -match '[\x00-\x20\x7f]' -or -not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$Parsed) -or
        $Parsed.Scheme -notin @('http', 'https') -or $Parsed.Host -eq '' -or
        $Parsed.UserInfo -ne '' -or $Parsed.Fragment -ne '') { throw 'Private destination was refused.' }
    return $Parsed
}

function Test-ErgoptiAddressRange {
    param([string]$HostName, [string]$Range)
    $Parts = $Range.Split('/')
    if ($Parts.Count -ne 2 -or $Parts[1] -notmatch '^\d+$') { throw 'Canonical address range was refused.' }
    [Net.IPAddress]$Address = $null
    [Net.IPAddress]$Base = $null
    if (-not [Net.IPAddress]::TryParse($Parts[0], [ref]$Base)) { throw 'Canonical address range was refused.' }
    $Bits = [int]$Parts[1]
    $BaseBytes = $Base.GetAddressBytes()
    if ($BaseBytes.Length -eq 4 -and ($Parts[0] -notmatch '^(?:0|[1-9][0-9]{0,2})(?:\.(?:0|[1-9][0-9]{0,2})){3}$' -or
        $Parts[0] -cne $Base.ToString())) { throw 'Canonical numeric address range was refused.' }
    if ($Bits -lt 0 -or $Bits -gt $BaseBytes.Length * 8) { throw 'Canonical address range was refused.' }
    if (-not [Net.IPAddress]::TryParse($HostName, [ref]$Address)) { return $false }
    $AddressBytes = $Address.GetAddressBytes()
    if ($AddressBytes.Length -ne $BaseBytes.Length) { return $false }
    for ($Index = 0; $Index -lt $BaseBytes.Length; $Index++) {
        $Remain = $Bits - $Index * 8
        $Mask = if ($Remain -ge 8) { 255 } elseif ($Remain -le 0) { 0 } else { (255 -shl (8 - $Remain)) -band 255 }
        if (($BaseBytes[$Index] -band $Mask) -ne ($AddressBytes[$Index] -band $Mask)) { return $false }
    }
    return $true
}

function Test-ErgoptiLoopback {
    param([Uri]$Destination, $Policy)
    $HostName = $Destination.DnsSafeHost.Trim('[', ']').TrimEnd('.').ToLowerInvariant()
    if ($Policy.loopback.dns_hosts -contains $HostName) { return $true }
    foreach ($Suffix in $Policy.loopback.dns_suffixes) {
        if ($HostName.Length -gt $Suffix.Length -and $HostName.EndsWith($Suffix, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    foreach ($Range in $Policy.loopback.ipv4_cidrs) {
        if (Test-ErgoptiAddressRange $HostName $Range) { return $true }
    }
    [Net.IPAddress]$Address = $null
    if ([Net.IPAddress]::TryParse($HostName, [ref]$Address)) {
        foreach ($Name in $Policy.loopback.ipv6_addresses) {
            [Net.IPAddress]$Candidate = $null
            if (-not [Net.IPAddress]::TryParse($Name, [ref]$Candidate)) { throw 'Canonical loopback address was refused.' }
            if ($Address.Equals($Candidate)) { return $true }
        }
    }
    return $false
}

function Get-ErgoptiHttpRelay {
    param([string]$Value, $Policy)
    if ($Value -eq '' -or [Text.Encoding]::UTF8.GetByteCount($Value) -gt $Policy.max_proxy_bytes -or
        $Value -match '[\x00-\x20\x7f]') { throw 'Private relay was refused.' }
    if ($Value -notmatch '^[A-Za-z][A-Za-z0-9+.-]*://') { $Value = 'http://' + $Value }
    [Uri]$Proxy = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$Proxy) -or
        $Policy.allowed_proxy_schemes -cnotcontains $Proxy.Scheme -or
        # .NET Framework HttpWebRequest supports this admitted transport only.
        $Proxy.Scheme -cne 'http' -or $Proxy.Host -eq '' -or $Proxy.UserInfo -ne '' -or
        $Proxy.Port -lt 1 -or $Proxy.Port -gt 65535 -or $Proxy.Query -ne '' -or
        $Proxy.Fragment -ne '' -or $Proxy.AbsolutePath -ne '/') { throw 'Private relay capability was refused.' }
    return $Proxy.AbsoluteUri
}

# The owned loopback hop: what lets WinHTTP and HttpWebRequest, which reach a plain
# http relay only, use an https relay, a socks5 relay or credentials in the address.
# The client talks HTTP or CONNECT to 127.0.0.1 in this same process; the hop speaks
# the real relay's protocol, so the client's TLS to the origin stays end to end.
# 1. It lives in this process and dies with it: a worker's request, nothing else.
# 2. It answers only this process (the peer's owner is read from the TCP table): a
#    credentialed relay must not become an open door for the machine.
# 3. Credentials stay in this process's memory. No exception text, receipt or
#    argument carries them; a refusal is one closed status line.
# 4. An https relay is checked like any TLS peer, by the Windows trust store, and
#    nothing in this file can widen that: a test's self-signed relay is trusted by
#    a patched copy of this file in the test's own folder, never by a shipped input.
$script:ErgoptiRelayHopTimeoutMs = 10000
$script:ErgoptiRelayHops = @{}
$script:ErgoptiRelayHopSource = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Authentication;
using System.Text;
using System.Threading;

public sealed class ErgoptiRelayHop {
    private const int HeadLimit = 16384;
    private const int BufferBytes = 65536;
    private const int TcpTableOwnerPidAll = 5;
    private const int AddressFamilyIpv4 = 2;
    private const uint LoopbackAddress = 0x0100007F;
    private const string Refused = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    private const string NotAllowed = "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    private const string Established = "HTTP/1.1 200 Connection established\r\n\r\n";

    private readonly string scheme, relayHost, user, password;
    private readonly int relayPort, timeoutMs;
    private TcpListener listener;

    public int Port { get; private set; }

    public ErgoptiRelayHop(string scheme, string relayHost, int relayPort, string user, string password, int timeoutMs) {
        this.scheme = scheme; this.relayHost = relayHost; this.relayPort = relayPort;
        this.user = user; this.password = password; this.timeoutMs = timeoutMs;
    }

    public void Start() {
        listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        Port = ((IPEndPoint)listener.LocalEndpoint).Port;
        Thread accept = new Thread(AcceptLoop);
        accept.IsBackground = true;
        accept.Start();
    }

    private void AcceptLoop() {
        while (true) {
            TcpClient client;
            try { client = listener.AcceptTcpClient(); } catch (SocketException) { return; } catch (ObjectDisposedException) { return; }
            Thread serve = new Thread(() => Serve(client));
            serve.IsBackground = true;
            serve.Start();
        }
    }

    [DllImport("iphlpapi.dll")]
    private static extern uint GetExtendedTcpTable(IntPtr table, ref int size, bool sorted, int family, int tableClass, int reserved);

    private static int NetworkPort(int value) { return ((value & 0xFF) << 8) | ((value >> 8) & 0xFF); }

    // The row of the peer's own socket names the process that connected.
    private bool PeerIsThisProcess(int peerPort) {
        int size = 0;
        GetExtendedTcpTable(IntPtr.Zero, ref size, false, AddressFamilyIpv4, TcpTableOwnerPidAll, 0);
        IntPtr table = Marshal.AllocHGlobal(size);
        try {
            if (GetExtendedTcpTable(table, ref size, false, AddressFamilyIpv4, TcpTableOwnerPidAll, 0) != 0) return false;
            int rows = Marshal.ReadInt32(table);
            int self = Process.GetCurrentProcess().Id;
            for (int row = 0; row < rows; row++) {
                int offset = 4 + row * 24;
                if ((uint)Marshal.ReadInt32(table, offset + 4) != LoopbackAddress) continue;
                if (NetworkPort(Marshal.ReadInt32(table, offset + 8)) != peerPort) continue;
                if (NetworkPort(Marshal.ReadInt32(table, offset + 16)) != Port) continue;
                return Marshal.ReadInt32(table, offset + 20) == self;
            }
            return false;
        } finally { Marshal.FreeHGlobal(table); }
    }

    private static void Write(Stream stream, string text) {
        byte[] bytes = Encoding.ASCII.GetBytes(text);
        stream.Write(bytes, 0, bytes.Length);
    }

    // One byte at a time: nothing after the head may be consumed.
    private static string ReadHead(Stream stream) {
        StringBuilder head = new StringBuilder();
        while (head.Length < HeadLimit) {
            int value = stream.ReadByte();
            if (value < 0) return null;
            head.Append((char)value);
            int length = head.Length;
            if (length >= 4 && head[length - 4] == '\r' && head[length - 3] == '\n' && head[length - 2] == '\r' && head[length - 1] == '\n')
                return head.ToString();
        }
        return null;
    }

    private static void SplitAuthority(string authority, out string host, out int port) {
        int colon = authority.LastIndexOf(':');
        host = authority.Substring(0, colon).Trim('[', ']');
        port = int.Parse(authority.Substring(colon + 1));
    }

    private bool ConnectThroughHttp(Stream stream, string authority) {
        StringBuilder request = new StringBuilder("CONNECT " + authority + " HTTP/1.1\r\nHost: " + authority + "\r\n");
        if (user != null) {
            string token = Convert.ToBase64String(Encoding.UTF8.GetBytes(user + ":" + password));
            request.Append("Proxy-Authorization: Basic " + token + "\r\n");
        }
        request.Append("\r\n");
        Write(stream, request.ToString());
        string head = ReadHead(stream);
        return head != null && (head.StartsWith("HTTP/1.1 200") || head.StartsWith("HTTP/1.0 200"));
    }

    private static byte[] ReadExact(Stream stream, int count) {
        byte[] data = new byte[count];
        int done = 0;
        while (done < count) {
            int read = stream.Read(data, done, count - done);
            if (read <= 0) throw new IOException("closed");
            done += read;
        }
        return data;
    }

    private static void Send(Stream stream, byte[] data) { stream.Write(data, 0, data.Length); }

    // RFC 1928 with the username method of RFC 1929.
    private bool ConnectThroughSocks(Stream stream, string authority) {
        Send(stream, user != null ? new byte[] { 5, 2, 0, 2 } : new byte[] { 5, 1, 0 });
        byte[] chosen = ReadExact(stream, 2);
        if (chosen[0] != 5) return false;
        if (chosen[1] == 2) {
            if (user == null) return false;
            byte[] name = Encoding.UTF8.GetBytes(user), secret = Encoding.UTF8.GetBytes(password);
            if (name.Length > 255 || secret.Length > 255) return false;
            MemoryStream login = new MemoryStream();
            login.WriteByte(1); login.WriteByte((byte)name.Length); login.Write(name, 0, name.Length);
            login.WriteByte((byte)secret.Length); login.Write(secret, 0, secret.Length);
            Send(stream, login.ToArray());
            if (ReadExact(stream, 2)[1] != 0) return false;
        } else if (chosen[1] != 0) return false;
        string host; int port;
        SplitAuthority(authority, out host, out port);
        MemoryStream request = new MemoryStream();
        request.WriteByte(5); request.WriteByte(1); request.WriteByte(0);
        IPAddress address;
        if (!IPAddress.TryParse(host, out address) && scheme != "socks5h") address = Dns.GetHostAddresses(host)[0];
        if (address != null) {
            byte[] raw = address.GetAddressBytes();
            request.WriteByte(raw.Length == 4 ? (byte)1 : (byte)4);
            request.Write(raw, 0, raw.Length);
        } else {
            byte[] name = Encoding.ASCII.GetBytes(host);
            if (name.Length > 255) return false;
            request.WriteByte(3); request.WriteByte((byte)name.Length); request.Write(name, 0, name.Length);
        }
        request.WriteByte((byte)(port >> 8)); request.WriteByte((byte)(port & 0xFF));
        Send(stream, request.ToArray());
        byte[] reply = ReadExact(stream, 4);
        if (reply[0] != 5 || reply[1] != 0) return false;
        if (reply[3] == 1) ReadExact(stream, 6);
        else if (reply[3] == 4) ReadExact(stream, 18);
        else if (reply[3] == 3) ReadExact(stream, ReadExact(stream, 1)[0] + 2);
        else return false;
        return true;
    }

    // Forward proxies need an absolute-form HTTP target. The hop owns the
    // upstream credential header, so a caller cannot duplicate or replace it.
    private string ForwardHead(string head) {
        StringBuilder request = new StringBuilder();
        foreach (string line in head.Split(new string[] { "\r\n" }, StringSplitOptions.None)) {
            if (line.Length == 0) break;
            if (line.StartsWith("Proxy-Authorization:", StringComparison.OrdinalIgnoreCase)) continue;
            request.Append(line).Append("\r\n");
        }
        if (user != null) {
            string token = Convert.ToBase64String(Encoding.UTF8.GetBytes(user + ":" + password));
            request.Append("Proxy-Authorization: Basic " + token + "\r\n");
        }
        return request.Append("\r\n").ToString();
    }

    private Stream Dial(TcpClient relay, string authority, bool tunnel) {
        IAsyncResult connect = relay.BeginConnect(relayHost, relayPort, null, null);
        if (!connect.AsyncWaitHandle.WaitOne(timeoutMs)) return null;
        relay.EndConnect(connect);
        relay.ReceiveTimeout = timeoutMs;
        relay.SendTimeout = timeoutMs;
        Stream stream = relay.GetStream();
        if (scheme == "https") {
            SslStream secure = new SslStream(stream, false);
            secure.AuthenticateAsClient(relayHost, null, SslProtocols.Tls12, false);
            stream = secure;
        }
        bool open = scheme.StartsWith("socks") ? ConnectThroughSocks(stream, authority) : (!tunnel || ConnectThroughHttp(stream, authority));
        if (!open) return null;
        relay.ReceiveTimeout = 0;
        relay.SendTimeout = 0;
        return stream;
    }

    private static void Copy(Stream from, Stream to, TcpClient first, TcpClient second) {
        byte[] buffer = new byte[BufferBytes];
        try {
            int read;
            while ((read = from.Read(buffer, 0, buffer.Length)) > 0) { to.Write(buffer, 0, read); to.Flush(); }
        } catch (IOException) { } catch (ObjectDisposedException) { }
        first.Close();
        second.Close();
    }

    private void Serve(TcpClient client) {
        TcpClient relay = new TcpClient();
        try {
            if (!PeerIsThisProcess(((IPEndPoint)client.Client.RemoteEndPoint).Port)) return;
            client.ReceiveTimeout = timeoutMs;
            client.SendTimeout = timeoutMs;
            NetworkStream local = client.GetStream();
            string head = ReadHead(local);
            if (head == null) return;
            string[] line = head.Substring(0, head.IndexOf("\r\n", StringComparison.Ordinal)).Split(' ');
            if (line.Length != 3) { Write(local, NotAllowed); return; }
            string authority, replay = null;
            bool tunnel = true;
            if (line[0] == "CONNECT") {
                authority = line[1];
            } else if (line[1].StartsWith("http://", StringComparison.OrdinalIgnoreCase)) {
                Uri target = new Uri(line[1]);
                // IPv6 punctuation cannot identify an explicit destination port.
                // Build one canonical authority from the URI's separate fields.
                string targetHost = target.IdnHost.Trim('[', ']');
                if (target.HostNameType == UriHostNameType.IPv6) targetHost = "[" + targetHost + "]";
                authority = targetHost + ":" + target.Port.ToString(System.Globalization.CultureInfo.InvariantCulture);
                // HTTP proxies forward plaintext HTTP without CONNECT. SOCKS
                // still establishes a destination tunnel carrying origin form.
                tunnel = scheme.StartsWith("socks");
                replay = tunnel
                    ? line[0] + " " + target.PathAndQuery + " " + line[2] + head.Substring(head.IndexOf("\r\n", StringComparison.Ordinal))
                    : ForwardHead(head);
            } else { Write(local, NotAllowed); return; }
            if (authority.LastIndexOf(':') < 1) { Write(local, Refused); return; }
            Stream remote = Dial(relay, authority, tunnel);
            if (remote == null) { Write(local, Refused); return; }
            if (replay == null) Write(local, Established); else Write(remote, replay);
            client.ReceiveTimeout = 0;
            client.SendTimeout = 0;
            Thread upstream = new Thread(() => Copy(local, remote, client, relay));
            upstream.IsBackground = true;
            upstream.Start();
            Copy(remote, local, client, relay);
        } catch (Exception) {
            // The client sees a closed connection. Exception text may name the relay.
            try { Write(client.GetStream(), Refused); } catch (Exception) { }
        } finally {
            client.Close();
            relay.Close();
        }
    }
}
'@

# Reads one override relay: the grammar of route_plan.lua. Returns $null for
# anything else; never an exception, whose text could quote a credential.
function Get-ErgoptiRelayParts {
    param([string]$Relay)
    if ($Relay -cnotmatch '^(https?|socks5h?)://(?:([^@/\s]+)@)?(\[[0-9A-Fa-f:]+\]|[A-Za-z0-9._\-]+):([0-9]{1,5})\z') { return $null }
    $Parts = @{ Scheme = $Matches[1]; Host = $Matches[3].Trim('[', ']'); Port = [int]$Matches[4]; User = $null; Password = '' }
    $UserInfo = $Matches[2]
    if ($Parts.Port -lt 1 -or $Parts.Port -gt 65535) { return $null }
    if ($null -ne $UserInfo) {
        $Colon = $UserInfo.IndexOf(':')
        $Name = if ($Colon -lt 0) { $UserInfo } else { $UserInfo.Substring(0, $Colon) }
        $Parts.User = [Uri]::UnescapeDataString($Name)
        if ($Colon -ge 0) { $Parts.Password = [Uri]::UnescapeDataString($UserInfo.Substring($Colon + 1)) }
    }
    return $Parts
}

# The address the clients of this process use for one relay: the relay itself when
# they can reach it, else the loopback hop, started once. Returns the normalized
# relay URI, or throws a text that quotes nothing.
function Resolve-ErgoptiRelayEndpoint {
    param([string]$Relay, $Policy)
    $Parts = Get-ErgoptiRelayParts $Relay
    if ($null -eq $Parts) { throw 'The relay was refused.' }
    if ($Parts.Scheme -ceq 'http' -and $null -eq $Parts.User) { return (Get-ErgoptiHttpRelay $Relay $Policy) }
    if (-not $script:ErgoptiRelayHops.ContainsKey($Relay)) {
        if (-not ('ErgoptiRelayHop' -as [type])) { Add-Type -TypeDefinition $script:ErgoptiRelayHopSource -ErrorAction Stop }
        $Hop = [ErgoptiRelayHop]::new($Parts.Scheme, $Parts.Host, $Parts.Port, $Parts.User, $Parts.Password,
            $script:ErgoptiRelayHopTimeoutMs)
        $Hop.Start()
        $script:ErgoptiRelayHops[$Relay] = $Hop
    }
    return ('http://127.0.0.1:' + $script:ErgoptiRelayHops[$Relay].Port + '/')
}

function Test-ErgoptiEnvironmentBypass {
    param([Uri]$Destination, [string]$Bypass, $Policy)
    if ([Text.Encoding]::UTF8.GetByteCount($Bypass) -gt $Policy.max_proxy_bytes) { throw 'Environment bypass bound was refused.' }
    # This is transport-level curl NO_PROXY syntax. Unsupported tokens refuse
    # admission rather than producing an implicit DIRECT fallback.
    $HostName = $Destination.DnsSafeHost.Trim('[', ']').TrimEnd('.').ToLowerInvariant()
    $Matched = $false
    foreach ($Part in $Bypass.Split(',')) {
        $Pattern = $Part.Trim().ToLowerInvariant()
        if ($Pattern -eq '') { continue }
        if ($Pattern -eq '*') { $Matched = $true; continue }
        if ($Pattern -match '[\x00-\x20\x7f@?#%\\\[\]]' -or $Pattern.Contains('*')) { throw 'Environment bypass capability was refused.' }
        if ($Pattern.Contains('/')) {
            if (Test-ErgoptiAddressRange $HostName $Pattern) { $Matched = $true }
            continue
        }
        [Net.IPAddress]$Address = $null
        $Numeric = $Pattern.Trim('[', ']')
        if ([Net.IPAddress]::TryParse($Numeric, [ref]$Address)) {
            # IPAddress accepts historical IPv4 aliases that curl NO_PROXY does
            # not necessarily interpret alike. Refuse them rather than bypass.
            if ($Address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and
                ($Numeric -notmatch '^(?:0|[1-9][0-9]{0,2})(?:\.(?:0|[1-9][0-9]{0,2})){3}$' -or
                $Numeric -cne $Address.ToString())) { throw 'Environment numeric bypass was refused.' }
            [Net.IPAddress]$Target = $null
            if ([Net.IPAddress]::TryParse($HostName, [ref]$Target) -and $Target.Equals($Address)) { $Matched = $true }
            continue
        }
        if ($Pattern -notmatch '^\.?[a-z0-9_-]+(?:\.[a-z0-9_-]+)*\.?$') {
            throw 'Environment bypass capability was refused.'
        }
        $Pattern = $Pattern.TrimStart('.').TrimEnd('.')
        if ($HostName -ceq $Pattern -or $HostName.EndsWith('.' + $Pattern, [StringComparison]::Ordinal)) { $Matched = $true }
    }
    return $Matched
}

function Get-ErgoptiStaticRoutes {
    param([Uri]$Destination, $Config, $Policy, [string]$Source)
    $HostName = $Destination.DnsSafeHost.Trim('[', ']').ToLowerInvariant()
    $Bypassed = $false
    foreach ($Part in ($Config.Bypass -split '[;, ]+')) {
        $Pattern = $Part.Trim().ToLowerInvariant()
        if ($Pattern -eq '') { continue }
        if ($Pattern -eq '<local>') {
            if (-not $HostName.Contains('.')) { $Bypassed = $true }
        } elseif ($Pattern -match '^[a-z0-9.*_-]+$') {
            $Expression = '^' + [Regex]::Escape($Pattern).Replace('\*', '.*') + '$'
            if ($HostName -match $Expression) { $Bypassed = $true }
        } else { throw 'WinINet bypass capability was refused.' }
    }
    if ($Config.Proxy -eq '' -or $Bypassed) {
        return ,@(@{ Kind = 'direct'; Endpoint = ''; Authentication = 'none'; Source = $Source + $(if ($Bypassed) { '_bypass' } else { '_direct' }) })
    }
    $Specific = @()
    $Generic = @()
    $SeenSchemes = @{}
    foreach ($Part in ($Config.Proxy -split '[; ]+')) {
        if ($Part -eq '') { continue }
        $Endpoint = $Part
        $Name = ''
        if ($Part -match '^([A-Za-z]+)=(.+)$') {
            $Name = $Matches[1].ToLowerInvariant()
            $Endpoint = $Matches[2]
            if ($Name -notin @('http', 'https') -or $SeenSchemes.ContainsKey($Name)) { throw 'WinINet scheme map was refused.' }
            $SeenSchemes[$Name] = $true
        }
        $Relay = Get-ErgoptiHttpRelay $Endpoint $Policy
        if ($Name -eq $Destination.Scheme) { $Specific += $Relay }
        elseif ($Name -eq '') { $Generic += $Relay }
    }
    $Chosen = @(if ($Specific.Count -gt 0) { $Specific } else { $Generic })
    # WinHTTP leaves an unmapped protocol direct; every declared endpoint has
    # already been admitted above, so malformed maps cannot take this branch.
    if ($Chosen.Count -eq 0 -and $SeenSchemes.Count -gt 0) {
        return ,@(@{ Kind = 'direct'; Endpoint = ''; Authentication = 'none'; Source = $Source + '_direct' })
    }
    if ($Chosen.Count -ne 1) { throw 'WinINet static route capability was refused.' }
    return ,@(@{ Kind = 'proxy'; Endpoint = [string]$Chosen[0]; Source = $Source + '_proxy'; Authentication = 'current_user_proxy_only' })
}

function Get-ErgoptiProxyConfigIdentity {
    param($Config)
    if ($Config.Ok -isnot [bool] -or -not $Config.Ok -or $Config.Absent -isnot [bool] -or $Config.AutoDetect -isnot [bool] -or
        $Config.PacUrl -isnot [string] -or $Config.Proxy -isnot [string] -or $Config.Bypass -isnot [string]) {
        throw 'Native current-user configuration was refused.'
    }
    return (@($Config.Absent, $Config.AutoDetect, $Config.PacUrl, $Config.Proxy, $Config.Bypass) | ConvertTo-Json -Compress)
}

function Resolve-ErgoptiNativeNetworkRoutes {
    param([string]$DestinationUrl, [int]$BudgetMs, [scriptblock]$ReadConfig = $null,
        [scriptblock]$ReadEnvironment = $null,
        [string]$PolicyPath = '', [string]$UpdaterDefaultsPath = '')
    $Clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        if ($PolicyPath -eq '' -or $UpdaterDefaultsPath -eq '') { throw 'Canonical private policy paths are required.' }
        $Policy = Get-ErgoptiNetworkPolicy $PolicyPath
        $Defaults = Get-Content -LiteralPath $UpdaterDefaultsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $LookupBudget = $Defaults.release_sources.proxy_resolve_timeout_sec
        if (-not (Test-ErgoptiNetworkInt32 $LookupBudget) -or $LookupBudget -le 0 -or $LookupBudget -gt [int]::MaxValue / 1000) {
            throw 'Canonical proxy lookup budget was refused.'
        }
        $LookupBudget *= 1000
        $Destination = Get-ErgoptiDestination $DestinationUrl
        if ($BudgetMs -le 0 -or $Clock.ElapsedMilliseconds -ge $BudgetMs) { return New-ErgoptiRouteRefusal }
        if (Test-ErgoptiLoopback $Destination $Policy) {
            if ($Clock.ElapsedMilliseconds -ge $BudgetMs) { return New-ErgoptiRouteRefusal }
            return @{ Ok = $true; MaxRoutes = $Policy.max_selections; MaxRedirects = $Policy.redirects.max_hops; Routes = @(@{ Kind = 'direct'; Endpoint = ''; Source = 'loopback'; Authentication = 'none' }) }
        }
        if ($null -eq $ReadEnvironment) { $ReadEnvironment = { param($Name) [Environment]::GetEnvironmentVariable($Name, 'Process') } }
        # The user's proxy override: the driver sets it on this worker's own environment
        # (adapters/proxy_override.ahk). It wins over an exported relay and the PAC or
        # WPAD lookup never runs.
        $Override = & $ReadEnvironment 'ERGOPTI_PROXY_OVERRIDE'
        if ($Override -is [string] -and $Override -ne '') {
            if ($Override -ceq 'direct') {
                return @{ Ok = $true; MaxRoutes = $Policy.max_selections; MaxRedirects = $Policy.redirects.max_hops; Routes = @(@{ Kind = 'direct'; Endpoint = ''; Source = 'override'; Authentication = 'none' }) }
            }
            # Anything but a relay, the refused token included, refuses the download
            # and is never read as automatic. Relay names the real relay for a client
            # that reads it from its environment (the daemon); Endpoint is what this
            # process's own WinHTTP and HttpWebRequest clients can reach.
            if ($null -eq (Get-ErgoptiRelayParts $Override)) { return New-ErgoptiRouteRefusal 'dotnet' 'invalid_configuration' 0 $true }
            return @{ Ok = $true; MaxRoutes = $Policy.max_selections; MaxRedirects = $Policy.redirects.max_hops; Routes = @(@{ Kind = 'proxy';
                Endpoint = (Resolve-ErgoptiRelayEndpoint $Override $Policy); Relay = $Override; Source = 'override'; Authentication = 'current_user_proxy_only' }) }
        }
        foreach ($Name in $Policy.environment_precedence.($Destination.Scheme)) {
            $Value = & $ReadEnvironment $Name
            if ($null -ne $Value -and $Value -isnot [string]) { return New-ErgoptiRouteRefusal 'dotnet' 'invalid_configuration' }
            if ($Value -ne '' -and $null -ne $Value) {
                $Endpoint = Get-ErgoptiHttpRelay $Value $Policy
                $Bypass = ''
                foreach ($BypassName in $Policy.environment_bypass_precedence) {
                    $Candidate = & $ReadEnvironment $BypassName
                    if ($null -ne $Candidate -and $Candidate -isnot [string]) { throw 'Explicit environment bypass was refused.' }
                    if ($null -ne $Candidate -and $Candidate -ne '') { $Bypass = $Candidate; break }
                }
                if ($Bypass -isnot [string]) { throw 'Explicit environment bypass was refused.' }
                if ($Clock.ElapsedMilliseconds -ge $BudgetMs) { return New-ErgoptiRouteRefusal }
                $EnvironmentBypassed = Test-ErgoptiEnvironmentBypass $Destination $Bypass $Policy
                if ($Clock.ElapsedMilliseconds -ge $BudgetMs) { return New-ErgoptiRouteRefusal }
                if ($EnvironmentBypassed) {
                    return @{ Ok = $true; MaxRoutes = $Policy.max_selections; MaxRedirects = $Policy.redirects.max_hops; Routes = @(@{ Kind = 'direct'; Endpoint = ''; Source = 'environment_bypass'; Authentication = 'none' }) }
                }
                return @{ Ok = $true; MaxRoutes = $Policy.max_selections; MaxRedirects = $Policy.redirects.max_hops; Routes = @(@{ Kind = 'proxy'; Endpoint = $Endpoint;
                    Source = 'environment'; Authentication = 'current_user_proxy_only' }) }
            }
        }
        if ($null -eq $ReadConfig) { $ReadConfig = { param($MaxBytes) [ErgoptiWindowsProxyConfig]::Read($MaxBytes) } }
        while ($Clock.ElapsedMilliseconds -lt $BudgetMs) {
            $Config = & $ReadConfig $Policy.max_proxy_bytes
            if ($null -eq $Config -or $Config.Ok -ne $true) {
                return New-ErgoptiRouteRefusal 'wininet' 'unavailable' $Config.NativeError ($Config.FailureOrigin -ceq 'native')
            }
            $Identity = Get-ErgoptiProxyConfigIdentity $Config
            if ($Config.PacUrl -eq '' -and -not $Config.AutoDetect) {
                $StaticSource = if ($Config.Absent) { 'system_config_absent' } else { 'system' }
                $Routes = Get-ErgoptiStaticRoutes $Destination $Config $Policy $StaticSource
            } else {
                if ($Config.PacUrl -ne '') { $null = Get-ErgoptiDestination $Config.PacUrl }
                $Remaining = [int][Math]::Min($LookupBudget, $BudgetMs - $Clock.ElapsedMilliseconds)
                if ($Remaining -lt 1500) {
                    $Fallback = New-ErgoptiPacDirectFallback $Policy 'native_proxy_budget'
                    return $(if ($null -ne $Fallback) { $Fallback } else { New-ErgoptiRouteRefusal })
                }
                $Native = Resolve-ErgoptiFullUrlPac -DestinationUrl $DestinationUrl -PacUrl $Config.PacUrl -AutoDetect $Config.AutoDetect `
                    -Deadline ([ErgoptiNetworkPac]::CurrentTick() + $Remaining) -Policy $Policy
                if (-not $Native.OwnersRetired) {
                    $Status = if ($Config.PacUrl -ne '') { 'pac_failed' } else { 'wpad_failed' }
                    $Refusal = New-ErgoptiRouteRefusal $Native.Backend $Status $Native.NativeError ($Native.FailureOrigin -ceq 'native') $(if($Native.NativeErrorDomain -cin @('win32','winsock','posix')){$Native.NativeErrorDomain}else{'win32'})
                    $Refusal.CleanupDebt = $true
                    return $Refusal
                }
                if ($Native.Kind -ceq 'no_auto_proxy' -and $Native.NativeError -eq 12180 -and
                    $Config.PacUrl -eq '' -and $Config.AutoDetect) {
                    $Routes = Get-ErgoptiStaticRoutes $Destination $Config $Policy 'wpad_absent'
                } elseif (-not $Native.Ok -or $Native.Kind -cne 'pac_routes') {
                    $Fallback = New-ErgoptiPacDirectFallback $Policy (Get-ErgoptiPacFailureStage $Native)
                    if ($null -ne $Fallback) { return $Fallback }
                    $Status = if ($Config.PacUrl -ne '') { 'pac_failed' } else { 'wpad_failed' }
                    return New-ErgoptiRouteRefusal $Native.Backend $Status $Native.NativeError ($Native.FailureOrigin -ceq 'native') $(if($Native.NativeErrorDomain -cin @('win32','winsock','posix')){$Native.NativeErrorDomain}else{'win32'})
                } else {
                    $Routes = ConvertFrom-ErgoptiPacRoutes $Native.Proxy $Policy
                }
            }
            $Current = & $ReadConfig $Policy.max_proxy_bytes
            if ((Get-ErgoptiProxyConfigIdentity $Current) -cne $Identity) { continue }
            if ($Clock.ElapsedMilliseconds -ge $BudgetMs) { return New-ErgoptiRouteRefusal }
            return @{ Ok = $true; MaxRoutes = $Policy.max_selections; MaxRedirects = $Policy.redirects.max_hops; Routes = @($Routes) }
        }
    } catch {
        # Raw input and managed/native exception text may contain credentials.
        return New-ErgoptiRouteRefusal 'wininet' 'invalid_configuration'
    }
    return New-ErgoptiRouteRefusal
}
