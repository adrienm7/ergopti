# tests/fixtures/healthcheck_pac_encoding_peer.ps1
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
$Script = "function FindProxyForURL(url,host){return 'DIRECT';}"
$Valid = $Mode -eq 'utf16le' -or $Mode -eq 'utf16be'
$BigEndian = $Mode -eq 'utf16be' -or $Mode -eq 'malformedbe'
if ($Mode -notin @('utf16le','utf16be','malformedle','malformedbe')) { throw 'Unknown PAC encoding mode.' }
# Numeric scalars keep this Windows PowerShell 5.1 fixture itself ASCII-only.
if ($Valid) {
    $Script = '// ' + [char]0x00e9 + ' ' + [char]0xd83d + [char]0xde00 + ' ' + [char]0xfffd + "`n" + $Script
}
$Encoding = [Text.UnicodeEncoding]::new($BigEndian, $true, $true)
$Bytes = [byte[]]($Encoding.GetPreamble() + $Encoding.GetBytes($Script))
if (-not $Valid) {
    # A complete ASCII PAC followed by one unpaired source byte. FileRead's
    # UTF16LE decoder historically drops it; the real PAC source must refuse.
    $Bytes = [byte[]]($Bytes + [byte]0x41)
}
$Expected = [Text.UTF8Encoding]::new($false, $true).GetBytes($Script)
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
public sealed class HealthcheckPacEncodingPeer : IDisposable
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
    public HealthcheckPacEncodingPeer(byte[] bytes) {
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
    $Peer = [HealthcheckPacEncodingPeer]::new($Bytes)
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
        for ($Index = 0; $Index -lt $Expected.Length; $Index++) {
            if ($Actual[$Index] -ne $Expected[$Index]) { throw 'The source fetcher changed normalized script content.' }
        }
    } catch {
        $Failure = $_.Exception.GetBaseException()
        if (-not $Valid -and $Failure -is [Text.DecoderFallbackException]) {
            $SourceError = 'invalid_utf16'
        } else { throw }
    }
    if ($SourceAllowed -ne $Valid) { throw 'The genuine source-fetch classification differs from its encoding contract.' }
    $Utf8Valid = $true
    try { $null = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes) }
    catch [Text.DecoderFallbackException] { $Utf8Valid = $false }
    $Hasher = [Security.Cryptography.SHA256]::Create()
    try {
        $Digest = ([BitConverter]::ToString($Hasher.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
        $NormalizedDigest = if ($SourceAllowed) {
            ([BitConverter]::ToString($Hasher.ComputeHash($Actual))).Replace('-', '').ToLowerInvariant()
        } else { '' }
    } finally { $Hasher.Dispose() }
    $Ready = @{ mode=$Mode; port=$Peer.Port; raw_bytes=$Bytes.Length; raw_sha256=$Digest;
        source_allowed=$SourceAllowed; source_error=$SourceError; normalized_bytes=$NormalizedBytes;
        normalized_sha256=$NormalizedDigest; utf8_valid=$Utf8Valid; source_requests=$Peer.Requests }
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
Write-Output ('PAC_ENCODING_PEER mode=' + $Mode + ' requests=' + $Peer.Requests + ' retired=true')
