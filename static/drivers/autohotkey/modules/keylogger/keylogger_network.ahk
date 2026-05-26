; modules/keylogger_network.ahk

; ==============================================================================
; MODULE: Keylogger Network State
; DESCRIPTION:
; Tracks network connectivity transitions and emits events that help
; correlate typing patterns with connection context (offline work, VPN
; sessions, location changes via SSID hash).
;
; FEATURES & RATIONALE:
; 1. Network change — polls the active Wi-Fi SSID and connection type
;    every NETWORK_TICK_MS. On change emits a network_change event with
;    a SHA-256 hash of the SSID (never the raw name — privacy) and the
;    signal-strength bracket (excellent/good/fair/poor) derived from the
;    RSSI reported by netsh wlan show interfaces.
; 2. Internet reachability — polls internet connectivity via a lightweight
;    DNS lookup (resolve a known stable hostname) every REACH_TICK_MS.
;    Emits internet_up / internet_down events on transition. This surfaces
;    offline writing sessions.
; 3. VPN detection — checks for known VPN adapter names in the network
;    interface list every VPN_TICK_MS. Emits vpn_connected / vpn_disconnected.
;    VPN-on correlates with « work from external location » or « secure
;    channel required » contexts.
;
; PRIVACY:
; - SSID is SHA-256 hashed before storage; the raw string never touches
;   today.log or data.sql.
; - No packet content, no DNS response content, no IP addresses are logged.
; - The DNS reachability check resolves "dns.msftncsi.com" (Windows NCSI
;   host — always resolves when internet is available) without sending any
;   user data.
; ==============================================================================

#Requires Autohotkey v2.0+





; ===================================
; ============================
; ======= 1/ Constants =======
; ============================
; ===================================

class KLNetConst {
    static NETWORK_TICK_MS  := 15000   ; Wi-Fi / SSID poll interval
    static REACH_TICK_MS    := 30000   ; Internet reachability check
    static VPN_TICK_MS      := 20000   ; VPN adapter poll interval

    ; RSSI thresholds (dBm) for signal-strength bracket
    static RSSI_EXCELLENT   := -50
    static RSSI_GOOD        := -65
    static RSSI_FAIR        := -75
    ; Below RSSI_FAIR → "poor"

    ; Substring fragments in VPN adapter names (lower-cased)
    static VPN_NAME_HINTS := [
        "vpn", "wireguard", "nordvpn", "expressvpn", "protonvpn",
        "openvpn", "fortinet", "cisco anyconnect", "globalprotect",
        "zscaler", "tailscale", "mullvad"
    ]

    ; Windows NCSI hostname — always resolves when internet is up
    static NCSI_HOST := "dns.msftncsi.com"
}





; ===================================
; ===============================
; ======= 2/ Module state =======
; ===============================
; ===================================

class KLNet {
    static last_ssid_hash   := ""
    static last_signal      := ""
    static internet_up      := true   ; assume up until first check
    static vpn_active       := false
    static vpn_adapter_name := ""

    static wifi_fn          := unset
    static reach_fn         := unset
    static vpn_fn           := unset
}





; =========================================
; ====================================
; ======= 3/ Wi-Fi / SSID poll =======
; ====================================
; =========================================

