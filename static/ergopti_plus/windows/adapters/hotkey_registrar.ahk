; adapters/hotkey_registrar.ahk

; ==============================================================================
; MODULE: Hotkey Registrar Adapter (AutoHotkey)
; DESCRIPTION:
; AutoHotkey implementation of the HotkeyRegistrar port contract defined in
; static/ergopti_plus/_shared/core/ports/HotkeyRegistrar.spec.js. Wraps the
; built-in Hotkey() so that "register a system-wide chord" is one call the caller
; can make without knowing that AutoHotkey wants "^+s" rather than a modifier list
; and a key, and without knowing that AutoHotkey hands back no object at all.
;
; FEATURES & RATIONALE:
; 1. Canonical chords only: every chord is parsed by infra/chord.ahk before it is
;    translated, so "shift+ctrl+s" and "Ctrl+Shift+S" produce ONE registration
;    rather than two live bindings that both fire.
; 2. Handles are tokens, not chord strings: AutoHotkey addresses a hotkey by its
;    native spec, so returning the spec would let a caller "unbind" a chord it
;    never bound. A token issued by this adapter can only name a binding this
;    adapter created.
; 3. Refusal is a return value: an unparseable chord never reaches the OS, and a
;    chord AutoHotkey rejects yields an empty handle. A variant already owned by
;    another producer in this AHK process is refused without replacement.
; ==============================================================================





; =====================================
; =====================================
; ======= 1/ Native Translation =======
; =====================================
; =====================================

; Canonical modifier → AutoHotkey hotkey-spec prefix. "cmd" maps to the Windows
; key because that is the modifier in the same physical position, which is what
; the shared notation means by it
global HOTKEY_MOD_PREFIXES := Map("cmd", "#", "ctrl", "^", "alt", "!", "shift", "+")

; AutoHotkey accepts modifier prefixes in several orders, but its variant
; registry does not promise that every spelling will keep one physical identity.
; Emit the established metrics order so every producer reaches the same spec.
global HOTKEY_NATIVE_MOD_ORDER := ["ctrl", "alt", "shift", "cmd"]

; Human key aliases which name one physical Windows key. The shared notation is
; deliberately platform-neutral and therefore preserves these spellings; the
; adapter must collapse them before ownership is indexed by native spec.
global HOTKEY_PHYSICAL_KEY_ALIASES := Map(
	"esc", "escape",
	"escape", "escape",
	"return", "enter",
	"enter", "enter",
	"bs", "backspace",
	"backspace", "backspace",
	"del", "delete",
	"delete", "delete",
	"ins", "insert",
	"insert", "insert"
)

; Canonical key name → AutoHotkey Hotkey() key name. Braces belong to Send(),
; not Hotkey(); named keys are bare. Anything absent is passed through unchanged,
; which is correct for letters, digits and punctuation.
global HOTKEY_KEY_NATIVE := Map(
	"space", "space",
	"return", "enter",
	"enter", "enter",
	"tab", "tab",
	"escape", "escape",
	"backspace", "backspace",
	"delete", "delete"
)

; AutoHotkey v2 resolves these named suffixes by scan code so their number-pad
; counterparts, which share a virtual key, remain distinct. Keep this list in
; the native adapter beside the spelling table; ownership comparisons must use
; the same primary axis as Hotkey::TextToKey rather than comparing both codes.
global HOTKEY_NATIVE_SC_PRIMARY_KEYS := Map(
	"numpadenter", true,
	"delete", true,
	"del", true,
	"insert", true,
	"ins", true,
	"up", true,
	"down", true,
	"left", true,
	"right", true,
	"home", true,
	"end", true,
	"pgup", true,
	"pgdn", true
)

; Live bindings keyed by handle token, each holding the native spec and the
; enabled state. The spec never leaves this file, so exactly one code path can
; turn a hotkey off
global HOTKEY_REGISTRAR_BINDINGS := Map()

; Native variants remain addressable after Hotkey(spec, "Off"). Keep a
; spec-indexed tombstone so a later registrar owner can safely replace that
; known inert callback instead of mistaking it for an unknown foreign binding.
global HOTKEY_REGISTRAR_SPECS := Map()

; Monotonic token source. Tokens are never reused, so a handle from a released
; binding stays permanently unknown instead of silently addressing a later one
global HOTKEY_REGISTRAR_NEXT_TOKEN := 0

/**
 * Translates a parsed chord into an AutoHotkey hotkey specification.
 * @param {Array} mods Canonical modifier names.
 * @param {String} key Canonical key.
 * @returns {String} The native spec, e.g. "^+s", or "" when a modifier has no
 *          AutoHotkey equivalent (fn, which no Windows API exposes).
 */
HotkeyRegistrarPhysicalKey(key) {
	global HOTKEY_PHYSICAL_KEY_ALIASES

	if (!IsSet(key) || Type(key) != "String" || key = "")
		return ""
	CanonicalKey := ChordCanonicalKey(key)
	return HOTKEY_PHYSICAL_KEY_ALIASES.Get(StrLower(CanonicalKey), CanonicalKey)
}

HotkeyRegistrarNativeKey(key) {
	global HOTKEY_KEY_NATIVE

	PhysicalKey := HotkeyRegistrarPhysicalKey(key)
	if (PhysicalKey = "")
		return ""
	if HOTKEY_KEY_NATIVE.Has(PhysicalKey)
		return HOTKEY_KEY_NATIVE[PhysicalKey]
	if RegExMatch(PhysicalKey, "^sc[0-9a-f]{3,}$")
		return StrUpper(PhysicalKey)
	return StrLower(PhysicalKey)
}

HotkeyRegistrarNativeSpec(mods, key) {
	global HOTKEY_MOD_PREFIXES, HOTKEY_NATIVE_MOD_ORDER

	if !(mods is Array)
		return ""
	Present := Map()
	for _, RawModName in mods {
		if Type(RawModName) != "String"
			return ""
		ModName := StrLower(RawModName)
		if !HOTKEY_MOD_PREFIXES.Has(ModName)
			return ""
		Present[ModName] := true
	}

	spec := ""
	for _, ModName in HOTKEY_NATIVE_MOD_ORDER {
		if Present.Has(ModName)
			spec .= HOTKEY_MOD_PREFIXES[ModName]
	}

	NativeKey := HotkeyRegistrarNativeKey(key)
	if (NativeKey = "")
		return ""
	return spec . NativeKey
}

