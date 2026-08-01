; adapters/network_info.ahk

; ==============================================================================
; MODULE: NetworkInfo Adapter (AutoHotkey)
; DESCRIPTION:
; AHK v2 implementation of the NetworkInfo port contract defined in
; static/ergopti_plus/_shared/core/ports/NetworkInfo.spec.js. Wraps native Win32 APIs
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

; DOT11_SSID field offsets inside WLAN_CONNECTION_ATTRIBUTES (64-bit layout)
global NI_WLAN_OFFSET_SSID_LEN                := 520  ; uSSIDLength (UInt)
global NI_WLAN_OFFSET_SSID_DATA               := 524  ; ucSSID octet buffer
global NI_WLAN_OFFSET_SIGNAL_QUALITY          := 576  ; wlanSignalQuality (UInt)
; Maximum DOT11_SSID payload — ucSSID is a fixed 32-octet buffer
global NI_WLAN_MAX_SSID_LEN                   := 32
; Smallest cbData that can still hold the signal-quality field at +576 (4 bytes).
; Guards against a truncated WlanQueryInterface result before NumGet'ing +576.
global NI_WLAN_MIN_CONN_ATTR_SIZE             := 580

; IP_ADAPTER_ADDRESSES offsets — architecture-dependent.
; x64 layout: ULONG(4)+IfIndex(4)+8ptr×Next+AdapterName+…+DnsSuffix+Description = 56 (DnsSuffix ptr),
;             +8 = 64 (Description ptr), +8 = 72 (FriendlyName ptr),
;             then PhysicalAddress[8]+PhysicalAddressLength(4)+Flags(4)+Mtu(4)+IfType(4)+OperStatus(4) = offset 104.
; x86 layout: pointers are 4 bytes; OperStatus is at offset 68, FriendlyName at 40.
global NI_ADAPTER_OFFSET_OPER_STATUS          := (A_PtrSize == 8) ? 104 : 68   ; IF_OPER_STATUS field
global NI_ADAPTER_OFFSET_FRIENDLY_NAME        := (A_PtrSize == 8) ? 72  : 40   ; PWCHAR FriendlyName
global NI_ADAPTER_OFFSET_NEXT                 := 8    ; PIP_ADAPTER_ADDRESSES Next (same on x86/x64)

; GetAdaptersAddresses flags (skip address lists we do not need)
global NI_GAA_FLAG_SKIP_UNICAST               := 0x0001
global NI_GAA_FLAG_SKIP_ANYCAST               := 0x0002
global NI_GAA_FLAG_SKIP_MULTICAST             := 0x0004
global NI_GAA_FLAG_SKIP_DNS_SERVER            := 0x0008
global NI_AF_UNSPEC                           := 0    ; address family — all

; IF_OPER_STATUS value for "up"
global NI_IF_OPER_STATUS_UP                   := 1

; Lifetime of one WLAN query result, in ms. The NetworkInfo port exposes the
; SSID and the signal strength as two independent methods, but both values come
; out of the SAME WLAN_CONNECTION_ATTRIBUTES buffer, and every caller asks for
; them back to back — so a stateless implementation pays two full round-trips
; for one buffer. WlanOpenHandle is an RPC to the WLAN AutoConfig service and
; dominates the cost (measured on this machine: 9.3 ms of the 18.0 ms a keylogger
; tick spent querying twice, against 9.8 ms for a single query). It runs as a
; DllCall on the AHK script thread, which cannot be interrupted mid-flight, so a
; keystroke arriving during it simply waits. 2 s is an order of magnitude below
; the 15 s network poll interval, so no observable freshness is lost.
global NI_WLAN_CACHE_TTL_MS                   := 2000

; Substring hints for VPN adapter friendly-name detection (lowercase)
global NI_VPN_NAME_HINTS := [
    "vpn", "wireguard", "nordvpn", "expressvpn", "protonvpn",
    "openvpn", "fortinet", "cisco anyconnect", "globalprotect",
    "zscaler", "tailscale", "mullvad"
]





; ==========================================================
; ==========================================================
; ======= 2/ Internal helper — raw WLAN query result =======
; ==========================================================
; ==========================================================

; Builds a stable, encoding-independent hash input from the raw DOT11_SSID
; octets. 802.11 SSIDs are opaque octet strings — decoding them as UTF-8 is a
; heuristic that mojibakes non-UTF-8 access points, yielding an unstable hash
; that fails to identify the same physical network across polls. We instead
; serialise the exact octets as a fixed two-hex-digits-per-byte string so the
; digest is a deterministic function of the true network identifier regardless
; of its byte encoding.
;
; @param pBytes Pointer to the first SSID octet (caller passes pData + offset).
; @param len    Number of valid SSID octets (uSSIDLength, already bounds-checked).
; @returns A lowercase hex string of exactly len*2 characters.
_NI_SsidOctetsToHashInput(pBytes, len) {
    out := ""
    Loop len
        out .= Format("{:02x}", NumGet(pBytes, A_Index - 1, "UChar"))
    return out
}


; Last WLAN query result and the tick at which it was taken. Shared by every
; _NI_QueryWlan exit path so that a failed query is memoised exactly like a
; successful one — otherwise the most expensive case (the WLAN service not
; answering) would be the one re-paid on every call.
global NI_WLAN_CACHE                          := Map()
global NI_WLAN_CACHE_AT                       := 0

; Publishes a query result as the current cache entry and hands it back, so the
; caching contract is stated once instead of at each of _NI_QueryWlan's exits.
_NI_CacheWlanResult(result) {
    global NI_WLAN_CACHE, NI_WLAN_CACHE_AT
    NI_WLAN_CACHE    := result
    NI_WLAN_CACHE_AT := A_TickCount
    return result
}


