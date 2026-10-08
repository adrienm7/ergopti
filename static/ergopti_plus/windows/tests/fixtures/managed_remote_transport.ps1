# tests/fixtures/managed_remote_transport.ps1
# One owned fixture supplies native TLS, revocation, fixed proxy and PAC services.
param(
    [Parameter(Mandatory = $true)][string]$StatePath,
    [Parameter(Mandatory = $true)][string]$EventPrefix,
    [ValidateSet('Serve', 'ServeUpdater', 'Cleanup')][string]$Mode = 'Serve',
    [Parameter(Mandatory = $true)][string]$OwnedRootStoreScope,
    [string]$OwnedRootThumbprint = '',
    [string]$OwnedRootSubject = ''
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
function Get-OwnedFixtureTokenElevation {
    if (-not ('ErgoptiOwnedFixtureToken' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Runtime.ExceptionServices;
public static class ErgoptiOwnedFixtureToken {
    private static readonly List<Observation> debt = new List<Observation>();
    [DllImport("kernel32.dll", ExactSpelling = true)]
    private static extern IntPtr GetCurrentProcess();
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(IntPtr process, UInt32 access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool GetTokenInformation(IntPtr token, Int32 kind, out UInt32 value, UInt32 size, out UInt32 returned);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);
    private static IntPtr OpenNative() {
        IntPtr token;
        if (!OpenProcessToken(GetCurrentProcess(), 8, out token)) {
            throw new InvalidOperationException("Owned fixture token acquisition was refused.");
        }
        return token;
    }
    private static bool QueryNative(IntPtr token) {
        UInt32 elevated, returned;
        if (!GetTokenInformation(token, 20, out elevated, 4, out returned) || returned != 4) {
            throw new InvalidOperationException("Owned fixture token elevation query was refused.");
        }
        return elevated != 0;
    }
    public sealed class Observation {
        private readonly Func<IntPtr> open;
        private readonly Func<IntPtr, bool> query;
        private readonly Func<IntPtr, bool> close;
        private bool attempted;
        public IntPtr Token { get; private set; }
        public bool Complete { get; private set; }
        public Exception QueryFailure { get; private set; }
        public Exception RetirementFailure { get; private set; }
        public string RetirementStatus { get; private set; }
        public Observation(Func<IntPtr> open, Func<IntPtr, bool> query, Func<IntPtr, bool> close) {
            this.open = open; this.query = query; this.close = close;
            RetirementStatus = "not_requested";
        }
        public bool Observe() {
            if (attempted || debt.Count != 0) {
                throw new InvalidOperationException("Unretired token ownership prevents a new permission observation.");
            }
            attempted = true;
            Token = open();
            if (Token == IntPtr.Zero) { throw new InvalidOperationException("Owned fixture token acquisition was refused."); }
            bool elevated = false;
            try { elevated = query(Token); }
            catch (Exception failure) { QueryFailure = failure; }
            bool retired = Retire();
            if (QueryFailure != null) { ExceptionDispatchInfo.Capture(QueryFailure).Throw(); }
            if (!retired && RetirementFailure != null) { ExceptionDispatchInfo.Capture(RetirementFailure).Throw(); }
            if (!retired) { throw new InvalidOperationException("Owned fixture token retirement was refused."); }
            Complete = true;
            return elevated;
        }
        public bool Retire() {
            if (Token == IntPtr.Zero) { return true; }
            bool closed = false;
            try { closed = close(Token); }
            catch (Exception failure) {
                RetirementStatus = "unavailable";
                if (RetirementFailure == null) { RetirementFailure = failure; }
            }
            if (!closed) {
                RetirementStatus = "unavailable";
                if (!debt.Contains(this)) { debt.Add(this); }
                return false;
            }
            Token = IntPtr.Zero;
            RetirementStatus = "acknowledged";
            debt.Remove(this);
            return true;
        }
    }
    public static int PendingRetirements { get { return debt.Count; } }
    public static void RetryRetirement() {
        foreach (Observation owner in debt.ToArray()) { owner.Retire(); }
    }
    public static bool ReadElevation() {
        Observation owner = new Observation(OpenNative, QueryNative, CloseHandle);
        return owner.Observe();
    }
}
'@ -ErrorAction Stop
    }
    return [ErgoptiOwnedFixtureToken]::ReadElevation()
}
function Assert-OwnedFixtureRootScope {
    param([string]$Scope, [scriptblock]$ReadElevation = { Get-OwnedFixtureTokenElevation })
    if ($Scope -cnotin @('CurrentUser', 'LocalMachine')) {
        throw [ArgumentException]::new('Owned fixture root-store scope is invalid.')
    }
    if ($Scope -ceq 'LocalMachine') {
        if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted') {
            throw [InvalidOperationException]::new('Machine scope requires the explicit hosted ephemeral CI context.')
        }
        $Elevated = & $ReadElevation
        if ($Elevated -isnot [bool] -or -not $Elevated) {
            throw [InvalidOperationException]::new('Machine scope requires verified native token elevation.')
        }
    }
}
Assert-OwnedFixtureRootScope $OwnedRootStoreScope
function Remove-OwnedRoot([string]$Thumbprint, [string]$Subject, [string]$Scope) {
    Assert-OwnedFixtureRootScope $Scope
    if ($Thumbprint -cnotmatch '^[0-9A-F]{40}$' -or $Subject -cnotmatch '^CN=ErgoptiPlus managed-network fixture [0-9a-f]{32}$') {
        throw 'Invalid owned certificate identity.'
    }
    $Store = [Security.Cryptography.X509Certificates.X509Store]::new('Root', $Scope)
    try {
        $Store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        $Found = @($Store.Certificates | Where-Object { $_.Thumbprint -ceq $Thumbprint })
        if ($Found.Count -gt 1) { throw 'Ambiguous owned certificate identity.' }
        foreach ($Certificate in $Found) {
            if ($Certificate.Subject -cne $Subject) { throw 'Owned certificate subject changed.' }
            $Store.Remove($Certificate)
        }
    } finally { $Store.Close() }
    $Store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
    try {
        if (@($Store.Certificates | Where-Object { $_.Thumbprint -ceq $Thumbprint }).Count -ne 0) {
            throw 'Owned declared-scope root removal was not acknowledged.'
        }
    } finally { $Store.Close(); $Store.Dispose() }
}
if ($Mode -ceq 'Cleanup') {
    try {
        Remove-OwnedRoot $OwnedRootThumbprint $OwnedRootSubject $OwnedRootStoreScope
        $CleanupReceipt = @{ version = 1; operation = 'root_cleanup'; root_store_scope = $OwnedRootStoreScope;
            root_thumbprint = $OwnedRootThumbprint; root_subject = $OwnedRootSubject; root_removed = $true }
        [IO.File]::WriteAllText($StatePath, ($CleanupReceipt | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
        [Console]::Out.WriteLine('OWNED_ROOT_REMOVED')
        exit 0
    } catch {
        [Console]::Out.WriteLine('OWNED_ROOT_REMOVAL_REFUSED')
        exit 1
    }
}
$Fixture = $null
$Events = @()
$RootInstalled = $false
$State = @{ version = 1; state = 'starting'; phase = 'untrusted'; sequence = 0;
    root_store_scope = $OwnedRootStoreScope; root_removed = $false; service_stopped = $false }
function Publish-State {
    param([string]$TrustStep = '')
    if ($TrustStep -ne '') {
        if ($TrustStep -cnotin @('event_received', 'before_open', 'before_enumeration',
            'before_export', 'before_add', 'after_add', 'before_postcheck', 'before_close')) {
            throw [ArgumentException]::new('Invalid owned trust diagnostic step.')
        }
        # Trust checkpoints must not wait on native TLS observation getters.
        $State.trust_step = $TrustStep
    } else {
    try {
    if ($null -ne $Fixture) {
        $State.server_tls_backend = 'native_openssl3'
        $State.server_tls_version = $Fixture.NativeTls.Version
        $State.server_tls_ssl_image_sha256 = $Fixture.NativeTls.SslImageHash
        $State.server_tls_crypto_image_sha256 = $Fixture.NativeTls.CryptoImageHash
        $State.server_tls_key_ephemeral = $Fixture.NativeTls.KeyEphemeral
        $State.server_tls_private_der_cleared = $Fixture.NativeTls.PrivateDerCleared
        $State.server_tls_source_unchanged = $Fixture.NativeTls.SourceUnchanged
        $State.server_tls_owned_modules = $Fixture.NativeTls.OwnedModuleReferences
        $State.server_tls_owned_source_fences = $Fixture.NativeTls.OwnedSourceFences
        $State.server_tls_owned_streams = $Fixture.NativeTls.OwnedStreams
        $Fact = $Fixture.ReadServiceFailure()
        if ($Fact.Stage -cne 'none') {
            $State.service_failure_stage = $Fact.Stage
            $State.service_failure_kind = $Fact.Kind
            $State.service_failure_hresult = $Fact.HResult
        }
    }
    } catch { } # Observation cannot suppress the original state write.
    }
    $State.sequence++
    [IO.File]::WriteAllText($StatePath, ($State | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
}
try {
    if ($EventPrefix -cnotmatch '^Local\\ErgoptiPlus\.ManagedNetworkFixture\.[0-9a-f]{32}$') {
        throw 'Invalid owned fixture event prefix.'
    }
    $CurlPath = Join-Path $env:WINDIR 'System32\curl.exe'
    $CurlVersion = & $CurlPath --version
    if ($LASTEXITCODE -ne 0 -or (($CurlVersion -join "`n") -notmatch '\bSchannel\b')) {
        throw 'The actual shipped curl does not use Schannel.'
    }
    $State.curl_schannel = $true
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Threading;

// Fixture-only native TLS: the clients still use Windows Schannel and system trust.
public sealed class ErgoptiFixtureOpenSsl : IDisposable
{
    private sealed class ImageFence : IDisposable
    {
        public readonly string Path;
        public readonly string Hash;
        public readonly List<string> Imports;
        private readonly FileStream file;
        public ImageFence(string path)
        {
            Path = System.IO.Path.GetFullPath(path);
            if ((File.GetAttributes(Path) & FileAttributes.ReparsePoint) != 0)
                throw new InvalidOperationException("Native TLS image reparse point refused.");
            file = new FileStream(Path, FileMode.Open, FileAccess.Read, FileShare.Read);
            try {
                if (file.Length < 512 || file.Length > 33554432)
                    throw new InvalidDataException("Native TLS image size refused.");
                byte[] bytes = new byte[(int)file.Length];
                int offset = 0;
                while (offset < bytes.Length) {
                    int count = file.Read(bytes, offset, bytes.Length - offset);
                    if (count <= 0) throw new EndOfStreamException();
                    offset += count;
                }
                using (SHA256 sha = SHA256.Create()) Hash = Hex(sha.ComputeHash(bytes));
                Imports = InspectNativeImage(bytes);
                file.Position = 0;
            } catch { file.Dispose(); throw; }
        }
        public void Verify()
        {
            file.Position = 0;
            string current;
            using (SHA256 sha = SHA256.Create()) current = Hex(sha.ComputeHash(file));
            file.Position = 0;
            if (!String.Equals(current, Hash, StringComparison.Ordinal))
                throw new InvalidOperationException("Native TLS image changed under its source fence.");
        }
        public void Dispose() { file.Dispose(); }
    }

    [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr LoadLibraryExW(string path, IntPtr file, uint flags);
    [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Ansi, ExactSpelling = true, SetLastError = true)]
    private static extern IntPtr GetProcAddress(IntPtr module, string name);
    [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
    private static extern uint GetModuleFileNameW(IntPtr module, StringBuilder path, uint capacity);
    [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr GetModuleHandleW(string name);
    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
    [return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)]
    private static extern bool FreeLibrary(IntPtr module);

    [System.Runtime.InteropServices.UnmanagedFunctionPointer(System.Runtime.InteropServices.CallingConvention.Cdecl)]
    private delegate uint VersionCall();
    [System.Runtime.InteropServices.UnmanagedFunctionPointer(System.Runtime.InteropServices.CallingConvention.Cdecl)]
    private delegate int InitializeCall(ulong flags, IntPtr settings);
    [System.Runtime.InteropServices.UnmanagedFunctionPointer(System.Runtime.InteropServices.CallingConvention.Cdecl)]
    private delegate IntPtr MethodCall();
    [System.Runtime.InteropServices.UnmanagedFunctionPointer(System.Runtime.InteropServices.CallingConvention.Cdecl)]
    private delegate IntPtr NewCall(IntPtr input);
    [System.Runtime.InteropServices.UnmanagedFunctionPointer(System.Runtime.InteropServices.CallingConvention.Cdecl)]
    private delegate void FreeCall(IntPtr input);
    [System.Runtime.InteropServices.UnmanagedFunctionPointer(System.Runtime.InteropServices.CallingConvention.Cdecl)]
    private delegate int ContextControlCall(IntPtr context, int command, int argument, IntPtr pointer);
    [System.Runtime.InteropServices.UnmanagedFunctionPointer(System.Runtime.InteropServices.CallingConvention.Cdecl)]
    private delegate int CertificateCall(IntPtr context, int count, IntPtr der);
    [System.Runtime.InteropServices.UnmanagedFunctionPointer(System.Runtime.InteropServices.CallingConvention.Cdecl)]
    private delegate int PrivateKeyCall(int type, IntPtr context, IntPtr der, int count);
    [System.Runtime.InteropServices.UnmanagedFunctionPointer(System.Runtime.InteropServices.CallingConvention.Cdecl)]
    private delegate int OneCall(IntPtr input);
    [System.Runtime.InteropServices.UnmanagedFunctionPointer(System.Runtime.InteropServices.CallingConvention.Cdecl)]
    private delegate void BioPairCall(IntPtr ssl, IntPtr input, IntPtr output);
    [System.Runtime.InteropServices.UnmanagedFunctionPointer(System.Runtime.InteropServices.CallingConvention.Cdecl)]
    private delegate int IoCall(IntPtr owner, IntPtr bytes, int count);
    [System.Runtime.InteropServices.UnmanagedFunctionPointer(System.Runtime.InteropServices.CallingConvention.Cdecl)]
    private delegate int ErrorCall(IntPtr ssl, int result);
    [System.Runtime.InteropServices.UnmanagedFunctionPointer(System.Runtime.InteropServices.CallingConvention.Cdecl)]
    private delegate void ClearErrorCall();
    [System.Runtime.InteropServices.UnmanagedFunctionPointer(System.Runtime.InteropServices.CallingConvention.Cdecl)]
    private delegate uint LastErrorCall();

    private readonly List<ImageFence> images = new List<ImageFence>();
    private readonly Dictionary<string, string> imports = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    private readonly string nativeDirectory;
    private readonly string systemDirectory;
    private IntPtr cryptoModule;
    private IntPtr sslModule;
    private IntPtr context;
    private int streams;
    private bool closed;
    private readonly object gate = new object();
    private NewCall sslNew;
    private FreeCall sslFree;
    private FreeCall contextFree;
    private MethodCall bioMethod;
    private NewCall bioNew;
    private OneCall bioFree;
    private BioPairCall setBio;
    private FreeCall acceptState;
    private OneCall handshake;
    private OneCall shutdown;
    private IoCall sslRead;
    private IoCall sslWrite;
    private IoCall bioRead;
    private IoCall bioWrite;
    private ErrorCall sslError;
    private ClearErrorCall clearError;
    private LastErrorCall lastError;
    public readonly uint Version;
    public readonly bool KeyEphemeral;
    public readonly string SslImageHash;
    public readonly string CryptoImageHash;
    public bool PrivateDerCleared { get; private set; }
    public bool SourceUnchanged { get; private set; }
    public int OwnedModuleReferences { get { return (sslModule != IntPtr.Zero ? 1 : 0) + (cryptoModule != IntPtr.Zero ? 1 : 0); } }
    public int OwnedSourceFences { get { return images.Count; } }
    public int OwnedStreams { get { lock (gate) return streams; } }

    private static string Hex(byte[] bytes)
    {
        StringBuilder value = new StringBuilder(bytes.Length * 2);
        foreach (byte one in bytes) value.Append(one.ToString("x2", CultureInfo.InvariantCulture));
        return value.ToString();
    }
    private static bool ApiSet(string name)
    {
        return name.StartsWith("api-ms-win-", StringComparison.OrdinalIgnoreCase) ||
            name.StartsWith("ext-ms-win-", StringComparison.OrdinalIgnoreCase);
    }
    private static void VerifyDirectory(string path)
    {
        DirectoryInfo directory = new DirectoryInfo(path);
        while (directory != null) {
            if (!directory.Exists || (directory.Attributes & FileAttributes.ReparsePoint) != 0)
                throw new InvalidOperationException("Native TLS installation directory refused.");
            directory = directory.Parent;
        }
    }
    private static int RvaOffset(byte[] image, uint rva, int table, int sections)
    {
        for (int index = 0; index < sections; index++) {
            int section = table + index * 40;
            uint address = BitConverter.ToUInt32(image, section + 12);
            uint rawSize = BitConverter.ToUInt32(image, section + 16);
            uint rawAddress = BitConverter.ToUInt32(image, section + 20);
            if (rva >= address && (ulong)rva - address < rawSize) {
                ulong offset = (ulong)rawAddress + rva - address;
                if (offset >= (ulong)image.Length) break;
                return (int)offset;
            }
        }
        throw new InvalidDataException("Native TLS image address refused.");
    }
    public static List<string> InspectNativeImage(byte[] image)
    {
        if (image == null || image.Length < 512 || image.Length > 33554432 ||
            image[0] != 0x4d || image[1] != 0x5a)
            throw new InvalidDataException("Native TLS PE header refused.");
        int pe = BitConverter.ToInt32(image, 60);
        if (pe < 64 || pe > image.Length - 264 || BitConverter.ToUInt32(image, pe) != 0x4550 ||
            BitConverter.ToUInt16(image, pe + 4) != 0x8664 ||
            (BitConverter.ToUInt16(image, pe + 22) & 0x2000) == 0)
            throw new InvalidDataException("Native TLS AMD64 DLL identity refused.");
        int sections = BitConverter.ToUInt16(image, pe + 6);
        int optionalSize = BitConverter.ToUInt16(image, pe + 20);
        int optional = pe + 24;
        int table = optional + optionalSize;
        if (sections < 1 || sections > 96 || optionalSize < 240 ||
            table > image.Length - sections * 40 ||
            BitConverter.ToUInt16(image, optional) != 0x20b ||
            BitConverter.ToUInt32(image, optional + 108) < 2)
            throw new InvalidDataException("Native TLS PE32+ sections refused.");
        uint rva = BitConverter.ToUInt32(image, optional + 120);
        uint size = BitConverter.ToUInt32(image, optional + 124);
        if (rva == 0 || size < 20 || size > 1048576)
            throw new InvalidDataException("Native TLS import directory refused.");
        List<string> result = new List<string>();
        int descriptor = RvaOffset(image, rva, table, sections);
        for (int index = 0; index < 256 && index * 20 < size; index++) {
            int row = descriptor + index * 20;
            if (row < 0 || row > image.Length - 20)
                throw new InvalidDataException("Native TLS import descriptor refused.");
            bool terminal = true;
            for (int byteIndex = 0; byteIndex < 20; byteIndex++) terminal &= image[row + byteIndex] == 0;
            if (terminal) {
                if (result.Count == 0) throw new InvalidDataException("Native TLS imports absent.");
                return result;
            }
            int name = RvaOffset(image, BitConverter.ToUInt32(image, row + 12), table, sections);
            StringBuilder text = new StringBuilder();
            while (text.Length < 128 && name < image.Length && image[name] != 0) {
                byte one = image[name++];
                if (!((one >= 0x41 && one <= 0x5a) || (one >= 0x61 && one <= 0x7a) ||
                    (one >= 0x30 && one <= 0x39) || one == 0x2d || one == 0x2e || one == 0x5f))
                    throw new InvalidDataException("Native TLS import name refused.");
                text.Append((char)one);
            }
            string dependency = text.ToString();
            if (name >= image.Length || image[name] != 0 || dependency.Length < 5 ||
                !dependency.EndsWith(".dll", StringComparison.OrdinalIgnoreCase) ||
                dependency.IndexOf("..", StringComparison.Ordinal) >= 0)
                throw new InvalidDataException("Native TLS import name refused.");
            if (dependency.Equals("msys-2.0.dll", StringComparison.OrdinalIgnoreCase) ||
                dependency.StartsWith("msys-", StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("MSYS TLS libraries are not native Windows libraries.");
            result.Add(dependency);
        }
        throw new InvalidDataException("Native TLS imports did not terminate.");
    }
    private ImageFence Fence(string path)
    {
        foreach (ImageFence existing in images)
            if (String.Equals(existing.Path, path, StringComparison.OrdinalIgnoreCase)) return existing;
        if (images.Count >= 16) throw new InvalidDataException("Native TLS dependency ceiling exceeded.");
        ImageFence image = new ImageFence(path);
        images.Add(image);
        foreach (string name in image.Imports) {
            if (imports.ContainsKey(name)) continue;
            if (ApiSet(name)) { imports.Add(name, ""); continue; }
            string local = Path.Combine(nativeDirectory, name);
            string system = Path.Combine(systemDirectory, name);
            if (File.Exists(local)) {
                imports.Add(name, local);
                Fence(local);
            } else if (File.Exists(system)) imports.Add(name, system);
            else throw new InvalidOperationException("Native TLS dependency unavailable.");
        }
        return image;
    }
    private static string ModulePath(IntPtr module)
    {
        StringBuilder path = new StringBuilder(32768);
        uint count = GetModuleFileNameW(module, path, (uint)path.Capacity);
        if (count == 0 || count >= path.Capacity)
            throw new System.ComponentModel.Win32Exception(System.Runtime.InteropServices.Marshal.GetLastWin32Error());
        return Path.GetFullPath(path.ToString());
    }
    private static void VerifyModule(IntPtr module, string expected)
    {
        if (module == IntPtr.Zero || !String.Equals(ModulePath(module), expected, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Native TLS loaded image identity refused.");
    }
    private IntPtr LoadImage(string path)
    {
        IntPtr previous = GetModuleHandleW(Path.GetFileName(path));
        if (previous != IntPtr.Zero) VerifyModule(previous, path);
        IntPtr module = LoadLibraryExW(path, IntPtr.Zero, 0x00000100u | 0x00000800u);
        if (module == IntPtr.Zero)
            throw new System.ComponentModel.Win32Exception(System.Runtime.InteropServices.Marshal.GetLastWin32Error());
        try { VerifyModule(module, path); return module; }
        catch { if (!FreeLibrary(module)) throw new InvalidOperationException("Refused TLS image reference did not retire."); throw; }
    }
    private void VerifyLoadedImports()
    {
        foreach (KeyValuePair<string, string> import in imports) {
            IntPtr module = GetModuleHandleW(import.Key);
            if (ApiSet(import.Key)) {
                if (module != IntPtr.Zero && !String.Equals(Path.GetDirectoryName(ModulePath(module)), systemDirectory, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("Native TLS API-set image escaped system directory.");
            } else VerifyModule(module, import.Value);
        }
    }
    private T Export<T>(IntPtr module, string name) where T : class
    {
        IntPtr address = GetProcAddress(module, name);
        if (address == IntPtr.Zero) throw new InvalidOperationException("Required native TLS export unavailable.");
        return (T)(object)System.Runtime.InteropServices.Marshal.GetDelegateForFunctionPointer(address, typeof(T));
    }
    private void VerifySources()
    {
        SourceUnchanged = false;
        foreach (ImageFence image in images) image.Verify();
        SourceUnchanged = true;
    }
    public static bool ClearPrivateDer(byte[] bytes)
    {
        if (bytes == null) return false;
        Array.Clear(bytes, 0, bytes.Length);
        if (bytes.Length < 1 || bytes.Length > 65536) return false;
        foreach (byte one in bytes) if (one != 0) return false;
        return true;
    }
    public static bool IsExpectedClientTrustRefusal(bool trustAdmitted, uint error)
    {
        if (trustAdmitted || ((error >> 23) & 0xffu) != 20u) return false;
        uint reason = error & 0x7fffffu;
        // Actual peer certificate alerts, confined to the original untrusted phases.
        return reason == 1042u || reason == 1044u || reason == 1045u || reason == 1046u || reason == 1048u;
    }
    public ErgoptiFixtureOpenSsl(X509Certificate2 leaf, RSACng key)
    {
        if (Environment.OSVersion.Platform != PlatformID.Win32NT || IntPtr.Size != 8 ||
            leaf == null || key == null || !key.Key.IsEphemeral)
            throw new InvalidOperationException("Native in-memory TLS fixture prerequisite unavailable.");
        KeyEphemeral = key.Key.IsEphemeral;
        nativeDirectory = Path.GetFullPath(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Git", "mingw64", "bin"));
        systemDirectory = Path.GetFullPath(Environment.GetFolderPath(Environment.SpecialFolder.System));
        VerifyDirectory(nativeDirectory);
        string cryptoPath = Path.Combine(nativeDirectory, "libcrypto-3-x64.dll");
        string sslPath = Path.Combine(nativeDirectory, "libssl-3-x64.dll");
        byte[] privateDer = null;
        try {
            ImageFence crypto = Fence(cryptoPath);
            ImageFence ssl = Fence(sslPath);
            CryptoImageHash = crypto.Hash;
            SslImageHash = ssl.Hash;
            cryptoModule = LoadImage(cryptoPath);
            sslModule = LoadImage(sslPath);
            VerifyLoadedImports();
            VersionCall major = Export<VersionCall>(cryptoModule, "OPENSSL_version_major");
            VersionCall version = Export<VersionCall>(cryptoModule, "OpenSSL_version_num");
            Version = version();
            if (major() != 3 || Version < 0x30000000u || Version >= 0x40000000u)
                throw new InvalidOperationException("Native OpenSSL3 identity refused.");
            InitializeCall initialize = Export<InitializeCall>(sslModule, "OPENSSL_init_ssl");
            if (initialize(0x00000080ul, IntPtr.Zero) != 1)
                throw new InvalidOperationException("Native TLS configuration-free initialization refused.");
            MethodCall method = Export<MethodCall>(sslModule, "TLS_server_method");
            NewCall contextNew = Export<NewCall>(sslModule, "SSL_CTX_new");
            contextFree = Export<FreeCall>(sslModule, "SSL_CTX_free");
            ContextControlCall control = Export<ContextControlCall>(sslModule, "SSL_CTX_ctrl");
            CertificateCall certificate = Export<CertificateCall>(sslModule, "SSL_CTX_use_certificate_ASN1");
            PrivateKeyCall privateKey = Export<PrivateKeyCall>(sslModule, "SSL_CTX_use_PrivateKey_ASN1");
            OneCall checkKey = Export<OneCall>(sslModule, "SSL_CTX_check_private_key");
            sslNew = Export<NewCall>(sslModule, "SSL_new");
            sslFree = Export<FreeCall>(sslModule, "SSL_free");
            setBio = Export<BioPairCall>(sslModule, "SSL_set_bio");
            acceptState = Export<FreeCall>(sslModule, "SSL_set_accept_state");
            handshake = Export<OneCall>(sslModule, "SSL_do_handshake");
            shutdown = Export<OneCall>(sslModule, "SSL_shutdown");
            sslRead = Export<IoCall>(sslModule, "SSL_read");
            sslWrite = Export<IoCall>(sslModule, "SSL_write");
            sslError = Export<ErrorCall>(sslModule, "SSL_get_error");
            bioMethod = Export<MethodCall>(cryptoModule, "BIO_s_mem");
            bioNew = Export<NewCall>(cryptoModule, "BIO_new");
            bioFree = Export<OneCall>(cryptoModule, "BIO_free");
            bioRead = Export<IoCall>(cryptoModule, "BIO_read");
            bioWrite = Export<IoCall>(cryptoModule, "BIO_write");
            clearError = Export<ClearErrorCall>(cryptoModule, "ERR_clear_error");
            lastError = Export<LastErrorCall>(cryptoModule, "ERR_peek_last_error");
            context = contextNew(method());
            if (context == IntPtr.Zero || control(context, 123, 0x0303, IntPtr.Zero) != 1 ||
                control(context, 124, 0x0303, IntPtr.Zero) != 1)
                throw new InvalidOperationException("Native TLS1.2 server context refused.");
            byte[] publicDer = leaf.Export(X509ContentType.Cert);
            System.Runtime.InteropServices.GCHandle publicPin = System.Runtime.InteropServices.GCHandle.Alloc(publicDer, System.Runtime.InteropServices.GCHandleType.Pinned);
            try {
                if (certificate(context, publicDer.Length, publicPin.AddrOfPinnedObject()) != 1)
                    throw new CryptographicException("Native TLS fixture certificate refused.");
            } finally { publicPin.Free(); Array.Clear(publicDer, 0, publicDer.Length); }
            privateDer = key.Key.Export(CngKeyBlobFormat.Pkcs8PrivateBlob);
            if (privateDer.Length < 1 || privateDer.Length > 65536)
                throw new CryptographicException("Native TLS private DER ceiling refused.");
            System.Runtime.InteropServices.GCHandle privatePin = System.Runtime.InteropServices.GCHandle.Alloc(privateDer, System.Runtime.InteropServices.GCHandleType.Pinned);
            try {
                if (privateKey(6, context, privatePin.AddrOfPinnedObject(), privateDer.Length) != 1 || checkKey(context) != 1)
                    throw new CryptographicException("Native TLS fixture key match refused.");
            } finally { privatePin.Free(); PrivateDerCleared = ClearPrivateDer(privateDer); }
            if (!PrivateDerCleared) throw new CryptographicException("Native TLS private DER clearing refused.");
            VerifySources();
        } catch {
            if (privateDer != null) PrivateDerCleared = ClearPrivateDer(privateDer);
            Dispose();
            throw;
        }
    }
    public Stream Open(NetworkStream network, Func<bool> trustAdmitted)
    {
        lock (gate) {
            if (closed || context == IntPtr.Zero) throw new ObjectDisposedException("Owned native TLS fixture");
            NativeStream stream = new NativeStream(this, network, trustAdmitted);
            streams++;
            return stream;
        }
    }
    public void Authenticate(Stream stream)
    {
        NativeStream native = stream as NativeStream;
        if (native == null || !Object.ReferenceEquals(native.Owner, this))
            throw new InvalidOperationException("Native TLS stream ownership refused.");
        native.Authenticate();
    }
    public void Dispose()
    {
        lock (gate) {
            if (closed) return;
            if (streams != 0) throw new InvalidOperationException("Native TLS streams remain owned.");
            VerifySources();
            if (context != IntPtr.Zero) { contextFree(context); context = IntPtr.Zero; }
            if (sslModule != IntPtr.Zero) {
                if (!FreeLibrary(sslModule)) throw new System.ComponentModel.Win32Exception(System.Runtime.InteropServices.Marshal.GetLastWin32Error());
                sslModule = IntPtr.Zero;
            }
            if (cryptoModule != IntPtr.Zero) {
                if (!FreeLibrary(cryptoModule)) throw new System.ComponentModel.Win32Exception(System.Runtime.InteropServices.Marshal.GetLastWin32Error());
                cryptoModule = IntPtr.Zero;
            }
            VerifySources();
            foreach (ImageFence image in images) image.Dispose();
            images.Clear();
            closed = true;
        }
    }
    private sealed class NativeStream : Stream
    {
        public readonly ErgoptiFixtureOpenSsl Owner;
        private readonly NetworkStream network;
        private readonly Func<bool> trustAdmitted;
        private IntPtr ssl;
        private IntPtr input;
        private IntPtr output;
        private readonly byte[] encrypted = new byte[16384];
        private bool disposed;
        private bool authenticated;
        public NativeStream(ErgoptiFixtureOpenSsl owner, NetworkStream network, Func<bool> trustAdmitted)
        {
            if (network == null || trustAdmitted == null) throw new ArgumentNullException();
            Owner = owner; this.network = network; this.trustAdmitted = trustAdmitted;
            bool attached = false;
            try {
                ssl = owner.sslNew(owner.context);
                if (ssl == IntPtr.Zero) throw new InvalidOperationException("Native TLS connection allocation refused.");
                input = owner.bioNew(owner.bioMethod());
                output = owner.bioNew(owner.bioMethod());
                if (input == IntPtr.Zero || output == IntPtr.Zero)
                    throw new InvalidOperationException("Native TLS memory BIO allocation refused.");
                owner.setBio(ssl, input, output);
                attached = true;
                owner.acceptState(ssl);
            } catch {
                if (!attached && input != IntPtr.Zero) owner.bioFree(input);
                if (!attached && output != IntPtr.Zero) owner.bioFree(output);
                if (ssl != IntPtr.Zero) owner.sslFree(ssl);
                input = output = ssl = IntPtr.Zero;
                throw;
            }
        }
        private int Drain()
        {
            int total = 0;
            System.Runtime.InteropServices.GCHandle pin = System.Runtime.InteropServices.GCHandle.Alloc(encrypted, System.Runtime.InteropServices.GCHandleType.Pinned);
            try {
                while (true) {
                    int count = Owner.bioRead(output, pin.AddrOfPinnedObject(), encrypted.Length);
                    if (count <= 0) return total;
                    if (count > encrypted.Length || total > 1048576 - count)
                        throw new InvalidDataException("Native TLS encrypted output ceiling refused.");
                    network.Write(encrypted, 0, count);
                    total += count;
                }
            } finally { pin.Free(); Array.Clear(encrypted, 0, encrypted.Length); }
        }
        private void Receive()
        {
            int count = network.Read(encrypted, 0, encrypted.Length);
            if (count <= 0) throw new EndOfStreamException("Owned TLS peer closed before protocol completion.");
            System.Runtime.InteropServices.GCHandle pin = System.Runtime.InteropServices.GCHandle.Alloc(encrypted, System.Runtime.InteropServices.GCHandleType.Pinned);
            try {
                if (Owner.bioWrite(input, pin.AddrOfPinnedObject(), count) != count)
                    throw new InvalidOperationException("Native TLS encrypted input admission refused.");
            } finally { pin.Free(); Array.Clear(encrypted, 0, encrypted.Length); }
        }
        private void Continue(int error, uint nativeError, bool authenticating)
        {
            if (authenticating && error == 1 && IsExpectedClientTrustRefusal(trustAdmitted(), nativeError)) {
                Drain();
                throw new System.Security.Authentication.AuthenticationException("Actual untrusted client certificate alert.");
            }
            if (error == 6) { Drain(); throw new EndOfStreamException("Owned TLS peer acknowledged closure."); }
            if (error == 2 || error == 3) {
                int written = Drain();
                if (error == 2) { Receive(); return; } // SSL_ERROR_WANT_READ.
                if (written > 0) return; // SSL_ERROR_WANT_WRITE requires actual progress.
            }
            // Unexpected native TLS faults stay visible even if the socket has also closed.
            throw new InvalidOperationException("Actual native TLS protocol operation refused.");
        }
        public void Authenticate()
        {
            for (int attempts = 0; attempts < 512; attempts++) {
                Owner.clearError();
                int result = Owner.handshake(ssl);
                int error = result == 1 ? 0 : Owner.sslError(ssl, result);
                uint nativeError = result == 1 ? 0u : Owner.lastError();
                if (result == 1) { Drain(); authenticated = true; return; }
                Continue(error, nativeError, true);
            }
            throw new InvalidDataException("Native TLS handshake progress ceiling exceeded.");
        }
        public override int Read(byte[] bytes, int offset, int count)
        {
            if (disposed) throw new ObjectDisposedException("Owned native TLS stream");
            if (bytes == null || offset < 0 || count < 0 || offset > bytes.Length - count)
                throw new ArgumentOutOfRangeException();
            if (count == 0) return 0;
            System.Runtime.InteropServices.GCHandle pin = System.Runtime.InteropServices.GCHandle.Alloc(bytes, System.Runtime.InteropServices.GCHandleType.Pinned);
            try {
                for (int attempts = 0; attempts < 512; attempts++) {
                    Owner.clearError();
                    int result = Owner.sslRead(ssl, IntPtr.Add(pin.AddrOfPinnedObject(), offset), count);
                    int error = result > 0 ? 0 : Owner.sslError(ssl, result);
                    uint nativeError = result > 0 ? 0u : Owner.lastError();
                    if (result > 0) { Drain(); return result; }
                    if (error == 6) { Drain(); return 0; }
                    Continue(error, nativeError, false);
                }
                throw new InvalidDataException("Native TLS read progress ceiling exceeded.");
            } finally { pin.Free(); }
        }
        public override void Write(byte[] bytes, int offset, int count)
        {
            if (disposed) throw new ObjectDisposedException("Owned native TLS stream");
            if (bytes == null || offset < 0 || count < 0 || offset > bytes.Length - count)
                throw new ArgumentOutOfRangeException();
            System.Runtime.InteropServices.GCHandle pin = System.Runtime.InteropServices.GCHandle.Alloc(bytes, System.Runtime.InteropServices.GCHandleType.Pinned);
            try {
                while (count > 0) {
                    int chunk = Math.Min(count, 16384);
                    bool completed = false;
                    for (int attempts = 0; attempts < 512; attempts++) {
                        Owner.clearError();
                        int result = Owner.sslWrite(ssl, IntPtr.Add(pin.AddrOfPinnedObject(), offset), chunk);
                        int error = result > 0 ? 0 : Owner.sslError(ssl, result);
                        uint nativeError = result > 0 ? 0u : Owner.lastError();
                        if (result > 0) {
                            if (result > chunk) throw new InvalidDataException("Native TLS write length refused.");
                            Drain(); offset += result; count -= result; completed = true; break;
                        }
                        Continue(error, nativeError, false);
                    }
                    if (!completed) throw new InvalidDataException("Native TLS write progress ceiling exceeded.");
                }
            } finally { pin.Free(); }
        }
        protected override void Dispose(bool disposing)
        {
            if (disposed) return;
            if (disposing) {
                try {
                    if (authenticated && ssl != IntPtr.Zero) {
                        Owner.clearError();
                        int result = Owner.shutdown(ssl);
                        int error = result < 0 ? Owner.sslError(ssl, result) : 0;
                        if (result < 0 && error != 2 && error != 3 && error != 6)
                            throw new InvalidOperationException("Native TLS close notification refused.");
                        // Send close_notify once; never wait for a peer during retirement.
                        Drain();
                    }
                } finally {
                    if (ssl != IntPtr.Zero) { Owner.sslFree(ssl); ssl = input = output = IntPtr.Zero; }
                    try { network.Dispose(); }
                    finally {
                        Array.Clear(encrypted, 0, encrypted.Length);
                        lock (Owner.gate) Owner.streams--;
                        disposed = true;
                    }
                }
            }
            base.Dispose(disposing);
        }
        public override void Flush() { if (disposed) throw new ObjectDisposedException("Owned native TLS stream"); Drain(); network.Flush(); }
        public override bool CanRead { get { return !disposed; } }
        public override bool CanWrite { get { return !disposed; } }
        public override bool CanSeek { get { return false; } }
        public override long Length { get { throw new NotSupportedException(); } }
        public override long Position { get { throw new NotSupportedException(); } set { throw new NotSupportedException(); } }
        public override long Seek(long offset, SeekOrigin origin) { throw new NotSupportedException(); }
        public override void SetLength(long value) { throw new NotSupportedException(); }
    }
}

public sealed class ErgoptiManagedRemoteFixture : IDisposable
{
    private readonly List<TcpListener> listeners = new List<TcpListener>();
    private readonly List<Thread> listenersThreads = new List<Thread>();
    private readonly List<Thread> workers = new List<Thread>();
    private readonly List<TcpClient> clients = new List<TcpClient>();
    private readonly object gate = new object();
    // Closed first-failure facts only; the original counters and catches retain ownership.
    private readonly object diagnosticGate = new object();
    public sealed class FailureFact
    {
        public string Stage = "none";
        public string Kind = "none";
        public int HResult;
    }
    private FailureFact firstFailure = new FailureFact();
    private void CaptureServiceFailure(string stage, Exception failure)
    {
        try {
        lock (diagnosticGate) {
            if (firstFailure.Stage != "none") return;
            string kind = "other";
            if (failure is SocketException) kind = "socket";
            else if (failure is System.ComponentModel.Win32Exception) kind = "win32";
            else if (failure is System.Security.Authentication.AuthenticationException) kind = "authentication";
            else if (failure is InvalidDataException) kind = "invalid_data";
            else if (failure is IOException) kind = "io";
            else if (failure is ObjectDisposedException) kind = "disposed";
            else if (failure is InvalidOperationException) kind = "invalid_operation";
            firstFailure = new FailureFact { Stage = stage, Kind = kind, HResult = failure.HResult };
        }
        } catch (Exception) { } // Observation must not replace the original counter or rethrow.
    }
    public FailureFact ReadServiceFailure()
    {
        lock (diagnosticGate) return new FailureFact {
            Stage = firstFailure.Stage, Kind = firstFailure.Kind, HResult = firstFailure.HResult };
    }
    private volatile bool stopping;
    private readonly RSA rootKey;
    private readonly RSA leafKey;
    public readonly ErgoptiFixtureOpenSsl NativeTls;
    public volatile bool TrustAdmitted;
    public readonly X509Certificate2 Root;
    private readonly X509Certificate2 leaf;
    private readonly byte[] crl;
    public readonly int TlsPort;
    public readonly int ProxyPort;
    public readonly int HttpPort;
    public int Requests;
    public int Generations;
    public int ReadyRequests;
    public int ProxyConnects;
    public int PacRequests;
    public int CrlRequests;
    public int FailedTls;
    public int ServiceFailures;
    public int ClosedConnections;
    public readonly int SecondProxyPort;
    public readonly int RefusalProxyPort;
    private readonly bool updater;
    public int DownloadRequests;
    public int DownloadRedirects;
    public int DownloadGood;
    public int DownloadOrigin401;
    public int DownloadOrigin403;
    public int DownloadSmall;
    public int DownloadWrongDigest;
    public int DownloadTruncated;
    public int DownloadSlow;
    public int DownloadCredentials;
    public int SecondProxyConnects;
    public int ProxyRefusals;
    public int BasicCredentials;

    public ErgoptiManagedRemoteFixture(string identity) : this(identity, false) { }
    public ErgoptiManagedRemoteFixture(string identity, bool enableUpdater)
    {
        updater = enableUpdater;
        TcpListener tls = Listen(IPAddress.Loopback);
        TcpListener proxy = Listen(IPAddress.Loopback);
        TcpListener http = Listen(IPAddress.Loopback);
        TlsPort = ((IPEndPoint)tls.LocalEndpoint).Port;
        ProxyPort = ((IPEndPoint)proxy.LocalEndpoint).Port;
        HttpPort = ((IPEndPoint)http.LocalEndpoint).Port;
        rootKey = new RSACng(2048);
        leafKey = new RSACng(2048);
        if (!((RSACng)rootKey).Key.IsEphemeral || !((RSACng)leafKey).Key.IsEphemeral)
            throw new InvalidOperationException("Fixture key lifetime must remain process owned.");
        CertificateRequest rootRequest = new CertificateRequest(
            "CN=ErgoptiPlus managed-network fixture " + identity,
            rootKey, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        rootRequest.CertificateExtensions.Add(new X509BasicConstraintsExtension(true, false, 0, true));
        rootRequest.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.KeyCertSign | X509KeyUsageFlags.CrlSign, true));
        rootRequest.CertificateExtensions.Add(new X509SubjectKeyIdentifierExtension(rootRequest.PublicKey, false));
        DateTimeOffset from = DateTimeOffset.UtcNow.AddMinutes(-5);
        DateTimeOffset until = DateTimeOffset.UtcNow.AddDays(1);
        Root = rootRequest.CreateSelfSigned(from, until);
        CertificateRequest leafRequest = new CertificateRequest("CN=managed-fixture.invalid", leafKey,
            HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        leafRequest.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
        leafRequest.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.KeyEncipherment, true));
        OidCollection usages = new OidCollection(); usages.Add(new Oid("1.3.6.1.5.5.7.3.1"));
        leafRequest.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(usages, true));
        // Reserved DNS name reaches only this owned CONNECT relay, without hosts changes.
        leafRequest.CertificateExtensions.Add(new X509Extension("2.5.29.17",
            Sequence(Tag(0x82, Encoding.ASCII.GetBytes("managed-fixture.invalid"))), false));
        string crlUrl = "http://127.0.0.1:" + HttpPort + "/fixture.crl";
        byte[] distribution = Sequence(Sequence(Tag(0xa0, Tag(0xa0, Tag(0x86, Encoding.ASCII.GetBytes(crlUrl))))));
        leafRequest.CertificateExtensions.Add(new X509Extension("2.5.29.31", distribution, false));
        byte[] serial = new byte[16]; using (RandomNumberGenerator random = RandomNumberGenerator.Create()) random.GetBytes(serial);
        serial[0] &= 0x7f; serial[15] |= 1;
        using (X509Certificate2 issued = leafRequest.Create(Root, from, until, serial))
            leaf = RSACertificateExtensions.CopyWithPrivateKey(issued, leafKey);
        crl = CreateCrl(Root.SubjectName.RawData, rootKey);
        NativeTls = new ErgoptiFixtureOpenSsl(leaf, (RSACng)leafKey);
        Start(tls, Tls);
        Start(proxy, Proxy);
        Start(http, Http);
        if (updater) {
            TcpListener second = Listen(IPAddress.Loopback);
            TcpListener refusal = Listen(IPAddress.Loopback);
            SecondProxyPort = ((IPEndPoint)second.LocalEndpoint).Port;
            RefusalProxyPort = ((IPEndPoint)refusal.LocalEndpoint).Port;
            Start(second, SecondProxy);
            Start(refusal, RefusalProxy);
        }
    }

    private TcpListener Listen(IPAddress address)
    {
        TcpListener listener = new TcpListener(address, 0); listener.Start(); listeners.Add(listener); return listener;
    }
    private void Start(TcpListener listener, Action<TcpClient> serve)
    {
        Thread accept = new Thread(() => {
            while (!stopping) {
                try {
                    TcpClient client = listener.AcceptTcpClient(); client.ReceiveTimeout = 5000; client.SendTimeout = 5000;
                    Thread worker = new Thread(() => {
                        try { serve(client); }
                        catch (IOException) { Interlocked.Increment(ref ClosedConnections); }
                        catch (SocketException) { Interlocked.Increment(ref ClosedConnections); }
                        catch (ObjectDisposedException) { Interlocked.Increment(ref ClosedConnections); }
                        catch (Exception failure) { CaptureServiceFailure("service_request", failure); Interlocked.Increment(ref ServiceFailures); }
                        finally { client.Close(); lock (gate) clients.Remove(client); }
                    });
                    worker.IsBackground = true;
                    lock (gate) {
                        // Retirement may have closed its client snapshot after Accept returned.
                        if (stopping) { client.Close(); continue; }
                        clients.Add(client); workers.Add(worker);
                    }
                    worker.Start();
                } catch (SocketException failure) { if (!stopping) { CaptureServiceFailure("listener_accept", failure); Interlocked.Increment(ref ServiceFailures); } return; }
                catch (ObjectDisposedException failure) { if (!stopping) { CaptureServiceFailure("listener_accept", failure); Interlocked.Increment(ref ServiceFailures); } return; }
            }
        });
        accept.IsBackground = true; listenersThreads.Add(accept); accept.Start();
    }
    private static string Header(Stream stream)
    {
        StringBuilder result = new StringBuilder();
        while (result.Length < 16384) {
            int one = stream.ReadByte(); if (one < 0) throw new EndOfStreamException();
            result.Append((char)one); if (result.ToString().EndsWith("\r\n\r\n", StringComparison.Ordinal)) return result.ToString();
        }
        throw new InvalidDataException("Fixture header ceiling exceeded.");
    }
    private static void Reply(Stream stream, string type, byte[] body)
    {
        byte[] headers = Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nConnection: close\r\nCache-Control: no-store\r\nContent-Type: " + type + "\r\nContent-Length: " + body.Length + "\r\n\r\n");
        stream.Write(headers, 0, headers.Length); stream.Write(body, 0, body.Length); stream.Flush();
    }
    private void Tls(TcpClient client)
    {
        using (Stream tls = NativeTls.Open(client.GetStream(), () => TrustAdmitted)) {
            try { NativeTls.Authenticate(tls); }
            catch (System.Security.Authentication.AuthenticationException) { Interlocked.Increment(ref FailedTls); return; }
            catch (IOException) { Interlocked.Increment(ref FailedTls); return; }
            catch (Exception failure) { CaptureServiceFailure("tls_authenticate", failure); throw; }
            string header = Header(tls);
            string first = header.Split('\n')[0].Trim();
            if (updater && first.StartsWith("GET /updater/", StringComparison.Ordinal)) {
                Download(tls, header, first); return;
            }
            if (header.IndexOf("Authorization: Bearer managed-network-fixture-token\r\n", StringComparison.OrdinalIgnoreCase) < 0)
                throw new InvalidDataException("Actual production auth header absent.");
            Interlocked.Increment(ref Requests);
            if (first == "GET /v1/models HTTP/1.1") {
                Interlocked.Increment(ref ReadyRequests);
                Reply(tls, "application/json", Encoding.UTF8.GetBytes("{\"data\":[{\"id\":\"fixture\"}]}"));
                return;
            }
            if (first != "POST /v1/chat/completions?marker=managed-network-fixture HTTP/1.1")
                throw new InvalidDataException("Actual production destination mismatch.");
            int length = -1;
            foreach (string line in header.Split('\n')) if (line.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase)) length = Int32.Parse(line.Substring(15).Trim(), CultureInfo.InvariantCulture);
            if (length < 1 || length > 16384) throw new InvalidDataException("Actual production payload absent.");
            byte[] body = new byte[length]; int offset = 0;
            while (offset < length) { int read = tls.Read(body, offset, length-offset); if (read < 1) throw new EndOfStreamException(); offset += read; }
            if (Encoding.UTF8.GetString(body) != "{\"messages\":[],\"stream\":false}") throw new InvalidDataException("Actual production payload mismatch.");
            Interlocked.Increment(ref Generations);
            Reply(tls, "application/json", Encoding.UTF8.GetBytes("{\"choices\":[{\"message\":{\"content\":\"managed-network-ok\"}}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1,\"total_tokens\":2}}"));
        }
    }
    private void Proxy(TcpClient client)
    {
        NetworkStream source = client.GetStream(); string first = Header(source).Split('\n')[0].Trim();
        if (first != "CONNECT managed-fixture.invalid:" + TlsPort + " HTTP/1.1") throw new InvalidDataException("Proxy destination escaped fixture.");
        using (TcpClient destination = new TcpClient()) {
            lock (gate) clients.Add(destination);
            try {
                destination.Connect(IPAddress.Loopback, TlsPort);
                Interlocked.Increment(ref ProxyConnects);
                byte[] accepted = Encoding.ASCII.GetBytes("HTTP/1.1 200 Connection established\r\n\r\n"); source.Write(accepted, 0, accepted.Length);
                NetworkStream target = destination.GetStream();
                Thread inbound = new Thread(() => {
                    try { source.CopyTo(target); }
                    catch (IOException) { Interlocked.Increment(ref ClosedConnections); }
                    catch (ObjectDisposedException) { Interlocked.Increment(ref ClosedConnections); }
                    catch (Exception failure) { CaptureServiceFailure("tunnel_pump", failure); Interlocked.Increment(ref ServiceFailures); }
                    finally { destination.Close(); }
                });
                inbound.IsBackground = true; lock (gate) workers.Add(inbound); inbound.Start();
                try { target.CopyTo(source); } finally { client.Close(); destination.Close(); }
                if (!inbound.Join(3000)) throw new InvalidOperationException("Owned tunnel pump did not settle.");
            } finally { lock (gate) clients.Remove(destination); }
        }
    }

    // Independent fixture bytes: 0..255 repeated 2048 times (524288 bytes).
    // The controller's digest is a fixed external expectation, never obtained
    // from a worker-generated file or receipt.
    private static byte[] DownloadBytes()
    {
        byte[] bytes = new byte[524288];
        for (int i = 0; i < bytes.Length; i++) bytes[i] = (byte)(i % 256);
        return bytes;
    }
    private void Download(Stream tls, string header, string first)
    {
        Interlocked.Increment(ref DownloadRequests);
        if (header.IndexOf("\r\nAuthorization:", StringComparison.OrdinalIgnoreCase) >= 0 ||
            header.IndexOf("\r\nProxy-Authorization:", StringComparison.OrdinalIgnoreCase) >= 0) {
            Interlocked.Increment(ref DownloadCredentials);
            throw new InvalidDataException("Updater origin received credentials.");
        }
        string origin = "https://managed-fixture.invalid:" + TlsPort;
        if (first == "GET /updater/start HTTP/1.1") {
            Interlocked.Increment(ref DownloadRedirects);
            Status(tls, "302 Found", "Location: " + origin + "/updater/good?marker=staging-fixture\r\n", new byte[0], 0);
        } else if (first == "GET /updater/good?marker=staging-fixture HTTP/1.1") {
            Interlocked.Increment(ref DownloadGood); byte[] bytes = DownloadBytes();
            Status(tls, "200 OK", "", bytes, bytes.Length);
        } else if (first == "GET /updater/401 HTTP/1.1") {
            Interlocked.Increment(ref DownloadOrigin401);
            Status(tls, "401 Unauthorized", "WWW-Authenticate: Basic realm=\"owned-origin-refusal\"\r\n", new byte[0], 0);
        } else if (first == "GET /updater/403 HTTP/1.1") {
            Interlocked.Increment(ref DownloadOrigin403);
            Status(tls, "403 Forbidden", "", new byte[0], 0);
        } else if (first == "GET /updater/small HTTP/1.1") {
            Interlocked.Increment(ref DownloadSmall); byte[] bytes = new byte[32];
            Status(tls, "200 OK", "", bytes, bytes.Length);
        } else if (first == "GET /updater/wrong-digest HTTP/1.1") {
            Interlocked.Increment(ref DownloadWrongDigest); byte[] bytes = DownloadBytes(); bytes[0] ^= 1;
            Status(tls, "200 OK", "", bytes, bytes.Length);
        } else if (first == "GET /updater/truncated HTTP/1.1") {
            Interlocked.Increment(ref DownloadTruncated);
            Status(tls, "200 OK", "", new byte[32], 524288);
        } else if (first == "GET /updater/slow HTTP/1.1") {
            Interlocked.Increment(ref DownloadSlow);
            byte[] headerBytes = Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 524288\r\n\r\n");
            tls.Write(headerBytes, 0, headerBytes.Length); tls.Flush();
            byte[] part = new byte[32];
            for (int index = 0; index < 600 && !stopping; index++) {
                tls.Write(part, 0, part.Length); tls.Flush(); Thread.Sleep(100);
            }
        } else { throw new InvalidDataException("Updater destination escaped fixture."); }
    }
    private static void Status(Stream stream, string status, string extra, byte[] body, int declared)
    {
        byte[] header = Encoding.ASCII.GetBytes("HTTP/1.1 " + status + "\r\nConnection: close\r\nCache-Control: no-store\r\nContent-Type: application/octet-stream\r\n" + extra + "Content-Length: " + declared + "\r\n\r\n");
        stream.Write(header, 0, header.Length); stream.Write(body, 0, body.Length); stream.Flush();
    }
    private void SecondProxy(TcpClient client)
    {
        Interlocked.Increment(ref SecondProxyConnects); Proxy(client);
    }
    private void RefusalProxy(TcpClient client)
    {
        NetworkStream stream = client.GetStream(); string header = Header(stream);
        if (header.Split('\n')[0].Trim() != "CONNECT managed-fixture.invalid:" + TlsPort + " HTTP/1.1")
            throw new InvalidDataException("Refusal relay destination escaped fixture.");
        Interlocked.Increment(ref ProxyRefusals);
        if (header.IndexOf("\r\nProxy-Authorization:", StringComparison.OrdinalIgnoreCase) >= 0) {
            Interlocked.Increment(ref BasicCredentials);
            throw new InvalidDataException("Disallowed Basic relay received credentials.");
        }
        Status(stream, "407 Proxy Authentication Required", "Proxy-Authenticate: Basic realm=\"owned-proxy-refusal\"\r\n", new byte[0], 0);
    }

    private void Http(TcpClient client)
    {
        NetworkStream stream = client.GetStream(); string first = Header(stream).Split('\n')[0].Trim();
        if (first == "GET /fixture.crl HTTP/1.1" || first == "GET /fixture.crl HTTP/1.0") {
            Interlocked.Increment(ref CrlRequests); Reply(stream, "application/pkix-crl", crl); return;
        }
        if (updater && (first == "GET /updater.pac HTTP/1.1" || first == "GET /updater.pac HTTP/1.0")) {
            Interlocked.Increment(ref PacRequests);
            string owned = "https://managed-fixture.invalid:" + TlsPort;
            string updaterScript = "function FindProxyForURL(url,host){" +
                "if(url == '" + owned + "/updater/good?marker=staging-fixture') return 'PROXY 127.0.0.1:" + SecondProxyPort + "';" +
                "if(url == '" + owned + "/updater/407') return 'PROXY 127.0.0.1:" + RefusalProxyPort + "';" +
                "if(url == '" + owned + "/updater/slow' || url == '" + owned + "/updater/start' || url == '" + owned + "/updater/401' || url == '" + owned + "/updater/403' || url == '" + owned + "/updater/small' || url == '" + owned + "/updater/wrong-digest' || url == '" + owned + "/updater/truncated') return 'PROXY 127.0.0.1:" + ProxyPort + "';" +
                "return 'PROXY refused.invalid:9';}";
            Reply(stream, "application/x-ns-proxy-autoconfig", Encoding.UTF8.GetBytes(updaterScript)); return;
        }
        if (first != "GET /proxy.pac HTTP/1.1" && first != "GET /proxy.pac HTTP/1.0") throw new InvalidDataException("HTTP fixture destination mismatch.");
        Interlocked.Increment(ref PacRequests);
        string origin = "https://managed-fixture.invalid:" + TlsPort;
        string script = "function FindProxyForURL(url,host){if(url == '" + origin + "/v1/models' || url == '" + origin + "/v1/chat/completions?marker=managed-network-fixture') return 'PROXY 127.0.0.1:" + ProxyPort + "'; return 'PROXY refused.invalid:9';}";
        Reply(stream, "application/x-ns-proxy-autoconfig", Encoding.UTF8.GetBytes(script));
    }
    private static byte[] Tag(byte tag, byte[] data)
    {
        using (MemoryStream outp = new MemoryStream()) {
            outp.WriteByte(tag);
            if (data.Length < 128) outp.WriteByte((byte)data.Length);
            else { List<byte> length = new List<byte>(); int n=data.Length; while(n>0){length.Insert(0,(byte)(n&255));n>>=8;} outp.WriteByte((byte)(0x80|length.Count));outp.Write(length.ToArray(),0,length.Count); }
            outp.Write(data,0,data.Length); return outp.ToArray();
        }
    }
    private static byte[] Sequence(params byte[][] values)
    {
        using (MemoryStream data = new MemoryStream()) { foreach(byte[] value in values)data.Write(value,0,value.Length); return Tag(0x30,data.ToArray()); }
    }
    private static byte[] CreateCrl(byte[] issuer, RSA signer)
    {
        byte[] algorithm = new byte[] {0x30,0x0d,0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x0b,0x05,0x00};
        byte[] tbs = Sequence(new byte[]{0x02,0x01,0x01}, algorithm, issuer,
            Tag(0x17,Encoding.ASCII.GetBytes(DateTime.UtcNow.AddMinutes(-5).ToString("yyMMddHHmmss'Z'",CultureInfo.InvariantCulture))),
            Tag(0x17,Encoding.ASCII.GetBytes(DateTime.UtcNow.AddDays(1).ToString("yyMMddHHmmss'Z'",CultureInfo.InvariantCulture))));
        byte[] signature=signer.SignData(tbs,HashAlgorithmName.SHA256,RSASignaturePadding.Pkcs1);
        byte[] bitString=new byte[signature.Length+1];Buffer.BlockCopy(signature,0,bitString,1,signature.Length);
        return Sequence(tbs,algorithm,Tag(0x03,bitString));
    }
    public void Dispose()
    {
        stopping=true; foreach(TcpListener listener in listeners) listener.Stop();
        lock(gate) foreach(TcpClient client in clients.ToArray()) client.Close();
        foreach(Thread thread in listenersThreads) if(!thread.Join(3000))throw new InvalidOperationException("Owned fixture accept thread did not settle.");
        Thread[] pending;lock(gate)pending=workers.ToArray();
        foreach(Thread thread in pending) if(!thread.Join(3000))throw new InvalidOperationException("Owned fixture worker did not settle.");
        NativeTls.Dispose();
        leaf.Dispose();Root.Dispose();leafKey.Dispose();rootKey.Dispose();
    }
}
'@
    $Identity = $EventPrefix.Substring($EventPrefix.LastIndexOf('.') + 1)
    $Fixture = [ErgoptiManagedRemoteFixture]::new($Identity, ($Mode -ceq 'ServeUpdater'))
    $State.root_thumbprint = $Fixture.Root.Thumbprint
    $State.root_subject = $Fixture.Root.Subject
    $State.tls_port = $Fixture.TlsPort
    $State.proxy_port = $Fixture.ProxyPort
    $State.http_port = $Fixture.HttpPort
    if ($Mode -ceq 'ServeUpdater') {
        $State.second_proxy_port = $Fixture.SecondProxyPort
        $State.refusal_proxy_port = $Fixture.RefusalProxyPort
    }
    $State.state = 'ready'
    foreach ($Name in @('InstallRoot', 'RemoveRoot', 'Observe', 'Shutdown')) {
        $Events += [Threading.EventWaitHandle]::OpenExisting($EventPrefix + '.' + $Name)
    }
    Publish-State
    $Deadline = [DateTime]::UtcNow.AddSeconds(90)
    while ([DateTime]::UtcNow -lt $Deadline) {
        $Choice = [Threading.WaitHandle]::WaitAny([Threading.WaitHandle[]]$Events, 1000)
        if ($Choice -eq 0) {
            Publish-State -TrustStep 'event_received'
            $Store = [Security.Cryptography.X509Certificates.X509Store]::new('Root', $OwnedRootStoreScope)
            try {
                Publish-State -TrustStep 'before_open'
                $Store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
                Publish-State -TrustStep 'before_enumeration'
                if (@($Store.Certificates | Where-Object { $_.Thumbprint -ceq $State.root_thumbprint }).Count -ne 0) {
                    throw 'Unique owned root already existed before admission.'
                }
                Publish-State -TrustStep 'before_export'
                $PublicRoot = [Security.Cryptography.X509Certificates.X509Certificate2]::new($Fixture.Root.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert))
                try {
                    Publish-State -TrustStep 'before_add'
                    $Store.Add($PublicRoot)
                    Publish-State -TrustStep 'after_add'
                } finally { $PublicRoot.Dispose() }
                $RootInstalled = $true
                Publish-State -TrustStep 'before_postcheck'
                if (@($Store.Certificates | Where-Object { $_.Thumbprint -ceq $State.root_thumbprint }).Count -ne 1) {
                    throw 'Unique owned root installation was not acknowledged.'
                }
                # Keep the original finally ownership and exception priority.
                Publish-State -TrustStep 'before_close'
            } finally { $Store.Close(); $Store.Dispose() }
            $Fixture.TrustAdmitted = $true
            $State.phase = 'trusted'
        } elseif ($Choice -eq 1) {
            Remove-OwnedRoot $State.root_thumbprint $State.root_subject $OwnedRootStoreScope
            $RootInstalled = $false
            $State.root_removed = $true
            $Fixture.TrustAdmitted = $false
            $State.phase = 'removed'
        } elseif ($Choice -eq 3) { break }
        if ($Choice -ne [Threading.WaitHandle]::WaitTimeout) {
            foreach ($Counter in @('Requests','Generations','ReadyRequests','ProxyConnects','PacRequests','CrlRequests','FailedTls','ServiceFailures','ClosedConnections','DownloadRequests','DownloadRedirects','DownloadGood','DownloadOrigin401','DownloadOrigin403','DownloadSmall','DownloadWrongDigest','DownloadTruncated','DownloadSlow','DownloadCredentials','SecondProxyConnects','ProxyRefusals','BasicCredentials')) {
                $State[$Counter] = $Fixture.$Counter
            }
            Publish-State
        }
    }
} catch {
    $State.state = 'failed'
    $State.failure_type = $_.Exception.GetType().Name
    $State.failure_hresult = $_.Exception.HResult
    $State.service_failure_stage = 'fixture_boundary'
    $State.service_failure_kind = 'other'
    $State.service_failure_hresult = $_.Exception.HResult
} finally {
    try {
        if ($null -ne $Fixture) { $Fixture.Dispose(); $State.service_stopped = $true }
        if ($State.ContainsKey('root_thumbprint')) {
            Remove-OwnedRoot $State.root_thumbprint $State.root_subject $OwnedRootStoreScope
            $RootInstalled = $false
            $State.root_removed = $true
        }
    } catch {
        $State.state = 'failed'
        $State.cleanup_refused = $true
        if (-not $State.ContainsKey('service_failure_stage')) {
            $State.service_failure_stage = 'fixture_cleanup'
            $State.service_failure_kind = 'other'
            $State.service_failure_hresult = $_.Exception.HResult
        }
    }
    foreach ($Event in $Events) { $Event.Dispose() }
    if ($State.state -ne 'failed') { $State.state = 'stopped' }
    try { Publish-State } catch { [Console]::Out.WriteLine('OWNED_FIXTURE_STATE_REFUSED'); exit 1 }
}
if ($State.state -eq 'failed' -or -not $State.root_removed -or -not $State.service_stopped) { exit 1 }
[Console]::Out.WriteLine('OWNED_FIXTURE_STOPPED_ROOT_REMOVED')