_HotkeyRegistrarGetKeyboardLayout() {
	return DllCall("GetKeyboardLayout", "UInt", 0, "Ptr")
}

_HotkeyRegistrarVkKeyScan(Key, Layout) {
	return DllCall("VkKeyScanExW", "UShort", Ord(Key),
		"Ptr", Layout, "Short")
}

_HotkeyRegistrarGetKeyVK(Key) {
	return GetKeyVK(Key)
}

_HotkeyRegistrarGetKeySC(Key) {
	return GetKeySC(Key)
}

; One collision decision must resolve every owner against one keyboard layout.
; Returning a unary bound resolver prevents a layout switch between candidate
; and contextual-owner probes from producing a torn ownership snapshot.
HotkeyRegistrarNativeKeyResolverSnapshot(Port := 0) {
	ResolvedPort := Port is Map ? Port : Map()
	LayoutFn := ResolvedPort.Get("get_layout", _HotkeyRegistrarGetKeyboardLayout)
	if !HasMethod(LayoutFn, "Call")
		return false
	try Layout := LayoutFn.Call()
	catch
		return false
	if !(Layout is Integer) || Layout == 0
		return false
	return _HotkeyRegistrarResolveNativeKeyIdentityAtLayout.Bind(Layout,
		ResolvedPort)
}

; Mirrors the supported AutoHotkey v2 Hotkey::TextToKey identity boundary.
; Single-character suffixes resolve through one captured HKL and acquire any
; implicit Shift/Ctrl/Alt bits returned by VkKeyScanExW. Named keys use the same
; VK-vs-SC primary axis as AutoHotkey's public key table.
HotkeyRegistrarResolveNativeKeyIdentity(Key, Port := 0) {
	Resolver := HotkeyRegistrarNativeKeyResolverSnapshot(Port)
	if !HasMethod(Resolver, "Call")
		return false
	return Resolver.Call(Key)
}

_HotkeyRegistrarResolveNativeKeyIdentityAtLayout(Layout, Port, Key) {
	global HOTKEY_NATIVE_SC_PRIMARY_KEYS
	if !(Key is String) || Key == "" || !(Port is Map)
		return false
	try {
		if StrLen(Key) == 1 {
			VkScanFn := Port.Get("vk_scan", _HotkeyRegistrarVkKeyScan)
			if !HasMethod(VkScanFn, "Call")
				return false
			Packed := VkScanFn.Call(Key, Layout)
			if !(Packed is Integer)
				return false
			if Packed == -1 {
				if !RegExMatch(Key, "i)^[a-z]$")
					return false
				Code := Ord(StrUpper(Key))
				Flags := 0
			} else {
				Code := Packed & 0xFF
				Flags := (Packed >> 8) & 0xFF
				if Code == 0 || (Flags & 0xF8)
					return false
			}
			; AHK deliberately makes alphabetic hotkeys case-insensitive by removing
			; the Shift bit which VkKeyScanExW reports for uppercase letters.
			if Code >= 0x41 && Code <= 0x5A
				Flags := Flags & 0xFE
			; AltGr is a right-sided Ctrl+Alt owner while neutral modifiers expand
			; across left/right slots. A scalar identity cannot model their overlap,
			; so reject this LLM trigger key rather than authorize two owners.
			if (Flags & 0x06) == 0x06
				return false
			Implicit := ""
			if Flags & 0x02
				Implicit .= "^"
			if Flags & 0x04
				Implicit .= "!"
			if Flags & 0x01
				Implicit .= "+"
			return Map("axis", "vk", "code", Code,
				"implicit_modifiers", Implicit)
		}

		LowerKey := StrLower(Key)
		if RegExMatch(LowerKey, "^vk([0-9a-f]{2})$", &ExplicitMatch) {
			Code := Integer("0x" . ExplicitMatch[1])
			if Code <= 0 || Code > 0xFF
				return false
			return Map("axis", "vk", "code", Code,
				"implicit_modifiers", "")
		}
		if RegExMatch(LowerKey, "^sc([0-9a-f]{3})$", &ExplicitMatch) {
			Code := Integer("0x" . ExplicitMatch[1])
			if Code <= 0 || Code > 0x1FF
				return false
			return Map("axis", "sc", "code", Code,
				"implicit_modifiers", "")
		}
		if RegExMatch(LowerKey, "^(?:vk|sc)[0-9a-f]")
			return false
		if HOTKEY_NATIVE_SC_PRIMARY_KEYS.Has(LowerKey) {
			ResolveFn := Port.Get("get_sc", _HotkeyRegistrarGetKeySC)
			Axis := "sc"
		} else {
			ResolveFn := Port.Get("get_vk", _HotkeyRegistrarGetKeyVK)
			Axis := "vk"
		}
		if !HasMethod(ResolveFn, "Call")
			return false
		Code := ResolveFn.Call(Key)
		if !(Code is Integer) || Code <= 0
				|| (Axis == "vk" && Code > 0xFF)
				|| (Axis == "sc" && Code > 0x1FF)
			return false
		return Map("axis", Axis, "code", Code,
			"implicit_modifiers", "")
	} catch as e {
		try LoggerError("HotkeyRegistrar",
			"Could not resolve native hotkey key '{1}': {2}.", Key, e.Message)
		return false
	}
}

_HotkeyRegistrarParseNativeSpec(Spec) {
	if !(Spec is String)
		return false
	Raw := StrLower(Trim(Spec))
	if Raw == ""
		return false
	Modifiers := Map()
	Tilde := false
	Dollar := false
	Wildcard := false
	KeyStart := 1
	Loop StrLen(Raw) {
		Ch := SubStr(Raw, A_Index, 1)
		if Ch == "<" || Ch == ">"
			return false
		if Ch == "~" {
			Tilde := true
			KeyStart := A_Index + 1
			continue
		}
		if Ch == "$" {
			Dollar := true
			KeyStart := A_Index + 1
			continue
		}
		if Ch == "*" {
			Wildcard := true
			KeyStart := A_Index + 1
			continue
		}
		if Ch == "^" || Ch == "!" || Ch == "+" || Ch == "#" {
			Modifiers[Ch] := true
			KeyStart := A_Index + 1
			continue
		}
		break
	}
	Key := SubStr(Raw, KeyStart)
	if Key == "" || InStr(Key, "&")
		return false
	return Map("modifiers", Modifiers, "tilde", Tilde, "dollar", Dollar,
		"wildcard", Wildcard, "key", Key)
}

