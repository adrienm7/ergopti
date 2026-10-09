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
; All DllCall paths are wrapped in try/catch. Port functions return null or
; false, and the stateful snapshot returns typed "unknown", rather than throwing
; when the underlying API is unavailable.
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
global NI_ERROR_BUFFER_OVERFLOW               := 111

; Stateful consumers need a typed observation so a transient native API
; failure cannot be mistaken for a real disconnect. The public port methods
; remain boolean for cross-driver compatibility and reduce these snapshots.
global NI_BINARY_STATUS_UP                    := "up"
global NI_BINARY_STATUS_DOWN                  := "down"
global NI_BINARY_STATUS_UNKNOWN               := "unknown"

; Tri-state WLAN observation contract. A successful enumeration with no
; connected interface is a real disconnect; API failures are unknown and must
; never be mistaken for a disconnect by stateful consumers.
global NI_WIFI_STATUS_CONNECTED               := "connected"
global NI_WIFI_STATUS_DISCONNECTED            := "disconnected"
global NI_WIFI_STATUS_UNKNOWN                 := "unknown"

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
; out of the SAME WLAN_CONNECTION_ATTRIBUTES buffer. Callers may ask for them
; back to back, so a stateless implementation pays two full round-trips for one
; buffer. WlanOpenHandle is an RPC to the WLAN AutoConfig service and
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
global NI_WLAN_CACHE                          := Map("status", NI_WIFI_STATUS_UNKNOWN)
global NI_WLAN_CACHE_AT                       := 0

; Publishes a query result as the current cache entry and hands it back, so the
; caching contract is stated once instead of at each of _NI_QueryWlan's exits.
_NI_CacheWlanResult(result) {
    global NI_WLAN_CACHE, NI_WLAN_CACHE_AT
    NI_WLAN_CACHE    := result
    NI_WLAN_CACHE_AT := A_TickCount
    return result
}


; Queries wlanapi.dll for the first connected Wi-Fi interface. Every result has
; a typed "status": connected includes "ssid" (an encoding-independent hex
; serialisation of the raw SSID octets) and "signal_pct" (integer 0-100),
; disconnected means enumeration succeeded with no connected interface, and
; unknown means the API failed or returned malformed connection attributes.
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

    result           := Map("status", NI_WIFI_STATUS_UNKNOWN)
    hClient          := 0
    client_owned     := false
    pIfaceList       := 0
    iface_list_owned := false

    try {
        pdwNeg := 0
        rc := DllCall("Wlanapi\WlanOpenHandle",
            "UInt", NI_WLAN_API_VERSION, "Ptr", 0,
            "UInt*", &pdwNeg, "Ptr*", &hClient, "UInt")
        if (rc = NI_ERROR_SUCCESS and hClient != 0) {
            client_owned := true
            rc := DllCall("Wlanapi\WlanEnumInterfaces",
                "Ptr", hClient, "Ptr", 0, "Ptr*", &pIfaceList, "UInt")
            if (rc = NI_ERROR_SUCCESS and pIfaceList != 0) {
                iface_list_owned := true
                ; A successful enumeration starts as a proven disconnect. Seeing
                ; a connected interface moves it back to unknown until its
                ; attributes have been validated completely.
                result := Map("status", NI_WIFI_STATUS_DISCONNECTED)

                ; WLAN_INTERFACE_INFO_LIST: dwNumberOfItems(4) + dwIndex(4)
                ; = 8-byte header. Each WLAN_INTERFACE_INFO is 532 bytes.
                nItems := NumGet(pIfaceList, 0, "UInt")
                Loop nItems {
                    pIface := pIfaceList + 8 + (A_Index - 1) * 532
                    ; isState at +528. WLAN_INTERFACE_STATE_CONNECTED = 1.
                    if (NumGet(pIface, 528, "UInt") != 1)
                        continue

                    result := Map("status", NI_WIFI_STATUS_UNKNOWN)
                    guid := Buffer(16, 0)
                    DllCall("RtlMoveMemory", "Ptr", guid, "Ptr", pIface, "UPtr", 16)

                    pData     := 0
                    data_owned := false
                    cbData    := 0
                    valueType := 0
                    try {
                        rc := DllCall("Wlanapi\WlanQueryInterface",
                            "Ptr",   hClient,
                            "Ptr",   guid,
                            "UInt",  NI_WLAN_INTF_OPCODE_CURRENT_CONNECTION,
                            "Ptr",   0,
                            "UInt*", &cbData,
                            "Ptr*",  &pData,
                            "UInt*", &valueType,
                            "UInt")
                        if (rc = NI_ERROR_SUCCESS and pData)
                            data_owned := true
                        ; Bounds check before reading signal quality at +576.
                        if (rc != NI_ERROR_SUCCESS or !pData
                            or cbData < NI_WLAN_MIN_CONN_ATTR_SIZE)
                            continue

                        ssid_len := NumGet(pData, NI_WLAN_OFFSET_SSID_LEN, "UInt")
                        if (ssid_len <= 0 or ssid_len > NI_WLAN_MAX_SSID_LEN)
                            continue

                        ; Hash the raw octets (not a UTF-8 re-decode) so the
                        ; digest remains stable for non-UTF-8 SSIDs.
                        ssid := _NI_SsidOctetsToHashInput(
                            pData + NI_WLAN_OFFSET_SSID_DATA, ssid_len)
                        signal_pct := NumGet(pData, NI_WLAN_OFFSET_SIGNAL_QUALITY, "UInt")
                        if (signal_pct > 100)
                            signal_pct := 100
                        result := Map(
                            "status",     NI_WIFI_STATUS_CONNECTED,
                            "ssid",       ssid,
                            "signal_pct", signal_pct
                        )
                        break
                    } finally {
                        if data_owned
                            try DllCall("Wlanapi\WlanFreeMemory", "Ptr", pData)
                    }
                }
            }
        }
    } catch {
        result := Map("status", NI_WIFI_STATUS_UNKNOWN)
    } finally {
        if iface_list_owned
            try DllCall("Wlanapi\WlanFreeMemory", "Ptr", pIfaceList)
        if client_owned
            try DllCall("Wlanapi\WlanCloseHandle", "Ptr", hClient, "Ptr", 0)
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
        if (info.Get("status", NI_WIFI_STATUS_UNKNOWN) != NI_WIFI_STATUS_CONNECTED)
            return ""   ; no proven Wi-Fi connection
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
        if (info.Get("status", NI_WIFI_STATUS_UNKNOWN) != NI_WIFI_STATUS_CONNECTED)
            return ""
        return info["signal_pct"]
    } catch {
        return ""
    }
}


