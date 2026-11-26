# tests/fixtures/owned_close_progress_controls.ps1
# Exact source closure/copy methods use controlled native ports and real TCP.
param([Parameter(Mandatory=$true)][string]$FixturePath,[Parameter(Mandatory=$true)][string]$ProxyPath,[switch]$QueuedShutdown)
$ErrorActionPreference='Stop'
$Fixture=[IO.File]::ReadAllText($FixturePath)
$Blocks=[regex]::Matches($Fixture,"(?s)Add-Type -TypeDefinition @'\n(.*?)\n'@")
if($Blocks.Count -ne 2){throw 'Expected exact two actual fixture definition blocks.'}
$Definitions=@($Blocks | ForEach-Object { $_.Groups[1].Value })
$Relay=[IO.File]::ReadAllText($ProxyPath)
$Block=[regex]::Match($Relay,"(?s)Add-Type -TypeDefinition @'\n(.*?)\n'@")
if(-not $Block.Success){throw 'Expected exact actual relay definition block.'}
$Definitions+= $Block.Groups[1].Value
$Control=@'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Reflection;
using System.Runtime.InteropServices;
public static class OwnedCloseProgressControls {
    static int freed, drained, result, error;
    static bool refuseAfterDrain;
    static object Empty(Type type) {
        Type factory=Type.GetType("System.Runtime.Serialization.FormatterServices, mscorlib",false);
        if(factory==null)factory=Type.GetType("System.Runtime.Serialization.FormatterServices, System.Runtime.Serialization.Formatters",true);
        return factory.GetMethod("GetUninitializedObject",BindingFlags.Static|BindingFlags.Public).Invoke(null,new object[]{type});
    }
    static int Shutdown(IntPtr pointer) { return result; }
    static int Error(IntPtr pointer,int value) { return error; }
    static void Free(IntPtr pointer) { freed++; }
    static void Clear() { }
    static int Bio(IntPtr pointer,IntPtr target,int count) {
        if(drained++>0){if(refuseAfterDrain)throw new IOException("PRIVATE_DRAIN_FAILURE");return -1;}
        Marshal.Copy(new byte[]{1,0,255},0,target,3);return 3;
    }
    static void Set(object owner,string name,object value) {
        owner.GetType().GetField(name,BindingFlags.Instance|BindingFlags.NonPublic).SetValue(owner,value);
    }
    static void Bind(object owner,string field,string method) {
        FieldInfo member=owner.GetType().GetField(field,BindingFlags.Instance|BindingFlags.NonPublic);
        member.SetValue(owner,Delegate.CreateDelegate(member.FieldType,typeof(OwnedCloseProgressControls).GetMethod(method,BindingFlags.Static|BindingFlags.NonPublic)));
    }
    static object Owner() {
        object owner=Empty(typeof(ErgoptiFixtureOpenSsl));
        Set(owner,"gate",new object());Set(owner,"streams",1);
        Bind(owner,"shutdown","Shutdown");Bind(owner,"sslError","Error");Bind(owner,"sslFree","Free");
        Bind(owner,"bioRead","Bio");Bind(owner,"clearError","Clear");return owner;
    }
    static void Require(bool value,string label){if(!value)throw new InvalidDataException(label);}
    static void Case(int shutdownResult,int shutdownError,bool authenticated,bool expectedFailure,string expectedPeerClose,bool partialDrain=false) {
        TcpListener listener=new TcpListener(IPAddress.Loopback,0);
        TcpClient peer=new TcpClient(),origin=null;
        try {
            listener.Start();peer.Connect((IPEndPoint)listener.LocalEndpoint);origin=listener.AcceptTcpClient();
            peer.ReceiveTimeout=3000;
            result=shutdownResult;error=shutdownError;freed=drained=0;refuseAfterDrain=partialDrain;
            object owner=Owner();Type streamType=typeof(ErgoptiFixtureOpenSsl).GetNestedType("NativeStream",BindingFlags.NonPublic);
            Stream stream=(Stream)Empty(streamType);
            streamType.GetField("Owner").SetValue(stream,owner);
            Set(stream,"network",new ErgoptiFixtureNetworkStream(origin.Client));Set(stream,"encrypted",new byte[16384]);Set(stream,"ssl",new IntPtr(1));
            Set(stream,"authenticated",authenticated);Set(stream,"receivedEncrypted",9);Set(stream,"writtenEncrypted",11);Set(stream,"peerCloseWaitMs",2000);
            // The peer has already closed its side: a wait for it ends at its FIN.
            NetworkStream reader=peer.GetStream();peer.Client.Shutdown(SocketShutdown.Send);
            bool failed=false;try{stream.Dispose();}catch(InvalidOperationException){failed=true;}catch(IOException){if(!partialDrain)throw;failed=true;}
            Require(failed==expectedFailure,"original_shutdown_failure_preserved");
            Require((string)streamType.GetField("peerClose",BindingFlags.Instance|BindingFlags.NonPublic).GetValue(stream)==expectedPeerClose,"peer_close_outcome");
            ErgoptiFixtureOpenSsl value=(ErgoptiFixtureOpenSsl)owner;
            ErgoptiFixtureOpenSsl.ClosedStreamFact fact=value.ReadClosedStream();
            Require(fact!=null && fact.Sequence==1 && fact.NetworkClosed==1,"actual_stream_dispose_ack");
            Require(fact.ShutdownCalled==(authenticated?1:0) && fact.ShutdownResult==(authenticated?result:0),"actual_owned_call_result");
            Require(fact.Received==9 && fact.Written==11+(authenticated&&(!expectedFailure||partialDrain)?3:0),"retained_byte_domains");
            Require(fact.CloseWritten==(authenticated&&(!expectedFailure||partialDrain)?3:0) && fact.Pending==0,"actual_close_progress");
            Require(freed==1 && value.OwnedStreams==0,"original_native_port_and_stream_retired");
            stream.Dispose();Require(freed==1 && value.ReadClosedStream().Sequence==1,"no_duplicate_native_close");
            if(authenticated&&(!expectedFailure||partialDrain))Require(reader.ReadByte()==1&&reader.ReadByte()==0&&reader.ReadByte()==255,"actual_output_bytes");
            Require(reader.ReadByte()==-1,"actual_network_closed");
        } finally {if(origin!=null)origin.Close();peer.Close();listener.Stop();}
    }
    sealed class FailingRead : MemoryStream {
        bool first=true;
        public override int Read(byte[] bytes,int offset,int count) {
            if(!first)throw new IOException("PRIVATE_NOT_LOGGED");first=false;
            bytes[offset]=0;bytes[offset+1]=255;return 2;
        }
    }
    sealed class FailingWrite : MemoryStream {
        public override void Write(byte[] bytes,int offset,int count){throw new IOException("PRIVATE_NOT_LOGGED");}
    }
    static void Response(bool failingWrite) {
        MethodInfo copy=typeof(ErgoptiArtifactNtlmProxy).GetMethod("CopyResponseObserved",BindingFlags.Static|BindingFlags.NonPublic);
        string operation=null;int read=-1,written=-1;Exception observed=null;
        using(Stream source=new FailingRead())using(Stream target=failingWrite?(Stream)new FailingWrite():new MemoryStream()) {
            copy.Invoke(null,new object[]{source,target,new Action<string,Exception,int,int>(delegate(string op,Exception failure,int received,int sent) {
                operation=op;observed=failure;read=received;written=sent;
            })});
        }
        Require(observed is IOException && operation==(failingWrite?"write":"read"),"original_exact_failure_operation");
        Require(read==2 && written==(failingWrite?0:2),"source_owned_response_progress");
    }
    public static int Run() {
        Case(0,0,true,false,"peer_closed");Case(1,0,true,false,"received");Case(-1,2,true,false,"peer_closed");
        Case(-1,1,true,true,null);Case(0,0,false,false,null);Case(0,0,true,true,null,true);
        object owner=Owner();MethodInfo observe=typeof(ErgoptiFixtureOpenSsl).GetMethod("ObserveClosedStream",BindingFlags.Instance|BindingFlags.NonPublic);
        observe.Invoke(owner,new object[]{1,0,0,1,1,1,-1,false});
        Require(((ErgoptiFixtureOpenSsl)owner).ReadClosedStream()==null,"unacknowledged_close_unavailable");
        Response(false);Response(true);
        object relay=Empty(typeof(ErgoptiArtifactNtlmProxy));
        MethodInfo failure=typeof(ErgoptiArtifactNtlmProxy).GetMethod("ObserveException",BindingFlags.Instance|BindingFlags.NonPublic);
        failure.Invoke(relay,new object[]{"forward_response",new IOException("PRIVATE_FIRST"),"read",0,false,17,11});
        failure.Invoke(relay,new object[]{"forward_response",new IOException("PRIVATE_SECOND"),"write",2,true,999,998});
        ErgoptiArtifactNtlmProxy.FailureObservation first=((ErgoptiArtifactNtlmProxy)relay).FirstFailure;
        Require(first.ResponseRead==17&&first.ResponseWritten==11&&first.Operation=="read"&&first.TargetCloseState==0,"one_immutable_first_failure_snapshot");
        return 10;
    }
}
// Actual source Dispose uses controlled TLS ports; socket input/closure are real.
public static class QueuedTlsShutdownControls {
    const BindingFlags Private=BindingFlags.Instance|BindingFlags.NonPublic;
    static int calls,errors,freed,drained,inputBytes,mode;
    static object Empty(Type type) {
        Type factory=Type.GetType("System.Runtime.Serialization.FormatterServices, mscorlib",false);
        if(factory==null)factory=Type.GetType("System.Runtime.Serialization.FormatterServices, System.Runtime.Serialization.Formatters",true);
        return factory.GetMethod("GetUninitializedObject",BindingFlags.Static|BindingFlags.Public).Invoke(null,new object[]{type});
    }
    static void Set(object owner,string field,object value){owner.GetType().GetField(field,Private).SetValue(owner,value);}
    static void Bind(object owner,string field,string method){FieldInfo member=owner.GetType().GetField(field,Private);member.SetValue(owner,Delegate.CreateDelegate(member.FieldType,typeof(QueuedTlsShutdownControls).GetMethod(method,BindingFlags.Static|BindingFlags.NonPublic)));}
    // Mode 7: the client's close_notify, read during the peer wait, completes the shutdown.
    static int Shutdown(IntPtr ssl){calls++;if(calls==1)return 0;if(mode==0 || (mode==1&&calls==3) || (mode==7&&calls>=3))return 1;return -1;}
    static int Error(IntPtr ssl,int value){errors++;return mode==2 || (mode==5&&calls==3)?1:mode==4?3:2;}
    static void Free(IntPtr ssl){freed++;}
    static void Clear(){ }
    static int BioRead(IntPtr bio,IntPtr target,int count){if(drained++>0)return -1;Marshal.Copy(new byte[]{9,0,255},0,target,3);return 3;}
    static int BioWrite(IntPtr bio,IntPtr bytes,int count){Require(count==3,"actual_input_length");byte[] actual=new byte[3];Marshal.Copy(bytes,actual,0,3);Require(actual[0]==3&&actual[1]==0&&actual[2]==254,"actual_input_bytes");inputBytes+=count;return count;}
    static void Require(bool value,string label){if(!value)throw new InvalidDataException(label);}
    sealed class ObservedInput:ErgoptiFixtureNetworkStream {
        public int Reads;
        public ObservedInput(Socket socket):base(socket){ }
        public override int Read(byte[] bytes,int offset,int count){Reads++;return base.Read(bytes,offset,Math.Min(count,3));}
    }
    // Peer behaviours: Silent never closes; Fin half-closes before the close starts;
    // Notify answers the server's close as a TLS client does, with its own close
    // record once it has read the server's output and FIN.
    const int Silent=0,Fin=1,Notify=2;
    static void Case(int choice,int caseMode,int queuedBytes,int peerMode,int waitMs,bool expectedFailure,int expectedCalls,int expectedErrors,
        int expectedInput,string expectedPeerClose,int expectedPending,int expectedDiscarded) {
        TcpListener listener=new TcpListener(IPAddress.Loopback,0);TcpClient peer=new TcpClient(),origin=null;Stream stream=null;
        System.Threading.Thread answer=null;int[] seen=new int[]{-2,-2,-2,-2};Exception answerFailure=null;
        try {
            listener.Start();peer.Connect((IPEndPoint)listener.LocalEndpoint);origin=listener.AcceptTcpClient();peer.ReceiveTimeout=3000;origin.ReceiveTimeout=3000;
            var network=new ObservedInput(origin.Client);NetworkStream client=peer.GetStream();
            if(queuedBytes>0){client.Write(queuedBytes==6?new byte[]{3,0,254,3,0,254}:new byte[]{3,0,254},0,queuedBytes);var elapsed=System.Diagnostics.Stopwatch.StartNew();while(origin.Available<queuedBytes && elapsed.ElapsedMilliseconds<3000)System.Threading.Thread.Yield();Require(origin.Available==queuedBytes,"actual_input_queued");}
            if(peerMode==Fin)peer.Client.Shutdown(SocketShutdown.Send);
            if(peerMode==Notify){
                answer=new System.Threading.Thread(delegate() {
                    try {for(int index=0;index<4;index++)seen[index]=client.ReadByte();client.Write(new byte[]{3,0,254},0,3);}
                    catch(Exception failure){answerFailure=failure;}
                });
                answer.IsBackground=true;answer.Start();
            }
            mode=caseMode;calls=errors=freed=drained=inputBytes=0;
            var owner=(ErgoptiFixtureOpenSsl)Empty(typeof(ErgoptiFixtureOpenSsl));Set(owner,"gate",new object());Set(owner,"streams",1);
            Bind(owner,"shutdown","Shutdown");Bind(owner,"sslError","Error");Bind(owner,"sslFree","Free");Bind(owner,"bioRead","BioRead");Bind(owner,"bioWrite","BioWrite");Bind(owner,"clearError","Clear");
            Type type=typeof(ErgoptiFixtureOpenSsl).GetNestedType("NativeStream",BindingFlags.NonPublic);stream=(Stream)Empty(type);type.GetField("Owner").SetValue(stream,owner);
            Set(stream,"network",network);Set(stream,"encrypted",new byte[16384]);Set(stream,"ssl",new IntPtr(1));Set(stream,"authenticated",true);Set(stream,"receivedEncrypted",9);Set(stream,"writtenEncrypted",11);
            Set(stream,"peerCloseWaitMs",waitMs);
            var closing=System.Diagnostics.Stopwatch.StartNew();
            bool failed=false;try{stream.Dispose();}catch(InvalidOperationException){failed=true;}
            closing.Stop();
            if(answer!=null)Require(answer.Join(3000)&&answerFailure==null,"peer_answer_completed");
            var fact=owner.ReadClosedStream();
            Require(failed==expectedFailure,"original_tls_error_not_waived");
            Require(calls==expectedCalls && errors==expectedErrors,"exact_calls_zero_never_get_error");
            Require((string)type.GetField("peerClose",Private).GetValue(stream)==expectedPeerClose,"peer_close_outcome");
            // Only an expired wait spends its bound; every other close ends at the peer's own close.
            Require(expectedPeerClose=="wait_expired"?closing.ElapsedMilliseconds>=waitMs-50:closing.ElapsedMilliseconds<waitMs,"peer_wait_bounded");
            bool completed=expectedPeerClose=="received"||expectedPeerClose=="peer_close_notify";
            Require(fact!=null&&fact.ShutdownResult==(completed?1:-1)&&fact.NetworkClosed==1,"actual_final_shutdown_fact");
            Require(inputBytes==expectedInput&&network.Reads==expectedInput/3,"only_already_readable_input");
            Require(fact.Received==9+expectedInput&&fact.Written==14&&fact.CloseWritten==3&&fact.Pending==expectedPending,"retained_exact_byte_accounting");
            Require(network.DiscardedInputBytes==expectedDiscarded,"only_captured_raw_bytes_retired_outside_TLS");
            Require(freed==1&&owner.OwnedStreams==0,"actual_native_and_network_retirement");
            stream.Dispose();Require(freed==1&&owner.ReadClosedStream().Sequence==1,"no_duplicate_shutdown_owner");
            if(answer==null)for(int index=0;index<4;index++)seen[index]=client.ReadByte();
            Require(seen[0]==9&&seen[1]==0&&seen[2]==255&&seen[3]==-1,"actual_output_and_eof");
        } catch(Exception failure) {
            QueuedTlsShutdownObservation.Report(choice,stream,failure,calls,errors,inputBytes);
            throw;
        } finally {if(stream!=null)stream.Dispose();if(origin!=null)origin.Close();peer.Close();listener.Stop();if(answer!=null)answer.Join(3000);}
    }
    public static int Run(){
        // The close the peer already sent ends it at once, even from a silent peer.
        Case(0,0,0,Silent,2000,false,2,0,0,"received",0,0);
        Case(1,1,3,Silent,2000,false,3,1,3,"received",0,0);
        // A TLS fault is never waived, and no wait follows it.
        Case(2,2,0,Silent,2000,true,2,1,0,null,0,0);
        // The server half-closes and waits for the client's close: its FIN...
        Case(3,3,0,Fin,2000,false,2,1,0,"peer_closed",0,0);
        Case(4,4,0,Fin,2000,false,2,1,0,"peer_closed",0,0);
        Case(5,5,3,Silent,2000,true,3,2,3,null,0,0);
        Case(6,6,6,Fin,2000,false,4,3,6,"peer_closed",0,0);
        // ...or its close_notify, sent only after it read the server's FIN.
        Case(7,7,0,Notify,2000,false,3,1,3,"peer_close_notify",0,0);
        // A client that never closes costs the bound, then the server closes.
        Case(8,3,0,Silent,300,false,2,1,0,"wait_expired",0,0);
        // A TLS fault in the client's close stays an error.
        Case(9,5,0,Notify,2000,true,3,2,3,null,0,0);
        // Input left by a failed close is retired outside TLS, never reset.
        Case(10,5,6,Silent,2000,true,3,2,3,null,1,3);
        return 11;
    }
}

