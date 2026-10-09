# tests/fixtures/pac_source_contract.ps1
# Executes the actual source fetcher; portable mode qualifies only pure URI scope.
param([Parameter(Mandatory=$true)][string]$WorkerPath, [Parameter(Mandatory=$true)][string]$PolicyPath, [switch]$Portable)
$ErrorActionPreference = 'Stop'
# The original terminating error remains the failure owner; formatting cannot hide its line.
trap {
    $SourceErrorRecord = $_
    try {
        $SourceErrorLine = 0
        if ($null -ne $SourceErrorRecord.InvocationInfo -and
            $SourceErrorRecord.InvocationInfo.ScriptName -ceq $PSCommandPath) {
            $CandidateLine = [int]$SourceErrorRecord.InvocationInfo.ScriptLineNumber
            if ($CandidateLine -ge 1 -and $CandidateLine -le 4095) { $SourceErrorLine = $CandidateLine }
        }
        $SourceErrorClasses = @(
            'MethodException',
            'MethodInvocationException',
            'RuntimeException',
            'TargetInvocationException',
            'TargetParameterCountException',
            'MissingMethodException',
            'ArgumentException',
            'ArgumentNullException',
            'ArgumentOutOfRangeException',
            'InvalidOperationException',
            'InvalidDataException',
            'DecoderFallbackException',
            'FileNotFoundException',
            'DirectoryNotFoundException',
            'IOException',
            'UnauthorizedAccessException',
            'TimeoutException',
            'WebException',
            'ObjectDisposedException',
            'PacOwnerDebtException',
            'TypeInitializationException',
            'NotSupportedException',
            'PlatformNotSupportedException',
            'Win32Exception'
        )
        $SourceErrorClass = 'unknown'
        $SourceErrorException = $SourceErrorRecord.Exception
        for ($Depth = 0; $Depth -lt 4 -and $null -ne $SourceErrorException; $Depth++) {
            $CandidateClass = $SourceErrorException.GetType().Name
            $SourceErrorClass = if ($SourceErrorClasses -ccontains $CandidateClass) { $CandidateClass } else { 'unknown' }
            $SourceErrorException = $SourceErrorException.InnerException
        }
        if ($null -ne $SourceErrorException) { $SourceErrorClass = 'unknown' }
        [Console]::Error.WriteLine(('PAC_SOURCE_ERROR exception={0} line={1}' -f $SourceErrorClass, $SourceErrorLine))
    } catch {
        # A diagnostic writer refusal cannot replace the original terminating error.
    }
    break
}
$Definition = [IO.File]::ReadAllText($WorkerPath, [Text.UTF8Encoding]::new($false, $true))
$Match = [regex]::Match($Definition, "Add-Type -TypeDefinition @'\n([\s\S]*?)\n'@")
if (-not $Match.Success) { throw 'Production PAC executor definition was refused.' }
Add-Type -TypeDefinition $Match.Groups[1].Value -IgnoreWarnings -WarningAction SilentlyContinue
$Flags = [Reflection.BindingFlags]'NonPublic,Static'
$Same = [ErgoptiNetworkPac].GetMethod('SameAuthority', $Flags)
if ($null -eq $Same) { throw 'Production credential scope method is missing.' }
$Controls = 0
foreach ($Case in @(
    @('https://PAC.example/a','https://pac.example:443/b',$true),
    @('http://pac.example/a','http://PAC.example:80/b',$true),
    @('https://pac.example/a','https://pac.example:444/a',$false),
    @('https://pac.example/a','http://pac.example/a',$false),
    @('https://pac.example/a','https://foreign.example/a',$false),
    @('http://127.0.0.1:4455/a','http://localhost:4455/a',$false),
    @('http://[::1]:4455/a','http://[::1]:4456/a',$false)
)) {
    $Actual = $Same.Invoke($null, @([Uri]$Case[0], [Uri]$Case[1]))
    if ($Actual -cne $Case[2]) { throw 'Native credential authority tuple differs.' }
    $Controls++
}
# Execute the actual PowerShell validator before any metadata/source acquisition.
. $WorkerPath
function Test-ErgoptiNetworkInt32($Value) {
    return (($Value -is [int] -or $Value -is [long]) -and $Value -ge 0 -and $Value -le 2147483647)
}
function Get-ErgoptiDestination($Value) { throw 'Fixture reached source acquisition before refusal.' }
$PolicyBytes = [IO.File]::ReadAllText($PolicyPath,[Text.UTF8Encoding]::new($false,$true))
$Original = $PolicyBytes | ConvertFrom-Json
foreach ($Case in @(
    @('route','system'), @('credentials','stored'), @('credential_scope','every_authority'),
    @('allowed_schemes','http,https'), @('required_status',$true), @('required_status',201),
    @('encodings','utf-8,utf-8-bom,utf-16le-bom,utf-16be-bom'),
    @('strict_decoding',1), @('strict_decoding',$false),
    @('forbid_https_downgrade',1), @('forbid_https_downgrade',$false)
)) {
    $Policy = $PolicyBytes | ConvertFrom-Json
    $Policy.native_pac.source_acquisition.($Case[0]) = $Case[1]
    $Refused = $false
    try { $null = Resolve-ErgoptiFullUrlPac 'https://fixture.invalid/a' 'http://fixture.invalid/pac' $false 0 $Policy }
    catch { $Refused = $_.Exception.Message -ceq 'Canonical PAC source acquisition was refused.' }
    if (-not $Refused) { throw 'Production source policy mutation did not refuse before acquisition.' }
    $Controls++
}
foreach ($Field in $Original.native_pac.source_acquisition.PSObject.Properties.Name) {
    $Policy = $PolicyBytes | ConvertFrom-Json
    $Policy.native_pac.source_acquisition.PSObject.Properties.Remove($Field)
    $Refused = $false
    try { $null = Resolve-ErgoptiFullUrlPac 'https://fixture.invalid/a' 'http://fixture.invalid/pac' $false 0 $Policy }
    catch { $Refused = $_.Exception.Message -ceq 'Canonical PAC source acquisition was refused.' }
    if (-not $Refused) { throw 'Production missing source policy field did not refuse before acquisition.' }
    $Controls++
}
# JSON singleton arrays are not canonical string fields in PowerShell.
foreach ($Field in @('route','credentials','credential_scope','allowed_schemes','encodings')) {
    $Policy = $PolicyBytes | ConvertFrom-Json
    $OriginalValue = $Policy.native_pac.source_acquisition.$Field
    $Policy.native_pac.source_acquisition.$Field = if ($OriginalValue -is [Array]) {
        ,@(($OriginalValue -join ','))
    } else { ,@($OriginalValue) }
    # Roundtrip actual JSON to prevent test assignment coercion from hiding types.
    $Policy = $Policy | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $Refused = $false
    try { $null = Resolve-ErgoptiFullUrlPac 'https://fixture.invalid/a' 'http://fixture.invalid/pac' $false 0 $Policy }
    catch { $Refused = $_.Exception.Message -ceq 'Canonical PAC source acquisition was refused.' }
    if (-not $Refused) { throw 'Production JSON array source field did not refuse before acquisition.' }
    $Controls++
}

