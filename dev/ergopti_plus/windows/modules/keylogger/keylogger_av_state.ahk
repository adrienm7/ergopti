; modules/keylogger/keylogger_av_state.ahk

; ==============================================================================
; MODULE: Keylogger Audio/Video State
; DESCRIPTION:
; Tracks audio volume changes, default audio device switches, and
; screen-recording / sharing activity. Emits discrete events into the
; keylogger pipeline so the metrics dashboard can correlate typing patterns
; with communication context (muted during meetings, screen-sharing while
; explaining code, etc.).
;
; FEATURES & RATIONALE:
; 1. Volume change — polls the system master volume every AVSTATE_TICK_MS.
;    When the level changes by more than VOLUME_DELTA_PCT or the mute state
;    flips, a volume_change event is emitted. This is the most lightweight
;    indicator of meeting activity: users unmute to speak and mute back.
; 2. Audio device change — Windows emits WM_DEVICECHANGE (0x0219) when
;    a device is plugged/unplugged. We additionally poll for the default
;    audio output device name; a change indicates a headset swap (moving
;    from speakers to headphones correlates with calls / focus music).
; 3. Screen recording detection — queries the running process list for
;    known capture / conferencing executables (OBS, Teams presenter mode,
;    Zoom share, etc.) every SLOW_TICK_MS. Emits screen_recording_start
;    and screen_recording_end events when capture software enters or leaves
;    the running process list.
;
; NOTE: Windows Focus Assist (quiet hours) detection was removed. The only
; known local read path (a recursive registry-key walk of the deep CloudStore
; tree) blocks the AHK main thread for ~30 s on some Windows builds,
; reintroducing a keyboard lockup. The feature stays out until a non-blocking
; source (WNF / notification API) is available, rather than shipping inert
; machinery that misleads maintainers (see project rule 5.6).
;
; PRIVACY: All detection is local (no internet, no external DLL). Volume
; queries use the lightweight winmm waveOutGetVolume path via DllCall; process
; scanning uses COM WMI Win32_Process. No audio content is ever sampled.
; ==============================================================================

#Requires Autohotkey v2.0+





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

class KLAVConst {
		; Fast tick for volume polling
		static AVSTATE_TICK_MS      := 1000

		; Slow tick for capture-process scanning
		static SLOW_TICK_MS         := 30000

		; Minimum volume level change (0-100) to log as a volume_change event
		static VOLUME_DELTA_PCT     := 3

		; Known screen-capture / conferencing executables (lower-cased)
		static CAPTURE_EXES := [
				"obs64.exe", "obs32.exe", "obs.exe",
				"zoom.exe", "teams.exe", "teams2.exe",
				"webex.exe", "discord.exe",
				"screenrec.exe", "camtasia.exe",
				"loom.exe", "clipchamp.exe",
				"sharex.exe", "greenshot.exe",
				"win10screenshot.exe"
		]
}

global KL_AV_CAPTURE_STATUS_ACTIVE   := "active"
global KL_AV_CAPTURE_STATUS_INACTIVE := "inactive"
global KL_AV_CAPTURE_STATUS_UNKNOWN  := "unknown"





; ===============================
; ===============================
; ======= 2/ Module state =======
; ===============================
; ===============================

class KLAVState {
		; Volume / mute baseline
		static last_volume      := -1.0
		static last_muted       := -1     ; -1 = unknown, 0 = unmuted, 1 = muted

		; Audio device baseline
		static last_device_name := ""

		; Capture process baseline
		static capture_active   := false
		static capture_exe      := ""
		static capture_snapshot_fn := 0

		; Lifecycle
		static fast_fn          := unset
		static slow_fn          := unset
		static warmup_fn        := unset
}





; =====================================
; =====================================
; ======= 3/ Volume / mute poll =======
; =====================================
; =====================================

KL_AV_FastTick() {
		if !Keylogger.initialized
				return
		if A_IsSuspended
				return
		KL_AV_PollVolume()
}