; Returns one internally consistent WLAN observation for stateful consumers.
; Unknown is deliberately distinct from disconnected: callers must preserve
; their last accepted state when the adapter cannot prove either outcome.
NI_GetWifiSnapshot() {
    try {
        info   := _NI_QueryWlan()
        status := info.Get("status", NI_WIFI_STATUS_UNKNOWN)
        if (status = NI_WIFI_STATUS_DISCONNECTED)
            return Map("status", NI_WIFI_STATUS_DISCONNECTED)
        if (status != NI_WIFI_STATUS_CONNECTED)
            return Map("status", NI_WIFI_STATUS_UNKNOWN)

        ssid := info.Get("ssid", "")
        signal_pct := info.Get("signal_pct", "")
        if !(ssid is String) or ssid = "" or !(signal_pct is Number)
            return Map("status", NI_WIFI_STATUS_UNKNOWN)

        ssid_hash := CryptoSha256(ssid)
        if !(ssid_hash is String) or ssid_hash = ""
            return Map("status", NI_WIFI_STATUS_UNKNOWN)

        return Map(
            "status",     NI_WIFI_STATUS_CONNECTED,
            "ssid_hash",  ssid_hash,
            "signal_pct", signal_pct
        )
    } catch {
        return Map("status", NI_WIFI_STATUS_UNKNOWN)
    }
}


; Returns a typed observation of whether the host has a working internet
; connection. Uses
; InternetGetConnectedState from wininet.dll which reads the Network List
; service's cached state without opening a socket — safe to call on the
; AHK main thread at any frequency.
NI_GetInternetStatus() {
    try {
        flags := 0
        connected := DllCall("Wininet\InternetGetConnectedState",
            "UInt*", &flags, "UInt", 0, "Int")
        return connected ? NI_BINARY_STATUS_UP : NI_BINARY_STATUS_DOWN
    } catch {
        return NI_BINARY_STATUS_UNKNOWN
    }
}


NI_IsInternetReachable() {
    return NI_GetInternetStatus() = NI_BINARY_STATUS_UP
}


; Returns a typed observation of whether at least one VPN adapter with a
; recognised friendly name is currently in the IF_OPER_STATUS_UP state. Walks
; the GetAdaptersAddresses linked list via iphlpapi.dll — native, in-process,
; no subprocess latency.
NI_GetVpnStatus() {
    try {
        flags := NI_GAA_FLAG_SKIP_UNICAST | NI_GAA_FLAG_SKIP_ANYCAST
               | NI_GAA_FLAG_SKIP_MULTICAST | NI_GAA_FLAG_SKIP_DNS_SERVER

        ; Two-call idiom: first call sizes the buffer, second fills it.
        cb := 0
        rc := DllCall("Iphlpapi\GetAdaptersAddresses",
            "UInt", NI_AF_UNSPEC, "UInt", flags, "Ptr", 0,
            "Ptr",  0,            "UInt*", &cb,  "UInt")
        if (rc != NI_ERROR_BUFFER_OVERFLOW or cb = 0)
            return NI_BINARY_STATUS_UNKNOWN

        buf := Buffer(cb, 0)
        rc := DllCall("Iphlpapi\GetAdaptersAddresses",
            "UInt", NI_AF_UNSPEC, "UInt", flags, "Ptr", 0,
            "Ptr",  buf,          "UInt*", &cb,  "UInt")
        if (rc != 0)
            return NI_BINARY_STATUS_UNKNOWN

        p := buf.Ptr
        while (p) {
            oper_status := NumGet(p, NI_ADAPTER_OFFSET_OPER_STATUS, "UInt")
            if (oper_status = NI_IF_OPER_STATUS_UP) {
                pname := NumGet(p, NI_ADAPTER_OFFSET_FRIENDLY_NAME, "Ptr")
                if (pname) {
                    lower_name := StrLower(StrGet(pname, "UTF-16"))
                    for _, hint in NI_VPN_NAME_HINTS {
                        if InStr(lower_name, hint)
                            return NI_BINARY_STATUS_UP
                    }
                }
            }
            p := NumGet(p, NI_ADAPTER_OFFSET_NEXT, "Ptr")
        }
        return NI_BINARY_STATUS_DOWN
    } catch {
        return NI_BINARY_STATUS_UNKNOWN
    }
}


NI_IsVpnActive() {
    return NI_GetVpnStatus() = NI_BINARY_STATUS_UP
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