# Inspect the actual request returned to Fetch; helper-only tuple proofs cannot
# establish that the native request uses the restricted credential selection.
$Create = [ErgoptiNetworkPac].GetMethod('CreateSourceRequest', $Flags)
if ($null -eq $Create) { throw 'Production source request constructor is missing.' }
foreach ($Case in @(
    @('https://PAC.example/a','https://pac.example:443/b',$true),
    @('https://pac.example/a','http://pac.example/a',$false),
    @('https://pac.example/a','https://foreign.example/a',$false),
    @('https://pac.example/a','https://pac.example:444/a',$false)
)) {
    $Request = $Create.Invoke($null, @([Uri]$Case[0], [Uri]$Case[1]))
    try {
        if ($Case[2]) {
            if (-not [Object]::ReferenceEquals($Request.Credentials,[Net.CredentialCache]::DefaultNetworkCredentials)) {
                throw 'Initial authority lost native default credentials.'
            }
        } elseif ($null -ne $Request.Credentials) {
            throw 'Foreign authority acquired native default credentials.'
        }
        $Controls++
    } finally { $Request.Abort() }
}
$FetchBody = [regex]::Match($Match.Groups[1].Value,'private static byte\[\] Fetch([\s\S]*?)public static Result Execute').Value
if ($FetchBody -notmatch 'HttpWebRequest request=CreateSourceRequest\(initial,current\);' -or
    $FetchBody -match 'request\.Credentials\s*=' -or $FetchBody -match 'WebRequest\.Create\(') {
    throw 'Fetch bypassed the actual credential-scoped request constructor.'
}
$Controls++

