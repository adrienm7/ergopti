; adapters/network_info.ahk

; ==============================================================================
; MODULE: NetworkInfo Adapter (AutoHotkey)
; DESCRIPTION:
; AHK v2 implementation of the NetworkInfo port contract defined in
; static/ergopti_plus/_shared/ports/NetworkInfo.spec.js. Wraps native Win32 APIs
; (wlanapi.dll, wininet.dll, iphlpapi.dll) behind four canonical functions so
; domain modules can query network context without coupling to OS-specific APIs.
;
; NAMING CONVENTION:
; Port method      → AHK function name
;   getSsidHash()         → NI_GetSsidHash()
;   getSignalStrength()   → NI_GetSignalStrength()
;   isInternetReachable() → NI_IsInternetReachable()
;   isVpnActive()         → NI_IsVpnActive()
;
; PRIVACY:
; NI_GetSsidHash() returns the SHA-256 hex digest of the SSID (via CryptoSha256
; from the Crypto adapter), never the raw network name.
;
; FAIL-SAFE:
; All DllCall paths are wrapped in try/catch. Functions return null or false
; rather than throwing when the underlying API is unavailable.
;
; Requires: Crypto
; ==============================================================================

#Requires Autohotkey v2.0+




; ==============================================
; ==============================================
; ======= 1/ WLAN API constants / layout =======
; ==============================================
; ==============================================

; WLAN API version negotiated with WlanOpenHandle
global NI_WLAN_API_VERSION                    := 2
; WlanQueryInterface opcode to retrieve current connection attributes
global NI_WLAN_INTF_OPCODE_CURRENT_CONNECTION := 7
; Win32 ERROR_SUCCESS
global NI_ERROR_SUCCESS                       := 0

; IP_ADAPTER_ADDRESSES offsets on 64-bit Windows (v1 base structure)
global NI_ADAPTER_OFFSET_OPER_STATUS          := 56   ; IF_OPER_STATUS field
global NI_ADAPTER_OFFSET_FRIENDLY_NAME        := 64   ; PWCHAR FriendlyName
global NI_ADAPTER_OFFSET_NEXT                 := 8    ; PIP_ADAPTER_ADDRESSES Next

; GetAdaptersAddresses flags (skip address lists we do not need)
global NI_GAA_FLAG_SKIP_UNICAST               := 0x0001
global NI_GAA_FLAG_SKIP_ANYCAST               := 0x0002
global NI_GAA_FLAG_SKIP_MULTICAST             := 0x0004
global NI_GAA_FLAG_SKIP_DNS_SERVER            := 0x0008
global NI_AF_UNSPEC                           := 0    ; address family — all

; IF_OPER_STATUS value for "up"
global NI_IF_OPER_STATUS_UP                   := 1

; Substring hints for VPN adapter friendly-name detection (lowercase)
global NI_VPN_NAME_HINTS := [
    "vpn", "wireguard", "nordvpn", "expressvpn", "protonvpn",
    "openvpn", "fortinet", "cisco anyconnect", "globalprotect",
    "zscaler", "tailscale", "mullvad"
]




; ===========================================================
; ===========================================================
; ======= 2/ Internal helper — raw WLAN query result =======
; ===========================================================
; ===========================================================

; Queries wlanapi.dll for the first connected Wi-Fi interface. Returns a Map
; with "ssid" (string) and "signal_pct" (integer 0-100) on success, or an
; empty Map when no Wi-Fi adapter is connected or the API is unavailable.
;
; Why native wlanapi rather than netsh: WScript.Shell.Exec spawns a visible
; cmd.exe window on every poll tick — visually disruptive and blocks input.
; wlanapi.dll is in-process with microsecond latency.
;
; WLAN_CONNECTION_ATTRIBUTES layout (offsets used below):
;   isState (4) + wlanConnectionMode (4) + strProfileName (512 WCHAR = 512 bytes)
;   = offset 520 → start of WLAN_ASSOCIATION_ATTRIBUTES.
;   DOT11_SSID = uSSIDLength (4) + ucSSID (32 bytes) → SSID data at +524.
;   wlanSignalQuality at +576 (DOT11_SSID 36 + DOT11_BSS_TYPE 4 +
;   DOT11_MAC_ADDRESS 6 + 2 padding + DOT11_PHY_TYPE 4 + uDot11PhyIndex 4 = 56).
_NI_QueryWlan() {
    result := Map()

    hClient := 0
    pdwNeg  := 0
    rc := DllCall("Wlanapi\WlanOpenHandle",
        "UInt", NI_WLAN_API_VERSION, "Ptr", 0,
        "UInt*", &pdwNeg, "Ptr*", &hClient, "UInt")
    if (rc != NI_ERROR_SUCCESS or hClient = 0)
        return result

    pIfaceList := 0
    rc := DllCall("Wlanapi\WlanEnumInterfaces",
        "Ptr", hClient, "Ptr", 0, "Ptr*", &pIfaceList, "UInt")
    if (rc != NI_ERROR_SUCCESS or pIfaceList = 0) {
        DllCall("Wlanapi\WlanCloseHandle", "Ptr", hClient, "Ptr", 0)
        return result
    }

    ; WLAN_INTERFACE_INFO_LIST: dwNumberOfItems(4) + dwIndex(4) = 8 bytes header.
    ; Each WLAN_INTERFACE_INFO = GUID(16) + WCHAR[256](512) + isState(4) = 532 bytes.
    nItems := NumGet(pIfaceList, 0, "UInt")
    Loop nItems {
        pIface := pIfaceList + 8 + (A_Index - 1) * 532
        ; isState at offset 528 (GUID 16 + description 512). State 1 = connected.
        if (NumGet(pIface, 528, "UInt") != 1)
            continue

        guid := Buffer(16, 0)
        DllCall("RtlMoveMemory", "Ptr", guid, "Ptr", pIface, "UPtr", 16)

        pData     := 0
        cbData    := 0
        valueType := 0
        rc := DllCall("Wlanapi\WlanQueryInterface",
            "Ptr",   hClient,
            "Ptr",   guid,
            "UInt",  NI_WLAN_INTF_OPCODE_CURRENT_CONNECTION,
            "Ptr",   0,
            "UInt*", &cbData,
            "Ptr*",  &pData,
            "UInt*", &valueType,
            "UInt")
        if (rc = NI_ERROR_SUCCESS and pData) {
            ssid_len := NumGet(pData, 520, "UInt")
            if (ssid_len > 0 and ssid_len <= 32) {
                ssid       := StrGet(pData + 524, ssid_len, "UTF-8")
                signal_pct := NumGet(pData, 576, "UInt")
                if (signal_pct > 100)
                    signal_pct := 100
                result["ssid"]       := ssid
                result["signal_pct"] := signal_pct
            }
            DllCall("Wlanapi\WlanFreeMemory", "Ptr", pData)
        }
        if (result.Count > 0)
            break
    }

    DllCall("Wlanapi\WlanFreeMemory", "Ptr", pIfaceList)
    DllCall("Wlanapi\WlanCloseHandle", "Ptr", hClient, "Ptr", 0)
    return result
}