_HotkeyRegistrarDescriptorPrefix(Parsed) {
	if !(Parsed is Map) || !(Parsed.Get("modifiers", 0) is Map)
		return false
	Prefix := Parsed.Get("wildcard", false) ? "*" : ""
	for Symbol in ["^", "!", "+", "#"] {
		if Parsed["modifiers"].Has(Symbol)
			Prefix .= Symbol
	}
	return Prefix
}

; VkKeyScanEx can add only neutral Ctrl, Alt and Shift. Ctrl+Alt is rejected
; earlier because it represents AltGr, whose sided ownership is not scalar.
_HotkeyRegistrarImplicitModifiersAreCanonical(Value) {
	return Value is String && (Value == "" || Value == "^" || Value == "!"
		|| Value == "+" || Value == "^+" || Value == "!+")
}

/**
 * Resolves one AHK hotkey spec into an immutable native descriptor. Character
 * suffixes are converted to explicit VK specs, so a later keyboard-layout
 * change cannot make Hotkey() register a different physical owner than the
 * identity used by collision admission.
 */
HotkeyRegistrarResolvedNativeDescriptor(Spec, KeyResolverFn := 0) {
	Parsed := _HotkeyRegistrarParseNativeSpec(Spec)
	if !(Parsed is Map)
		return false
	Resolver := HasMethod(KeyResolverFn, "Call") ? KeyResolverFn
		: HotkeyRegistrarNativeKeyResolverSnapshot(KeyResolverFn is Map
			? KeyResolverFn : 0)
	if !HasMethod(Resolver, "Call")
		return false
	try ResolvedKey := Resolver.Call(Parsed["key"])
	catch
		return false
	if !(ResolvedKey is Map)
		return false
	Axis := ResolvedKey.Get("axis", "")
	Code := ResolvedKey.Get("code", 0)
	ImplicitModifiers := ResolvedKey.Get("implicit_modifiers", "")
	CharacterKey := StrLen(Parsed["key"]) == 1
	if !((Axis == "vk" || Axis == "sc") && (Code is Integer)
			&& Code > 0 && (ImplicitModifiers is String))
		return false
	if CharacterKey && Axis != "vk"
		return false
	if !_HotkeyRegistrarImplicitModifiersAreCanonical(ImplicitModifiers)
		return false
	if !CharacterKey && ImplicitModifiers != ""
		return false
	if (Axis == "vk" && Code > 0xFF) || (Axis == "sc" && Code > 0x1FF)
		return false
	SourcePrefix := _HotkeyRegistrarDescriptorPrefix(Parsed)
	if !(SourcePrefix is String)
		return false
	VariantPrefix := (Parsed["tilde"] ? "~" : "")
		. (Parsed["dollar"] ? "$" : "")
	LogicalSpec := VariantPrefix . SourcePrefix . Parsed["key"]
	Loop StrLen(ImplicitModifiers) {
		Symbol := SubStr(ImplicitModifiers, A_Index, 1)
		Parsed["modifiers"][Symbol] := true
	}
	Prefix := _HotkeyRegistrarDescriptorPrefix(Parsed)
	if !(Prefix is String)
		return false
	Identity := Prefix . Axis . Format("{:04X}", Code)
	; AHK gives an explicitly numeric VK different semantics for named keys
	; which share a virtual key (Enter/NumpadEnter and several numpad aliases).
	; Freeze only layout-dependent character suffixes; named suffixes already
	; have layout-independent parsing and must retain their AHK name.
	NativeKey := CharacterKey
		? "vk" . Format("{:02X}", Code)
		: Parsed["key"]
	return Map("identity", Identity,
		"native_spec", VariantPrefix . Prefix . NativeKey,
		"logical_spec", LogicalSpec,
		"kind", CharacterKey ? "character" : "named",
		"axis", Axis,
		"code", Code,
		"implicit_modifiers", ImplicitModifiers,
		"resolver", Resolver)
}