// Optional facts bind this exact controlled Case stream; they cannot replace its failure.
public static class QueuedTlsShutdownObservation {
    static string I(int value) { return value.ToString(System.Globalization.CultureInfo.InvariantCulture); }
    public static void Report(int choice,Stream stream,Exception failure,int calls,int errors,int input) {
        try {
            if(choice<0 || choice>10 || failure==null)return;
            ErgoptiFixtureOpenSsl.ClosedStreamFact fact=null;
            if(stream!=null) {
                FieldInfo field=stream.GetType().GetField("Owner",BindingFlags.Public|BindingFlags.Instance);
                var owner=field==null?null:field.GetValue(stream) as ErgoptiFixtureOpenSsl;
                if(owner!=null)fact=owner.ReadClosedStream();
            }
            string phase=fact==null?"unavailable":"closed";
            if(failure is InvalidDataException) {
                switch(failure.Message) {
                    case "actual_input_queued":phase="assert_queued";break;
                    case "original_tls_error_not_waived":phase="assert_tls";break;
                    case "exact_calls_zero_never_get_error":phase="assert_calls";break;
                    case "actual_final_shutdown_fact":phase="assert_fact";break;
                    case "actual_input_length":case "actual_input_bytes":case "only_already_readable_input":phase="assert_input";break;
                    case "retained_exact_byte_accounting":phase="assert_bytes";break;
                    case "actual_native_and_network_retirement":phase="assert_retired";break;
                    case "no_duplicate_shutdown_owner":phase="assert_duplicate";break;
                    case "actual_output_and_eof":phase="assert_output";break;
                    case "peer_close_outcome":case "peer_answer_completed":phase="assert_peer";break;
                    case "peer_wait_bounded":phase="assert_wait";break;
                }
            }
            string family=failure is InvalidDataException?"invalid_data":failure is InvalidOperationException?"invalid_operation":failure is IOException?"io":"other";
            int code=-1;
            Exception current=failure;
            for(int depth=0;current!=null && depth<8;depth++,current=current.InnerException) {
                var socket=current as SocketException;
                if(socket!=null){family="socket";code=socket.NativeErrorCode;break;}
            }
            if(family=="socket" && code<0)return;
            string fields=" case="+I(choice)+" phase="+phase+" family="+family+" code="+I(code)+" hresult="+I(failure.HResult)+" fact="+(fact==null?"0":"1");
            fields+=" sequence="+I(fact==null?-1:fact.Sequence)+" called="+I(fact==null?-1:fact.ShutdownCalled)+" result="+I(fact==null?-1:fact.ShutdownResult)+" error="+I(fact==null?-1:fact.ShutdownError);
            fields+=" received="+I(fact==null?-1:fact.Received)+" written="+I(fact==null?-1:fact.Written)+" close_written="+I(fact==null?-1:fact.CloseWritten)+" pending="+I(fact==null?-1:fact.Pending)+" network_closed="+I(fact==null?-1:fact.NetworkClosed);
            fields+=" calls="+I(fact==null?-1:calls)+" errors="+I(fact==null?-1:errors)+" input="+I(fact==null?-1:input);
            Console.Out.WriteLine("OWNED_QUEUED_TLS_SHUTDOWN_FAILURE"+fields);
        } catch(Exception) { /* Optional publication never replaces the original Case exception. */ }
    }
}


