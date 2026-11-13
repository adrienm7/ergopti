; adapters/registry_notify.ahk

; ==============================================================================
; MODULE: Registry Change Notification Adapter (AutoHotkey)
; DESCRIPTION:
; The native half of a registry watch: a key opened for notification only, an
; auto-reset event, RegNotifyChangeKeyValue arming that event for the key and
; its subtree, a zero-timeout signal query, and the closing of both handles.
; modules/keymap/layout_registry_watch.ahk owns the policy around them.
;
; FEATURES & RATIONALE:
; 1. KEY_NOTIFY is the only right a notification needs, so the watch can never
;    read or write the values it watches.
; 2. The events are unnamed and created without security attributes, so no
;    child process inherits them.
; 3. Fail fast: every Win32 failure throws an OSError with its status and the
;    call that refused.
; ==============================================================================

#Requires AutoHotkey v2.0

; KEY_NOTIFY: the only right RegNotifyChangeKeyValue needs.
global REGISTRY_NOTIFY_KEY_NOTIFY := 0x0010

; Opens a key for change notification only.
; @param Root {Integer} A predefined key, sign-extended.
; @param SubKey {String} The key under Root.
; @returns {Integer} The key handle.
; @throws {OSError} When Windows refuses the key.
RegistryNotifyOpenKey(Root, SubKey) {
	global REGISTRY_NOTIFY_KEY_NOTIFY
	Handle := 0
	Status := DllCall("Advapi32\RegOpenKeyExW", "Ptr", Root, "WStr", SubKey, "UInt", 0,
		"UInt", REGISTRY_NOTIFY_KEY_NOTIFY, "Ptr*", &Handle, "UInt")
	if (Status != 0)
		throw OSError(Status, -1, "RegOpenKeyExW " . SubKey)
	return Handle
}

; An auto-reset event, unnamed and not inheritable (no security attributes).
; @returns {Integer} The event handle.
; @throws {OSError} When Windows cannot create it.
RegistryNotifyCreateEvent() {
	Handle := DllCall("CreateEventW", "Ptr", 0, "Int", false, "Int", false, "Ptr", 0, "Ptr")
	if !Handle
		throw OSError(A_LastError, -1, "CreateEventW")
	return Handle
}

; Asynchronous: returns at once and signals Event at the next change of the
; key or its subtree. The notification belongs to the calling (the only) thread.
; @param Handle {Integer} RegistryNotifyOpenKey's handle.
; @param Event {Integer} RegistryNotifyCreateEvent's handle.
; @param Filter {Integer} REG_NOTIFY_CHANGE_* flags.
; @throws {OSError} When Windows refuses the notification.
RegistryNotifyArm(Handle, Event, Filter) {
	Status := DllCall("Advapi32\RegNotifyChangeKeyValue", "Ptr", Handle, "Int", true,
		"UInt", Filter, "Ptr", Event, "Int", true, "UInt")
	if (Status != 0)
		throw OSError(Status, -1, "RegNotifyChangeKeyValue")
}

; Whether Event is signaled; a true answer resets the auto-reset event. The
; wait results are PLC_WAIT_OBJECT_0 / PLC_WAIT_TIMEOUT (../core/process/adapters/lifecycle.ahk).
; @param Event {Integer} RegistryNotifyCreateEvent's handle.
; @returns {Boolean}
; @throws {OSError} When the wait fails.
RegistryNotifySignaled(Event) {
	global PLC_WAIT_OBJECT_0, PLC_WAIT_TIMEOUT
	Result := DllCall("WaitForSingleObject", "Ptr", Event, "UInt", 0, "UInt")
	if (Result == PLC_WAIT_OBJECT_0)
		return true
	if (Result == PLC_WAIT_TIMEOUT)
		return false
	throw OSError(A_LastError, -1, "WaitForSingleObject")
}

; Closes a key, which ends its notification.
; @throws {OSError} When Windows refuses.
RegistryNotifyCloseKey(Handle) {
	Status := DllCall("Advapi32\RegCloseKey", "Ptr", Handle, "UInt")
	if (Status != 0)
		throw OSError(Status, -1, "RegCloseKey")
}

; Closes an event.
; @throws {OSError} When Windows refuses.
RegistryNotifyCloseEvent(Handle) {
	if !DllCall("CloseHandle", "Ptr", Handle)
		throw OSError(A_LastError, -1, "CloseHandle")
}