HotkeyRegistrarResolvedDescriptorIsValid(Descriptor) {
	if !(Descriptor is Map)
		return false
	Identity := Descriptor.Get("identity", "")
	NativeSpec := Descriptor.Get("native_spec", "")
	LogicalSpec := Descriptor.Get("logical_spec", "")
	Kind := Descriptor.Get("kind", "")
	Axis := Descriptor.Get("axis", "")
	Code := Descriptor.Get("code", 0)
	ImplicitModifiers := Descriptor.Get("implicit_modifiers", "")
	Resolver := Descriptor.Get("resolver", 0)
	if !(Identity is String) || !(NativeSpec is String)
			|| !(LogicalSpec is String) || LogicalSpec == ""
			|| !(Kind == "character" || Kind == "named")
			|| !(Axis == "vk" || Axis == "sc")
			|| !(Code is Integer) || Code <= 0
			|| !_HotkeyRegistrarImplicitModifiersAreCanonical(ImplicitModifiers)
			|| !HasMethod(Resolver, "Call")
		return false
	if !RegExMatch(Identity,
			"^(\*?\^?!?\+?#?)(vk|sc)([0-9A-F]{4})$", &IdentityMatch)
		return false
	IdentityCode := Integer("0x" . IdentityMatch[3])
	if IdentityMatch[2] != Axis || IdentityCode != Code
		return false
	if (Axis == "vk" && Code > 0xFF) || (Axis == "sc" && Code > 0x1FF)
		return false
	NativeParsed := _HotkeyRegistrarParseNativeSpec(NativeSpec)
	LogicalParsed := _HotkeyRegistrarParseNativeSpec(LogicalSpec)
	if !(NativeParsed is Map) || !(LogicalParsed is Map)
		return false
	try ResolvedKey := Resolver.Call(LogicalParsed["key"])
	catch
		return false
	if !(ResolvedKey is Map)
		return false
	ResolvedAxis := ResolvedKey.Get("axis", "")
	ResolvedCode := ResolvedKey.Get("code", 0)
	ResolvedImplicit := ResolvedKey.Get("implicit_modifiers", "")
	if ResolvedAxis != Axis || ResolvedCode != Code
			|| !_HotkeyRegistrarImplicitModifiersAreCanonical(ResolvedImplicit)
		return false
	if ImplicitModifiers != ResolvedImplicit
		return false
	NativePrefix := _HotkeyRegistrarDescriptorPrefix(NativeParsed)
	LogicalPrefix := _HotkeyRegistrarDescriptorPrefix(LogicalParsed)
	NativeVariantPrefix := (NativeParsed["tilde"] ? "~" : "")
		. (NativeParsed["dollar"] ? "$" : "")
	LogicalVariantPrefix := (LogicalParsed["tilde"] ? "~" : "")
		. (LogicalParsed["dollar"] ? "$" : "")
	ExpectedNativeKey := Kind == "character"
		? (Axis == "vk" ? "vk" . Format("{:02X}", Code)
			: "sc" . Format("{:03X}", Code))
		: LogicalParsed["key"]
	ExpectedNativeSpec := NativeVariantPrefix . NativePrefix
		. ExpectedNativeKey
	ExpectedLogicalSpec := LogicalVariantPrefix . LogicalPrefix
		. LogicalParsed["key"]
	ExpectedParsed := Map("modifiers", LogicalParsed["modifiers"].Clone(),
		"wildcard", LogicalParsed["wildcard"])
	Loop StrLen(ImplicitModifiers) {
		Symbol := SubStr(ImplicitModifiers, A_Index, 1)
		if !(Symbol == "^" || Symbol == "!" || Symbol == "+")
			return false
		ExpectedParsed["modifiers"][Symbol] := true
	}
	ExpectedPrefix := _HotkeyRegistrarDescriptorPrefix(ExpectedParsed)
	if !(NativePrefix is String) || !(LogicalPrefix is String)
			|| !(ExpectedPrefix is String)
			|| NativePrefix != IdentityMatch[1]
			|| ExpectedPrefix != IdentityMatch[1]
			|| NativeSpec !== ExpectedNativeSpec
			|| LogicalSpec !== ExpectedLogicalSpec
			|| NativeParsed["tilde"] != LogicalParsed["tilde"]
			|| NativeParsed["dollar"] != LogicalParsed["dollar"]
		return false
	if Kind == "named" {
		if StrLen(LogicalParsed["key"]) <= 1
				|| ImplicitModifiers != "" || NativeSpec != LogicalSpec
			return false
		return true
	}
	if StrLen(LogicalParsed["key"]) != 1
		return false
	if Axis != "vk"
		return false
	if !RegExMatch(NativeParsed["key"],
			"^(vk)([0-9a-f]{2})$", &NativeKeyMatch)
		return false
	NativeCode := Integer("0x" . NativeKeyMatch[2])
	return NativeKeyMatch[1] == Axis && NativeCode == Code
		&& StrLen(NativeKeyMatch[2]) == 2
}





; ==================================
; ==================================
; ======= 2/ Adapter Methods =======
; ==================================
; ==================================

/**
 * Registers a system-wide chord against a callback.
 * @param {String} chordString Canonical chord string, e.g. "Ctrl+Shift+S".
 * @param {Func} callback Invoked on each press.
 * @returns {String} An opaque handle, or "" when the chord was refused.
 */
HotkeyRegistrarBind(chordString, callback) {
	return _HotkeyRegistrarBindOwned(chordString, callback, "port")
}

; State objects are immutable after construction. A callback observes either
; the complete old authority or the complete new authority through one Map
; reference read; it can never observe a half-published set of booleans.
_HotkeyRegistrarState(Phase, Dispatch := 0, NativeState := "unknown") {
	return Map("phase", Phase, "dispatch", Dispatch, "native", NativeState)
}

; A registrar Entry owns its exact AHK lifecycle spec. Call only inside an
; existing Critical section so the lookup forms one non-yielding ownership
; snapshot.
_HotkeyRegistrarOwnsSpec(Entry) {
	global HOTKEY_REGISTRAR_SPECS

	Spec := Entry["spec"]
	if !HOTKEY_REGISTRAR_SPECS.Has(Spec)
			|| (HOTKEY_REGISTRAR_SPECS[Spec] != Entry)
		return false
	return true
}

; Internal owner-aware seam. HotkeyFn and ProbeFn are injected only by the
; behavioural suite; public port arity remains exactly bind(chord, callback).
_HotkeyRegistrarBindOwned(chordString, callback, Owner := "anonymous",
		HotkeyFn := 0, ProbeFn := 0, HotIfFn := 0) {
	Handle := _HotkeyRegistrarReserveOwned(chordString, callback, Owner,
		HotkeyFn, ProbeFn, HotIfFn)
	if (Handle = "")
		return ""
	if _HotkeyRegistrarActivate(Handle, HotkeyFn, HotIfFn)
		return Handle
	; Hotkey() is exception-atomic for action-only On: failure leaves native Off.
	; Discard that private reservation before reporting refusal.
	_HotkeyRegistrarAbort(Handle)
	return ""
}