; Queries wlanapi.dll for the first connected Wi-Fi interface. Returns a Map
; with "ssid" (an encoding-independent hex serialisation of the raw SSID octets,
; suitable for hashing) and "signal_pct" (integer 0-100) on success, or an
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
    global NI_WLAN_CACHE, NI_WLAN_CACHE_AT, NI_WLAN_CACHE_TTL_MS
    ; Serve back-to-back callers from one round-trip. NI_GetSsidHash() and
    ; NI_GetSignalStrength() are two port methods reading two fields of the same
    ; buffer, and the keylogger network tick calls them one after the other; the
    ; second WlanOpenHandle RPC was pure duplicated work on the script thread.
    if (NI_WLAN_CACHE_AT != 0
        and ((A_TickCount - NI_WLAN_CACHE_AT) & 0xFFFFFFFF) < NI_WLAN_CACHE_TTL_MS)
        return NI_WLAN_CACHE

    result := Map()

    hClient := 0
    pdwNeg  := 0
    rc := DllCall("Wlanapi\WlanOpenHandle",
        "UInt", NI_WLAN_API_VERSION, "Ptr", 0,
        "UInt*", &pdwNeg, "Ptr*", &hClient, "UInt")
    if (rc != NI_ERROR_SUCCESS or hClient = 0)
        return _NI_CacheWlanResult(result)

    pIfaceList := 0
    rc := DllCall("Wlanapi\WlanEnumInterfaces",
        "Ptr", hClient, "Ptr", 0, "Ptr*", &pIfaceList, "UInt")
    if (rc != NI_ERROR_SUCCESS or pIfaceList = 0) {
        DllCall("Wlanapi\WlanCloseHandle", "Ptr", hClient, "Ptr", 0)
        return _NI_CacheWlanResult(result)
    }

    ; WLAN_INTERFACE_INFO_LIST: dwNumberOfItems(4) + dwIndex(4) = 8 bytes header.
    ; Each WLAN_INTERFACE_INFO = GUID(16) + WCHAR[256](512) + isState(4) = 532 bytes.
    nItems := NumGet(pIfaceList, 0, "UInt")
    ; finally guarantees pIfaceList and hClient are always freed even if an
    ; exception is thrown inside the loop body (e.g. from a bad NumGet address
    ; or an unexpected DllCall failure that the loop body does not catch itself).
    try {
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
            ; Bounds check: WlanQueryInterface must have returned a buffer large
            ; enough to hold the signal-quality field at +576; a truncated result
            ; would make the +576 NumGet read past the allocation.
            if (rc = NI_ERROR_SUCCESS and pData and cbData >= NI_WLAN_MIN_CONN_ATTR_SIZE) {
                ssid_len := NumGet(pData, NI_WLAN_OFFSET_SSID_LEN, "UInt")
                if (ssid_len > 0 and ssid_len <= NI_WLAN_MAX_SSID_LEN) {
                    ; Hash the raw octets (not a UTF-8 re-decode) so the digest is
                    ; stable for non-UTF-8 SSIDs — see _NI_SsidOctetsToHashInput.
                    ssid       := _NI_SsidOctetsToHashInput(pData + NI_WLAN_OFFSET_SSID_DATA, ssid_len)
                    signal_pct := NumGet(pData, NI_WLAN_OFFSET_SIGNAL_QUALITY, "UInt")
                    if (signal_pct > 100)
                        signal_pct := 100
                    result["ssid"]       := ssid
                    result["signal_pct"] := signal_pct
                }
            }
            if (rc = NI_ERROR_SUCCESS and pData)
                DllCall("Wlanapi\WlanFreeMemory", "Ptr", pData)
            if (result.Count > 0)
                break
        }
    } finally {
        DllCall("Wlanapi\WlanFreeMemory", "Ptr", pIfaceList)
        DllCall("Wlanapi\WlanCloseHandle", "Ptr", hClient, "Ptr", 0)
    }
    return _NI_CacheWlanResult(result)
}





; ==================================================
; ==================================================
; ======= 3/ NetworkInfo port implementation =======
; ==================================================
; ==================================================

; Returns the SHA-256 hex digest of the active Wi-Fi SSID, or null when no
; Wi-Fi connection is available. Uses CryptoSha256() from the Crypto adapter
; so the raw SSID never reaches the caller.
NI_GetSsidHash() {
    try {
        info := _NI_QueryWlan()
        if (info.Count = 0)
            return ""   ; no Wi-Fi — return empty string (null equivalent in AHK)
        return CryptoSha256(info["ssid"])
    } catch {
        return ""
    }
}


; Returns the Wi-Fi signal quality as an integer percentage (0-100), or null
; (empty string) when no Wi-Fi connection is available.
NI_GetSignalStrength() {
    try {
        info := _NI_QueryWlan()
        if (info.Count = 0)
            return ""
        return info["signal_pct"]
    } catch {
        return ""
    }
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
    } catch {
        return false
    }
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
        ; No matching VPN adapter found. Return a genuine boolean false rather
        ; than falling off the end (an AHK v2 function with no return yields "",
        ; violating the NetworkInfo.spec.js boolean contract on the common path).
        return false
    } catch {
        return false
    }
}

; Port dispatch map (ADAPTER_NETWORK_INFO) — the single-source-of-truth contract
; surface, verified against _shared/core/ports/contracts.json by
; tools/test/test-port-compliance.cjs.
global ADAPTER_NETWORK_INFO := Map(
    "getSignalStrength", NI_GetSignalStrength,
    "getSsidHash", NI_GetSsidHash,
    "isInternetReachable", NI_IsInternetReachable,
    "isVpnActive", NI_IsVpnActive
)