KL_AV_PollVolume() {
		; Query the system master volume via the lightweight winmm
		; waveOutGetVolume path (see KL_AV_GetMasterVolume) and derive mute
		; heuristically. Falls back gracefully if the API is unavailable (e.g.
		; server SKUs without audio hardware).
		vol   := -1.0
		muted := -1
		try {
				; winmm waveOutGetVolume reads the left-channel master level without
				; the heavier IAudioEndpointVolume COM round-trip; mute is inferred.
				; We query the default
				; multimedia render device.
				vol   := KL_AV_GetMasterVolume()
				muted := KL_AV_GetMasterMuted(vol)
		}
		if (vol < 0)
				return

		vol_pct := Round(vol * 100)

		; Mute state change
		if (KLAVState.last_muted >= 0 and muted != KLAVState.last_muted) {
				KL_AppendLog(Map(
						"type",       "volume_change",
						"app",        Keylogger.session_app,
						"volume_pct", vol_pct,
						"muted",      muted = 1 ? true : false,
						"change",     muted = 1 ? "muted" : "unmuted"
				))
		} else if (KLAVState.last_volume >= 0
								and Abs(vol_pct - Round(KLAVState.last_volume * 100)) >= KLAVConst.VOLUME_DELTA_PCT) {
				; Volume level change without mute toggle
				KL_AppendLog(Map(
						"type",          "volume_change",
						"app",           Keylogger.session_app,
						"volume_pct",    vol_pct,
						"prev_volume_pct", Round(KLAVState.last_volume * 100),
						"muted",         muted = 1 ? true : false,
						"change",        "level"
				))
		}
		KLAVState.last_volume := vol
		KLAVState.last_muted  := muted
}

KL_AV_GetMasterVolume() {
		; Query system master volume via winmm waveOutGetVolume (left channel,
		; 0-65535). Returns a float 0.0-1.0, or -1.0 on failure.
		vol := -1.0
		try {
				buf := Buffer(4, 0)
				if (DllCall("winmm\waveOutGetVolume", "Ptr", 0, "Ptr", buf.Ptr) = 0) {
						raw := NumGet(buf, 0, "UShort")   ; left channel 0-65535
						vol := raw / 65535.0
				}
		}
		return vol
}

KL_AV_GetMasterMuted(vol) {
		; No lightweight native path — use a heuristic based on the volume level
		; rather than invoking the heavier IAudioEndpointVolume COM path.
		; Only literally-zero volume is treated as muted: 0.01 (1%) is audible
		; and must not be misclassified as muted, which would cause false
		; volume_change "muted" events on systems with default low-volume settings
		return (vol <= 0.0) ? 1 : 0
}





; =======================================
; =======================================
; ======= 4/ Capture process scan =======
; =======================================
; =======================================

KL_AV_SlowTick() {
		if !Keylogger.initialized
				return
		if A_IsSuspended
				return
		KL_AV_ScanCapture()
}

KL_AV_ScanCapture() {
		; Use CreateToolhelp32Snapshot instead of WMI — WMI ExecQuery on
		; Win32_Process can block the AHK thread for several seconds, which
		; manifests as a keyboard lockup every SLOW_TICK_MS under sustained typing.
		snapshot_fn := KLAVState.capture_snapshot_fn
		if !HasMethod(snapshot_fn, "Call")
				snapshot_fn := _KL_AV_FindCaptureExeSnapshot
		try sample := snapshot_fn.Call()
		catch as Err {
				try LoggerWarn("KL_AV", "Capture-process probe failed; preserving state: {1}", Err.Message)
				return
		}
		transition := KL_AV_ReduceCaptureSample(
				KLAVState.capture_active, KLAVState.capture_exe, sample)
		if !transition["accepted"] {
				try LoggerWarn("KL_AV", "Capture-process state is unknown; preserving the last accepted state.")
				return
		}
		now_active := transition["next_active"]
		running_exe := transition["next_exe"]
		if transition["changed"] and now_active {
				KLAVState.capture_active := true
				KLAVState.capture_exe    := running_exe
				KL_AppendLog(Map(
						"type", "screen_recording_start",
						"app",  Keylogger.session_app,
						"exe",  running_exe
				))
		} else if transition["changed"] {
				KLAVState.capture_active := false
				KL_AppendLog(Map(
						"type", "screen_recording_end",
						"app",  Keylogger.session_app,
						"exe",  KLAVState.capture_exe
				))
				KLAVState.capture_exe := ""
		}
}


KL_AV_ReduceCaptureSample(previous_active, previous_exe, sample) {
		result := Map(
				"accepted",    false,
				"changed",     false,
				"next_active", previous_active,
				"next_exe",    previous_exe
		)
		if !(sample is Map)
				return result
		status := sample.Get("status", KL_AV_CAPTURE_STATUS_UNKNOWN)
		if (status = KL_AV_CAPTURE_STATUS_UNKNOWN)
				return result
		if (status = KL_AV_CAPTURE_STATUS_INACTIVE) {
				result["accepted"]    := true
				result["changed"]     := previous_active
				result["next_active"] := false
				result["next_exe"]    := ""
				return result
		}
		if (status != KL_AV_CAPTURE_STATUS_ACTIVE)
				return result
		exe := sample.Get("exe", "")
		if !(exe is String) or exe = ""
				return result
		result["accepted"]    := true
		result["changed"]     := !previous_active
		result["next_active"] := true
		result["next_exe"]    := previous_active ? previous_exe : exe
		return result
}

