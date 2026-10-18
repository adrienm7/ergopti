; modules/keymap/layout/digit_row_bindings.ahk

; ==============================================================================
; MODULE: Direct Digit Binding Ownership
; DESCRIPTION:
; Retains the original static number-row variants and publishes their source
; only after all twenty existing slots have been checked and updated through
; the genuine AHK registration functions. This owns binding metadata, not
; physical input provenance, native host mapping or accepted output effects.
; ==============================================================================

#Requires AutoHotkey v2.0

; These remain the original legacy emitters. Binding ownership does not select
; the future native backend or change repeat, release or screen-ring behavior.
_DigitRowDown(Digit, *) {
	Critical("On")
	SendEvent("{" Digit " Down}")
	; An armed suppressing hook can consume the character before the screen.
	if _EmitReachedScreen()
		UpdateLastSentCharacter(Digit)
}

_DigitRowUp(Digit, *) {
	Critical("On")
	SendEvent("{" Digit " Up}")
}

/**
 * Updates the original twenty static variants without changing their priority.
 * @returns {Integer} Twenty after complete registration and HotIf cleanup.
 * @throws {Error} On duplicate, reentrant, partial or withdrawn registration.
 */
DigitRow_RegisterBindings() {
	return _DigitRowBindingOwner("register")
}

/** Returns the exact issued capture factory, or zero before complete ownership. */
DigitRow_BindingSource() {
	return _DigitRowBindingOwner("source")
}

/**
 * Resolves only the exact currently issued factory; caller Maps grant nothing.
 * @param {BoundFunc} Source Exact factory returned by DigitRow_BindingSource.
 * @param {Integer} Scan Physical number-row position, 0x02 through 0x0B.
 * @returns {Map|Integer} Detached binding metadata or zero; never dispatch consent.
 */
DigitRow_CaptureBinding(Source, Scan) {
	return _DigitRowBindingOwner("capture", Source, Scan)
}

/** One private initialization owner; there is deliberately no reset or issuer API. */
_DigitRowBindingOwner(Request, Value := 0, Scan := 0) {
	static Phase := "fresh", Factory := 0, Bindings := Map()
	static Criterion := 'NumberRowEffectiveMode() == "digits"'
	static NativeCall := Func.Prototype.Call
	static NativeBind := Func.Prototype.Bind
	static Keys := [["SC002", "1"], ["SC003", "2"], ["SC004", "3"],
		["SC005", "4"], ["SC006", "5"], ["SC007", "6"], ["SC008", "7"],
		["SC009", "8"], ["SC00A", "9"], ["SC00B", "0"]]
	; Map is a Class with its own Call; retain that Func without weakening the roster.
	static Owners := [DigitRow_RegisterBindings, DigitRow_BindingSource,
		DigitRow_CaptureBinding, _DigitRowBindingOwner, _DigitRowDown, _DigitRowUp,
		NumberRowEffectiveMode, HotIf, Hotkey, Critical, Map.Call,
		Func.Prototype.Call, Func.Prototype.Bind]

	OwnersCurrent() {
		Current := [DigitRow_RegisterBindings, DigitRow_BindingSource,
			DigitRow_CaptureBinding, _DigitRowBindingOwner, _DigitRowDown, _DigitRowUp,
			NumberRowEffectiveMode, HotIf, Hotkey, Critical, Map.Call,
			Func.Prototype.Call, Func.Prototype.Bind]
		for Index, Owner in Owners
			if !(Owner is Func) || Owner != Current[Index]
					|| Object.Prototype.HasOwnProp.Call(Owner, "Call")
				return false
		return true
	}

	BindingsCurrent() {
		if Bindings.Count != 10
			return false
		for _, Binding in Bindings
			for Callback in [Binding["down"], Binding["up"]]
				if !(Callback is BoundFunc)
						|| Object.Prototype.HasOwnProp.Call(Callback, "Call")
					return false
		return true
	}

	SourceCurrent() {
		if Phase != "ready"
			return false
		if !(Factory is BoundFunc) || Object.Prototype.HasOwnProp.Call(Factory, "Call")
				|| !OwnersCurrent() || !BindingsCurrent() {
			; Restoring a public function cannot recreate the original source lease.
			Factory := 0
			Phase := "failed"
			return false
		}
		return true
	}

	CaptureOwned(Position) {
		if !SourceCurrent() || !(Position is Integer) || Position < 0x02 || Position > 0x0B
			return 0
		Binding := Bindings[Position]
		return Map("source", Factory, "scan", Position, "digit", Binding["digit"],
			"down", Binding["down"], "up", Binding["up"],
			"criterion", Criterion, "input_level", 2, "metadata_only", true)
	}

	if !(Request is String)
		throw TypeError("A direct-digit binding operation is required.")
	if Request == "source"
		return SourceCurrent() ? Factory : 0
	if Request == "capture"
		return SourceCurrent() && Value is BoundFunc && Value == Factory ? CaptureOwned(Scan) : 0
	if Request != "register"
		throw ValueError("Unknown direct-digit binding operation.")
	if Phase == "registering" {
		Phase := "failed"
		throw Error("Direct-digit registration was reentered; source publication is refused.")
	}
	if Phase != "fresh"
		throw Error("Direct-digit registration has already been attempted.")
	if !(Value is Integer) || Value != 0 || !(Scan is Integer) || Scan != 0
		throw ValueError("Direct-digit registration does not accept supplied authority.")
	Phase := "registering"
	if !OwnersCurrent() {
		Phase := "failed"
		throw Error("Direct-digit registration functions were withdrawn.")
	}

	RequireCurrent() {
		if Phase != "registering" || !OwnersCurrent()
			throw Error("Direct-digit registration lost its original ownership.")
	}

	ContextReleased := false
	try {
		PreviousCritical := NativeCall.Call(Critical, "On")
		try {
			NativeCall.Call(HotIf, Criterion)
			RequireCurrent()
			; Omitting the callback refuses absent slots rather than creating a
			; late variant which would change the static tap-hold priority.
			for Index, Key in Keys {
				Name := Key[1]
				for Suffix in ["", " Up"] {
					RequireCurrent()
					NativeCall.Call(Hotkey, Name . Suffix, , "I2")
					RequireCurrent()
				}
			}
			Count := 0
			for Index, Key in Keys {
				Position := Index + 1
				Name := Key[1], Digit := Key[2]
				Binding := Map("digit", Digit, "down", NativeBind.Call(_DigitRowDown, Digit),
					"up", NativeBind.Call(_DigitRowUp, Digit))
				Bindings[Position] := Binding
				for Edge in ["down", "up"] {
					RequireCurrent()
					HotkeyName := Name . (Edge == "up" ? " Up" : "")
					NativeCall.Call(Hotkey, HotkeyName, Binding[Edge], "I2")
					Count += 1
					RequireCurrent()
				}
			}
			NativeCall.Call(HotIf)
			ContextReleased := true
			RequireCurrent()
			if Count != 20 || !BindingsCurrent()
				throw Error("Direct-digit registration did not complete all bindings.")
			Factory := NativeBind.Call(CaptureOwned)
			Phase := "ready"
		} finally {
			try {
				; No supplied callback runs between the genuine updates and cleanup.
				if !ContextReleased
					NativeCall.Call(HotIf)
			} finally NativeCall.Call(Critical, PreviousCritical)
		}
	} catch as Err {
		Factory := 0
		Phase := "failed"
		throw Err
	}
	if !SourceCurrent() {
		Factory := 0
		Phase := "failed"
		throw Error("Direct-digit source publication lost its binding ownership.")
	}
	return Count
}
