; tests/unit/ui/physical_shortcuts/test_physical_shortcut_host.ahk

; ==============================================================================
; MODULE: Physical Shortcut Host (Windows)
; DESCRIPTION:
; The Windows twin of the Linux and macOS real-chain tests
; (test_physical_delivery_available.lua): the production
; PhysicalShortcutDeliveryAvailable answers false (maintainer decision of
; 2026-11-11), so the real host and the shared menu port keep the editor
; closed even with the GUI ready, capture no scope, tell the refusal once, and
; the manifest row greys with physical_shortcuts.delivery_unqualified. The
; editor protocol and the key-position capture are driven through their ports.
; ==============================================================================




; ==========================================
; ==========================================
; ======= 1/ Helpers =======================
; ==========================================
; ==========================================

; Runs Body with the real host over a stubbed GUI readiness, restoring it.
_PSH_WithGui(Ready, Body) {
	Saved := PhysicalShortcutsHost.NativeProbe
	PhysicalShortcutsHost.NativeProbe := () => Ready
	try Body.Call()
	finally PhysicalShortcutsHost.NativeProbe := Saved
}

; The shared menu port over the real host, counting captures and refusals.
_PSH_Menu(Paused, Counts) {
	Counts["captured"] := 0, Counts["refused"] := 0
	return PhysicalEditorMenu(Map(
		"host", () => PhysicalShortcutsHost,
		"scope", () => (Counts["captured"] += 1, PhysicalShortcutsScope(Map("read", _PSH_NoRead))),
		"paused", () => Paused,
		"refused", () => Counts["refused"] += 1))
}

_PSH_NoRead(*) {
	throw Error("No scope may read the configuration while delivery is refused.")
}

_PSH_Model() {
	return PhysicalSlots.Load()
}




; ==========================================
; ==========================================
; ======= 2/ The real chain refuses ========
; ==========================================
; ==========================================

Test("physical shortcuts: the production delivery getter answers false (physical-delivery-unqualified)", () => (
	AssertFalse(PhysicalShortcutDeliveryAvailable(), "the production getter"),
	AssertFalse(PhysicalShortcutsHost.PhysicalDeliveryAvailable(), "the host reads the production getter"),
	AssertFalse(PhysicalShortcutsScope(Map("model", _PSH_Model())).PhysicalDeliveryAvailable(),
		"the scope reads the production getter")
))

Test("physical shortcuts: GUI ready, the real host and menu port keep the editor closed (physical-delivery-unqualified)", () =>
	_PSH_WithGui(true, () => (
		Counts := Map(),
		Menu := _PSH_Menu(0, Counts),
		AssertTrue(PhysicalShortcutsHost.NativeAvailable(), "the GUI is ready"),
		AssertFalse(Menu.Ready(), "the editor row is not ready"),
		AssertFalse(Menu.Open(), "the editor stays closed"),
		AssertEqual(0, Counts["captured"], "no scope is captured"),
		AssertEqual(1, Counts["refused"], "the refusal is told once"),
		AssertFalse(IsObject(PhysicalShortcutsHost.Current), "no window was built")
	)))

Test("physical shortcuts: a paused script or a GUI not ready also refuse (physical-delivery-unqualified)", () => (
	_PSH_WithGui(true, () => (
		Counts := Map(),
		Menu := _PSH_Menu(1, Counts),
		AssertFalse(Menu.Ready()),
		AssertFalse(Menu.Open()),
		AssertEqual(0, Counts["captured"], "paused: no scope is captured")
	)),
	_PSH_WithGui(false, () => (
		Counts := Map(),
		Menu := _PSH_Menu(0, Counts),
		AssertFalse(Menu.Ready()),
		AssertFalse(Menu.Open()),
		AssertEqual(0, Counts["captured"], "no GUI: no scope is captured"),
		AssertEqual(1, Counts["refused"])
	))
))

Test("physical shortcuts: the manifest row greys with the unqualified delivery (physical-delivery-unqualified)", () =>
	_PSH_WithGui(true, () => (
		Counts := Map(),
		Menu := _PSH_Menu(0, Counts),
		Getters := PhysicalShortcutsMenuGetters(Menu),
		AssertFalse(Getters["physical_shortcuts_editor_ready"].Call()),
		AssertTrue(Getters["physical_shortcuts_delivery_unqualified"].Call()),
		Row := MenuRenderer_CommandRow("shortcuts_menu", "physical_shortcuts_editor",
			Map(MenuCommand.PHYSICAL_SHORTCUTS_EDITOR, ObjBindMethod(Menu, "Open")), Getters),
		AssertTrue((Row is Map) && Row.Get("disabled", false), "the row is greyed on Windows"),
		AssertEqual("physical_shortcuts.delivery_unqualified", Row.Get("disabled_reason_key", ""),
			"the row names the unqualified delivery")
	)))