; Internal staging primitive: claim one exact native spec and install its wrapper in
; confirmed native Off state. The returned handle is not an active binding until
; _HotkeyRegistrarActivate succeeds, so a durable transaction can prepare it
; without publishing the candidate action early.
_HotkeyRegistrarReserveOwned(chordString, callback, Owner := "anonymous",
		HotkeyFn := 0, ProbeFn := 0, HotIfFn := 0,
		ResolvedDescriptor := 0) {
	global HOTKEY_REGISTRAR_BINDINGS, HOTKEY_REGISTRAR_SPECS
	global HOTKEY_REGISTRAR_NEXT_TOKEN

	if (!IsSet(callback) || !HasMethod(callback, "Call")) {
		LoggerError("adapters.hotkey_registrar", "bind(): callback must be a function.")
		return ""
	}
	parsed := ChordParse(chordString)
	if (!parsed["ok"]) {
		LoggerError("adapters.hotkey_registrar", "bind(): refusing '" . chordString . "' — " . parsed["err"] . ".")
		return ""
	}

	PhysicalKey := HotkeyRegistrarPhysicalKey(parsed["key"])
	DisplaySpec := HotkeyRegistrarNativeSpec(parsed["mods"], PhysicalKey)
	if (DisplaySpec = "") {
		LoggerWarn("adapters.hotkey_registrar", "bind(): '" . chordString . "' names a modifier Windows does not expose.")
		return ""
	}
	PhysicalIdentity := ""
	spec := DisplaySpec
	if ResolvedDescriptor is Map {
		if !HotkeyRegistrarResolvedDescriptorIsValid(ResolvedDescriptor)
				|| ResolvedDescriptor["logical_spec"] !== StrLower(DisplaySpec)
			return ""
		PhysicalIdentity := ResolvedDescriptor["identity"]
		spec := ResolvedDescriptor["native_spec"]
	} else if !((ResolvedDescriptor is Integer) && ResolvedDescriptor == 0) {
		return ""
	}
	Formatted := ChordFormat(parsed["mods"], PhysicalKey)
	if !Formatted["ok"] {
		LoggerError("adapters.hotkey_registrar", "bind(): refusing '" . chordString . "' — " . Formatted["err"] . ".")
		return ""
	}
	canonical := Formatted["label"]
	OwnerText := String(Owner)
	HasConflict := false
	ConflictOwner := ""
	KnownTombstone := false
	HadPreviousEntry := false
	PreviousEntry := 0
	entry := 0
	ReserveState := 0
	PreviousCritical := Critical("On")
	try {
		if HOTKEY_REGISTRAR_SPECS.Has(spec) {
			Existing := HOTKEY_REGISTRAR_SPECS[spec]
			ExistingState := Existing["state"]
			if (ExistingState["phase"] != "retired") {
				HasConflict := true
				ConflictOwner := Existing["owner"]
			} else {
				KnownTombstone := true
				HadPreviousEntry := true
				PreviousEntry := Existing
			}
		}
		; Strict LLM reservations freeze character keys to VK/SC spellings while
		; legacy consumers retain their established textual specs. Serialize both
		; representations of the same logical chord before either can reach the
		; interruptible native probe.
		if !HasConflict {
			for , Existing in HOTKEY_REGISTRAR_SPECS {
				if Existing.Get("display_spec", Existing.Get("spec", ""))
						!== DisplaySpec
					continue
				ExistingState := Existing["state"]
				if ExistingState["phase"] != "retired" {
					HasConflict := true
					ConflictOwner := Existing["owner"]
					break
				}
			}
		}
		if !HasConflict {
			HOTKEY_REGISTRAR_NEXT_TOKEN += 1
			handle := "hotkey#" . HOTKEY_REGISTRAR_NEXT_TOKEN
			entry := Map(
				"handle", handle,
				"spec", spec,
				"display_spec", DisplaySpec,
				"chord", canonical,
				"owner", OwnerText,
				; Optional immutable native identity and explicit VK/SC spec supplied as
				; one validated descriptor. The native call below uses ``spec`` itself,
				; so metadata and the registered owner cannot diverge after an HKL switch.
				"physical_identity", PhysicalIdentity,
				"callback", callback,
				"state", 0)
			ReserveState := _HotkeyRegistrarState("reserving", 0, "off")
			entry["state"] := ReserveState
			HOTKEY_REGISTRAR_SPECS[spec] := entry
		}
	} finally {
		Critical(PreviousCritical)
	}
	if HasConflict {
		LoggerWarn("adapters.hotkey_registrar", "bind(): refusing '" . canonical
			. "' — owner '" . ConflictOwner . "' already holds it.")
		return ""
	}

	; Unknown native variants are probed after the in-memory claim. Sibling binds
	; now see this reservation, while no Critical span covers the OS call. A
	; frozen character spec (for example ^vk56) can address the same AHK variant
	; as a raw producer registered under its textual spelling (~^v). Probe that
	; spelling as well: freezing the candidate must not make an older producer
	; invisible. An exact tombstone only proves the frozen spec is ours; it says
	; nothing about a later textual producer.
	DisplayOccupied := spec != DisplaySpec
		&& _HotkeyRegistrarNativeExists(DisplaySpec, HotkeyFn, ProbeFn,
			HotIfFn)
	SpecOccupied := !DisplayOccupied && !KnownTombstone
		&& _HotkeyRegistrarNativeExists(spec, HotkeyFn, ProbeFn, HotIfFn)
	if DisplayOccupied || SpecOccupied {
		RolledBack := _HotkeyRegistrarRollbackClaim(entry, ReserveState,
			PreviousEntry, HadPreviousEntry)
		_HotkeyRegistrarRequireState(RolledBack,
			"bind(): could not roll back an occupied claim for '" . canonical . "'")
		LoggerWarn("adapters.hotkey_registrar", "bind(): refusing '" . canonical
			. "' — another producer already owns this process variant.")
		return ""
	}

	Wrapper := _HotkeyRegistrarDispatch.Bind(entry)
	try {
		; Supplying a callback with Off creates or replaces the global variant in
		; disabled state. This is the only safe reversible staging primitive.
		_HotkeyRegistrarInvoke(spec, Wrapper, "Off", HotkeyFn, HotIfFn)
	}
	catch as err {
		; AHK v2 Hotkey::Dynamic validates the callback, options and key before
		; mutation, and deletes a partially constructed hotkey on failure.
		RolledBack := _HotkeyRegistrarRollbackClaim(entry, ReserveState,
			PreviousEntry, HadPreviousEntry)
		_HotkeyRegistrarRequireState(RolledBack,
			"bind(): could not roll back refused reserve-Off for '" . canonical . "'")
		LoggerWarn("adapters.hotkey_registrar", "bind(): native reserve-Off refused '"
			. canonical . "' without mutation: " . err.Message . ".")
		return ""
	}
	Published := false
	PreviousCritical := Critical("On")
	try {
		if _HotkeyRegistrarOwnsSpec(entry)
				&& (entry["state"] == ReserveState) {
			entry["state"] := _HotkeyRegistrarState("reserved", 0, "off")
			HOTKEY_REGISTRAR_BINDINGS[handle] := entry
			Published := true
		}
	}
	finally Critical(PreviousCritical)
	if !Published {
		_HotkeyRegistrarRequireState(false,
			"bind(): reserve ownership publication was lost for '" . canonical . "'")
	}
	LoggerDebug("adapters.hotkey_registrar", "Reserved " . canonical . " → " . handle . ".")
	return handle
}

