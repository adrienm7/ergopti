# tests/fixtures/healthcheck_pac_boundaries_peer.ps1
# A private HTTP peer and the genuine managed PAC source fetcher. No proxy
# settings, registry, certificates or user configuration are changed.
param(
    [Parameter(Mandatory=$true)][string]$Mode,
    [Parameter(Mandatory=$true)][string]$Directory,
    [Parameter(Mandatory=$true)][string]$WorkerPath,
    [Parameter(Mandatory=$true)][string]$PolicyPath
)
$ErrorActionPreference = 'Stop'
$Policy = [IO.File]::ReadAllText($PolicyPath, [Text.UTF8Encoding]::new($false, $true)) | ConvertFrom-Json
$Maximum = [int]$Policy.native_pac.max_script_bytes
if ($Maximum -ne 1048576) { throw 'The canonical PAC byte bound changed.' }
$Script = "function FindProxyForURL(url,host){return 'DIRECT';}" + "`n//"
$Valid = $Mode -eq 'utf8exact'
if ($Mode -eq 'utf8exact') {
    $Script += [string]::new([char]0x78, $Maximum - $Script.Length)
    $Bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes($Script)
} elseif ($Mode -eq 'utf16rawover') {
    # UTF16 source units fit the textual limit, but BOM-inclusive raw bytes do not.
    $Script += [string]::new([char]0x78, ($Maximum / 2) - $Script.Length)
    $Encoding = [Text.UnicodeEncoding]::new($false, $true, $true)
    $Bytes = [byte[]]($Encoding.GetPreamble() + $Encoding.GetBytes($Script))
} elseif ($Mode -eq 'utf16normalizedover') {
    # Each CJK unit occupies two UTF16 bytes and three normalized UTF8 bytes.
    $Script += [string]::new([char]0x4e2d, 350000)
    $Encoding = [Text.UnicodeEncoding]::new($false, $true, $true)
    $Bytes = [byte[]]($Encoding.GetPreamble() + $Encoding.GetBytes($Script))
} else { throw 'Unknown PAC boundary mode.' }
$Expected = [Text.UTF8Encoding]::new($false, $true).GetBytes($Script)
if ($Mode -eq 'utf8exact' -and ($Bytes.Length -ne $Maximum -or $Expected.Length -ne $Maximum)) {
    throw 'The affirmative source must meet both exact inclusive byte bounds.'
}
if ($Mode -eq 'utf16rawover' -and ($Bytes.Length -ne ($Maximum + 2) -or $Expected.Length -ge $Maximum)) {
    throw 'Only the original source byte bound may refuse this UTF16 vector.'
}
if ($Mode -eq 'utf16normalizedover' -and ($Bytes.Length -ge $Maximum -or $Expected.Length -le $Maximum)) {
    throw 'Only normalized UTF8 may exceed the byte bound for this UTF16 vector.'
}
[IO.File]::WriteAllBytes((Join-Path $Directory 'response.bin'), $Bytes)
$Definition = [IO.File]::ReadAllText($WorkerPath, [Text.UTF8Encoding]::new($false, $true))
$Match = [regex]::Match($Definition, "Add-Type -TypeDefinition @'\n([\s\S]*?)\n'@")
if (-not $Match.Success) { throw 'The genuine PAC source definition is missing.' }
Add-Type -TypeDefinition $Match.Groups[1].Value -IgnoreWarnings -WarningAction SilentlyContinue
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
public sealed class HealthcheckPacBoundaryPeer : IDisposable
{
    private readonly TcpListener listener = new TcpListener(IPAddress.Loopback,0);
    private readonly Thread worker;
    private readonly byte[] body;
    private readonly object gate = new object();
    private TcpClient current;
    private bool stopping;
    public int Requests;
    public bool Failed;
    public int Port { get { return ((IPEndPoint)listener.LocalEndpoint).Port; } }
    public HealthcheckPacBoundaryPeer(byte[] bytes) {
        body=bytes; listener.Start(); worker=new Thread(Run); worker.IsBackground=true;
        try { worker.Start(); } catch { listener.Stop(); throw; }
    }
    private void Run() {
        while(true) {
            TcpClient client;
            try { client=listener.AcceptTcpClient(); }
            catch { lock(gate) { if(!stopping) Failed=true; } return; }
            lock(gate) current=client;
            try {
                client.ReceiveTimeout=3000; client.SendTimeout=3000;
                using(NetworkStream stream=client.GetStream()) {
                    int length=0, matched=0;
                    byte[] end=new byte[]{13,10,13,10};
                    while(length++<65536) {
                        int value=stream.ReadByte(); if(value<0) throw new IOException();
                        matched=value==end[matched]?matched+1:0;
                        if(matched==4) break;
                    }
                    if(matched!=4) throw new IOException();
                    Interlocked.Increment(ref Requests);
                    byte[] header=Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Type: application/x-ns-proxy-autoconfig\r\nContent-Length: "+body.Length+"\r\nConnection: close\r\n\r\n");
                    stream.Write(header,0,header.Length);
                    // The real source-size refusal may abort before reading the body.
                    try { stream.Write(body,0,body.Length); } catch(IOException) { }
                }
            } catch { lock(gate) { if(!stopping) Failed=true; } }
            finally { client.Close(); lock(gate) current=null; }
        }
    }
    public void Dispose() {
        lock(gate) { stopping=true; listener.Stop(); if(current!=null) current.Close(); }
        if(!worker.Join(3000)) throw new InvalidOperationException("Private PAC peer did not retire.");
    }
}
'@
$Peer = $null
$Primary = $null
try {
    $Peer = [HealthcheckPacBoundaryPeer]::new($Bytes)
    $Url = 'http://127.0.0.1:' + $Peer.Port + '/proxy.pac'
    $Fetch = [ErgoptiNetworkPac].GetMethod('Fetch', [Reflection.BindingFlags]'NonPublic,Static')
    if ($null -eq $Fetch) { throw 'The actual PAC source fetcher is missing.' }
    $SourceAllowed = $false
    $SourceError = 'none'
    $NormalizedBytes = 0
    $Deadline = [ErgoptiNetworkPac]::CurrentTick() + 10000
    try {
        $Actual = $Fetch.Invoke($null, @($Url, [long]$Deadline, [long]($Deadline + 1000), $Maximum, [int]50))
        $SourceAllowed = $true
        $NormalizedBytes = $Actual.Length
        if ($Actual.Length -ne $Expected.Length) { throw 'The actual source fetcher changed normalized script length.' }
    } catch {
        $Failure = $_.Exception.GetBaseException()
        if (-not $Valid -and $Failure -is [InvalidOperationException]) {
            $SourceError = 'byte_limit'
        } else { throw }
    }
    if ($SourceAllowed -ne $Valid) { throw 'The genuine source-fetch classification differs from its byte-bound contract.' }
    $Utf8Valid = $true
    try { $null = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes) }
    catch [Text.DecoderFallbackException] { $Utf8Valid = $false }
    $Hasher = [Security.Cryptography.SHA256]::Create()
    try {
        $Digest = ([BitConverter]::ToString($Hasher.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
        $NormalizedDigest = if ($SourceAllowed) {
            ([BitConverter]::ToString($Hasher.ComputeHash($Actual))).Replace('-', '').ToLowerInvariant()
        } else { '' }
        $ExpectedDigest = ([BitConverter]::ToString($Hasher.ComputeHash($Expected))).Replace('-', '').ToLowerInvariant()
        if ($SourceAllowed -and $NormalizedDigest -ne $ExpectedDigest) { throw 'The actual source fetcher changed normalized script bytes.' }
    } finally { $Hasher.Dispose() }
    $Ready = @{ mode=$Mode; port=$Peer.Port; raw_bytes=$Bytes.Length; raw_sha256=$Digest;
        source_allowed=$SourceAllowed; source_error=$SourceError; normalized_bytes=$NormalizedBytes;
        normalized_sha256=$NormalizedDigest; expected_normalized_bytes=$Expected.Length; expected_normalized_sha256=$ExpectedDigest; utf8_valid=$Utf8Valid; source_requests=$Peer.Requests }
    [IO.File]::WriteAllText((Join-Path $Directory 'ready.pending'), ($Ready | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
    [IO.File]::Move((Join-Path $Directory 'ready.pending'), (Join-Path $Directory 'ready.json'))
    $Until = [DateTime]::UtcNow.AddSeconds(45)
    while (-not [IO.File]::Exists((Join-Path $Directory 'stop')) -and [DateTime]::UtcNow -lt $Until) {
        Start-Sleep -Milliseconds 20
    }
    if (-not [IO.File]::Exists((Join-Path $Directory 'stop'))) { throw 'Private PAC peer stop was not received.' }
    if ($Peer.Failed) { throw 'Private PAC peer request precondition failed.' }
} catch { $Primary = $_ }
finally {
    if ($null -ne $Peer) {
        try { $Peer.Dispose() } catch { if ($null -eq $Primary) { $Primary = $_ } }
    }
}
if ($null -ne $Primary) { throw $Primary }
Write-Output ('PAC_BOUNDARY_PEER mode=' + $Mode + ' requests=' + $Peer.Requests + ' retired=true')
