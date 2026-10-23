# vendor/ergopti_winhttp_transport.ps1
# Windows system HTTP stack (WinHTTP) transport for the managed remote requests.
#
# Why WinHTTP: it is the stack Windows itself uses for proxies, so it follows
# the route list chosen by ergopti_network_routes.ps1, does NTLM/Negotiate with
# the signed-in user's session and trusts the operating system certificate
# store, without shipping a binary and without depending on the optional
# features of System32\curl.exe (which no longer lists NTLM).
#
# Loading defines a native class and a factory only; creating an engine starts
# no request. One Execute call runs exactly one request over exactly one route
# (DIRECT or one named proxy) and never chooses a route, follows a redirect or
# retries on its own: those decisions stay with the canonical route owner.
#
# Contract kept from the former curl transport:
#   - TLS verification is always enforced; the only relaxation is the explicit
#     revocation_best_effort input, which retries once without the revocation
#     check when, and only when, WinHTTP reports that the check could not run.
#   - The proxy is authenticated with the current user's default credentials
#     through Negotiate or NTLM only. Basic, Digest and Passport challenges are
#     never answered, and an origin server never receives credentials.
#   - The response body is streamed to a file and bounded; headers are bounded.
#   - Every native handle is closed and acknowledged before the result claims
#     the request is retired (Retired), so the parent Job can trust the ack.
if (-not ('ErgoptiWinHttpTransport' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public sealed class ErgoptiWinHttpSpec
{
    public string Url;
    public string Method;
    public string UserAgent = "ErgoptiPlus";
    // "" = DIRECT, otherwise host:port of one HTTP proxy.
    public string ProxyEndpoint = "";
    public string[] HeaderNames = new string[0];
    public string[] HeaderValues = new string[0];
    public byte[] Body;
    public string ResponsePath;
    public string HeaderPath;
    public int ConnectTimeoutMs = 5000;
    // Remaining milliseconds of the original request budget.
    public int BudgetMs;
    // Extra milliseconds, outside BudgetMs, reserved to retire native handles.
    public int ReserveMs = 1000;
    public long MaxResponseBytes;
    public int MaxHeaderBytes;
    public bool RevocationBestEffort;
}

public sealed class ErgoptiWinHttpResult
{
    // An HTTP response (from the origin or from the proxy) was fully received.
    public bool Completed;
    public int Status;
    // True when the final response was produced by the proxy, not the origin.
    public bool ProxyAnswered;
    public bool ProxyUsed;
    public long Delivered;
    public int NativeError;
    public string Stage = "connect";
    // Closed enum: none, proxy_name_resolution, proxy_connect, connect, timeout,
    // tls, deadline, oversize, file_write, refused.
    public string Failure = "refused";
    public uint SecureFlags;
    public string TlsStatus = "";
    public bool RevocationRelaxed;
    public string RawHeaders = "";
    // Fixed token naming the refused step or the exception class; never text
    // that could carry a URL, header or credential.
    public string Diagnostic = "";
    // Every native handle was closed and its HANDLE_CLOSING acknowledged.
    public bool Retired;
}

public static class ErgoptiWinHttpTransport
{
    private const uint AccessNoProxy = 1;
    private const uint AccessNamedProxy = 3;
    private const uint FlagSecure = 0x00800000;
    private const uint FlagEscapeDisable = 0x00000040;
    private const uint FlagEscapeDisableQuery = 0x00000080;
    private const uint OptionDisableFeature = 63;
    private const uint OptionEnableFeature = 79;
    private const uint OptionSecureProtocols = 84;
    private const uint OptionRedirectPolicy = 88;
    private const uint OptionClientCertContext = 47;
    private const uint OptionServerCertContext = 78;
    private const uint DisableCookies = 0x1;
    private const uint DisableRedirects = 0x2;
    private const uint DisableAuthentication = 0x4;
    private const uint EnableSslRevocation = 0x1;
    private const uint ProtocolTls12 = 0x00000800;
    private const uint ProtocolTls13 = 0x00002000;
    private const uint RedirectNever = 0;
    private const uint QueryStatusCode = 19;
    private const uint QueryRawHeadersCrlf = 22;
    private const uint QueryContentLength = 5;
    private const uint QueryFlagNumber = 0x20000000;
    private const uint AddHeaderAdd = 0x20000000;
    private const uint AddHeaderReplace = 0x80000000;
    private const uint CallbackSecureFailure = 0x00010000;
    private const uint CallbackHandleClosing = 0x00000800;
    private const uint CallbackFlags = 0x00010000 | 0x00000C00;
    private const int ErrorSecureFailure = 12175;
    private const int ErrorNameNotResolved = 12007;
    private const int ErrorCannotConnect = 12029;
    private const int ErrorTimeout = 12002;
    private const int ErrorCancelled = 12017;
    private const uint SecureRevFailed = 0x1;
    private const uint SecureInvalidCert = 0x2;
    private const uint SecureCertRevoked = 0x4;
    private const uint SecureInvalidCa = 0x8;
    private const uint SecureCnInvalid = 0x10;
    private const uint SecureDateInvalid = 0x20;
    private const uint SecureChannelError = 0x80000000;

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate void StatusCallback(IntPtr handle, UIntPtr context,
        uint status, IntPtr information, uint length);

    [DllImport("winhttp.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
    private static extern IntPtr WinHttpOpen(string agent, uint access, string proxy, string bypass, uint flags);
    [DllImport("winhttp.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
    private static extern IntPtr WinHttpConnect(IntPtr session, string server, ushort port, uint reserved);
    [DllImport("winhttp.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
    private static extern IntPtr WinHttpOpenRequest(IntPtr connect, string verb, string target,
        string version, string referrer, IntPtr acceptTypes, uint flags);
    [DllImport("winhttp.dll", SetLastError = true, ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool WinHttpSetTimeouts(IntPtr handle, int resolve, int connect, int send, int receive);
    [DllImport("winhttp.dll", SetLastError = true, ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool WinHttpSetOption(IntPtr handle, uint option, ref uint value, uint length);
    [DllImport("winhttp.dll", SetLastError = true, ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool WinHttpSetOption(IntPtr handle, uint option, IntPtr value, uint length);
    [DllImport("winhttp.dll", SetLastError = true, ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool WinHttpQueryOption(IntPtr handle, uint option, IntPtr value, ref uint length);
    [DllImport("winhttp.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool WinHttpAddRequestHeaders(IntPtr request, string headers, uint length, uint modifiers);
    [DllImport("winhttp.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool WinHttpSendRequest(IntPtr request, string headers, uint headersLength,
        byte[] optional, uint optionalLength, uint totalLength, UIntPtr context);
    [DllImport("winhttp.dll", SetLastError = true, ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool WinHttpReceiveResponse(IntPtr request, IntPtr reserved);
    [DllImport("winhttp.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool WinHttpQueryHeaders(IntPtr request, uint level, string name,
        IntPtr buffer, ref uint length, IntPtr index);
    [DllImport("winhttp.dll", SetLastError = true, ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool WinHttpQueryDataAvailable(IntPtr request, out uint available);
    [DllImport("winhttp.dll", SetLastError = true, ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool WinHttpReadData(IntPtr request, byte[] buffer, uint toRead, out uint read);
    [DllImport("winhttp.dll", SetLastError = true, ExactSpelling = true)]
    private static extern IntPtr WinHttpSetStatusCallback(IntPtr handle, StatusCallback callback,
        uint notificationFlags, UIntPtr reserved);
    [DllImport("winhttp.dll", SetLastError = true, ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool WinHttpCloseHandle(IntPtr handle);
    [DllImport("crypt32.dll", ExactSpelling = true)]
    private static extern bool CertFreeCertificateContext(IntPtr context);
    [DllImport("kernel32.dll", ExactSpelling = true)]
    private static extern ulong GetTickCount64();

    // Native state of one Execute call. The callback delegate is an instance
    // field so the garbage collector cannot move it while WinHTTP holds it.
    private sealed class Operation
    {
        public readonly object Gate = new object();
        public readonly StatusCallback Callback;
        public IntPtr Session = IntPtr.Zero;
        public IntPtr Connect = IntPtr.Zero;
        public IntPtr Request = IntPtr.Zero;
        public bool CallbackRegistered;
        public volatile bool Cancelled;
        public int ActiveCallbacks;
        public int ClosingSeen;
        public uint SecureFlags;
        public readonly ManualResetEvent Idle = new ManualResetEvent(true);
        public int HandlesClosed;
        public Operation() { Callback = OnStatus; }
        private void OnStatus(IntPtr handle, UIntPtr context, uint status, IntPtr information, uint length)
        {
            // Account for the callback before touching any state so the parent
            // cannot release this owner while a callback is still executing.
            lock (Gate) { ActiveCallbacks++; Idle.Reset(); }
            try
            {
                if (status == CallbackSecureFailure && information != IntPtr.Zero && length >= 4)
                {
                    SecureFlags |= (uint)Marshal.ReadInt32(information);
                }
                else if (status == CallbackHandleClosing)
                {
                    lock (Gate) { ClosingSeen++; }
                }
            }
            catch (Exception) { /* A callback never throws into WinHTTP. */ }
            finally
            {
                lock (Gate) { ActiveCallbacks--; if (ActiveCallbacks == 0) Idle.Set(); }
            }
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SecPkgInfo
    {
        public uint Capabilities;
        public ushort Version;
        public ushort RpcId;
        public uint MaxToken;
        public IntPtr Name;
        public IntPtr Comment;
    }
    [DllImport("secur32.dll", ExactSpelling = true)]
    private static extern int EnumerateSecurityPackagesW(out uint count, out IntPtr packages);
    [DllImport("secur32.dll", ExactSpelling = true)]
    private static extern int FreeContextBuffer(IntPtr buffer);

    public static long CurrentTick() { return checked((long)GetTickCount64()); }

    // Bit 1 = Negotiate, bit 2 = NTLM: the Windows-integrated schemes WinHTTP
    // may answer a proxy with. Observed from the installed security providers.
    public static int IntegratedSchemes()
    {
        uint count;
        IntPtr packages;
        if (EnumerateSecurityPackagesW(out count, out packages) != 0 || packages == IntPtr.Zero) return 0;
        int mask = 0;
        try
        {
            int stride = Marshal.SizeOf(typeof(SecPkgInfo));
            for (uint index = 0; index < count && index < 256; index++)
            {
                SecPkgInfo info = (SecPkgInfo)Marshal.PtrToStructure(IntPtr.Add(packages, checked((int)index * stride)), typeof(SecPkgInfo));
                string name = info.Name == IntPtr.Zero ? "" : Marshal.PtrToStringUni(info.Name);
                if (string.Equals(name, "Negotiate", StringComparison.OrdinalIgnoreCase)) mask |= 1;
                else if (string.Equals(name, "NTLM", StringComparison.OrdinalIgnoreCase)) mask |= 2;
            }
        }
        finally { FreeContextBuffer(packages); }
        return mask;
    }

    // Opens and closes a WinHTTP session, proving the system HTTP stack loads
    // and every native handle retires, before any request secret is staged.
    public static bool ProbeStack(int reserveMs)
    {
        Operation op = new Operation();
        op.Session = WinHttpOpen("ErgoptiPlus", AccessNoProxy, null, null, 0);
        if (op.Session == IntPtr.Zero) return false;
        try { ConfigureSession(op, new ErgoptiWinHttpResult()); }
        catch (InvalidOperationException) { CloseOwned(op, ref op.Session); return false; }
        CloseOwned(op, ref op.Session);
        System.Diagnostics.Stopwatch wait = System.Diagnostics.Stopwatch.StartNew();
        while (wait.ElapsedMilliseconds < reserveMs)
        {
            lock (op.Gate) { if (op.ClosingSeen >= op.HandlesClosed) { GC.KeepAlive(op.Callback); return true; } }
            Thread.Sleep(2);
        }
        return false;
    }

    // One closed status per failure. An untrusted chain outranks a name or date
    // problem: the user cannot act on the others until the chain is trusted.
    private static string TlsStatusForFlags(uint flags)
    {
        if ((flags & SecureCertRevoked) != 0) return "revoked_certificate";
        if ((flags & (SecureInvalidCa | SecureInvalidCert)) != 0) return "untrusted_certificate";
        if ((flags & SecureDateInvalid) != 0) return "expired_certificate";
        if ((flags & SecureCnInvalid) != 0) return "hostname_mismatch";
        return "";
    }

    private static string TlsStatusForError(int error, uint flags)
    {
        switch (error)
        {
            case 12037: return "expired_certificate";
            case 12038: return "hostname_mismatch";
            case 12044: case 12045: case 12169: case 12179: return "untrusted_certificate";
            case 12170: return "revoked_certificate";
            case 12157: return "";
            case ErrorSecureFailure: return TlsStatusForFlags(flags);
        }
        return "";
    }

    private static bool IsTlsError(int error)
    {
        return error == ErrorSecureFailure || error == 12037 || error == 12038 || error == 12044 ||
            error == 12045 || error == 12157 || error == 12169 || error == 12170 || error == 12179;
    }

    private static void CloseOwned(Operation op, ref IntPtr handle)
    {
        IntPtr value;
        lock (op.Gate) { value = handle; handle = IntPtr.Zero; }
        if (value == IntPtr.Zero) return;
        lock (op.Gate) { op.HandlesClosed++; }
        WinHttpCloseHandle(value);
    }

    private static string QueryString(IntPtr request, uint level)
    {
        uint length = 0;
        WinHttpQueryHeaders(request, level, null, IntPtr.Zero, ref length, IntPtr.Zero);
        if (length == 0 || length > 4 * 1024 * 1024) return "";
        IntPtr buffer = Marshal.AllocHGlobal((int)length + 2);
        try
        {
            if (!WinHttpQueryHeaders(request, level, null, buffer, ref length, IntPtr.Zero)) return "";
            return Marshal.PtrToStringUni(buffer, (int)(length / 2));
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    private static int QueryStatus(IntPtr request)
    {
        uint length = 4;
        IntPtr buffer = Marshal.AllocHGlobal(4);
        try
        {
            if (!WinHttpQueryHeaders(request, QueryStatusCode | QueryFlagNumber, null, buffer, ref length, IntPtr.Zero)) return 0;
            return Marshal.ReadInt32(buffer);
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    // True once a TLS session has been negotiated on this request. A response
    // that arrives before it (an HTTPS request through a proxy) was produced by
    // the proxy's CONNECT handling, not by the origin.
    private static bool TlsEstablished(IntPtr request)
    {
        uint length = (uint)IntPtr.Size;
        IntPtr buffer = Marshal.AllocHGlobal(IntPtr.Size);
        try
        {
            if (!WinHttpQueryOption(request, OptionServerCertContext, buffer, ref length)) return false;
            // The query hands back a referenced certificate context.
            IntPtr context = Marshal.ReadIntPtr(buffer);
            if (context != IntPtr.Zero) CertFreeCertificateContext(context);
            return context != IntPtr.Zero;
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    private static bool SetUInt(IntPtr handle, uint option, uint value)
    {
        return WinHttpSetOption(handle, option, ref value, 4);
    }

    private static void ConfigureSession(Operation op, ErgoptiWinHttpResult result)
    {
        // TLS 1.2 and 1.3 only. Windows builds without TLS 1.3 reject that bit
        // as an invalid parameter; they keep TLS 1.2, never an older protocol.
        if (!SetUInt(op.Session, OptionSecureProtocols, ProtocolTls12 | ProtocolTls13))
        {
            if (!SetUInt(op.Session, OptionSecureProtocols, ProtocolTls12))
                throw new InvalidOperationException("secure_protocols");
        }
        if (WinHttpSetStatusCallback(op.Session, op.Callback, CallbackFlags, UIntPtr.Zero) == new IntPtr(-1))
            throw new InvalidOperationException("status_callback");
        op.CallbackRegistered = true;
    }

    private static void ConfigureRequest(Operation op, ErgoptiWinHttpSpec spec, bool secure, bool revocation)
    {
        IntPtr request = op.Request;
        // A DIRECT request has no proxy to authenticate with, so every automatic
        // authentication is off. A proxied request keeps it only because WinHTTP
        // answers the proxy challenge through it.
        uint disabled = DisableCookies | DisableRedirects | (spec.ProxyEndpoint == "" ? DisableAuthentication : 0u);
        if (!SetUInt(request, OptionDisableFeature, disabled))
            throw new InvalidOperationException("disable_feature");
        if (!SetUInt(request, OptionRedirectPolicy, RedirectNever))
            throw new InvalidOperationException("redirect_policy");
        // No client certificate is ever offered or prompted for.
        if (secure && !WinHttpSetOption(request, OptionClientCertContext, IntPtr.Zero, 0))
            throw new InvalidOperationException("client_certificate");
        if (revocation && !SetUInt(request, OptionEnableFeature, EnableSslRevocation))
            throw new InvalidOperationException("revocation");
        int names = spec.HeaderNames.Length;
        for (int index = 0; index < names; index++)
        {
            string line = spec.HeaderNames[index] + ": " + spec.HeaderValues[index] + "\r\n";
            // REPLACE with an empty value means "remove" to WinHTTP, so an empty
            // field is added without it.
            uint modifiers = spec.HeaderValues[index].Trim().Length == 0 ? AddHeaderAdd : AddHeaderAdd | AddHeaderReplace;
            if (!WinHttpAddRequestHeaders(request, line, unchecked((uint)-1), modifiers))
                throw new InvalidOperationException("request_header");
        }
    }

    private static void Classify(ErgoptiWinHttpResult result, ErgoptiWinHttpSpec spec, Operation op, int error, string phase)
    {
        result.NativeError = error;
        bool proxy = spec.ProxyEndpoint != "";
        if (op.Cancelled || error == ErrorCancelled) { result.Failure = "deadline"; result.Stage = "connect"; return; }
        if (IsTlsError(error))
        {
            result.Failure = "tls";
            result.Stage = "tls";
            result.SecureFlags = op.SecureFlags;
            result.TlsStatus = TlsStatusForError(error, op.SecureFlags);
            return;
        }
        if (error == ErrorNameNotResolved)
        {
            result.Failure = proxy ? "proxy_name_resolution" : "connect";
            result.Stage = proxy ? "proxy_resolve" : "connect";
            return;
        }
        if (error == ErrorCannotConnect)
        {
            result.Failure = proxy ? "proxy_connect" : "connect";
            result.Stage = "connect";
            return;
        }
        result.Failure = error == ErrorTimeout ? "timeout" : "connect";
        result.Stage = phase;
    }

    private static void Run(Operation op, ErgoptiWinHttpSpec spec, ErgoptiWinHttpResult result)
    {
        FileStream output = null;
        try
        {
            Uri destination = new Uri(spec.Url);
            bool secure = destination.Scheme == Uri.UriSchemeHttps;
            bool proxy = spec.ProxyEndpoint != "";
            result.ProxyUsed = proxy;
            op.Session = WinHttpOpen(spec.UserAgent, proxy ? AccessNamedProxy : AccessNoProxy,
                proxy ? spec.ProxyEndpoint : null, null, 0);
            if (op.Session == IntPtr.Zero) { Classify(result, spec, op, Marshal.GetLastWin32Error(), "connect"); return; }
            ConfigureSession(op, result);
            int budget = Math.Max(1, spec.BudgetMs);
            int connectMs = Math.Max(1, Math.Min(spec.ConnectTimeoutMs, budget));
            if (!WinHttpSetTimeouts(op.Session, connectMs, connectMs, budget, budget))
                throw new InvalidOperationException("timeouts");
            string host = destination.IdnHost;
            if (host.StartsWith("[") && host.EndsWith("]")) host = host.Substring(1, host.Length - 2);
            op.Connect = WinHttpConnect(op.Session, host, (ushort)destination.Port, 0);
            if (op.Connect == IntPtr.Zero) { Classify(result, spec, op, Marshal.GetLastWin32Error(), "connect"); return; }
            bool revocation = secure && spec.RevocationBestEffort;
            for (int pass = 0; pass < 2; pass++)
            {
                op.SecureFlags = 0;
                result.SecureFlags = 0;
                CloseOwned(op, ref op.Request);
                uint openFlags = (secure ? FlagSecure : 0) | FlagEscapeDisable | FlagEscapeDisableQuery;
                op.Request = WinHttpOpenRequest(op.Connect, spec.Method, destination.PathAndQuery,
                    null, null, IntPtr.Zero, openFlags);
                if (op.Request == IntPtr.Zero) { Classify(result, spec, op, Marshal.GetLastWin32Error(), "connect"); return; }
                ConfigureRequest(op, spec, secure, revocation);
                int error = Exchange(op, spec, result);
                if (error == 0) break;
                if (secure && pass == 0 && revocation && error == ErrorSecureFailure && op.SecureFlags == SecureRevFailed)
                {
                    // WinHTTP could not reach the revocation source; every other
                    // verification passed. Retry once without that single check.
                    revocation = false;
                    result.RevocationRelaxed = true;
                    continue;
                }
                Classify(result, spec, op, error, result.Stage);
                return;
            }
            if (!result.Completed) return;
            result.Status = QueryStatus(op.Request);
            result.RawHeaders = QueryString(op.Request, QueryRawHeadersCrlf);
            if (spec.MaxHeaderBytes > 0 && Encoding.UTF8.GetByteCount(result.RawHeaders) > spec.MaxHeaderBytes)
            {
                result.Completed = false; result.Failure = "oversize"; result.Stage = "http"; return;
            }
            result.ProxyAnswered = proxy && (result.Status == 407 || (secure && !TlsEstablished(op.Request)));
            string declared = QueryString(op.Request, QueryContentLength);
            long declaredBytes;
            if (declared != "" && long.TryParse(declared, out declaredBytes) && spec.MaxResponseBytes > 0 && declaredBytes > spec.MaxResponseBytes)
            {
                result.Completed = false; result.Failure = "oversize"; result.Stage = "http"; return;
            }
            try
            {
                output = new FileStream(spec.ResponsePath, FileMode.Create, FileAccess.Write, FileShare.None);
            }
            catch (Exception) { result.Completed = false; result.Failure = "file_write"; result.Stage = "file_write"; return; }
            byte[] chunk = new byte[65536];
            while (true)
            {
                uint available;
                if (!WinHttpQueryDataAvailable(op.Request, out available))
                {
                    result.Completed = false; Classify(result, spec, op, Marshal.GetLastWin32Error(), "http"); return;
                }
                if (available == 0) break;
                uint read;
                if (!WinHttpReadData(op.Request, chunk, (uint)Math.Min((long)available, (long)chunk.Length), out read))
                {
                    result.Completed = false; Classify(result, spec, op, Marshal.GetLastWin32Error(), "http"); return;
                }
                if (read == 0) break;
                result.Delivered += read;
                if (spec.MaxResponseBytes > 0 && result.Delivered > spec.MaxResponseBytes)
                {
                    result.Completed = false; result.Failure = "oversize"; result.Stage = "http"; return;
                }
                try { output.Write(chunk, 0, (int)read); }
                catch (Exception) { result.Completed = false; result.Failure = "file_write"; result.Stage = "file_write"; return; }
            }
            try { output.Flush(true); }
            catch (Exception) { result.Completed = false; result.Failure = "file_write"; result.Stage = "file_write"; return; }
            result.Failure = "none";
            result.Stage = "http";
        }
        catch (Exception exception)
        {
            // No URL, header, credential or managed exception text leaves this boundary.
            result.Diagnostic = exception is InvalidOperationException ? exception.Message : exception.GetType().Name;
            result.Completed = false;
            if (result.Failure == "none") result.Failure = "refused";
        }
        finally
        {
            if (output != null) { try { output.Dispose(); } catch (Exception) { result.Completed = false; result.Failure = "file_write"; } }
        }
    }

    // Sends the request and receives the response. When a proxy challenges with
    // Negotiate or NTLM, WinHTTP answers it itself with the signed-in user's
    // default credentials, including the multi-leg handshake. Basic and Digest
    // need an explicit user name and password, which this code never supplies,
    // so those challenges stay unanswered and the 407 is returned. An origin
    // server is never answered: a direct request disables automatic
    // authentication outright, and WinHTTP's default policy only logs on to a
    // server that bypasses the proxy. Returns 0 on a fully received response or
    // the native error that stopped it.
    private static int Exchange(Operation op, ErgoptiWinHttpSpec spec, ErgoptiWinHttpResult result)
    {
        byte[] body = spec.Body != null && spec.Body.Length > 0 ? spec.Body : null;
        uint length = body == null ? 0u : (uint)body.Length;
        if (!WinHttpSendRequest(op.Request, null, 0, body, length, length, UIntPtr.Zero))
        { result.Stage = "connect"; return Marshal.GetLastWin32Error(); }
        if (!WinHttpReceiveResponse(op.Request, IntPtr.Zero))
        { result.Stage = "connect"; return Marshal.GetLastWin32Error(); }
        result.Completed = true;
        result.Stage = "http";
        return 0;
    }

    public static ErgoptiWinHttpResult Execute(ErgoptiWinHttpSpec spec)
    {
        ErgoptiWinHttpResult result = new ErgoptiWinHttpResult();
        if (spec == null || spec.Url == null || spec.Method == null || spec.ResponsePath == null ||
            spec.BudgetMs < 1 || spec.ReserveMs < 1) return result;
        Operation op = new Operation();
        Thread worker = new Thread(delegate() { Run(op, spec, result); });
        worker.IsBackground = true;
        worker.Start();
        bool finished = worker.Join(spec.BudgetMs);
        if (!finished)
        {
            // Closing the handles from this thread is the documented way to
            // abort a blocked synchronous WinHTTP call.
            op.Cancelled = true;
            CloseOwned(op, ref op.Request);
            CloseOwned(op, ref op.Connect);
            CloseOwned(op, ref op.Session);
            worker.Join(spec.ReserveMs);
            result.Completed = false;
            result.Failure = "deadline";
            result.Stage = "connect";
        }
        CloseOwned(op, ref op.Request);
        CloseOwned(op, ref op.Connect);
        CloseOwned(op, ref op.Session);
        // Retirement waits are measured from here and bounded by ReserveMs.
        Stopwatch retire = Stopwatch.StartNew();
        bool workerGone = !worker.IsAlive || worker.Join(Math.Max(1, spec.ReserveMs));
        bool closed = false;
        while (!closed && retire.ElapsedMilliseconds < spec.ReserveMs)
        {
            lock (op.Gate) { closed = op.ClosingSeen >= op.HandlesClosed; }
            if (!closed) Thread.Sleep(2);
        }
        bool idle = op.Idle.WaitOne(Math.Max(1, spec.ReserveMs - (int)retire.ElapsedMilliseconds));
        result.SecureFlags = result.SecureFlags == 0 ? op.SecureFlags : result.SecureFlags;
        result.Retired = workerGone && closed && idle;
        if (result.Retired) op.Idle.Dispose();
        GC.KeepAlive(op.Callback);
        return result;
    }
}
'@ -ErrorAction Stop
}

# Factory for the per-operation engine shared by the managed request worker, the
# updater artifact download and the Ollama archive download. Each engine owns
# its own clock and quiescence flag; it exposes scalar acknowledgements only.
#
# InputValue members: started_tick, deadline_ms, connect_timeout_ms,
# max_response_bytes, max_header_bytes, response_path, header_path,
# revocation_best_effort, headers (name/value objects), body (string) and an
# optional user_agent.
function New-ErgoptiWinHttpAttemptEngine {
    param($InputValue, [hashtable]$Answer)
    $Module = New-Module -AsCustomObject -ArgumentList @($InputValue, $Answer) -ScriptBlock {
        param($InputValue, $Answer)
        $script:Quiesced = $true
        $script:BodyBytes = [Text.UTF8Encoding]::new($false).GetBytes([string]$InputValue.body)

        function Get-NativeRemainingBudget {
            $Now = [ErgoptiWinHttpTransport]::CurrentTick()
            if ($Now -lt $InputValue.started_tick) { throw 'The native request clock moved backwards.' }
            return [int][Math]::Max(0, $InputValue.deadline_ms - ($Now - $InputValue.started_tick))
        }

        function Get-RemainingBudget {
            $Remaining = Get-NativeRemainingBudget
            if ($Remaining -le 0) { throw 'The original request budget expired.' }
            return $Remaining
        }

        function ConvertFrom-RawHeaders {
            param([string]$Raw)
            $Result = @{ status = 0; headers = @{} }
            foreach ($Block in $Raw.Replace("`r`n", "`n").Split(@("`n`n"), [StringSplitOptions]::None)) {
                $Lines = $Block.Split("`n")
                if ($Lines.Count -eq 0 -or $Lines[0] -notmatch '^HTTP/\S+\s+([0-9]{3})(?:\s|$)') { continue }
                $Status = [int]$Matches[1]
                $Headers = @{}
                foreach ($Line in $Lines) {
                    $Colon = $Line.IndexOf(':')
                    if ($Colon -lt 1) { continue }
                    $Value = $Line.Substring($Colon + 1).Trim()
                    if ($Value -match '[\x00-\x1f\x7f]') { throw 'Native response header syntax was refused.' }
                    $Headers[$Line.Substring(0, $Colon).ToLowerInvariant()] = $Value
                }
                $Result.status = $Status
                $Result.headers = $Headers
            }
            return $Result
        }

        function Get-ProxyHostPort {
            param([string]$Endpoint)
            [Uri]$Relay = $null
            if (-not [Uri]::TryCreate($Endpoint, [UriKind]::Absolute, [ref]$Relay) -or $Relay.Scheme -cne 'http' -or
                $Relay.UserInfo -ne '' -or $Relay.Host -eq '' -or $Relay.Port -lt 1 -or $Relay.Port -gt 65535 -or
                $Relay.Query -ne '' -or $Relay.Fragment -ne '' -or $Relay.AbsolutePath -ne '/') {
                throw 'The exact proxy relay was refused.'
            }
            $HostName = $Relay.IdnHost
            if ($HostName.Contains(':') -and -not $HostName.StartsWith('[')) { $HostName = '[' + $HostName + ']' }
            return $HostName + ':' + $Relay.Port
        }

        function Invoke-WinHttpRoute {
            param([Uri]$Destination, $Route, [string]$Method, [bool]$SendBody, [bool]$SendHeaders)
            if ($Route.Kind -cnotin @('direct', 'proxy')) { throw 'The route kind was refused.' }
            $Budget = Get-RemainingBudget
            $Reserve = [int][Math]::Min(1000, [Math]::Max(50, [int]($Budget / 4)))
            $Spec = New-Object ErgoptiWinHttpSpec
            $Spec.Url = $Destination.AbsoluteUri
            $Spec.Method = $Method
            if ($InputValue.user_agent -is [string] -and $InputValue.user_agent -ne '') { $Spec.UserAgent = $InputValue.user_agent }
            if ($Route.Kind -ceq 'proxy') { $Spec.ProxyEndpoint = Get-ProxyHostPort $Route.Endpoint }
            $Sent = @($InputValue.headers)
            if ($SendHeaders -and $Sent.Count -gt 0) {
                $Spec.HeaderNames = [string[]]@($Sent | ForEach-Object { $_.name })
                $Spec.HeaderValues = [string[]]@($Sent | ForEach-Object { $_.value })
            }
            if ($SendBody -and $script:BodyBytes.Length -gt 0) { $Spec.Body = $script:BodyBytes }
            $Spec.ResponsePath = $InputValue.response_path
            $Spec.HeaderPath = $InputValue.header_path
            $Spec.ConnectTimeoutMs = [int]$InputValue.connect_timeout_ms
            $Spec.BudgetMs = [Math]::Max(1, $Budget - $Reserve)
            $Spec.ReserveMs = $Reserve
            $Spec.MaxResponseBytes = [long]$InputValue.max_response_bytes
            $Spec.MaxHeaderBytes = [int]$InputValue.max_header_bytes
            $Spec.RevocationBestEffort = [bool]$InputValue.revocation_best_effort
            # Clear each attempt's private output before it starts, so a failed
            # route can never leave the previous route's bytes behind.
            [IO.File]::WriteAllBytes($InputValue.response_path, [byte[]]@())
            [IO.File]::WriteAllBytes($InputValue.header_path, [byte[]]@())
            $Native = [ErgoptiWinHttpTransport]::Execute($Spec)
            if (-not $Native.Retired) { $script:Quiesced = $false; $Answer.child_quiesced = $false }
            $Metrics = @{
                completed = [bool]$Native.Completed; failure = [string]$Native.Failure
                status = [int]$Native.Status; delivered = [int64]$Native.Delivered
                proxy_used = [bool]$Native.ProxyUsed; proxy_answered = [bool]$Native.ProxyAnswered
                native_error = [int]$Native.NativeError; stage = [string]$Native.Stage
                tls_status = [string]$Native.TlsStatus; revocation_relaxed = [bool]$Native.RevocationRelaxed
                child_quiesced = [bool]$Native.Retired; diagnostic = [string]$Native.Diagnostic
                headers = @{ status = 0; headers = @{} }
            }
            if ($Native.Completed) {
                $Metrics.headers = ConvertFrom-RawHeaders $Native.RawHeaders
                [IO.File]::WriteAllText($InputValue.header_path, $Native.RawHeaders, [Text.UTF8Encoding]::new($false))
                if ($Metrics.headers.status -ne $Metrics.status -or
                    $Metrics.delivered -ne ([IO.FileInfo]::new($InputValue.response_path)).Length) {
                    throw 'Native response accounting was refused.'
                }
            }
            return $Metrics
        }

        function ConvertTo-FailureReceipt {
            param($Metrics, [Uri]$Destination)
            $Receipt = @{ backend = 'winhttp'; stage = 'connect'; failure_provenance = 'verified' }
            if ($Destination.Scheme -ceq 'https') { $Receipt.tls_verification = 'enforced' }
            $Receipt.proxy_mode = $(if ($Metrics.proxy_used) { 'selected' } else { 'direct' })
            if ($Metrics.completed) {
                # A complete response that is still a refusal: the proxy answered the
                # tunnel request or the request itself (407), never the origin.
                $Receipt.http_response_source = 'proxy'
                if ($Destination.Scheme -ceq 'https') {
                    $Receipt.stage = 'proxy_connect'
                    $Receipt.proxy_connect_status = $Metrics.status
                } else {
                    $Receipt.stage = 'http'
                    $Receipt.http_status = $Metrics.status
                }
                return $Receipt
            }
            $Receipt.http_response_source = 'unavailable'
            switch ($Metrics.failure) {
                'proxy_name_resolution' { $Receipt.stage = 'proxy_resolve'; $Receipt.proxy_resolution_status = 'unavailable' }
                'tls' {
                    $Receipt.stage = 'tls'
                    if ($Metrics.tls_status -ne '') { $Receipt.tls_status = $Metrics.tls_status }
                }
                'oversize' { $Receipt.stage = 'http' }
                'file_write' { $Receipt.stage = 'file_write' }
                'deadline' { $Receipt.failure_provenance = 'unknown' }
                'refused' { $Receipt.failure_provenance = 'unknown' }
                default { $Receipt.stage = $Metrics.stage }
            }
            if ($Metrics.native_error -ne 0) {
                $Receipt.native_errno_domain = 'win32'
                $Receipt.native_errno = [string]$Metrics.native_error
            }
            return $Receipt
        }

        # Failover to the next ordered route is allowed only when the proxy could
        # not be resolved or connected to before any byte of this request moved.
        # These two classes are the Windows spelling of the shared policy's
        # proxy_name_resolution_exits / proxy_connect_exits (curl exits 5 and 7).
        function Test-RouteFailover {
            param($Metrics, $Route)
            return ($Route.Kind -ceq 'proxy' -and $Metrics.proxy_used -and $Metrics.child_quiesced -and
                -not $Metrics.completed -and $Metrics.status -eq 0 -and $Metrics.delivered -eq 0 -and
                $Metrics.failure -cin @('proxy_name_resolution', 'proxy_connect'))
        }

        function Get-Capability {
            $Budget = Get-RemainingBudget
            if (-not [ErgoptiWinHttpTransport]::ProbeStack([int][Math]::Min($Budget, 1000))) {
                $script:Quiesced = $false
                $Answer.child_quiesced = $false
                throw 'The system HTTP stack did not retire its probe handles.'
            }
            $Schemes = [ErgoptiWinHttpTransport]::IntegratedSchemes()
            return @{ tls_backend = 'schannel'; version = 'winhttp'; spnego = (($Schemes -band 1) -ne 0);
                ntlm = (($Schemes -band 2) -ne 0); sspi = (($Schemes -band 3) -ne 0) }
        }

        function GetRemainingBudget { return (Get-RemainingBudget) }
        function GetNativeRemainingBudget { return (Get-NativeRemainingBudget) }
        function ObserveCapability { return (Get-Capability) }
        function InvokeRoute {
            param([Uri]$Destination, $Route, [string]$Method, [bool]$SendBody, [bool]$SendHeaders)
            return (Invoke-WinHttpRoute $Destination $Route $Method $SendBody $SendHeaders)
        }
        function GetFailureReceipt {
            param($Metrics, [Uri]$Destination)
            return (ConvertTo-FailureReceipt $Metrics $Destination)
        }
        function TestFailover {
            param($Metrics, $Route)
            return (Test-RouteFailover $Metrics $Route)
        }
        function ChildQuiesced { return $script:Quiesced }
        Export-ModuleMember -Function GetRemainingBudget, GetNativeRemainingBudget, ObserveCapability,
            InvokeRoute, GetFailureReceipt, TestFailover, ChildQuiesced
    }
    return $Module
}
