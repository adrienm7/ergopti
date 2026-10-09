# tests/fixtures/artifact_relay_controls.ps1
# Real TCP component controls use the actual relay copier, without claiming SSPI.
param([Parameter(Mandatory = $true)][string]$ProxyPath)
$ErrorActionPreference = 'Stop'
$Source = [IO.File]::ReadAllText($ProxyPath, [Text.Encoding]::UTF8)
$Embedded = [regex]::Match($Source, '(?s)Add-Type -TypeDefinition @''\n(.*?)\n''@')
if (-not $Embedded.Success) { throw 'The actual native relay source is absent.' }
$Control = @'
public static class ErgoptiArtifactRelayControls {
    sealed class Pair : IDisposable {
        public readonly TcpClient Reader, Writer;
        public Pair() {
            TcpListener listener=new TcpListener(IPAddress.Loopback,0);
            TcpClient writer=new TcpClient(); TcpClient reader=null;
            try {
                listener.Start(); writer.Connect((IPEndPoint)listener.LocalEndpoint);
                reader=listener.AcceptTcpClient();
                reader.ReceiveTimeout=3000; reader.SendTimeout=3000;
                writer.ReceiveTimeout=3000; writer.SendTimeout=3000;
                Reader=reader; Writer=writer;
            } catch { writer.Close(); if(reader!=null) reader.Close(); throw; }
            finally { listener.Stop(); }
        }
        public void Dispose() { Reader.Close(); Writer.Close(); }
    }
    sealed class ReadNotice : Stream {
        readonly Stream source; readonly ManualResetEvent entered; readonly bool refuse;
        readonly int signalAtRead; int reads;
        public ReadNotice(Stream source, ManualResetEvent entered, bool refuse, int signalAtRead) {
            this.source=source; this.entered=entered; this.refuse=refuse; this.signalAtRead=signalAtRead;
        }
        public override int Read(byte[] buffer,int offset,int count) {
            if(++reads==signalAtRead) entered.Set(); if(refuse) throw new IOException("Independent read refusal.");
            return source.Read(buffer,offset,count);
        }
        public override bool CanRead { get { return true; } }
        public override bool CanSeek { get { return false; } }
        public override bool CanWrite { get { return false; } }
        public override long Length { get { throw new NotSupportedException(); } }
        public override long Position { get { throw new NotSupportedException(); } set { throw new NotSupportedException(); } }
        public override void Flush() { throw new NotSupportedException(); }
        public override long Seek(long offset,SeekOrigin origin) { throw new NotSupportedException(); }
        public override void SetLength(long value) { throw new NotSupportedException(); }
        public override void Write(byte[] buffer,int offset,int count) { throw new NotSupportedException(); }
    }
    static void Require(bool value) { if(!value) throw new InvalidDataException("Actual relay TCP control refused."); }
    static void Case(System.Reflection.MethodInfo copy,string mode) {
        Pair remote=null, client=null; ManualResetEvent entered=null; Thread worker=null;
        Exception escaped=null, observed=null;
        string operation=null; int failures=0, closeState=0, observedClose=-1;
        try {
            remote=new Pair(); client=new Pair(); entered=new ManualResetEvent(false);
            Stream source=new ReadNotice(remote.Reader.GetStream(),entered,mode=="foreign_read",mode=="owned_read" ? 2 : 1);
            Stream destination=client.Writer.GetStream();
            byte[] literal=new byte[]{0,111,119,110,101,100,255,1,2,3};
            if(mode=="foreign_write") client.Writer.Close();
            worker=new Thread(delegate() {
                try { copy.Invoke(null,new object[]{source,destination,new Action<string,Exception>(delegate(string site,Exception failure) {
                    operation=site; observed=failure; observedClose=Interlocked.CompareExchange(ref closeState,0,0);
                    Interlocked.Increment(ref failures);
                })}); }
                catch(Exception failure) { escaped=failure; }
                finally { client.Writer.Close(); }
            }); worker.IsBackground=true; worker.Start();
            if(mode=="owned_read") {
                // The literal body crosses both real TCP pairs before the
                // second read waits for an unfinished origin body.
                remote.Writer.GetStream().Write(literal,0,literal.Length);
            }
            Require(entered.WaitOne(1000));
            if(mode=="owned_read") {
                // Match the actual source owner: close starts before Close,
                // and its acknowledgement is paid only after Close returns.
                Interlocked.Exchange(ref closeState,1); remote.Reader.Close(); Interlocked.Exchange(ref closeState,2);
            } else if(mode!="foreign_read") {
                NetworkStream bytes=remote.Writer.GetStream(); bytes.Write(literal,0,literal.Length);
                remote.Writer.Client.Shutdown(SocketShutdown.Send);
            }
            Require(worker.Join(3000)); Require(escaped==null);
            if(mode=="payload" || mode=="owned_read") {
                if(mode=="payload") Require(failures==0 && observed==null && closeState==0);
                else Require(failures==1 && observed!=null && operation=="read" && observedClose>=1 && observedClose<=2);
                byte[] actual=new byte[16]; int used=0, count;
                while((count=client.Reader.GetStream().Read(actual,used,actual.Length-used))!=0) used+=count;
                Require(used==literal.Length);for(int index=0;index<literal.Length;index++) Require(actual[index]==literal[index]);
            } else {
                Require(failures==1 && observed!=null);
                Require(operation==(mode=="foreign_write" ? "write" : "read"));
                Require(mode=="owned_read" ? observedClose>=1 && observedClose<=2 : observedClose==0);
                if(mode=="foreign_read") Require(observed is IOException);
            }
        } finally {
            if(remote!=null) remote.Dispose(); if(client!=null) client.Dispose();
            // Never dispose the read-entry signal while its exact worker remains live.
            bool retired=worker==null || worker.Join(3000);
            if(retired && entered!=null) entered.Close();
            Require(retired);
        }
    }
    public static int Run() {
        System.Reflection.MethodInfo copy=typeof(ErgoptiArtifactNtlmProxy).GetMethod("CopyResponse",System.Reflection.BindingFlags.Static|System.Reflection.BindingFlags.NonPublic);
        Require(copy!=null);
        foreach(string mode in new string[]{"payload","owned_read","foreign_write","foreign_read"}) Case(copy,mode);
        return 4;
    }
}
'@
Add-Type -TypeDefinition ($Embedded.Groups[1].Value + [Environment]::NewLine + $Control)
[Console]::Out.WriteLine('ARTIFACT_RELAY_TCP_CONTROLS:' + [ErgoptiArtifactRelayControls]::Run())