; Queries the active Wi-Fi connection via the Win32 WLAN API. Returns a Map
; with "ssid" and "signal_pct" (0-100) on success, or an empty Map when no
; Wi-Fi adapter is connected / the API is unavailable.
;
; Why this rather than ``netsh wlan show interfaces``: the WScript.Shell.Exec
; path spawned a visible cmd.exe console window every NETWORK_TICK_MS — a
; flash + brief input freeze on every poll, completely unacceptable on a
; keyboard driver. wlanapi.dll is a native API, no subprocess, no console.
;
; Layout of the structures we touch (see wlantypes.h on Microsoft Learn):
;   WLAN_INTERFACE_INFO_LIST = { dwNumberOfItems: DWORD, dwIndex: DWORD,
;       InterfaceInfo: WLAN_INTERFACE_INFO[] }
;   WLAN_INTERFACE_INFO      = { InterfaceGuid: 16 bytes,
;       strInterfaceDescription: 256 WCHAR, isState: DWORD }
;   WLAN_CONNECTION_ATTRIBUTES = { isState: 4, wlanConnectionMode: 4,
;       strProfileName: 256 WCHAR (=512 bytes), wlanAssociationAttributes: 152,
;       wlanSecurityAttributes: 16 }
;   WLAN_ASSOCIATION_ATTRIBUTES (152 bytes) starts with:
;       dot11Ssid (DOT11_SSID = uLength DWORD + ucSSID 32 bytes), …
;       wlanSignalQuality DWORD at offset 132
KL_Net_QueryWifi() {
    static WLAN_API_VERSION                   := 2
    static WLAN_INTF_OPCODE_CURRENT_CONNECTION := 7
    static ERROR_SUCCESS                       := 0

    result := Map()

    hClient   := 0
    pdwNeg    := 0
    rc := DllCall("Wlanapi\WlanOpenHandle",
        "UInt", WLAN_API_VERSION, "Ptr", 0,
        "UInt*", &pdwNeg, "Ptr*", &hClient, "UInt")
    if (rc != ERROR_SUCCESS or hClient = 0) {
        return result
    }

    pIfaceList := 0
    rc := DllCall("Wlanapi\WlanEnumInterfaces",
        "Ptr", hClient, "Ptr", 0, "Ptr*", &pIfaceList, "UInt")
    if (rc != ERROR_SUCCESS or pIfaceList = 0) {
        DllCall("Wlanapi\WlanCloseHandle", "Ptr", hClient, "Ptr", 0)
        return result
    }

    nItems := NumGet(pIfaceList, 0, "UInt")
    ; First WLAN_INTERFACE_INFO sits 8 bytes in (dwNumberOfItems + dwIndex).
    ; Each entry is GUID(16) + WCHAR[256](512) + isState(4) = 532 bytes; we
    ; only inspect the first connected interface — sufficient for the
    ; common single-radio laptop case.
    Loop nItems {
        pIface := pIfaceList + 8 + (A_Index - 1) * 532
        ; isState lives at offset 16 + 512 = 528. State 1 = connected.
        if (NumGet(pIface, 528, "UInt") != 1) {
            continue
        }
        ; Copy the 16-byte interface GUID for the query call.
        guid := Buffer(16, 0)
        DllCall("RtlMoveMemory", "Ptr", guid, "Ptr", pIface, "UPtr", 16)

        pData     := 0
        cbData    := 0
        valueType := 0
        rc := DllCall("Wlanapi\WlanQueryInterface",
            "Ptr",   hClient,
            "Ptr",   guid,
            "UInt",  WLAN_INTF_OPCODE_CURRENT_CONNECTION,
            "Ptr",   0,
            "UInt*", &cbData,
            "Ptr*",  &pData,
            "UInt*", &valueType,
            "UInt")
        if (rc = ERROR_SUCCESS and pData) {
            ; pData → WLAN_CONNECTION_ATTRIBUTES.
            ; isState(4) + wlanConnectionMode(4) + strProfileName(512)
            ;   = 520 → start of WLAN_ASSOCIATION_ATTRIBUTES.
            ; DOT11_SSID = uSSIDLength(4) + ucSSID(32 bytes).
            ssid_len := NumGet(pData, 520, "UInt")
            if (ssid_len > 0 and ssid_len <= 32) {
                ssid := StrGet(pData + 524, ssid_len, "UTF-8")
                ; wlanSignalQuality offset within WLAN_ASSOCIATION_ATTRIBUTES:
                ;   DOT11_SSID            36 bytes  (uLength 4 + ucSSID 32)
                ;   DOT11_BSS_TYPE         4 bytes
                ;   DOT11_MAC_ADDRESS      6 bytes  (+2 padding to 4-byte align)
                ;   DOT11_PHY_TYPE         4 bytes
                ;   uDot11PhyIndex         4 bytes
                ;   = 56 → assoc base is 520 → 520 + 56 = 576.
                signal_pct := NumGet(pData, 576, "UInt")
                if (signal_pct > 100) {
                    signal_pct := 100
                }
                result["ssid"]       := ssid
                result["signal_pct"] := signal_pct
            }
            DllCall("Wlanapi\WlanFreeMemory", "Ptr", pData)
        }
        if (result.Count > 0) {
            break
        }
    }

    DllCall("Wlanapi\WlanFreeMemory", "Ptr", pIfaceList)
    DllCall("Wlanapi\WlanCloseHandle", "Ptr", hClient, "Ptr", 0)
    return result
}

