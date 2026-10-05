# vendor/ergopti_native_proxy.ps1
# Native WinHTTP discovery definitions only; no input reads, receipts or requests.
# Imported by the private tree-owned worker and updater staging owner.
if (-not ('ErgoptiNativeProxy' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class ErgoptiNativeProxy
{
    // Layout follows the Microsoft WinSDK winhttp.h declarations. Windows BOOL
    // is a four-byte Int32; LPWSTR fields use the current process pointer size.
    [StructLayout(LayoutKind.Sequential)]
    public struct AutoProxyOptions
    {
        public UInt32 Flags;
        public UInt32 AutoDetectFlags;
        public IntPtr AutoConfigUrl;
        public IntPtr Reserved;
        public UInt32 ReservedFlags;
        public Int32 AutoLogonIfChallenged;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct ProxyInfo
    {
        public UInt32 AccessType;
        public IntPtr Proxy;
        public IntPtr Bypass;
    }

    public sealed class Result
    {
        public bool Ok;
        public string Kind = "refused";
        public UInt32 AccessType;
        public string Proxy = "";
        public string Bypass = "";
        public int NativeError;
        public string Stage = "lookup";
    }

    private const UInt32 NoProxy = 1;
    private const UInt32 NamedProxy = 3;
    private const UInt32 AutoDetect = 0x00000001;
    private const UInt32 ConfigUrl = 0x00000002;
    private const UInt32 NoCacheClient = 0x00080000;
    private const UInt32 NoCacheService = 0x00100000;
    private const UInt32 DetectDhcp = 1;
    private const UInt32 DetectDnsA = 2;
    private const int AutoDetectionFailed = 12180;

    [DllImport("winhttp.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
    private static extern IntPtr WinHttpOpen(string agent, UInt32 access,
        IntPtr proxy, IntPtr bypass, UInt32 flags);

    [DllImport("winhttp.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool WinHttpGetProxyForUrl(IntPtr session, string url,
        ref AutoProxyOptions options, ref ProxyInfo info);

    [DllImport("winhttp.dll", SetLastError = true, ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool WinHttpCloseHandle(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true, ExactSpelling = true)]
    private static extern IntPtr GlobalFree(IntPtr memory);

    public static Result Resolve(string url, string pacUrl, bool autoDetect)
    {
        Result result = new Result();
        IntPtr session = IntPtr.Zero;
        IntPtr configUrl = IntPtr.Zero;
        ProxyInfo info = new ProxyInfo();
        try
        {
            // WinHttpOpen initializes an explicit-direct session; it sends no
            // destination request. Only GetProxyForUrl performs PAC discovery.
            session = WinHttpOpen("ErgoptiPlus system proxy discovery", NoProxy,
                IntPtr.Zero, IntPtr.Zero, 0);
            if (session == IntPtr.Zero)
            {
                result.NativeError = Marshal.GetLastWin32Error();
                result.Stage = "open";
                return result;
            }
            AutoProxyOptions options = new AutoProxyOptions();
            // Disable native host-result caches so path/query decisions remain
            // per URL even when the autoproxy service is reused across workers.
            options.Flags = NoCacheClient | NoCacheService;
            if (pacUrl.Length != 0)
            {
                configUrl = Marshal.StringToHGlobalUni(pacUrl);
                options.Flags |= ConfigUrl;
                options.AutoConfigUrl = configUrl;
            }
            else if (autoDetect)
            {
                options.Flags |= AutoDetect;
                options.AutoDetectFlags = DetectDhcp | DetectDnsA;
            }
            else
            {
                result.Stage = "input";
                return result;
            }
            // No explicit credential is accepted. WinHTTP may answer a trusted
            // configured PAC NTLM/Negotiate challenge as the signed-in user.
            options.AutoLogonIfChallenged = 1;
            bool resolved = WinHttpGetProxyForUrl(session, url, ref options, ref info);
            int error = resolved ? 0 : Marshal.GetLastWin32Error();
            result.NativeError = error;
            if (!resolved)
            {
                // Discovery absence is not a PAC DIRECT evaluation. It permits
                // the parent's validated WinINet static fallback on home LANs.
                if (pacUrl.Length == 0 && autoDetect && error == AutoDetectionFailed)
                    result.Kind = "no_auto_proxy";
                return result;
            }
            result.AccessType = info.AccessType;
            result.Proxy = info.Proxy == IntPtr.Zero ? "" : Marshal.PtrToStringUni(info.Proxy);
            result.Bypass = info.Bypass == IntPtr.Zero ? "" : Marshal.PtrToStringUni(info.Bypass);
            if (info.AccessType == NoProxy && result.Proxy.Length == 0)
            {
                result.Kind = "no_proxy";
                result.Ok = true;
            }
            else if (info.AccessType == NamedProxy && result.Proxy.Length != 0)
            {
                // The parent validates every endpoint before selecting curl's
                // supported representation; native success alone is not enough.
                result.Kind = "named_proxy";
                result.Ok = true;
            }
            else
            {
                result.Stage = "answer";
            }
            return result;
        }
        finally
        {
            bool released = true;
            int releaseError = 0;
            if (info.Proxy != IntPtr.Zero && GlobalFree(info.Proxy) != IntPtr.Zero)
            {
                released = false;
                releaseError = Marshal.GetLastWin32Error();
            }
            if (info.Bypass != IntPtr.Zero && GlobalFree(info.Bypass) != IntPtr.Zero)
            {
                released = false;
                releaseError = Marshal.GetLastWin32Error();
            }
            if (configUrl != IntPtr.Zero)
                Marshal.FreeHGlobal(configUrl);
            if (session != IntPtr.Zero && !WinHttpCloseHandle(session))
            {
                released = false;
                releaseError = Marshal.GetLastWin32Error();
            }
            if (!released)
            {
                result.Ok = false;
                result.Kind = "refused";
                result.Stage = "release";
                result.NativeError = releaseError;
            }
        }
    }
}
'@ -ErrorAction Stop
}
