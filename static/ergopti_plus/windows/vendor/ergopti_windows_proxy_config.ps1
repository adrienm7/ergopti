# vendor/ergopti_windows_proxy_config.ps1
# Current-user WinINet configuration ownership; no request or route policy.
if (-not ('ErgoptiWindowsProxyConfig' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class ErgoptiWindowsProxyConfig
{
    [StructLayout(LayoutKind.Sequential)]
    public struct NativeConfig
    {
        public Int32 AutoDetect;
        public IntPtr AutoConfigUrl;
        public IntPtr Proxy;
        public IntPtr Bypass;
    }
    public sealed class Config
    {
        public bool Ok;
        public bool Absent;
        public bool AutoDetect;
        public string PacUrl="";
        public string Proxy="";
        public string Bypass="";
        public int NativeError;
        public int CleanupError;
        public string Stage="read";
        public string FailureOrigin="native";
    }
    [DllImport("winhttp.dll",SetLastError=true,ExactSpelling=true)]
    [return:MarshalAs(UnmanagedType.Bool)]
    private static extern bool WinHttpGetIEProxyConfigForCurrentUser(ref NativeConfig config);
    [DllImport("kernel32.dll",SetLastError=true,ExactSpelling=true)]
    private static extern IntPtr GlobalFree(IntPtr pointer);
    private static string ReadText(IntPtr address,int maxBytes)
    {
        if(address==IntPtr.Zero)return "";
        StringBuilder text=new StringBuilder();
        for(int index=0;index<maxBytes/2;index++) {
            char value=(char)Marshal.ReadInt16(address,checked(index*2));
            if(value==0)return text.ToString();
            text.Append(value);
        }
        throw new InvalidOperationException("Native configuration exceeded its admitted bound.");
    }
    public static Config Read(int maxBytes)
    {
        Config answer=new Config(); NativeConfig native=new NativeConfig();
        if(maxBytes<2 || maxBytes>1048576){answer.FailureOrigin="invalid_input";return answer;}
        try {
            if(!WinHttpGetIEProxyConfigForCurrentUser(ref native)) {
                answer.NativeError=Marshal.GetLastWin32Error();
                if(answer.NativeError==2){answer.Ok=true;answer.Absent=true;}
                return answer;
            }
            if(native.AutoDetect!=0 && native.AutoDetect!=1) { answer.FailureOrigin="invalid_native_receipt";return answer; }
            answer.AutoDetect=native.AutoDetect!=0;
            answer.PacUrl=ReadText(native.AutoConfigUrl,maxBytes);
            answer.Proxy=ReadText(native.Proxy,maxBytes);
            answer.Bypass=ReadText(native.Bypass,maxBytes);
            answer.Ok=true;
        } catch(Exception) { answer.FailureOrigin="managed_boundary"; }
        finally {
            bool readSucceeded=answer.Ok;
            HashSet<IntPtr> allocated=new HashSet<IntPtr>();
            foreach(IntPtr pointer in new[]{native.AutoConfigUrl,native.Proxy,native.Bypass}) {
                if(pointer!=IntPtr.Zero && allocated.Add(pointer) && GlobalFree(pointer)!=IntPtr.Zero) {
                    int cleanupError=Marshal.GetLastWin32Error();
                    answer.Ok=false;if(answer.CleanupError==0)answer.CleanupError=cleanupError;
                    if(readSucceeded && answer.NativeError==0) { answer.NativeError=answer.CleanupError;answer.Stage="cleanup";answer.FailureOrigin="native"; }
                }
            }
        }
        return answer;
    }
}
'@
}