KL_Net_WifiTick() {
    if !Keylogger.initialized
        return

    info := Map()
    try info := KL_Net_QueryWifi()
    if (info.Count = 0)
        return   ; not on Wi-Fi or API unavailable

    ssid       := info["ssid"]
    signal_pct := info["signal_pct"]

    ; Hash SSID
    ssid_hash := KL_Net_HashStr(ssid)

    ; Signal bracket (signal_pct is 0-100, not dBm, so the brackets here
    ; differ from KLNetConst.RSSI_* which target the netsh dBm output).
    signal := "poor"
    if (signal_pct >= 80)
        signal := "excellent"
    else if (signal_pct >= 60)
        signal := "good"
    else if (signal_pct >= 40)
        signal := "fair"

    if (ssid_hash != KLNet.last_ssid_hash or signal != KLNet.last_signal) {
        meta := Map("ssid_hash", ssid_hash, "signal", signal)
        if (KLNet.last_ssid_hash != "")
            meta["prev_ssid_hash"] := KLNet.last_ssid_hash
        KL_AppendLog(Map(
            "type", "network_change",
            "app",  Keylogger.session_app,
            "ssid_hash", ssid_hash,
            "signal",    signal
        ))
        KLNet.last_ssid_hash := ssid_hash
        KLNet.last_signal    := signal
    }
}





; =============================================
; =============================================
; ======= 4/ Internet reachability poll =======
; =============================================
; =============================================

KL_Net_ReachTick() {
    if !Keylogger.initialized
        return

    ; InternetGetConnectedState is part of wininet.dll and resolves
    ; instantly from the Network List service's cached state — no socket
    ; opened, no DNS lookup, no risk of freezing the AHK thread. The
    ; previous WinHttpRequest.Send(bAsync=false) blocked the entire
    ; script for up to 4 × 3 s on a flaky link, which is unacceptable on
    ; a keyboard driver.
    flags := 0
    up    := false
    try up := !!DllCall("Wininet\InternetGetConnectedState",
        "UInt*", &flags, "UInt", 0, "Int")

    if (up and !KLNet.internet_up) {
        KLNet.internet_up := true
        KL_AppendLog(Map("type", "internet_up", "app", Keylogger.session_app))
    } else if (!up and KLNet.internet_up) {
        KLNet.internet_up := false
        KL_AppendLog(Map("type", "internet_down", "app", Keylogger.session_app))
    }
}





; ==========================================
; ========================================
; ======= 5/ VPN adapter detection =======
; ========================================
; ==========================================

; Walks the Win32 GetAdaptersAddresses linked list looking for an enabled
; adapter whose FriendlyName contains a known VPN substring. Returns the
; adapter's friendly name on hit, "" otherwise.
;
; Why this rather than WMI Win32_NetworkAdapter: ComObjGet("winmgmts:")
; followed by ExecQuery is notoriously slow on cold-start (WMI service
; spinning up: 1-3 s on a typical machine) and synchronous on the AHK
; main thread, so every poll could starve keyboard input. iphlpapi is
; native, in-process, microsecond latency.
;
; IP_ADAPTER_ADDRESSES layout (only the fields we read):
;   ULONG          Length;             // 0  (or 8 on 64-bit due to union)
;   IF_INDEX       IfIndex;            // 4
;   PIP_ADAPTER_ADDRESSES Next;        // 8
;   PCHAR          AdapterName;        // 16
;   ...
;   PWCHAR         FriendlyName;       // offset varies — see below
;   ...
;   IF_OPER_STATUS OperStatus;         // 4 bytes, see PSDK
; The FriendlyName offset depends on alignment / version, so we use the
; documented offset for the v1 base structure on 64-bit Windows: 64.
KL_Net_FindVpnAdapter() {
    static GAA_FLAG_SKIP_UNICAST       := 0x0001
    static GAA_FLAG_SKIP_ANYCAST       := 0x0002
    static GAA_FLAG_SKIP_MULTICAST     := 0x0004
    static GAA_FLAG_SKIP_DNS_SERVER    := 0x0008
    static GAA_FLAG_SKIP_FRIENDLY_NAME := 0x0020
    static AF_UNSPEC                   := 0
    static ERROR_BUFFER_OVERFLOW       := 111
    static IF_OPER_STATUS_UP           := 1

    flags := GAA_FLAG_SKIP_UNICAST | GAA_FLAG_SKIP_ANYCAST
          | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER

    ; Two-call idiom — first call sizes the buffer, second fills it.
    cb := 0
    DllCall("Iphlpapi\GetAdaptersAddresses",
        "UInt", AF_UNSPEC, "UInt", flags, "Ptr", 0,
        "Ptr",  0,         "UInt*", &cb, "UInt")
    if (cb = 0) {
        return ""
    }
    buf := Buffer(cb, 0)
    rc := DllCall("Iphlpapi\GetAdaptersAddresses",
        "UInt", AF_UNSPEC, "UInt", flags, "Ptr", 0,
        "Ptr",  buf,       "UInt*", &cb, "UInt")
    if (rc != 0) {
        return ""
    }

    ; Walk the linked list. ``Next`` lives at offset 8.
    p := buf.Ptr
    while (p) {
        ; Skip adapters that are not currently up. OperStatus is at offset
        ; 56 on 64-bit Windows (after the v1 base header).
        oper_status := NumGet(p, 56, "UInt")
        if (oper_status = IF_OPER_STATUS_UP) {
            ; FriendlyName (PWCHAR) sits at offset 64 on 64-bit Windows.
            pname := NumGet(p, 64, "Ptr")
            if (pname) {
                name       := StrGet(pname, "UTF-16")
                lower_name := StrLower(name)
                for _, hint in KLNetConst.VPN_NAME_HINTS {
                    if InStr(lower_name, hint) {
                        return name
                    }
                }
            }
        }
        p := NumGet(p, 8, "Ptr")
    }
    return ""
}

