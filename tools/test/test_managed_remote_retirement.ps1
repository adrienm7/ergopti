# tools/test/test_managed_remote_retirement.ps1
# Exercise the actual accept and retirement bodies using owned loopback sockets.
param(
    [string]$FixturePath = (Join-Path $PSScriptRoot '../../static/ergopti_plus/windows/tests/fixtures/managed_remote_transport.ps1')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$Text = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $FixturePath), [Text.Encoding]::UTF8)
function Get-Body([string]$Pattern) {
    $Matches = [regex]::Matches($Text, $Pattern)
    if ($Matches.Count -ne 1) { throw 'Actual fixture body must have one source binding.' }
    return $Matches[0].Value
}
$Listen = Get-Body '(?s)    private TcpListener Listen\(IPAddress address\).*?(?=    private void Start\()'
$Start = Get-Body '(?s)    private void Start\(TcpListener listener, Action<TcpClient> serve\).*?(?=    private static string Header\()'
$Header = Get-Body '(?s)    private static string Header\(Stream stream\).*?(?=    private static void Reply\()'
$Dispose = Get-Body '(?s)    public void Dispose\(\)\n    \{\n        stopping=true;.*?\n    \}\n(?=\}\n''@)'
function Add-Barrier([string]$Body, [string]$Before, [string]$After) {
    if ([regex]::Matches($Body, [regex]::Escape($Before)).Count -ne 1) {
        throw 'Actual fixture barrier must have one source seam.'
    }
    return $Body.Replace($Before, $After)
}
$AcceptSeam = 'TcpClient client = listener.AcceptTcpClient(); client.ReceiveTimeout = 5000; client.SendTimeout = 5000;'
$Start = Add-Barrier $Start $AcceptSeam ($AcceptSeam + ' AfterAccept(client);')
$CloseSeam = 'lock(gate) foreach(TcpClient client in clients.ToArray()) client.Close();'
$Dispose = Add-Barrier $Dispose $CloseSeam ($CloseSeam + ' AfterInitialClose();')
$Prefix = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

// Crypto teardown is an explicit recording port; no certificate or native TLS is created.
public sealed class ManagedRetirementBody : IDisposable
{
    private readonly List<TcpListener> listeners = new List<TcpListener>();
    private readonly List<Thread> listenersThreads = new List<Thread>();
    private readonly List<Thread> workers = new List<Thread>();
    private readonly List<TcpClient> clients = new List<TcpClient>();
    private readonly object gate = new object();
    private volatile bool stopping;
    private int ClosedConnections, ServiceFailures;
    private readonly IDisposable NativeTls, leaf, Root, leafKey, rootKey;
    private int TeardownCalls, HandlerCalls;
    private TcpClient acceptedClient;
    private readonly ManualResetEvent accepted = new ManualResetEvent(false);
    private readonly ManualResetEvent resumeAccept = new ManualResetEvent(false);
    private readonly ManualResetEvent initiallyClosed = new ManualResetEvent(false);
    private readonly ManualResetEvent enteredHandler = new ManualResetEvent(false);
    private readonly bool pauseAccept;
    private sealed class TeardownPort : IDisposable
    {
        private readonly ManagedRetirementBody owner;
        public TeardownPort(ManagedRetirementBody owner) { this.owner = owner; }
        public void Dispose() { Interlocked.Increment(ref owner.TeardownCalls); }
    }
    private ManagedRetirementBody(bool pauseAccept)
    {
        this.pauseAccept = pauseAccept;
        NativeTls = new TeardownPort(this); leaf = new TeardownPort(this);
        Root = new TeardownPort(this); leafKey = new TeardownPort(this); rootKey = new TeardownPort(this);
    }
    private void CaptureServiceFailure(string stage, Exception failure) { }
    private void AfterAccept(TcpClient client)
    {
        acceptedClient = client;
        accepted.Set();
        if (pauseAccept) resumeAccept.WaitOne();
    }
    private void AfterInitialClose() { initiallyClosed.Set(); }
    private void Serve(TcpClient client)
    {
        Interlocked.Increment(ref HandlerCalls); enteredHandler.Set();
        Header(client.GetStream());
    }
    private static void Require(bool value, string cause)
    {
        if (!value) throw new InvalidOperationException(cause);
    }
    public static void RunCase(bool late)
    {
        ManagedRetirementBody owner = new ManagedRetirementBody(late);
        TcpClient peer = new TcpClient();
        Thread retire = null;
        Exception refusal = null;
        bool retirementAcknowledged = false;
        try {
            TcpListener listener = owner.Listen(IPAddress.Loopback);
            owner.Start(listener, owner.Serve);
            peer.ReceiveTimeout = 5000; peer.SendTimeout = 5000;
            peer.Connect((IPEndPoint)listener.LocalEndpoint);
            Require(owner.accepted.WaitOne(5000), "actual_accept_witness_missing");
            if (!late) Require(owner.enteredHandler.WaitOne(5000), "admitted_handler_witness_missing");
            retire = new Thread(() => {
                try { owner.Dispose(); retirementAcknowledged = true; }
                catch (Exception failure) { refusal = failure; }
            });
            retire.Start();
            Require(owner.initiallyClosed.WaitOne(5000), "actual_initial_client_close_witness_missing");
            owner.resumeAccept.Set();
            Require(retire.Join(5000), "actual_retirement_thread_unsettled");
            Require(retirementAcknowledged && refusal == null,
                "late_client_retirement_must_be_acknowledged" + (refusal == null ? "" : ": " + refusal.Message));
            Require(owner.HandlerCalls == (late ? 0 : 1), "stop_winner_must_not_start_late_handler");
            Require(owner.ServiceFailures == 0, "unexpected_service_failure_must_remain_visible");
            Require(owner.TeardownCalls == 5, "all_explicit_teardown_ports_must_acknowledge");
            int received;
            try { received = peer.GetStream().ReadByte(); }
            catch (IOException failure) { throw new InvalidOperationException("same_peer_must_observe_actual_eof", failure); }
            Require(received == -1, "same_peer_must_observe_actual_eof");
            lock (owner.gate) {
                Require(owner.clients.Count == 0, "exact_client_ledger_must_be_empty");
                foreach (Thread worker in owner.workers) Require(!worker.IsAlive, "actual_worker_must_be_terminal");
            }
            foreach (Thread accept in owner.listenersThreads) Require(!accept.IsAlive, "actual_accept_must_be_terminal");
        } finally {
            // A red assertion never abandons the accepted socket or a retained worker.
            owner.resumeAccept.Set(); peer.Close();
            if (owner.acceptedClient != null) owner.acceptedClient.Close();
            if (retire != null) retire.Join();
            foreach (TcpListener listener in owner.listeners) listener.Stop();
            lock (owner.gate) foreach (TcpClient client in owner.clients.ToArray()) client.Close();
            foreach (Thread accept in owner.listenersThreads) accept.Join();
            Thread[] pending; lock (owner.gate) pending = owner.workers.ToArray();
            foreach (Thread worker in pending) worker.Join();
            if (!retirementAcknowledged) owner.Dispose();
            owner.accepted.Dispose(); owner.resumeAccept.Dispose();
            owner.initiallyClosed.Dispose(); owner.enteredHandler.Dispose();
        }
    }
'@
$Source = $Prefix + $Listen + $Start + $Header + $Dispose + "}`n"
Add-Type -TypeDefinition $Source
[ManagedRetirementBody]::RunCase($false)
[Console]::Out.WriteLine('PASS admitted-client exact close and retirement')
[ManagedRetirementBody]::RunCase($true)
[Console]::Out.WriteLine('PASS late-client admission refusal and retirement')