; LLM collision admission must never fall back to a layout-dependent textual
; reserve when the descriptor is absent or malformed.
_HotkeyRegistrarReserveResolvedOwned(chordString, callback, Owner,
		ResolvedDescriptor, HotkeyFn := 0, ProbeFn := 0, HotIfFn := 0) {
	if !HotkeyRegistrarResolvedDescriptorIsValid(ResolvedDescriptor)
		return ""
	return _HotkeyRegistrarReserveOwned(chordString, callback, Owner,
		HotkeyFn, ProbeFn, HotIfFn, ResolvedDescriptor)
}

; Enables an inert reservation. Publish callback authority while native is still
; confirmed Off, then call On: this closes the interruptible line boundary after
; Hotkey() returns where the newly active wrapper could otherwise swallow its
; first press. A refusal leaves native Off and restores the inert snapshot.
_HotkeyRegistrarActivate(handle, HotkeyFn := 0, HotIfFn := 0) {
	global HOTKEY_REGISTRAR_BINDINGS

	if (!IsSet(handle) || Type(handle) != "String")
		return false
	Entry := 0
	PreviousState := 0
	TransitionState := 0
	PreviousCritical := Critical("On")
	try {
		if !HOTKEY_REGISTRAR_BINDINGS.Has(handle)
			return false
		Entry := HOTKEY_REGISTRAR_BINDINGS[handle]
		if !_HotkeyRegistrarOwnsSpec(Entry)
			return false
		PreviousState := Entry["state"]
		if (PreviousState["phase"] != "reserved")
			return false
		TransitionState := _HotkeyRegistrarState("enabling", Entry["callback"],
			"off")
		Entry["state"] := TransitionState
	} finally {
		Critical(PreviousCritical)
	}

	try _HotkeyRegistrarInvokeAction(Entry["spec"], "On", HotkeyFn, HotIfFn)
	catch as Err {
		Restored := _HotkeyRegistrarPublishLiveState(Entry, TransitionState,
			PreviousState)
		_HotkeyRegistrarRequireState(Restored,
			"activate(): could not restore the exact pre-call state for " . handle)
		LoggerWarn("adapters.hotkey_registrar", "activate(): native On refused '"
			. Entry["chord"] . "' without mutation: " . Err.Message . ".")
		return false
	}

	Published := _HotkeyRegistrarPublishLiveState(Entry, TransitionState,
		_HotkeyRegistrarState("active", Entry["callback"], "on"))
	_HotkeyRegistrarRequireState(Published,
		"activate(): ownership changed after native On for " . handle)
	LoggerDebug("adapters.hotkey_registrar", "Activated " . Entry["chord"]
		. " (" . handle . ").")
	return true
}

; Discards an inert reservation without touching the OS: reserve state already
; proves that its native variant is Off.
_HotkeyRegistrarAbort(handle) {
	global HOTKEY_REGISTRAR_BINDINGS

	if (!IsSet(handle) || Type(handle) != "String")
		return false

	Aborted := false
	Entry := 0
	PreviousCritical := Critical("On")
	try {
		if !HOTKEY_REGISTRAR_BINDINGS.Has(handle) {
			return false
		} else {
			Entry := HOTKEY_REGISTRAR_BINDINGS[handle]
			if !_HotkeyRegistrarOwnsSpec(Entry)
				return false
			if (Entry["state"]["phase"] != "reserved")
				return false
			Entry["state"] := _HotkeyRegistrarState("retired", 0, "off")
			HOTKEY_REGISTRAR_BINDINGS.Delete(handle)
			Aborted := true
		}
	} finally {
		Critical(PreviousCritical)
	}
	if Aborted
		LoggerDebug("adapters.hotkey_registrar", "Aborted reserved "
			. Entry["chord"] . " (" . handle . ").")
	return Aborted
}

; Every operation intentionally selects the unconditional global HotIf variant.
; HotIf is thread-local default state inherited by newly launched threads; an
; adapter call made from a contextual hotkey would otherwise probe or mutate a
; different variant. The adapter deliberately leaves the caller in global
; context after returning so later raw Hotkey calls cannot inherit stale policy.
_HotkeyRegistrarSelectGlobalContext(HotIfFn := 0) {
	if HasMethod(HotIfFn, "Call")
		return HotIfFn.Call()
	return HotIf()
}

_HotkeyRegistrarInvoke(Name, Callback, Options, HotkeyFn := 0, HotIfFn := 0) {
	_HotkeyRegistrarSelectGlobalContext(HotIfFn)
	if HasMethod(HotkeyFn, "Call")
		return HotkeyFn.Call(Name, Callback, Options)
	return Hotkey(Name, Callback, Options)
}

_HotkeyRegistrarInvokeAction(Name, Action, HotkeyFn := 0, HotIfFn := 0) {
	_HotkeyRegistrarSelectGlobalContext(HotIfFn)
	if HasMethod(HotkeyFn, "Call")
		return HotkeyFn.Call(Name, Action)
	return Hotkey(Name, Action)
}