if ($Portable) {
    Write-Output ('PAC_SOURCE_CREDENTIALS controls=' + $Controls + ' native_fetch=false')
    exit 0
}

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
public sealed class PacSourcePeer : IDisposable
{
    private readonly TcpListener listener = new TcpListener(IPAddress.Loopback,0);
    private readonly Thread worker;
    private readonly object gate=new object();
    private TcpClient current;
    private static readonly List<PacSourcePeer> retained=new List<PacSourcePeer>();
    public readonly List<string> Paths=new List<string>();
    public int ForeignPort;
    public int Port {get{return ((IPEndPoint)listener.LocalEndpoint).Port;}}
    public PacSourcePeer() {
        listener.Start();worker=new Thread(Run);worker.IsBackground=true;
        try {worker.Start();} catch {listener.Stop();throw;}
    }
    private void Run() {
        while(true) {
            TcpClient client;
            try {client=listener.AcceptTcpClient();} catch {return;}
            lock(gate)current=client;
            try {
                client.ReceiveTimeout=2000;client.SendTimeout=2000;
                using(NetworkStream stream=client.GetStream()) {
                    List<byte> request=new List<byte>();
                    while(request.Count<65536) {
                        int value=stream.ReadByte();if(value<0)break;request.Add((byte)value);
                        int count=request.Count;
                        if(count>=4&&request[count-4]==13&&request[count-3]==10&&request[count-2]==13&&request[count-1]==10)break;
                    }
                    string text=Encoding.ASCII.GetString(request.ToArray());
                    string[] first=text.Split(new string[]{"\r\n"},StringSplitOptions.None)[0].Split(' ');
                    if(first.Length!=3||first[0]!="GET")throw new InvalidOperationException();
                    string path=first[1];lock(gate)Paths.Add(path);
                    byte[] body=Encoding.UTF8.GetBytes("function FindProxyForURL(u,h){return 'DIRECT';}");
                    int status=200;string extra="";
                    if(path=="/utf16") {byte[] data=Encoding.Unicode.GetBytes("function FindProxyForURL(u,h){return 'DIRECT';}");body=new byte[data.Length+2];body[0]=255;body[1]=254;Array.Copy(data,0,body,2,data.Length);}
                    else if(path=="/invalid")body=new byte[]{192,128};
                    else if(path=="/oversized")body=new byte[1048577];
                    else if(path=="/unavailable")status=503;
                    else if(path=="/redirect") {status=302;extra="Location: /utf8\r\n";}
                    else if(path=="/foreign") {status=302;extra="Location: http://127.0.0.1:"+ForeignPort+"/utf8\r\n";}
                    else if(path!="/utf8")status=404;
                    string headers="HTTP/1.1 "+status+" Owned\r\nContent-Length: "+body.Length+"\r\nConnection: close\r\n"+extra+"\r\n";
                    byte[] head=Encoding.ASCII.GetBytes(headers);stream.Write(head,0,head.Length);stream.Write(body,0,body.Length);
                }
            } catch { } finally {client.Close();lock(gate)current=null;}
        }
    }
    public void Dispose() {
        listener.Stop();lock(gate)if(current!=null)current.Close();
        if(!worker.Join(2000)){lock(retained)retained.Add(this);throw new InvalidOperationException("Owned PAC peer did not retire");}
    }
}
'@
$Fetch = [ErgoptiNetworkPac].GetMethod('Fetch', $Flags)
if ($null -eq $Fetch) { throw 'Production source fetch method is missing.' }
$Peers = @()
try {
    $First = [PacSourcePeer]::new()
    $Peers += $First
    $Second = [PacSourcePeer]::new()
    $Peers += $Second
    $First.ForeignPort = $Second.Port
    foreach ($Path in @('utf8','utf16','redirect','foreign')) {
        $Deadline = [ErgoptiNetworkPac]::CurrentTick() + 5000
        $Bytes = $Fetch.Invoke($null, @(('http://127.0.0.1:' + $First.Port + '/' + $Path),
            [long]$Deadline, [long]($Deadline + 1000), [int]1048576, [int]50))
        if ([Text.UTF8Encoding]::new($false,$true).GetString($Bytes) -cne "function FindProxyForURL(u,h){return 'DIRECT';}") {
            throw 'Real source fetch did not preserve the complete script.'
        }
        $Controls++
    }
    foreach ($Path in @('invalid','oversized','unavailable')) {
        $Refused = $false
        $Deadline = [ErgoptiNetworkPac]::CurrentTick() + 5000
        try {
            $null = $Fetch.Invoke($null, @(('http://127.0.0.1:' + $First.Port + '/' + $Path),
                [long]$Deadline, [long]($Deadline + 1000), [int]1048576, [int]50))
        } catch [Text.DecoderFallbackException] {
            $Refused = $Path -ceq 'invalid'
        } catch [Net.WebException] {
            $Failure = $_.Exception.GetBaseException()
            $Refused = $Path -ceq 'unavailable' -and $Failure -is [Net.WebException] -and
                $Failure.Status -eq [Net.WebExceptionStatus]::ProtocolError -and
                $Failure.Response -is [Net.HttpWebResponse] -and
                [int]$Failure.Response.StatusCode -eq 503
        } catch [InvalidOperationException] {
            $Refused = $Path -ceq 'oversized'
        }
        if (-not $Refused) { throw 'Real malformed/non200/oversized source was admitted.' }
        $Controls++
    }
    $OwnerType = [ErgoptiNetworkPac].GetNestedType('RequestDeadlineOwner',[Reflection.BindingFlags]'NonPublic')
    $Retained = $OwnerType.GetField('retained',$Flags).GetValue($null)
    if ($Retained.Count -ne 0) { throw 'Production source deadline owner remains physically unsettled.' }
    $Controls++
} finally {
    foreach ($Peer in $Peers) { $Peer.Dispose() }
}
Write-Output ('PAC_SOURCE_NATIVE controls=' + $Controls + ' owners_retired=true')