'@
$Definitions+=$Control
$Imports=@(); $Bodies=@()
foreach($Definition in $Definitions){
    $Imports += @([regex]::Matches($Definition,'(?m)^using [^;]+;') | ForEach-Object {$_.Value})
    $Bodies += [regex]::Replace($Definition,'(?m)^using [^;]+;\r?\n','')
}
Add-Type -TypeDefinition ((($Imports | Select-Object -Unique) -join "`n")+"`n"+($Bodies -join "`n"))
if($QueuedShutdown){
    [Console]::Out.WriteLine('OWNED_QUEUED_TLS_SHUTDOWN_CONTROLLED_PORTS:'+([QueuedTlsShutdownControls]::Run()))
    return
}
$Count=[OwnedCloseProgressControls]::Run()
# Call the exact publisher with a failed new getter; original failure/state publication must survive.
$Ast=[Management.Automation.Language.Parser]::ParseInput($Fixture,[ref]$null,[ref]$null)
$Publisher=@($Ast.FindAll({param($Node) $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -ceq 'Publish-State'},$true))
if($Publisher.Count -ne 1){throw 'Exact original publisher ownership unavailable.'}
. ([scriptblock]::Create($Publisher[0].Extent.Text))
$Native=[pscustomobject]@{Version=3;SslImageHash='';CryptoImageHash='';KeyEphemeral=$true;PrivateDerCleared=$true;
    SourceUnchanged=$true;OwnedModuleReferences=2;OwnedSourceFences=2;OwnedStreams=0}
