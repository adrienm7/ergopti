; modules/keylogger/keylogger_network.ahk
; Requires: NetworkInfo, Crypto

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

KL_Net_WifiTick() {
    if !Keylogger.initialized
        return
    if A_IsSuspended
        return

    ; Wrap the entire poll in try so a transient WLAN API failure (unavailable
    ; adapter, mid-suspend state) never surfaces as an uncaught error that would
    ; cascade into PrefixWatcher and other per-keystroke callbacks.
    try {
        ; Delegate to the NetworkInfo adapter — no DllCall plumbing in this module
        ssid_hash  := NI_GetSsidHash()
        signal_pct := NI_GetSignalStrength()

        ; NI_GetSsidHash() returns "" when no Wi-Fi is connected
        if (ssid_hash = "")
            return

        ; signal_pct is 0-100 from the WLAN API signal quality field
        signal := "poor"
        if (signal_pct >= 80)
            signal := "excellent"
        else if (signal_pct >= 60)
            signal := "good"
        else if (signal_pct >= 40)
            signal := "fair"

        if (ssid_hash != KLNet.last_ssid_hash or signal != KLNet.last_signal) {
            entry := Map(
                "type",      "network_change",
                "app",       Keylogger.session_app,
                "ssid_hash", ssid_hash,
                "signal",    signal
            )
            if (KLNet.last_ssid_hash != "")
                entry["prev_ssid_hash"] := KLNet.last_ssid_hash
            KL_AppendLog(entry)
            KLNet.last_ssid_hash := ssid_hash
            KLNet.last_signal    := signal
        }
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
    if A_IsSuspended
        return

    ; Delegate to the NetworkInfo adapter — reads cached OS state, no socket.
    up := false
    try up := NI_IsInternetReachable()

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

KL_Net_VpnTick() {
    if !Keylogger.initialized
        return
    if A_IsSuspended
        return
    ; Delegate to the NetworkInfo adapter — returns true when a VPN adapter is up.
    ; The adapter name is not exposed by the port contract; we use a stable
    ; sentinel so the log field is always present and non-empty.
    now_active := false
    try now_active := NI_IsVpnActive()
    found_name := now_active ? "vpn" : ""
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
    ; Stagger initial fires to avoid a simultaneous WMI + netsh + WinHTTP burst.
    ; Starters are named global functions (not arrow lambdas) because AHK v2
    ; parses (f(), g()) as calling f with g() as an argument, not as a comma
    ; sequence — causing KL_Net_VpnTick to receive an unexpected parameter.
    ; Stored as BoundFuncs in KLNet so KL_Net_Stop() can cancel them by reference.
    KLNet.wifi_start_fn  := KL_Net_WifiStarter.Bind()
    KLNet.reach_start_fn := KL_Net_ReachStarter.Bind()
    KLNet.vpn_start_fn   := KL_Net_VpnStarter.Bind()
    SetTimer(KLNet.wifi_start_fn,  -5000)
    SetTimer(KLNet.reach_start_fn, -8000)
    SetTimer(KLNet.vpn_start_fn,   -11000)
}

; One-shot starter functions for KL_Net_Start() — fire the tick once then arm
; the repeating timer. Named functions avoid the AHK v2 comma-expression parsing
; ambiguity that would make (f(), g()) pass g() as an argument to f.
; The BoundFunc is copied to a local variable before calling: calling
; KLNet.xxx_fn() directly treats it as a class method and passes KLNet as an
; implicit first argument, which makes the zero-param tick functions throw
; "too many parameters".
KL_Net_WifiStarter() {
    fn := KLNet.wifi_fn
    fn()
    SetTimer(KLNet.wifi_fn, KLNetConst.NETWORK_TICK_MS)
}
KL_Net_ReachStarter() {
    fn := KLNet.reach_fn
    fn()
    SetTimer(KLNet.reach_fn, KLNetConst.REACH_TICK_MS)
}
KL_Net_VpnStarter() {
    fn := KLNet.vpn_fn
    fn()
    SetTimer(KLNet.vpn_fn, KLNetConst.VPN_TICK_MS)
}

KL_Net_Stop() {
    for prop in ["wifi_start_fn", "reach_start_fn", "vpn_start_fn", "wifi_fn", "reach_fn", "vpn_fn"] {
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
