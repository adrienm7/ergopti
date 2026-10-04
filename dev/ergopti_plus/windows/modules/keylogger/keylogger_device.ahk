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

; The first three GUID fields are native integers; Data4 retains byte order.
; @param CreateGuidFn Optional callable that fills the native 16-byte GUID.
; @returns {String} Lowercase canonical GUID text for a new device identity.
KL_UuidV4(CreateGuidFn := unset) {
		; CoCreateGuid via DllCall, formatted RFC 4122.
		guid_buf := Buffer(16, 0)
		Result := IsSet(CreateGuidFn)
				? CreateGuidFn.Call(guid_buf)
				: DllCall("ole32\CoCreateGuid", "Ptr", guid_buf, "Int")
		if !(Result is Integer)
				throw TypeError("GUID creation must return an integer HRESULT.")
		if Result != 0
				throw Error("GUID creation failed (HRESULT " . Format("0x{:08X}", Result & 0xFFFFFFFF) . ").")
		bytes := []
		Loop 16
				bytes.Push(NumGet(guid_buf, A_Index - 1, "UChar"))
		return Format("{:08x}-{:04x}-{:04x}-{:04x}-{:012x}",
				NumGet(guid_buf, 0, "UInt"),
				NumGet(guid_buf, 4, "UShort"),
				NumGet(guid_buf, 6, "UShort"),
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

; Metrics store directory of a configuration folder. The single rule shared by
; boot (KL_Init), the metrics menu, the dashboards and the onboarding consent
; text, so the folder the user consents to is the folder keystrokes go to.
; @param ConfigDir string Configuration folder, trailing separator optional.
; @return string <ConfigDir>\metrics
KL_MetricsDirFor(ConfigDir) {
		if !(ConfigDir is String) || ConfigDir == ""
				throw ValueError("KL_MetricsDirFor requires a configuration folder.")
		if !(ConfigDir ~= "[/\\]$")
				ConfigDir .= "\"
		return ConfigDir . "metrics"
}

/**
 * Recovers one proven local identity after checking the complete device history.
 * @param {String} metrics_dir Metrics root whose device children are scanned.
 * @param HostSignatureFn Optional host-signature callable for isolated fixtures.
 * @param CreateGuidFn Optional native GUID buffer producer for isolated fixtures.
 * @returns {Map} The complete decoded identity, or a newly generated identity.
 * @throws {Error} An uncertain candidate or ambiguous local history refuses boot.
 */
KL_ResolveDevice(metrics_dir, HostSignatureFn := unset, CreateGuidFn := unset) {
		md := metrics_dir
		if !RegExMatch(md, "[\\/]$")
				md .= "\"
		by_root := md . "by_device\"
		FSEnsureDirectoryStrict(by_root)
		current_host := IsSet(HostSignatureFn) ? HostSignatureFn.Call() : KL_HostSignature()
		if !(current_host is String) or current_host == ""
				throw Error("Device recovery requires a non-empty host signature.", -1, by_root)

		; An incomplete child may still own a journal. Never mint a replacement
		; from uncertain history, and never let directory order hide corruption.
		matching := 0
		for DeviceDir in FSListDirectoryStrict(by_root, true) {
				djpath := DeviceDir . "\device.json"
				SplitPath(DeviceDir, &DeviceFolder)
				try raw := FileRead(djpath, "UTF-8")
				catch as Failure
						throw Error("Cannot read device identity: " . Failure.Message, -1, djpath)
				try obj := JsonParse(raw)
				catch as Failure
						throw Error("Cannot decode device identity: " . Failure.Message, -1, djpath)
				if !(obj is Map) or !obj.Has("host_signature")
						or !(obj["host_signature"] is String) or obj["host_signature"] == ""
						throw Error("Device identity requires a non-empty top-level host signature.", -1, djpath)
				; Foreign hosts do not grant authority over their unrelated metadata.
				if obj["host_signature"] != current_host
						continue
				if !obj.Has("device_id") or !(obj["device_id"] is String)
						or !RegExMatch(obj["device_id"], "i)\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z")
						throw Error("Local device identity requires a safe GUID.", -1, djpath)
				if obj["device_id"] != DeviceFolder
						throw Error("Local device identity does not match its directory.", -1, djpath)
				if IsObject(matching)
						throw Error("Multiple device identities match this host.", -1, djpath)
				matching := obj
		}
		if IsObject(matching)
				return matching

		return Map(
				"device_id", KL_UuidV4(CreateGuidFn?),
				"name", A_ComputerName,
				"os", "windows",
				"os_version", A_OSVersion,
				"host_signature", current_host,
				"created_at", KL_NowTimestamp(),
				"schema_version", KeylogConst.SCHEMA_VERSION
		)
}

KL_WriteDeviceJson(obj) {
		KL_WriteAtomic(Keylogger.device_json_path, KL_JsonEncode(obj))
}
