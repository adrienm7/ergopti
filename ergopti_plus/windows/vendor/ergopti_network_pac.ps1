# vendor/ergopti_network_pac.ps1
# One private process owns fresh PAC retrieval and the bounded full-URL evaluator.
# WinINet configuration and native WPAD discovery remain platform authorities.
if (-not ('ErgoptiNetworkPac' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Cache;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

public static class ErgoptiNetworkPac
{
    [DllImport("kernel32.dll", ExactSpelling=true)]
    private static extern UInt64 GetTickCount64();
    [DllImport("winhttp.dll", CharSet=CharSet.Unicode, ExactSpelling=true, SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool WinHttpDetectAutoProxyConfigUrl(UInt32 flags, out IntPtr location);
    [DllImport("kernel32.dll", ExactSpelling=true, SetLastError=true)]
    private static extern IntPtr GlobalFree(IntPtr location);
    public static Int64 CurrentTick() { return checked((Int64)GetTickCount64()); }
    private static int Remaining(long deadline)
    {
        long now = CurrentTick();
        return now >= deadline ? 0 : (int)Math.Min(Int32.MaxValue, deadline-now);
    }
    public sealed class Result
    {
        public bool Ok;
        public string Kind="refused";
        public string Location="";
        public string Proxy="";
        public int NativeError;
        public string NativeErrorDomain="unknown";
        public string Backend="dotnet";
        public string FailureOrigin="unknown";
        public bool OwnersRetired=true;
    }
    private static Result DiscoverNative(int maximumBytes)
    {
        Result answer = new Result();
        IntPtr location = IntPtr.Zero;
        try {
            bool found = WinHttpDetectAutoProxyConfigUrl(3, out location);
            int error = found ? 0 : Marshal.GetLastWin32Error();
            answer.NativeError=error; answer.Backend="winhttp"; answer.NativeErrorDomain="win32"; answer.FailureOrigin="native";
            if (!found) {
                if (error==12180) answer.Kind="no_auto_proxy";
                return answer;
            }
            if (location==IntPtr.Zero || maximumBytes<2) return answer;
            StringBuilder text=new StringBuilder();
            bool terminated=false;
            for (int index=0; index<maximumBytes/2; index++) {
                char value=(char)Marshal.ReadInt16(location,checked(index*2));
                if (value==0) { terminated=true; break; }
                text.Append(value);
            }
            if (!terminated) { answer.FailureOrigin="invalid_native_receipt"; return answer; }
            answer.Location=text.ToString(); answer.Ok=true; answer.Kind="pac_location";
            return answer;
        } catch {
            answer.Ok=false; answer.Kind="refused"; answer.NativeError=0; answer.FailureOrigin="managed_boundary";
            return answer;
        } finally {
            answer.OwnersRetired=location==IntPtr.Zero || GlobalFree(location)==IntPtr.Zero;
            if (!answer.OwnersRetired) {
                answer.Ok=false; answer.Kind="refused"; answer.NativeError=Marshal.GetLastWin32Error();
                answer.NativeErrorDomain="win32";answer.FailureOrigin="native";
            }
        }
    }
    private sealed class DiscoveryOwner
    {
        private static readonly object retainedGate=new object();
        private static readonly List<DiscoveryOwner> retained=new List<DiscoveryOwner>();
        private readonly int maximumBytes;
        public readonly Thread Thread;
        public Result Answer;
        public DiscoveryOwner(int maximumBytes)
        {
            this.maximumBytes=maximumBytes;
            Thread=new Thread(Run);Thread.IsBackground=true;
        }
        private void Run() {Answer=DiscoverNative(maximumBytes);}
        public void Retain() {lock(retainedGate)retained.Add(this);}
    }
    public static Result Discover(int maximumBytes,long deadline,int retirementReserve)
    {
        Result answer=new Result();
        long workDeadline=deadline-retirementReserve;
        if(maximumBytes<2||retirementReserve<1||Remaining(workDeadline)==0)return answer;
        DiscoveryOwner owner=new DiscoveryOwner(maximumBytes);
        bool started=false;
        try {
            owner.Thread.Start();started=true;
            if(owner.Thread.Join(Remaining(workDeadline)))return owner.Answer;
            // This synchronous WinHTTP API cannot be cancelled in-process. Only a joined
            // owner may publish its result; the existing private Job contains any debt.
            owner.Retain();
            answer.OwnersRetired=false;answer.FailureOrigin="owner_debt";return answer;
        } catch {
            if(started&&!owner.Thread.Join(Remaining(deadline))) {
                owner.Retain();answer.OwnersRetired=false;answer.FailureOrigin="owner_debt";
            } else answer.FailureOrigin="managed_boundary";
            return answer;
        }
    }
    private static Uri AdmitLocation(string location)
    {
        Uri uri;
        if (String.IsNullOrEmpty(location) || !Uri.TryCreate(location,UriKind.Absolute,out uri) ||
            (uri.Scheme!="http" && uri.Scheme!="https") || uri.UserInfo.Length!=0 || uri.Fragment.Length!=0)
            throw new InvalidOperationException();
        foreach(char value in location) if(value<=32 || value==127) throw new InvalidOperationException();
        return uri;
    }
    private sealed class PacOwnerDebtException : Exception { }
    private sealed class RequestDeadlineOwner
    {
        private static readonly object retainedGate=new object();
        private static readonly List<RequestDeadlineOwner> retained=new List<RequestDeadlineOwner>();
        private readonly HttpWebRequest request;
        private readonly ManualResetEvent retired=new ManualResetEvent(false);
        private readonly Timer timer;
        public RequestDeadlineOwner(HttpWebRequest request,long deadline)
        {
            this.request=request;
            try {timer=new Timer(Expire,null,Remaining(deadline),Timeout.Infinite);}
            catch {retired.Dispose();throw;}
        }
        private void Expire(object ignored)
        {
            // The one-shot callback owns exactly this request, never a shared service timer.
            try{request.Abort();}catch{ }
        }
        public bool Retire(long deadline)
        {
            bool complete=false;
            try {complete=timer.Dispose(retired)&&retired.WaitOne(Remaining(deadline));}
            catch {complete=false;}
            if(complete)retired.Dispose();
            else {
                // The outer private Job is the last physical containment fence.
                // Never dispose an event while its native Timer completion can still signal it.
                lock(retainedGate)retained.Add(this);
            }
            return complete;
        }
    }
    private static byte[] Fetch(string location,long deadline,long retirementDeadline,int maximum,int maxRedirects)
    {
        Uri current=AdmitLocation(location);
        for(int hop=0;hop<=maxRedirects;hop++) {
            int remaining=Remaining(deadline);
            if(remaining==0)throw new TimeoutException();
            HttpWebRequest request=(HttpWebRequest)WebRequest.Create(current);
            request.Proxy=null;
            request.AllowAutoRedirect=false;
            request.CachePolicy=new RequestCachePolicy(RequestCacheLevel.NoCacheNoStore);
            request.Credentials=CredentialCache.DefaultNetworkCredentials;
            request.PreAuthenticate=false;
            request.Timeout=remaining;request.ReadWriteTimeout=remaining;
            request.Method="GET";request.KeepAlive=true;
            HttpWebResponse response=null;
            RequestDeadlineOwner deadlineOwner=new RequestDeadlineOwner(request,deadline);
            try {
                response=(HttpWebResponse)request.GetResponse();
                int code=(int)response.StatusCode;
                if(code==301||code==302||code==303||code==307||code==308) {
                    string next=response.Headers["Location"];
                    if(hop==maxRedirects||String.IsNullOrEmpty(next))throw new InvalidOperationException();
                    Uri redirected=AdmitLocation(new Uri(current,next).AbsoluteUri);
                    if(current.Scheme=="https"&&redirected.Scheme!="https")throw new InvalidOperationException();
                    current=redirected;
                    continue;
                }
                if(code!=200 || response.ContentLength>maximum)throw new InvalidOperationException();
                using(Stream input=response.GetResponseStream())
                using(MemoryStream body=new MemoryStream()) {
                    byte[] buffer=new byte[Math.Min(8192,maximum)];
                    try {
                        while(true) {
                            if(Remaining(deadline)==0)throw new TimeoutException();
                            int count=input.Read(buffer,0,Math.Min(buffer.Length,maximum-(int)body.Length+1));
                            if(count==0)break;
                            if(body.Length+count>maximum)throw new InvalidOperationException();
                            body.Write(buffer,0,count);
                        }
                        byte[] bytes=body.ToArray();
                        if(bytes.Length==0)throw new InvalidOperationException();
                        // Native PAC installations commonly include UTF-8 or UTF-16 BOMs.
                        // Decode strictly and give the VM fresh UTF-8 bytes without a BOM.
                        Encoding encoding=new UTF8Encoding(false,true); int offset=0;
                        if(bytes.Length>=3&&bytes[0]==239&&bytes[1]==187&&bytes[2]==191)offset=3;
                        else if(bytes.Length>=2&&bytes[0]==255&&bytes[1]==254){encoding=new UnicodeEncoding(false,false,true);offset=2;}
                        else if(bytes.Length>=2&&bytes[0]==254&&bytes[1]==255){encoding=new UnicodeEncoding(true,false,true);offset=2;}
                        try {
                            string script=encoding.GetString(bytes,offset,bytes.Length-offset);
                            if(script.IndexOf('\0')>=0)throw new InvalidOperationException();
                            byte[] utf8=new UTF8Encoding(false,true).GetBytes(script);
                            if(utf8.Length==0||utf8.Length>maximum){Array.Clear(utf8,0,utf8.Length);throw new InvalidOperationException();}
                            return utf8;
                        } finally { Array.Clear(bytes,0,bytes.Length); }
                    } finally { Array.Clear(buffer,0,buffer.Length); }
                }
            } finally {
                try {
                    request.Abort();
                    if(response!=null)response.Close();
                } finally {
                    if(!deadlineOwner.Retire(retirementDeadline))throw new PacOwnerDebtException();
                }
            }
        }
        throw new InvalidOperationException();
    }
    private sealed class Capture
    {
        private readonly Stream source;
        private readonly int maximum;
        public byte[] Bytes=new byte[0];
        public bool Ok;
        public Capture(Stream source,int maximum){this.source=source;this.maximum=maximum;}
        public void Read()
        {
            try {
                using(MemoryStream output=new MemoryStream()) {
                    byte[] buffer=new byte[Math.Min(8192,maximum+1)];
                    try {
                        while(true) {
                            int count=source.Read(buffer,0,Math.Min(buffer.Length,maximum-(int)output.Length+1));
                            if(count==0)break;
                            if(output.Length+count>maximum)return;
                            output.Write(buffer,0,count);
                        }
                        Bytes=output.ToArray();Ok=true;
                    } finally {Array.Clear(buffer,0,buffer.Length);}
                }
            } catch {Ok=false;}
        }
    }
    public static Result Execute(string executable,string expectedHash,string destination,string host,string location,
        long deadline,int retirementReserve,int scriptLimit,int outputLimit,int heapLimit,int queryLimit,int maxRedirects)
    {
        Result answer=new Result();
        Process child=null;
        Thread outputThread=null,errorThread=null;
        byte[] script=null,url=null,hostname=null;
        FileStream image=null;
        try {
            long workDeadline=deadline-retirementReserve;
            if(retirementReserve<1||Remaining(workDeadline)==0||scriptLimit<1||outputLimit<1||heapLimit<1||queryLimit<1||maxRedirects<1)
                return answer;
            image=new FileStream(executable,FileMode.Open,FileAccess.Read,FileShare.Read);
            using(SHA256 hash=SHA256.Create()) {
                byte[] actual=hash.ComputeHash(image);
                if(BitConverter.ToString(actual).Replace("-","").ToLowerInvariant()!=expectedHash)
                    throw new InvalidOperationException();
            }
            script=Fetch(location,workDeadline,deadline,scriptLimit,maxRedirects);
            url=new UTF8Encoding(false,true).GetBytes(destination);hostname=new UTF8Encoding(false,true).GetBytes(host);
            if(url.Length==0||url.Length>outputLimit||hostname.Length==0||hostname.Length>outputLimit)
                throw new InvalidOperationException();
            ProcessStartInfo start=new ProcessStartInfo(executable);
            start.UseShellExecute=false;start.CreateNoWindow=true;
            start.RedirectStandardInput=true;start.RedirectStandardOutput=true;start.RedirectStandardError=true;
            // A child inherits the already-owned Windows Job. No breakaway or URL arguments.
            child=Process.Start(start);
            Capture output=new Capture(child.StandardOutput.BaseStream,checked(44+outputLimit));
            Capture error=new Capture(child.StandardError.BaseStream,0);
            outputThread=new Thread(output.Read);errorThread=new Thread(error.Read);
            outputThread.IsBackground=true;errorThread.IsBackground=true;
            outputThread.Start();errorThread.Start();
            using(BinaryWriter writer=new BinaryWriter(child.StandardInput.BaseStream)) {
                writer.Write(Encoding.ASCII.GetBytes("ERGOPAC1"));writer.Write((UInt64)workDeadline);
                writer.Write((UInt32)script.Length);writer.Write((UInt32)url.Length);writer.Write((UInt32)hostname.Length);
                writer.Write(script);writer.Write(url);writer.Write(hostname);writer.Flush();
            }
            if(!child.WaitForExit(Remaining(workDeadline))||!outputThread.Join(Remaining(workDeadline))||
                !errorThread.Join(Remaining(workDeadline)))return answer;
            answer.OwnersRetired=true;
            if(child.ExitCode!=0||!output.Ok||!error.Ok||error.Bytes.Length!=0||output.Bytes.Length<44)
                return answer;
            byte[] frame=output.Bytes;
            if(Encoding.ASCII.GetString(frame,0,8)!="ERGOPAC3")return answer;
            UInt32 status=BitConverter.ToUInt32(frame,8);
            int nativeError=BitConverter.ToInt32(frame,12);
            UInt32 length=BitConverter.ToUInt32(frame,16);
            UInt64 peak=BitConverter.ToUInt64(frame,20),retained=BitConverter.ToUInt64(frame,28);
            UInt32 queries=BitConverter.ToUInt32(frame,36),domain=BitConverter.ToUInt32(frame,40);
            if(status>6||domain>3||length>outputLimit||frame.Length!=44+(long)length||peak>(UInt64)heapLimit||retained!=0||queries>queryLimit)
                return answer;
            answer.Backend="native_socket";
            if(status!=0) {
                if(status==5&&nativeError!=0&&domain>=1&&domain<=3){answer.NativeError=nativeError;answer.NativeErrorDomain=domain==1?"win32":domain==2?"winsock":"posix";answer.FailureOrigin="native";}
                else if(status==4)answer.FailureOrigin="application_budget";
                return answer;
            }
            if(nativeError!=0||domain!=0||length==0||Remaining(workDeadline)==0)return answer;
            string proxy=new UTF8Encoding(false,true).GetString(frame,44,(int)length);
            if(proxy.IndexOf('\0')>=0)return answer;
            answer.Proxy=proxy;answer.Ok=true;answer.Kind="pac_routes";answer.FailureOrigin="";
            return answer;
        } catch(PacOwnerDebtException) {
            answer.OwnersRetired=false;answer.Ok=false;answer.Kind="refused";answer.Proxy="";answer.NativeError=0;answer.FailureOrigin="owner_debt";
            return answer;
        } catch {
            answer.Ok=false;answer.Kind="refused";answer.Proxy="";answer.NativeError=0;answer.FailureOrigin="managed_boundary";
            return answer;
        } finally {
            if(child!=null) {
                try {
                    if(!child.HasExited)child.Kill();
                    bool stopped=child.WaitForExit(Remaining(deadline));
                    bool outputClosed=outputThread==null||outputThread.Join(Remaining(deadline));
                    bool errorClosed=errorThread==null||errorThread.Join(Remaining(deadline));
                    answer.OwnersRetired=stopped&&outputClosed&&errorClosed;
                } catch {answer.OwnersRetired=false;}
                child.Dispose();
            }
            if(image!=null)image.Dispose();
            if(script!=null)Array.Clear(script,0,script.Length);
            if(url!=null)Array.Clear(url,0,url.Length);
            if(hostname!=null)Array.Clear(hostname,0,hostname.Length);
            if(!answer.OwnersRetired){answer.Ok=false;answer.Kind="refused";answer.Proxy="";}
        }
    }
}
'@
}

function Resolve-ErgoptiFullUrlPac {
    param([string]$DestinationUrl, [string]$PacUrl, [bool]$AutoDetect, [long]$Deadline, $Policy)
    if ($PacUrl -eq '') {
        if (-not $AutoDetect) { throw 'Automatic configuration authority was refused.' }
        $Discovery = [ErgoptiNetworkPac]::Discover($Policy.max_proxy_bytes,$Deadline,[ErgoptiNativeProxyEx]::CleanupReserveMilliseconds)
        if (-not $Discovery.OwnersRetired -or -not $Discovery.Ok) { return $Discovery }
        $PacUrl = $Discovery.Location
    }
    $null = Get-ErgoptiDestination $PacUrl
    $Destination = Get-ErgoptiDestination $DestinationUrl
    $Native = $Policy.native_pac
    foreach ($Value in @($Native.max_script_bytes,$Native.max_heap_bytes,$Native.max_native_queries)) {
        if (-not (Test-ErgoptiNetworkInt32 $Value) -or $Value -lt 1) { throw 'Canonical PAC bounds were refused.' }
    }
    $ManifestPath = Join-Path $PSScriptRoot 'ergopti_network_pac.json'
    $ManifestOwner = [IO.FileStream]::new($ManifestPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        if ($ManifestOwner.Length -gt $Policy.max_proxy_bytes) { throw 'Native PAC identity bound was refused.' }
        $Reader = [IO.StreamReader]::new($ManifestOwner,[Text.UTF8Encoding]::new($false,$true),$false,1024,$true)
        try { $Identity = $Reader.ReadToEnd() | ConvertFrom-Json } finally { $Reader.Dispose() }
        if ($Identity.schema_version -ne 1 -or $Identity.exe_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
            $Identity.source_fingerprint -cnotmatch '^[0-9a-f]{64}$') { throw 'Native PAC source identity was refused.' }
        return [ErgoptiNetworkPac]::Execute((Join-Path $PSScriptRoot 'ergopti_network_pac.exe'),$Identity.exe_sha256,
            $DestinationUrl,$Destination.DnsSafeHost.Trim('[',']'),$PacUrl,$Deadline,[ErgoptiNativeProxyEx]::CleanupReserveMilliseconds,
            $Native.max_script_bytes,$Policy.max_proxy_bytes,$Native.max_heap_bytes,$Native.max_native_queries,$Policy.redirects.max_hops)
    } finally { $ManifestOwner.Dispose() }
}

function ConvertFrom-ErgoptiPacRoutes {
    param([string]$Value, $Policy)
    if ($Value -eq '' -or [Text.Encoding]::UTF8.GetByteCount($Value) -gt $Policy.max_proxy_bytes -or $Value -match '[\x00-\x1f\x7f]') {
        throw 'Complete native PAC answer was refused.'
    }
    $Routes = @()
    foreach ($Selection in $Value.Split(';')) {
        $Entry = $Selection.Trim()
        if ($Entry -ceq 'DIRECT') {
            $Routes += @{Kind='direct';Endpoint='';Source='native_direct';Authentication='none'}
        } elseif ($Entry -cmatch '^PROXY ([^\s;]+)$') {
            $Endpoint = Get-ErgoptiHttpRelay $Matches[1] $Policy
            $Routes += @{Kind='proxy';Endpoint=$Endpoint;Source='native_proxy';Authentication='current_user_proxy_only'}
        } else { throw 'Unsupported PAC route cannot be discarded.' }
        if ($Routes.Count -gt $Policy.max_selections) { throw 'Complete PAC selection bound was refused.' }
    }
    if ($Routes.Count -eq 0) { throw 'Empty PAC route list was refused.' }
    return ,$Routes
}