Test("physical shortcuts: a mapping edit is refused before any source read or write (physical-delivery-unqualified)", () => (
	Published := 0,
	Scope := PhysicalShortcutsScope(Map("model", _PSH_Model(), "path", "C:\unused\config.toml",
		"read", _PSH_NoRead, "publish", (*) => (Published += 1, true))),
	Answer := Scope.Edit([{ Section: ConfigKey.SHORTCUTS_KEYBOARD, Key: "physical_ctrl_KeyA", Value: "copy" }], {}),
	AssertEqual(0, Answer["committed"]),
	AssertEqual("unavailable", Answer["reason"]),
	AssertEqual(0, Published, "nothing is published")
))

Test("physical shortcuts: delivery answered true still needs a Windows collision owner (physical-delivery-unqualified)", () => (
	Scope := PhysicalShortcutsScope(Map("model", _PSH_Model(), "path", "C:\unused\config.toml",
		"read", _PSH_NoRead, "delivery", () => true, "publish", (*) => true)),
	Answer := Scope.Edit([{ Section: ConfigKey.SHORTCUTS_KEYBOARD, Key: "physical_ctrl_KeyA", Value: "copy" }], {}),
	AssertEqual("unavailable", Answer["reason"], "no collision owner: refused")
))




; ==========================================
; ==========================================
; ======= 3/ Slots and the editor ==========
; ==========================================
; ==========================================

Test("physical shortcuts: slots encode, parse and resolve the Windows scan code (physical-slots-windows)", () => (
	Model := _PSH_Model(),
	AssertEqual("physical_ctrl_shift_KeyA", Model.Encode("KeyA", Map("shift", 1, "ctrl", 1))),
	AssertEqual("physical_none_KeyA", Model.Encode("KeyA")),
	AssertEqual("", Model.Encode("ShiftLeft"), "a modifier position is never a slot"),
	AssertEqual("KeyA", Model.Parse("physical_ctrl_KeyA")["code"]),
	AssertFalse(Model.Owns("physical_shift_ctrl_KeyA"), "a noncanonical spelling is refused"),
	AssertEqual("KeyA", Model.CodeFor("SC01E")),
	AssertEqual("", Model.CodeFor("SC2A0"), "an unknown scan code names no position")
))

; A fake page and source around the real protocol.
_PSH_Window(Sent, Assignments) {
	Model := _PSH_Model()
	Receipt := {}
	return PhysicalEditorWindow(Map(
		"model", Model, "actions", PhysicalEntriesActions(),
		"positions", [Map("code", "KeyA", "available", PHYSICAL_JSON_TRUE)],
		"page_current", () => true, "translate", (Key) => Key,
		"send", (Name, Packet) => (Sent.Push(Name . "(" . PhysicalJsonEncode(Packet) . ")"), true),
		"close", () => true,
		"capture", () => Map("inventory", Map("assignments", Assignments, "parameters", Map()), "receipt", Receipt),
		"current", (Seen) => Seen == Receipt,
		"commit", (*) => Map("committed", true),
		"label", (Action) => "label:" . Action,
		"picker", (*) => true,
		"position_available", () => true,
		"capture_position", (Guard, Receive) => (Sent.Push(Receive), {}),
		"cancel_position", (*) => true))
}

Test("physical shortcuts: the init packet names keys and carries no id (physical-editor-windows)", () => (
	Sent := [],
	Window := _PSH_Window(Sent, Map("physical_ctrl_KeyA", "copy")),
	AssertTrue(Window.Receive(Map("action", "ready"))),
	AssertEqual(1, Sent.Length),
	AssertContains(Sent[1], '"slot":"physical_ctrl_KeyA"'),
	AssertContains(Sent[1], '"ctrl":true'),
	AssertContains(Sent[1], '"KeyA":"A"', "the position is named from the key name table"),
	AssertContains(Sent[1], '"capture":true'),
	AssertFalse(Window.Receive(Map("action", "ready")), "init is sent once"),
	AssertFalse(Window.Receive(Map("action", "save", "token", 1, "extra", 1)), "an open field set is refused")
))

Test("physical shortcuts: a captured scan code fills the draft with its position (physical-editor-windows)", () => (
	Sent := [],
	Window := _PSH_Window(Sent, Map()),
	Window.Receive(Map("action", "ready")),
	AssertTrue(Window.Receive(Map("action", "capture_position", "request", Map("request_id", 3)))),
	Receive := Sent[2],
	AssertTrue(Receive.Call(Map("native_code", "SC01E", "mods", Map("ctrl", 1, "alt", 0, "shift", 0, "super", 0)))),
	AssertContains(Sent[3], 'captured({'),
	AssertContains(Sent[3], '"code":"KeyA"'),
	AssertContains(Sent[3], '"request_id":3'),
	AssertFalse(Receive.Call(Map("native_code", "SC01E", "mods", Map())), "one key per request")
))

Test("physical shortcuts: the key capture refuses without the shared hook and a foreign token (physical-editor-windows)", () => (
	AssertEqual(HookDispatcher._started ? 1 : 0, KHPositionCaptureAvailable()),
	AssertFalse(KHCancelPosition({}), "a token the hook never issued is refused")
))