_HotkeyRegistrarNativeExists(Name, HotkeyFn := 0, ProbeFn := 0, HotIfFn := 0) {
	try _HotkeyRegistrarSelectGlobalContext(HotIfFn)
	catch as Err {
		try LoggerWarn("adapters.hotkey_registrar",
			"Could not select the global HotIf context for '{1}': {2}; treating it as occupied.",
			Name, Err.Message)
		return true
	}
	if HasMethod(ProbeFn, "Call") {
		try return ProbeFn.Call(Name) ? true : false
		catch as Err {
			try LoggerWarn("adapters.hotkey_registrar",
				"Could not probe native variant '{1}': {2}; treating it as occupied.",
				Name, Err.Message)
			return true
		}
	}
	; This probes variants in this AHK process only. Another process holding the
	; OS registration is not observable here because AHK may transparently fall
	; back to its keyboard hook. Never claim cross-process conflict detection.
	; Never let an injected seam fall through into the live process registry.
	if HasMethod(HotkeyFn, "Call")
		return false
	try {
		Hotkey(Name)
		return true
	} catch as Err {
		if (Err is TargetError)
			return false
		try LoggerWarn("adapters.hotkey_registrar",
			"Could not probe native variant '{1}': {2}; treating it as occupied.",
			Name, Err.Message)
		return true
	}
}

; A failed identity revalidation after a non-yielding native call means internal
; ownership corruption, not an ordinary user-level refusal. Continuing would
; strand an enabled native key or a transient handle, so fail fast.
_HotkeyRegistrarRequireState(Condition, Detail) {
	if Condition
		return true
	try LoggerError("adapters.hotkey_registrar", Detail . ".")
	throw Error(Detail)
}

_HotkeyRegistrarDispatch(Entry, Args*) {
	Snapshot := Entry["state"]
	Callback := Snapshot["dispatch"]
	if HasMethod(Callback, "Call")
		; The shared port is deliberately transport-agnostic: AHK's HotkeyName and
		; modifier arguments are native details and must not reach public callbacks.
		Callback.Call()
}

; Restores the exact prior tombstone after an exception-atomic reserve refusal.
; A new spec had no previous entry and is removed; a reusable disabled variant
; regains its former identity. No native compensation is needed or permitted.
_HotkeyRegistrarRollbackClaim(Entry, ExpectedState, PreviousEntry,
		HadPreviousEntry) {
	global HOTKEY_REGISTRAR_SPECS
	RolledBack := false
	PreviousCritical := Critical("On")
	try {
		Spec := Entry["spec"]
		if _HotkeyRegistrarOwnsSpec(Entry)
				&& (Entry["state"] == ExpectedState) {
			Entry["state"] := _HotkeyRegistrarState("retired", 0, "off")
			if HadPreviousEntry
				HOTKEY_REGISTRAR_SPECS[Spec] := PreviousEntry
			else
				HOTKEY_REGISTRAR_SPECS.Delete(Spec)
			RolledBack := true
		}
	} finally {
		Critical(PreviousCritical)
	}
	return RolledBack
}

_HotkeyRegistrarPublishLiveState(Entry, ExpectedState, NextState,
		RetireHandle := false) {
	global HOTKEY_REGISTRAR_BINDINGS

	Published := false
	PreviousCritical := Critical("On")
	try {
		Handle := Entry["handle"]
		if HOTKEY_REGISTRAR_BINDINGS.Has(Handle)
				&& (HOTKEY_REGISTRAR_BINDINGS[Handle] == Entry)
				&& _HotkeyRegistrarOwnsSpec(Entry)
				&& (Entry["state"] == ExpectedState) {
			Entry["state"] := NextState
			if RetireHandle
				HOTKEY_REGISTRAR_BINDINGS.Delete(Handle)
			Published := true
		}
	} finally {
		Critical(PreviousCritical)
	}
	return Published
}

/**
 * Releases a binding.
 * @param {String} handle A handle previously returned by HotkeyRegistrarBind.
 * @returns {Boolean} true if a live binding was released, false otherwise.
 */
HotkeyRegistrarUnbind(handle) {
	return _HotkeyRegistrarRetire(handle)
}

_HotkeyRegistrarRetire(handle, HotkeyFn := 0, HotIfFn := 0) {
	global HOTKEY_REGISTRAR_BINDINGS

	if (!IsSet(handle) || Type(handle) != "String") {
		; Not an error: teardown paths unbind defensively and a second call must
		; report "nothing to do" rather than raise mid-reload
		return false
	}

	Entry := 0
	PreviousState := 0
	TransitionState := 0
	RetiredWithoutNative := false
	PreviousCritical := Critical("On")
	try {
		if !HOTKEY_REGISTRAR_BINDINGS.Has(handle)
			return false
		Entry := HOTKEY_REGISTRAR_BINDINGS[handle]
		if !_HotkeyRegistrarOwnsSpec(Entry)
			return false
		Snapshot := Entry["state"]
		PreviousState := Snapshot
		Phase := Snapshot["phase"]
		if (Phase = "disabled" || Phase = "reserved") {
			Entry["state"] := _HotkeyRegistrarState("retired", 0, "off")
			HOTKEY_REGISTRAR_BINDINGS.Delete(handle)
			RetiredWithoutNative := true
		} else if (Phase = "active") {
			TransitionState := _HotkeyRegistrarState("retiring",
				Entry["callback"], "on")
			Entry["state"] := TransitionState
		} else {
			return false
		}
	} finally {
		Critical(PreviousCritical)
	}
	if RetiredWithoutNative {
		LoggerDebug("adapters.hotkey_registrar", "Released " . Entry["chord"] . " (" . handle . ").")
		return true
	}

	try _HotkeyRegistrarInvokeAction(Entry["spec"], "Off", HotkeyFn, HotIfFn)
	catch as Err {
		Restored := _HotkeyRegistrarPublishLiveState(Entry, TransitionState,
			PreviousState)
		_HotkeyRegistrarRequireState(Restored,
			"unbind(): could not restore the exact pre-call state for " . handle)
		LoggerWarn("adapters.hotkey_registrar", "unbind(): native Off refused '"
			. Entry["chord"] . "' without mutation: " . Err.Message . ".")
		return false
	}

	Published := _HotkeyRegistrarPublishLiveState(Entry, TransitionState,
		_HotkeyRegistrarState("retired", 0, "off"), true)
	_HotkeyRegistrarRequireState(Published,
		"unbind(): ownership changed after native Off for " . handle)
	LoggerDebug("adapters.hotkey_registrar", "Released " . Entry["chord"]
		. " (" . handle . ").")
	return true
}

