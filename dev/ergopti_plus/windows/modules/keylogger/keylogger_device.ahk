; modules/keylogger/keylogger_device.ahk

; ==============================================================================
; MODULE: Keylogger - Device Identity
; DESCRIPTION:
; Stable per-OS host signature, UUIDv4 generation, device resolution and the device.json writer. Mirrors the macOS keylogger device factoring.
;
; Extracted from keylogger.ahk (audit F1) and #Include'd in place by it. Pure
; definitions only - AHK resolves these symbols across the whole compilation
; unit, so the include position does not affect behaviour.
; ==============================================================================

KL_HostSignature() {
		; Use HKLM\SOFTWARE\Microsoft\Cryptography\MachineGuid — stable per OS
		; install, mirrors the macOS IOPlatformUUID role.
		guid := Reg_Read("HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Cryptography", "MachineGuid", "")
		if (guid != "")
				return guid
		return "fallback:" . A_ComputerName
}

KL_UuidV4() {
		; CoCreateGuid via DllCall, formatted RFC 4122.
		guid_buf := Buffer(16, 0)
		DllCall("ole32\CoCreateGuid", "Ptr", guid_buf)
		bytes := []
		Loop 16
				bytes.Push(NumGet(guid_buf, A_Index - 1, "UChar"))
		return Format("{:08x}-{:04x}-{:04x}-{:04x}-{:012x}",
				(bytes[1] << 24) | (bytes[2] << 16) | (bytes[3] << 8) | bytes[4],
				(bytes[5] << 8) | bytes[6],
				(bytes[7] << 8) | bytes[8],
				(bytes[9] << 8) | bytes[10],
				(bytes[11] << 40) | (bytes[12] << 32) | (bytes[13] << 24) | (bytes[14] << 16) | (bytes[15] << 8) | bytes[16])
}

KL_NowTimestamp() {
		; "YYYY-MM-DD HH:MM:SS.mmm"
		return WallClockTimestamp(".")
}

KL_Today() {
		return FormatTime(A_Now, "yyyy-MM-dd")
}

KL_ResolveDevice(metrics_dir) {
		md := metrics_dir
		if !RegExMatch(md, "[\\/]$")
				md .= "\"
		by_root := md . "by_device\"
		KL_MkdirP(by_root)

		current_host := KL_HostSignature()

		; Scan existing device folders, reuse the one whose host_signature
		; matches this machine.
		;
		; We use a regex over the raw bytes rather than a full JSON parse —
		; AHK v2 64-bit has no built-in JSON decoder and the COM
		; ScriptControl bridge we used initially is x86-only, which made
		; this scan silently fail on 64-bit hosts and mint a new device
		; folder on every reload. The shape of device.json is fixed (we
		; write it ourselves), so a targeted regex is both faster and
		; impervious to the bitness mismatch.
		if DirExist(by_root) {
				Loop Files, by_root . "*", "D" {
						djpath := A_LoopFileFullPath . "\device.json"
						if FileExist(djpath) {
								try {
										raw := FileRead(djpath, "UTF-8")
										if RegExMatch(raw, '"host_signature"\s*:\s*"([^"]+)"', &m) {
												if (m[1] = current_host) {
														; Reconstruct the minimal Map we need from
														; the same raw blob — same regex trick.
														obj := Map(
																"device_id",      "",
																"name",           "",
																"os",             "windows",
																"os_version",     "",
																"host_signature", current_host,
																"created_at",     "",
																"schema_version", KeylogConst.SCHEMA_VERSION
														)
														for _, field in ["device_id", "name", "os", "os_version", "created_at"] {
																if RegExMatch(raw, '"' . field . '"\s*:\s*"([^"]+)"', &mm)
																		obj[field] := mm[1]
														}
														return obj
												}
										}
								}
						}
				}
		}

		; Fresh install or clone-from-other-device → mint a new identity.
		obj := Map(
				"device_id",      KL_UuidV4(),
				"name",           A_ComputerName,
				"os",             "windows",
				"os_version",     A_OSVersion,
				"host_signature", current_host,
				"created_at",     KL_NowTimestamp(),
				"schema_version", KeylogConst.SCHEMA_VERSION
		)
		return obj
}

KL_WriteDeviceJson(obj) {
		KL_WriteAtomic(Keylogger.device_json_path, KL_JsonEncode(obj))
}