; =====================================================
; =====================================================
; ======= 3/ NetworkInfo port implementation =======
; =====================================================
; =====================================================

; Returns the SHA-256 hex digest of the active Wi-Fi SSID, or null when no
; Wi-Fi connection is available. Uses CryptoSha256() from the Crypto adapter
; so the raw SSID never reaches the caller.
NI_GetSsidHash() {
    try {
        info := _NI_QueryWlan()
        if (info.Count = 0)
            return ""   ; no Wi-Fi — return empty string (null equivalent in AHK)
        return CryptoSha256(info["ssid"])
    }
    return ""
}


; Returns the Wi-Fi signal quality as an integer percentage (0-100), or null
; (empty string) when no Wi-Fi connection is available.
NI_GetSignalStrength() {
    try {
        info := _NI_QueryWlan()
        if (info.Count = 0)
            return ""
        return info["signal_pct"]
    }
    return ""
}


; Returns true when the host has a working internet connection. Uses
; InternetGetConnectedState from wininet.dll which reads the Network List
; service's cached state without opening a socket — safe to call on the
; AHK main thread at any frequency.
NI_IsInternetReachable() {
    try {
        flags := 0
        return !!DllCall("Wininet\InternetGetConnectedState",
            "UInt*", &flags, "UInt", 0, "Int")
    }
    return false
}


; Returns true when at least one VPN adapter with a recognised friendly name
; is currently in the IF_OPER_STATUS_UP state. Walks the GetAdaptersAddresses
; linked list via iphlpapi.dll — native, in-process, no subprocess latency.
NI_IsVpnActive() {
    try {
        flags := NI_GAA_FLAG_SKIP_UNICAST | NI_GAA_FLAG_SKIP_ANYCAST
               | NI_GAA_FLAG_SKIP_MULTICAST | NI_GAA_FLAG_SKIP_DNS_SERVER

        ; Two-call idiom: first call sizes the buffer, second fills it.
        cb := 0
        DllCall("Iphlpapi\GetAdaptersAddresses",
            "UInt", NI_AF_UNSPEC, "UInt", flags, "Ptr", 0,
            "Ptr",  0,            "UInt*", &cb,  "UInt")
        if (cb = 0)
            return false

        buf := Buffer(cb, 0)
        rc := DllCall("Iphlpapi\GetAdaptersAddresses",
            "UInt", NI_AF_UNSPEC, "UInt", flags, "Ptr", 0,
            "Ptr",  buf,          "UInt*", &cb,  "UInt")
        if (rc != 0)
            return false

        p := buf.Ptr
        while (p) {
            oper_status := NumGet(p, NI_ADAPTER_OFFSET_OPER_STATUS, "UInt")
            if (oper_status = NI_IF_OPER_STATUS_UP) {
                pname := NumGet(p, NI_ADAPTER_OFFSET_FRIENDLY_NAME, "Ptr")
                if (pname) {
                    lower_name := StrLower(StrGet(pname, "UTF-16"))
                    for _, hint in NI_VPN_NAME_HINTS {
                        if InStr(lower_name, hint)
                            return true
                    }
                }
            }
            p := NumGet(p, NI_ADAPTER_OFFSET_NEXT, "Ptr")
        }
    }
    return false
}
