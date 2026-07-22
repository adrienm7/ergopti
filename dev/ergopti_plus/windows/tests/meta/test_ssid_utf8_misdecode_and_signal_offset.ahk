; tests/meta/test_ssid_utf8_misdecode_and_signal_offset.ahk

; ==============================================================================
; MODULE: NetworkInfo SSID Octet-Hash + Signal Bounds Meta Test
; DESCRIPTION:
; Static source guard for finding ssid-utf8-misdecode-and-signal-offset-fragility.
;
; 802.11 SSIDs are opaque octet strings. The original _NI_QueryWlan() decoded
; ucSSID as UTF-8 (StrGet(pData + 524, ssid_len, "UTF-8")) before hashing, which
; mojibakes non-UTF-8 access points and yields an unstable per-network hash.
; The fix serialises the raw octets via _NI_SsidOctetsToHashInput() so the digest
; is a deterministic function of the true network identifier regardless of byte
; encoding. The fix also bounds-checks cbData against the minimum size that can
; hold the signal-quality field at +576 before reading it.
;
; This is a meta-static test (scans source text) because adapters/network_info.ahk
; is NOT part of the headless runner include graph (run_all.ahk does not include
; it - its DllCall paths target live wlanapi/iphlpapi hardware). Calling its
; functions from a test would be a load-time error that hangs the suite, so the
; regression is encoded as a source guard instead.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

; Reads a windows/-relative source file. A_ScriptDir is the runner dir (tests/);
; its parent is the windows/ driver root.
_SsidHash_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}




; ==================================================
; ==================================================
; ======= 2/ Octet-hash + bounds assertions ========
; ==================================================
; ==================================================

_SsidHash_HashesRawOctetsNotUtf8() {
	Src := _SsidHash_ReadSource("adapters/network_info.ahk")
	Seg := _DriverFuncBody("_NI_QueryWlan")
	Assert(Seg != "", "_NI_QueryWlan() declaration must exist in network_info.ahk")
	Assert(InStr(Seg, "_NI_SsidOctetsToHashInput(") > 0,
		"_NI_QueryWlan must build its hash input from the raw SSID octets via _NI_SsidOctetsToHashInput - UTF-8 decoding mojibakes non-UTF-8 SSIDs and yields an unstable hash")
	Assert(InStr(Seg, Chr(34) . "UTF-8" . Chr(34)) = 0,
		"_NI_QueryWlan must NOT UTF-8-decode the SSID octets before hashing - that re-introduces the unstable-hash regression")
}
Test("NetworkInfo: SSID hashed from raw octets, not UTF-8 decode (ssid-utf8-misdecode-and-signal-offset-fragility)", _SsidHash_HashesRawOctetsNotUtf8)

_SsidHash_HasSignalSizeBoundsGuard() {
	Src := _SsidHash_ReadSource("adapters/network_info.ahk")
	Seg := _DriverFuncBody("_NI_QueryWlan")
	Assert(InStr(Seg, "NI_WLAN_MIN_CONN_ATTR_SIZE") > 0,
		"_NI_QueryWlan must bound-check cbData against NI_WLAN_MIN_CONN_ATTR_SIZE before reading the signal-quality field at +576 (a truncated buffer would NumGet past the allocation)")
}
Test("NetworkInfo: _NI_QueryWlan bounds-checks cbData before signal read (ssid-utf8-misdecode-and-signal-offset-fragility)", _SsidHash_HasSignalSizeBoundsGuard)

_SsidHash_OctetHelperSerialisesBytes() {
	Src := _SsidHash_ReadSource("adapters/network_info.ahk")
	Seg := _DriverFuncBody("_NI_SsidOctetsToHashInput")
	Assert(Seg != "", "_NI_SsidOctetsToHashInput(pBytes, len) helper must exist in network_info.ahk")
	Assert(InStr(Seg, "UChar") > 0,
		"_NI_SsidOctetsToHashInput must read individual octets as UChar so the hash input is a byte-exact, encoding-independent serialisation")
}
Test("NetworkInfo: octet-to-hash helper serialises raw bytes (ssid-utf8-misdecode-and-signal-offset-fragility)", _SsidHash_OctetHelperSerialisesBytes)
