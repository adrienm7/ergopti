# tests/fixtures/artifact_tunnel_retirement_controls.ps1
# Real TCP peers call the exact source relay request/response retirement methods.
param([Parameter(Mandatory = $true)][string]$ProxyPath)
$ErrorActionPreference = 'Stop'
$Source = [IO.File]::ReadAllText($ProxyPath, [Text.Encoding]::UTF8)
$Embedded = [regex]::Match($Source, '(?s)Add-Type -TypeDefinition @''\n(.*?)\n''@')
if (-not $Embedded.Success) { throw 'The actual native relay source is absent.' }
$Control = @'
public static class ErgoptiArtifactTunnelRetirementControls {
    sealed class Pair : IDisposable {
        public readonly TcpClient Reader, Writer;
        public Pair() {
            TcpListener listener=new TcpListener(IPAddress.Loopback,0);
            TcpClient writer=new TcpClient(); TcpClient reader=null;
            try {
                listener.Start(); writer.Connect((IPEndPoint)listener.LocalEndpoint);
                reader=listener.AcceptTcpClient(); reader.ReceiveTimeout=3000; reader.SendTimeout=3000;
                writer.ReceiveTimeout=3000; writer.SendTimeout=3000; Reader=reader; Writer=writer;
            } catch { writer.Close(); if(reader!=null) reader.Close(); throw; }
            finally { listener.Stop(); }
        }
        public void Dispose() { Reader.Close(); Writer.Close(); }
    }
    sealed class State {
        public volatile bool Stopping;
        public int Failures, CloseState;
        public bool ReceiverAliveAtRefusal;
        public Exception RequestFailure, OriginFailure;
        public string FailureOperation, RequestSite;
    }
    static void Require(bool value,string field) {
        if(!value) throw new InvalidDataException("Actual full-duplex control refused: "+field);
    }
    static void Equal(byte[] literal,byte[] actual,int count) {
        Require(count==literal.Length,"byte_count");
        for(int index=0;index<literal.Length;index++) Require(literal[index]==actual[index],"bytes");
    }
    static int ReadUntilEof(Stream source,byte[] buffer) {
        int used=0,count;
        while((count=source.Read(buffer,used,buffer.Length-used))!=0) {
            used+=count; if(used==buffer.Length) throw new InvalidDataException("Independent body bound exceeded.");
        }
        return used;
    }
    static void Case(System.Reflection.MethodInfo request,System.Reflection.MethodInfo response,string mode) {
        Pair origin=null, client=null; ManualResetEvent originEof=null, releaseOrigin=null, partialBody=null;
        Thread target=null, reverse=null, forward=null;
        State state=new State(); byte[] query=new byte[]{81,0,117,101,114,121,255};
        byte[] reply=new byte[]{82,101,112,108,121,0,255,99,1};
        try {
            origin=new Pair(); client=new Pair();
            originEof=new ManualResetEvent(false); releaseOrigin=new ManualResetEvent(false); partialBody=new ManualResetEvent(false);
            NetworkStream source=client.Reader.GetStream(), remote=origin.Writer.GetStream(), external=client.Writer.GetStream();
            reverse=new Thread(delegate() {
                try { response.Invoke(null,new object[]{remote,source,new Action<string,Exception>(delegate(string operation,Exception failure) {
                    if(!state.Stopping) { state.FailureOperation=operation; Interlocked.Increment(ref state.Failures); }
                })}); }
                finally { client.Reader.Close(); }
            }); reverse.IsBackground=true; reverse.Start();
            target=new Thread(delegate() {
                try {
                    Stream peer=origin.Reader.GetStream(); byte[] received=new byte[128]; int used=0;
                    if(mode=="response_first") {
                        while(used<query.Length) {int count=peer.Read(received,used,query.Length-used);if(count==0) break;used+=count;}
                    } else used=ReadUntilEof(peer,received);
                    Equal(query,received,used); originEof.Set();
                    if(!releaseOrigin.WaitOne(3000)) throw new TimeoutException("Owned origin release refused.");
                    if(mode=="foreign_origin") { origin.Reader.Client.LingerState=new LingerOption(true,0); origin.Reader.Client.Close(0); return; }
                    peer.Write(reply,0,reply.Length); partialBody.Set();
                    if(mode=="unfinished" || mode=="cancel") {
                        if(!releaseOrigin.WaitOne(3000)) throw new TimeoutException("Owned unfinished body release refused.");
                    } else origin.Reader.Client.Shutdown(SocketShutdown.Send);
                } catch(Exception failure) { state.OriginFailure=failure; }
            }); target.IsBackground=true; target.Start();
            forward=new Thread(delegate() {
                try { request.Invoke(null,new object[]{source,remote,origin.Writer,reverse,new Action<string>(delegate(string site) { state.RequestSite=site; })}); }
                catch(System.Reflection.TargetInvocationException failure) {
                    state.RequestFailure=failure.InnerException;
                    state.ReceiverAliveAtRefusal=reverse.IsAlive;
                    if(!state.Stopping) Interlocked.Increment(ref state.Failures);
                }
                finally {
                    Interlocked.Exchange(ref state.CloseState,1); origin.Writer.Close(); Interlocked.Exchange(ref state.CloseState,2);
                    client.Reader.Close();
                }
            }); forward.IsBackground=true; forward.Start();
            external.Write(query,0,query.Length);
            if(mode!="response_first") client.Writer.Client.Shutdown(SocketShutdown.Send);
            Require(originEof.WaitOne(1000),"request_eof_or_bytes");
            if(mode=="foreign_write") client.Reader.Close();
            releaseOrigin.Set();
            if(mode=="unfinished" || mode=="cancel") {
                Require(partialBody.WaitOne(1000),"progressing_partial_response");
                byte[] actual=new byte[128]; int used=0;
                while(used<reply.Length) {int count=external.Read(actual,used,reply.Length-used);if(count==0) break;used+=count;}
                Equal(reply,actual,used);
                if(mode=="cancel") {
                    state.Stopping=true; origin.Writer.Close(); client.Reader.Close();
                }
            }
            Require(forward.Join(3000),"forward_retirement"); Require(reverse.Join(3000),"reverse_retirement");
            Require(target.Join(3000),"origin_retirement");
            if(mode=="request_eof" || mode=="response_first") {
                Require(state.RequestFailure==null && state.OriginFailure==null && state.Failures==0,"successful_duplex");
                byte[] actual=new byte[128]; Equal(reply,actual,ReadUntilEof(external,actual));
                Require(state.CloseState==2 && !reverse.IsAlive,"full_close_after_receiver");
            } else if(mode=="unfinished") {
                Require(state.RequestFailure is InvalidOperationException,"original_join_failure");
                Require(state.RequestSite=="join_receiver" && state.ReceiverAliveAtRefusal,"unpaid_response_debt");
                Require(state.Failures>=1 && state.CloseState==2,"deadline_stays_red_then_owned_close");
            } else if(mode=="cancel") {
                Require(state.Stopping && state.Failures==0 && state.CloseState==2,"only_original_global_stop_cancels");
            } else {
                Require(state.Failures>=1,"foreign_failure_retained_"+mode);
                Require(state.FailureOperation==(mode=="foreign_write" ? "write" : "read"),"foreign_failure_operation");
            }
        } finally {
            state.Stopping=true;
            if(releaseOrigin!=null) releaseOrigin.Set();
            if(origin!=null) origin.Dispose(); if(client!=null) client.Dispose();
            Stopwatch retirement=Stopwatch.StartNew(); bool retired=true;
            foreach(Thread owned in new Thread[]{forward,reverse,target}) {
                int remaining=(int)Math.Max(0,3000-retirement.ElapsedMilliseconds);
                if(owned!=null && !owned.Join(remaining)) retired=false;
            }
            if(retired) {
                if(originEof!=null) originEof.Close(); if(releaseOrigin!=null) releaseOrigin.Close(); if(partialBody!=null) partialBody.Close();
            }
            Require(retired,"exact_component_threads_retired");
        }
    }
    public static int Run() {
        System.Reflection.MethodInfo request=typeof(ErgoptiArtifactNtlmProxy).GetMethod("CopyRequestAndRetireResponse",System.Reflection.BindingFlags.Static|System.Reflection.BindingFlags.NonPublic);
        System.Reflection.MethodInfo response=typeof(ErgoptiArtifactNtlmProxy).GetMethod("CopyResponse",System.Reflection.BindingFlags.Static|System.Reflection.BindingFlags.NonPublic);
        Require(request!=null && response!=null,"actual_source_methods");
        foreach(string mode in new string[]{"request_eof","response_first","foreign_write","foreign_origin","unfinished","cancel"}) Case(request,response,mode);
        return 6;
    }
}
'@
Add-Type -TypeDefinition ($Embedded.Groups[1].Value + [Environment]::NewLine + $Control)
[Console]::Out.WriteLine('ARTIFACT_TUNNEL_RETIREMENT_CONTROLS:' + [ErgoptiArtifactTunnelRetirementControls]::Run())