KL_Net_VpnTick() {
    if !Keylogger.initialized
        return
    found_name := ""
    try found_name := KL_Net_FindVpnAdapter()
    now_active := (found_name != "")
    if (now_active and !KLNet.vpn_active) {
        KLNet.vpn_active       := true
        KLNet.vpn_adapter_name := found_name
        KL_AppendLog(Map(
            "type",    "vpn_connected",
            "app",     Keylogger.session_app,
            "adapter", found_name
        ))
    } else if (!now_active and KLNet.vpn_active) {
        KLNet.vpn_active := false
        KL_AppendLog(Map(
            "type",    "vpn_disconnected",
            "app",     Keylogger.session_app,
            "adapter", KLNet.vpn_adapter_name
        ))
        KLNet.vpn_adapter_name := ""
    }
}





; ======================================
; ======================================
; ======= 6/ Privacy hash helper =======
; ======================================
; ======================================

; Returns a truncated hex SHA-256 of a string (first 16 hex chars = 64 bits).
; Not cryptographic — just enough entropy to distinguish different networks
; without storing the raw SSID.
KL_Net_HashStr(s) {
    try {
        stream := ComObject("ADODB.Stream")
        stream.Open()
        stream.Type := 2   ; text
        stream.WriteText(s)
        stream.Position := 0
        stream.Type := 1   ; binary
        data := stream.Read()
        stream.Close()

        sha := ComObject("System.Security.Cryptography.SHA256Managed")
        hash_bytes := sha.ComputeHash_2(data)
        out := ""
        for b in hash_bytes
            out .= Format("{:02X}", b)
        return SubStr(out, 1, 16)
    }
    ; Fallback: simple DJB2 hash when COM SHA is unavailable
    h := 5381
    loop StrLen(s) {
        h := ((h << 5) + h) + Ord(SubStr(s, A_Index, 1))
        h := h & 0xFFFFFFFF
    }
    return Format("{:08X}", h)
}





; =====================================
; ============================
; ======= 7/ Lifecycle =======
; ============================
; =====================================

KL_Net_Start() {
    if KLNet.HasOwnProp("wifi_fn") && IsObject(KLNet.wifi_fn)
        return
    KLNet.wifi_fn  := KL_Net_WifiTick.Bind()
    KLNet.reach_fn := KL_Net_ReachTick.Bind()
    KLNet.vpn_fn   := KL_Net_VpnTick.Bind()
    ; Stagger initial fires to avoid a simultaneous WMI + netsh + WinHTTP burst
    SetTimer(KLNet.wifi_fn,  -5000)
    SetTimer(KLNet.reach_fn, -8000)
    SetTimer(KLNet.vpn_fn,   -11000)
    SetTimer(KLNet.wifi_fn,  KLNetConst.NETWORK_TICK_MS)
    SetTimer(KLNet.reach_fn, KLNetConst.REACH_TICK_MS)
    SetTimer(KLNet.vpn_fn,   KLNetConst.VPN_TICK_MS)
}

KL_Net_Stop() {
    for prop in ["wifi_fn", "reach_fn", "vpn_fn"] {
        if KLNet.HasOwnProp(prop) && IsObject(KLNet.%prop%) {
            try SetTimer(KLNet.%prop%, 0)
            KLNet.%prop% := unset
        }
    }
    ; Emit vpn_disconnected on clean shutdown so the log is consistent
    if KLNet.vpn_active {
        try KL_AppendLog(Map(
            "type",    "vpn_disconnected",
            "app",     Keylogger.session_app,
            "adapter", KLNet.vpn_adapter_name
        ))
    }
}
