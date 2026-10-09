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
    static void Case(int shutdownResult,int shutdownError,bool authenticated,bool expectedFailure,bool partialDrain=false) {
        TcpListener listener=new TcpListener(IPAddress.Loopback,0);
        TcpClient peer=new TcpClient(),origin=null;
        try {
            listener.Start();peer.Connect((IPEndPoint)listener.LocalEndpoint);origin=listener.AcceptTcpClient();
            peer.ReceiveTimeout=3000;
            result=shutdownResult;error=shutdownError;freed=drained=0;refuseAfterDrain=partialDrain;
            object owner=Owner();Type streamType=typeof(ErgoptiFixtureOpenSsl).GetNestedType("NativeStream",BindingFlags.NonPublic);
            Stream stream=(Stream)Empty(streamType);
            streamType.GetField("Owner").SetValue(stream,owner);
            Set(stream,"network",origin.GetStream());Set(stream,"encrypted",new byte[16384]);Set(stream,"ssl",new IntPtr(1));
            Set(stream,"authenticated",authenticated);Set(stream,"receivedEncrypted",9);Set(stream,"writtenEncrypted",11);
            bool failed=false;try{stream.Dispose();}catch(InvalidOperationException){failed=true;}catch(IOException){if(!partialDrain)throw;failed=true;}
            Require(failed==expectedFailure,"original_shutdown_failure_preserved");
            ErgoptiFixtureOpenSsl value=(ErgoptiFixtureOpenSsl)owner;
            ErgoptiFixtureOpenSsl.ClosedStreamFact fact=value.ReadClosedStream();
            Require(fact!=null && fact.Sequence==1 && fact.NetworkClosed==1,"actual_stream_dispose_ack");
            Require(fact.ShutdownCalled==(authenticated?1:0) && fact.ShutdownResult==(authenticated?result:0),"actual_owned_call_result");
            Require(fact.Received==9 && fact.Written==11+(authenticated&&(!expectedFailure||partialDrain)?3:0),"retained_byte_domains");
            Require(fact.CloseWritten==(authenticated&&(!expectedFailure||partialDrain)?3:0) && fact.Pending==0,"actual_close_progress");
            Require(freed==1 && value.OwnedStreams==0,"original_native_port_and_stream_retired");
            stream.Dispose();Require(freed==1 && value.ReadClosedStream().Sequence==1,"no_duplicate_native_close");
            NetworkStream reader=peer.GetStream();
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
        Case(0,0,true,false);Case(1,0,true,false);Case(-1,2,true,false);Case(-1,1,true,true);Case(0,0,false,false);Case(0,0,true,true,true);
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
    static int Shutdown(IntPtr ssl){calls++;if(calls==1)return 0;if(mode==0 || (mode==1&&calls==3))return 1;return -1;}
    static int Error(IntPtr ssl,int value){errors++;return mode==2 || (mode==5&&calls==3)?1:mode==4?3:2;}
    static void Free(IntPtr ssl){freed++;}
    static void Clear(){ }
    static int BioRead(IntPtr bio,IntPtr target,int count){if(drained++>0)return -1;Marshal.Copy(new byte[]{9,0,255},0,target,3);return 3;}
    static int BioWrite(IntPtr bio,IntPtr bytes,int count){Require(count==3,"actual_input_length");byte[] actual=new byte[3];Marshal.Copy(bytes,actual,0,3);Require(actual[0]==3&&actual[1]==0&&actual[2]==254,"actual_input_bytes");inputBytes+=count;return count;}
    static void Require(bool value,string label){if(!value)throw new InvalidDataException(label);}
    sealed class ObservedInput:NetworkStream {
        public int Reads;
        public ObservedInput(Socket socket):base(socket,true){ }
        public override int Read(byte[] bytes,int offset,int count){Reads++;return base.Read(bytes,offset,Math.Min(count,3));}
    }
    static void Case(int choice,bool queued,bool expectedFailure,int expectedCalls,int expectedErrors) {
        TcpListener listener=new TcpListener(IPAddress.Loopback,0);TcpClient peer=new TcpClient(),origin=null;Stream stream=null;
        try {
            listener.Start();peer.Connect((IPEndPoint)listener.LocalEndpoint);origin=listener.AcceptTcpClient();peer.ReceiveTimeout=3000;origin.ReceiveTimeout=3000;
            var network=new ObservedInput(origin.Client);
            if(queued){peer.GetStream().Write(choice==6?new byte[]{3,0,254,3,0,254}:new byte[]{3,0,254},0,choice==6?6:3);var elapsed=System.Diagnostics.Stopwatch.StartNew();while(!network.DataAvailable && elapsed.ElapsedMilliseconds<3000)System.Threading.Thread.Yield();Require(network.DataAvailable,"actual_input_queued");}
            mode=choice;calls=errors=freed=drained=inputBytes=0;
            var owner=(ErgoptiFixtureOpenSsl)Empty(typeof(ErgoptiFixtureOpenSsl));Set(owner,"gate",new object());Set(owner,"streams",1);
            Bind(owner,"shutdown","Shutdown");Bind(owner,"sslError","Error");Bind(owner,"sslFree","Free");Bind(owner,"bioRead","BioRead");Bind(owner,"bioWrite","BioWrite");Bind(owner,"clearError","Clear");
            Type type=typeof(ErgoptiFixtureOpenSsl).GetNestedType("NativeStream",BindingFlags.NonPublic);stream=(Stream)Empty(type);type.GetField("Owner").SetValue(stream,owner);
            Set(stream,"network",network);Set(stream,"encrypted",new byte[16384]);Set(stream,"ssl",new IntPtr(1));Set(stream,"authenticated",true);Set(stream,"receivedEncrypted",9);Set(stream,"writtenEncrypted",11);
            bool failed=false;try{stream.Dispose();}catch(InvalidOperationException){failed=true;}
            var fact=owner.ReadClosedStream();
            Require(failed==expectedFailure,"original_tls_error_not_waived");
            Require(calls==expectedCalls && errors==expectedErrors,"exact_calls_zero_never_get_error");
            Require(fact!=null&&fact.ShutdownResult==(choice==0||choice==1?1:-1)&&fact.NetworkClosed==1,"actual_final_shutdown_fact");
            Require(inputBytes==(queued?3:0)&&network.Reads==(queued?1:0),"only_already_readable_input");
            Require(fact.Received==9+(queued?3:0)&&fact.Written==14&&fact.CloseWritten==3&&fact.Pending==(choice==6?1:0),"retained_exact_byte_accounting");
            Require(freed==1&&owner.OwnedStreams==0,"actual_native_and_network_retirement");
            stream.Dispose();Require(freed==1&&owner.ReadClosedStream().Sequence==1,"no_duplicate_shutdown_owner");
            NetworkStream received=peer.GetStream();Require(received.ReadByte()==9&&received.ReadByte()==0&&received.ReadByte()==255&&received.ReadByte()==-1,"actual_output_and_eof");
        } finally {if(stream!=null)stream.Dispose();if(origin!=null)origin.Close();peer.Close();listener.Stop();}
    }
    public static int Run(){Case(0,false,false,2,0);Case(1,true,false,3,1);Case(2,false,true,2,1);Case(3,false,false,2,1);Case(4,false,false,2,1);Case(5,true,true,3,2);Case(6,true,false,3,2);return 7;}
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