; Enumerate running processes via CreateToolhelp32Snapshot (Win32 API).
; Returns a typed snapshot. Inactive means a complete enumeration found no
; capture process; unknown means the Win32 enumeration failed.
; This replaces the previous WMI ExecQuery path which blocked AHK for
; several seconds on each call.
_KL_AV_FindCaptureExeSnapshot() {
		TH32CS_SNAPPROCESS := 0x2
		snap := DllCall("CreateToolhelp32Snapshot", "UInt", TH32CS_SNAPPROCESS, "UInt", 0, "Ptr")
		if (snap = -1 or snap = 0) {
				return Map("status", KL_AV_CAPTURE_STATUS_UNKNOWN)
		}
		; PROCESSENTRY32W layout on x64: dwSize(0-4)+cntUsage(4-8)+th32ProcessID(8-12)+
		; [4-byte pad](12-16)+th32DefaultHeapID(16-24)+th32ModuleID(24-28)+cntThreads(28-32)+
		; th32ParentProcessID(32-36)+pcPriClassBase(36-40)+dwFlags(40-44)+
		; szExeFile[260]*2=520 bytes(44-564) rounded up to 568 for 8-byte alignment.
		; Windows validates dwSize and returns ERROR_BAD_LENGTH (24) on mismatch — the
		; old value of 560 skipped the 8-byte alignment tail, permanently breaking detection.
		PE32_SIZE := 568   ; sizeof(PROCESSENTRY32W) on x64 — 520-byte szExeFile + fields + 8-byte alignment padding
		entry := Buffer(PE32_SIZE, 0)
		NumPut("UInt", PE32_SIZE, entry, 0)   ; dwSize must be set before Process32FirstW
		try {
				if !DllCall("Process32FirstW", "Ptr", snap, "Ptr", entry) {
						try LoggerWarn("KL_AV", "Process32FirstW failed (A_LastError={1}) — capture detection skipped.", A_LastError)
						return Map("status", KL_AV_CAPTURE_STATUS_UNKNOWN)
				}
				; AHK v2 has no break N — use a flag to exit the outer loop.
				loop {
						; szExeFile starts at offset 44, MAX_PATH wchars
						exe_name := StrLower(StrGet(entry.Ptr + 44, 260, "UTF-16"))
						for _, cap_exe in KLAVConst.CAPTURE_EXES {
								if (exe_name = cap_exe) {
										return Map(
												"status", KL_AV_CAPTURE_STATUS_ACTIVE,
												"exe",    exe_name)
								}
						}
						if !DllCall("Process32NextW", "Ptr", snap, "Ptr", entry) {
								if (A_LastError != 18) {
										try LoggerWarn("KL_AV", "Process32NextW failed (A_LastError={1}) — capture detection skipped.", A_LastError)
										return Map("status", KL_AV_CAPTURE_STATUS_UNKNOWN)
								}
								return Map("status", KL_AV_CAPTURE_STATUS_INACTIVE)
						}
				}
		} catch as Err {
				try LoggerWarn("KL_AV", "Capture process enumeration failed: {1}", Err.Message)
				return Map("status", KL_AV_CAPTURE_STATUS_UNKNOWN)
		} finally {
				DllCall("CloseHandle", "Ptr", snap)
		}
}





; ============================
; ============================
; ======= 5/ Lifecycle =======
; ============================
; ============================

KL_AV_Start(TimerFn := SetTimer) {
		; Warm-up one-shot routes through the GUARDED tick KL_AV_FastTick (which checks
		; Keylogger.initialized + A_IsSuspended) via its own stored Bind() reference, so it
		; (a) is cancellable by KL_AV_Stop and (b) cannot poll volume after Stop or under
		; pause — matching the KLNet/KLSensors warm-up pattern (av-warmup-cancellable). A
		; distinct Bind() avoids clobbering the recurring fast_fn timer (AHK replaces a timer
		; only when the SAME function reference is passed twice).
		return KL_TimerGroupStart(KLAVState, [
				Map("property", "warmup_fn", "callback", KL_AV_FastTick.Bind(),
						"period", -3000),
				Map("property", "fast_fn", "callback", KL_AV_FastTick.Bind(),
						"period", KLAVConst.AVSTATE_TICK_MS),
				Map("property", "slow_fn", "callback", KL_AV_SlowTick.Bind(),
						"period", KLAVConst.SLOW_TICK_MS)
		], TimerFn, "audio-video state")
}

KL_AV_Stop(TimerFn := SetTimer) {
		TimersStopped := KL_TimerGroupStop(KLAVState,
				["warmup_fn", "fast_fn", "slow_fn"], TimerFn,
				"audio-video state")
		; Close any open screen_recording_start with a matching end
		if KLAVState.capture_active {
				try KL_AppendLog(Map(
						"type", "screen_recording_end",
						"app",  Keylogger.session_app,
						"exe",  KLAVState.capture_exe
				))
		}
		return TimersStopped
}