/**
 * Suspends or resumes a binding without releasing it.
 * @param {String} handle A handle previously returned by HotkeyRegistrarBind.
 * @param {Boolean} enabled Desired state.
 * @returns {Boolean} true if the handle now holds the requested state.
 */
HotkeyRegistrarSetEnabled(handle, enabled) {
	return _HotkeyRegistrarSetEnabled(handle, enabled)
}

_HotkeyRegistrarSetEnabled(handle, enabled, HotkeyFn := 0, HotIfFn := 0) {
	global HOTKEY_REGISTRAR_BINDINGS

	if (!IsSet(handle) || Type(handle) != "String") {
		return false
	}
	want := enabled ? true : false
	Entry := 0
	PreviousState := 0
	TransitionState := 0
	PreviousCritical := Critical("On")
	try {
		if !HOTKEY_REGISTRAR_BINDINGS.Has(handle)
			return false
		Entry := HOTKEY_REGISTRAR_BINDINGS[handle]
		if !_HotkeyRegistrarOwnsSpec(Entry)
			return false
		PreviousState := Entry["state"]
		Phase := PreviousState["phase"]
		if ((Phase = "active" && want) || (Phase = "disabled" && !want))
			return true
		if (Phase != "active" && Phase != "disabled")
			return false
		; On is exception-atomic and native remains Off until it succeeds. Expose
		; callback authority first so the first interrupt after On cannot be lost.
		; For Off, retain prior authority until native suppression is gone.
		TransitionState := _HotkeyRegistrarState(want ? "enabling" : "disabling",
			Entry["callback"], PreviousState["native"])
		Entry["state"] := TransitionState
	} finally {
		Critical(PreviousCritical)
	}
	try _HotkeyRegistrarInvokeAction(Entry["spec"], want ? "On" : "Off",
		HotkeyFn, HotIfFn)
	catch as Err {
		Restored := _HotkeyRegistrarPublishLiveState(Entry, TransitionState,
			PreviousState)
		_HotkeyRegistrarRequireState(Restored,
			"setEnabled(): could not restore the exact pre-call state for " . handle)
		LoggerWarn("adapters.hotkey_registrar", "setEnabled(): native "
			. (want ? "On" : "Off") . " refused '" . Entry["chord"]
			. "' without mutation: " . Err.Message . ".")
		return false
	}

	NextState := want
		? _HotkeyRegistrarState("active", Entry["callback"], "on")
		: _HotkeyRegistrarState("disabled", 0, "off")
	Published := _HotkeyRegistrarPublishLiveState(Entry, TransitionState, NextState)
	_HotkeyRegistrarRequireState(Published,
		"setEnabled(): ownership changed after native "
		. (want ? "On" : "Off") . " for " . handle)
	LoggerDebug("adapters.hotkey_registrar", Entry["chord"] . " enabled="
		. (want ? "true" : "false") . ".")
	return true
}





; ================================
; ================================
; ======= 3/ Introspection =======
; ================================
; ================================

/**
 * Reports the canonical chord a handle is bound to.
 * Exists so the menu can label a binding without holding the chord string it
 * passed in, which may have been in any accepted spelling.
 * @param {String} handle
 * @returns {String} The canonical chord, or "" when the handle is unknown.
 */
HotkeyRegistrarChordOf(handle) {
	global HOTKEY_REGISTRAR_BINDINGS

	; Parse-time #HotIf helpers may query a retained binding during Bundle_Init's
	; first message pump, before this adapter's registry assignment executes.
	if (!IsSet(HOTKEY_REGISTRAR_BINDINGS)
			|| !IsSet(handle) || Type(handle) != "String")
		return ""
	Chord := ""
	PreviousCritical := Critical("On")
	try {
		; Has()+index must be one atomic snapshot: an unbind callback can otherwise
		; delete the handle after Has() and make the index operation throw.
		if HOTKEY_REGISTRAR_BINDINGS.Has(handle) {
			Entry := HOTKEY_REGISTRAR_BINDINGS[handle]
			Chord := Entry["chord"]
		}
	} finally {
		Critical(PreviousCritical)
	}
	return Chord
}

/**
 * Reports consumer-owned physical identity metadata captured with a handle.
 * The registrar deliberately does not derive this value later: AHK freezes a
 * hotkey's VK/SC interpretation when the native variant is created, while the
 * thread keyboard layout may subsequently change.
 * @param {String} handle
 * @returns {String} The immutable identity, or "" when absent/unknown.
 */
HotkeyRegistrarPhysicalIdentityOf(handle) {
	global HOTKEY_REGISTRAR_BINDINGS

	if (!IsSet(HOTKEY_REGISTRAR_BINDINGS)
			|| !IsSet(handle) || Type(handle) != "String")
		return ""
	Identity := ""
	PreviousCritical := Critical("On")
	try {
		if HOTKEY_REGISTRAR_BINDINGS.Has(handle) {
			Entry := HOTKEY_REGISTRAR_BINDINGS[handle]
			Candidate := Entry.Get("physical_identity", "")
			if Candidate is String
				Identity := Candidate
		}
	} finally Critical(PreviousCritical)
	return Identity
}

/**
 * Reports how many bindings this adapter currently holds.
 * A leak here is invisible in the UI — the hotkeys keep firing — so the count is
 * exposed for the suite to assert against after a stop/start cycle.
 * @returns {Integer}
 */
HotkeyRegistrarLiveCount() {
	global HOTKEY_REGISTRAR_BINDINGS

	PreviousCritical := Critical("On")
	try Count := HOTKEY_REGISTRAR_BINDINGS.Count
	finally Critical(PreviousCritical)
	return Count
}





; ====================================
; ====================================
; ======= 4/ Port Dispatch Map =======
; ====================================
; ====================================

; The dispatch map the port-compliance gate parses. Its keys must be exactly the
; contract's method names, which is what lets a rename in the spec fail here
; instead of at runtime on a user's machine
global ADAPTER_HOTKEY_REGISTRAR := Map(
	"bind", HotkeyRegistrarBind,
	"unbind", HotkeyRegistrarUnbind,
	"setEnabled", HotkeyRegistrarSetEnabled
)
