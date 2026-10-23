; tests/meta/modules/keystats/context/test_av_mute_heuristic.ahk

; ==============================================================================
; MODULE: AV Mute Heuristic Meta Test
; DESCRIPTION:
; Static source guard for the "av-mute-heuristic-and-doc-mismatch" finding.
; ==============================================================================

#Requires AutoHotkey v2.0

_TAV_Check() {
	; Move-resilient: scan the keystats module tree (comments preserved — one
	; assertion targets the "heuristic" doc string) instead of a pinned path.
	; The unique KL_AV_GetMasterMuted(vol) signature keeps the scope meaningful.
	Src := _DriverDirConcat("modules/keystats")
	Assert(InStr(Src, "KL_AV_GetMasterMuted(vol)") > 0, "keystats_av_state.ahk must take vol parameter")
	Assert(InStr(Src, "heuristic") > 0, "keystats_av_state.ahk must document the heuristic")
}

Test("Keystats: AV mute uses heuristic without double-call", _TAV_Check)

; av-mute-heuristic-and-doc-mismatch: the volume probe uses winmm waveOutGetVolume.
_ATG_AvVolumeUsesWinmm() {
	; Scoped to the keystats module tree: the winmm-vs-COM invariant is specific
	; to keystats_av_state, and other modules may legitimately use COM, so a
	; whole-tree scan would false-trip the CoCreateInstance absence check.
	Src := _StripFullLineComments(_DriverDirConcat("modules/keystats"))
	Assert(InStr(Src, "waveOutGetVolume") > 0,
		"the volume probe must read winmm waveOutGetVolume — the documented MMDevice/IAudioEndpointVolume COM path was never the implementation (av-mute-heuristic-and-doc-mismatch)")
	Assert(InStr(Src, "CoCreateInstance") = 0,
		"keystats_av_state must not claim a CoCreateInstance COM path in live code — the impl is the lightweight winmm probe (av-mute-heuristic-and-doc-mismatch)")
}
Test("keystats_av: master-volume probe uses the winmm path, code matches docs (av-mute-heuristic-and-doc-mismatch)", _ATG_AvVolumeUsesWinmm)