$Native|Add-Member -MemberType ScriptMethod -Name ReadClosedStream -Value {throw 'PRIVATE_OBSERVER_REFUSAL'}
$Fixture=[pscustomobject]@{NativeTls=$Native}
$Fixture|Add-Member -MemberType ScriptMethod -Name ReadServiceFailure -Value {[pscustomobject]@{Stage='service_request';Kind='io';HResult=-123}}
$State=@{sequence=0}
$StatePath=Join-Path ([IO.Path]::GetTempPath()) ('ErgoptiOwnedCloseObservation-'+[Guid]::NewGuid().ToString('N')+'.json')
$Lease=$null
try {
    $Lease=[IO.File]::Open($StatePath,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::ReadWrite)
    $Lease.Dispose()
    $Lease=[IO.File]::Open($StatePath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    Publish-State
    $Received=[IO.File]::ReadAllText($StatePath)|ConvertFrom-Json
    if($Received.sequence -ne 1 -or $Received.service_failure_stage -cne 'service_request' -or
        $Received.service_failure_kind -cne 'io' -or $Received.service_failure_hresult -ne -123) {
        throw 'New observer suppressed original service failure/state acknowledgement.'
    }
} finally {
    if($null -ne $Lease){$Lease.Dispose();[IO.File]::Delete($StatePath)}
}
[Console]::Out.WriteLine('OWNED_CLOSE_PROGRESS_CONTROLLED_PORTS:'+($Count+1))
