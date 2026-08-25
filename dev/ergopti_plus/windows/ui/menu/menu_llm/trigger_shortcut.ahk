; ui/menu/menu_llm/trigger_shortcut.ahk

; ==============================================================================
; MODULE: LLM Trigger Shortcut Transaction
; DESCRIPTION:
; Owns the one global LLM prediction shortcut through the shared registrar.
; Live edits reserve an inert native variant while the config writer owns the
; shared lease, activate it only after the candidate is durable, and retain
; every opaque handle when post-commit cleanup cannot prove it was released.
; ==============================================================================

#Requires AutoHotkey v2.0





; ========================================
; ========================================
; ======= 1/ State and Translation =======
; ========================================
; ========================================

global LLM_TRIGGER_STATUS_INACTIVE := "inactive"
global LLM_TRIGGER_STATUS_ACTIVE := "active"
global LLM_TRIGGER_STATUS_ERROR := "error"
global LLM_TRIGGER_STATUS_ROLLBACK_PENDING := "rollback_pending"
global LLM_TRIGGER_STATUS_CLEANUP_PENDING := "cleanup_pending"
global LLM_TRIGGER_WARNING_PREFIX := Chr(0x26A0) . " "
global LLM_TRIGGER_RECOVERY_DELAY_MS := 250
global LLM_TRIGGER_RECOVERY_MAX_DELAY_MS := 4000
global LLM_TRIGGER_RECOVERY_MAX_ATTEMPTS := 5

global _LLM_Menu_TriggerHandle := ""
global _LLM_Menu_TriggerAhk := ""
global _LLM_Menu_TriggerStatus := LLM_TRIGGER_STATUS_INACTIVE
global _LLM_Menu_TriggerRecoveryHandles := []
global _LLM_Menu_TriggerRecovery := false
global _LLM_Menu_TriggerRecoveryNextId := 0
global _LLM_Menu_TriggerFailureNoticeKey := ""

_LLM_Menu_TriggerKeyUsesNativeSyntax(Key) {
	if !(Key is String) || Key == ""
		return true
	; The shared chord grammar deliberately accepts physical VK/SC names for
	; low-level driver shortcuts. The LLM trigger cannot safely accept raw AHK
	; syntax: VK/SC aliases overlap named contextual variants, wildcard variants
	; cover additional modifiers, lateral modifier keys split one chord into two
	; actions, and an " Up" suffix adds a release action to the same physical
	; press. Keep that syntax out of this setting while leaving the shared
	; registrar contract unchanged.
	if RegExMatch(Key,
			"i)^(?:vk[0-9a-f]+(?:sc[0-9a-f]+)?|sc[0-9a-f]+)$")
		return true
	if RegExMatch(Key, "i)^(?:l|r)(?:ctrl|control|alt|shift|win)$")
		return true
	return RegExMatch(Key, "[\s*~$<>^!#&]") != 0
}

LLM_Menu_ShortcutToAhk(raw) {
	if (Type(raw) = "String" && Trim(raw) = "")
		return ""
	Parsed := ChordParse(raw)
	if !Parsed["ok"] {
		try LoggerWarn("LLM", "Rejected trigger shortcut '{1}': {2}.", raw,
			Parsed["err"])
		return ""
	}
	if _LLM_Menu_TriggerKeyUsesNativeSyntax(Parsed["key"]) {
		try LoggerWarn("LLM",
			"Rejected trigger shortcut '{1}': native AutoHotkey key syntax is not allowed.",
			raw)
		return ""
	}
	; Raw pointer observers own wildcard mouse-button and wheel variants, so every modified or
	; unmodified spelling overlaps their physical surface. A trigger variant would
	; eclipse activity tracking for that chord and must be rejected here.
	if RegExMatch(Parsed["key"],
			"i)^(?:[lrm]button|xbutton[12]|wheel(?:up|down|left|right))$") {
		try LoggerWarn("LLM",
			"Rejected trigger shortcut '{1}': the pointer key is reserved by the input dispatcher.",
			raw)
		return ""
	}
	Native := HotkeyRegistrarNativeSpec(Parsed["mods"], Parsed["key"])
	if (Native = "")
		try LoggerWarn("LLM",
			"Rejected trigger shortcut '{1}': a modifier has no Windows equivalent.", raw)
	return Native
}

LLM_Menu_IsValidModifierString(Raw) {
	if !(Raw is String)
		return false
	Value := Trim(Raw)
	if Value == ""
		return true
	for Token in StrSplit(Value, "+") {
		if Trim(Token) == ""
			return false
	}
	return LLM_Menu_ShortcutToAhk(Value . "+a") != ""
}

_LLM_Menu_ParseHotkeyNativeSpec(Spec) {
	if !(Spec is String)
		return false
	Raw := StrLower(Trim(Spec))
	if Raw == ""
		return false
	; HotIf receives the permanent name established by the first variant. Tilde
	; and hook-forcing dollar prefixes are variant properties, and modifier
	; symbols may be written in any order.
	Modifiers := Map()
	Wildcard := false
	KeyStart := 1
	Loop StrLen(Raw) {
		Ch := SubStr(Raw, A_Index, 1)
		if Ch == "<" || Ch == ">"
			return false
		if Ch == "~" || Ch == "$" {
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
	return Map("modifiers", Modifiers, "wildcard", Wildcard, "key", Key)
}

_LLM_Menu_HotkeyIdentityPrefix(Parsed) {
	if !(Parsed is Map) || !(Parsed.Get("modifiers", 0) is Map)
		return false
	Identity := Parsed.Get("wildcard", false) ? "*" : ""
	Modifiers := Parsed["modifiers"]
	for Prefix in ["^", "!", "+", "#"] {
		if Modifiers.Has(Prefix)
			Identity .= Prefix
	}
	return Identity
}

; Textual identity is intentionally retained for HotIf's permanent-name and
; per-plan lookup contract. Cross-owner admission uses the physical identity
; below because distinct character spellings can resolve to one native chord.
_LLM_Menu_HotkeyNativeIdentity(Spec) {
	Parsed := _LLM_Menu_ParseHotkeyNativeSpec(Spec)
	Prefix := _LLM_Menu_HotkeyIdentityPrefix(Parsed)
	if !(Prefix is String)
		return ""
	Key := Parsed["key"]
	if RegExMatch(Key, "^(vk|sc)([0-9a-f]+)$", &Match) {
		Code := Integer("0x" . Match[2])
		if Code <= 0 || (Match[1] == "vk" && Code > 0xFF)
				|| (Match[1] == "sc" && Code > 0x1FF)
			return ""
		Key := Match[1] == "vk" ? "vk" . Format("{:02x}", Code)
			: "sc" . Format("{:03x}", Code)
	}
	return Prefix . Key
}

_LLM_Menu_HotkeyKeyResolverSnapshot(KeyResolverFn := 0) {
	if HasMethod(KeyResolverFn, "Call")
		return KeyResolverFn
	return HotkeyRegistrarNativeKeyResolverSnapshot(
		KeyResolverFn is Map ? KeyResolverFn : 0)
}

_LLM_Menu_HotkeyResolvedDescriptor(Spec, KeyResolverFn := 0) {
	KeyResolverFn := _LLM_Menu_HotkeyKeyResolverSnapshot(KeyResolverFn)
	if !HasMethod(KeyResolverFn, "Call")
		return false
	Descriptor := HotkeyRegistrarResolvedNativeDescriptor(Spec, KeyResolverFn)
	return HotkeyRegistrarResolvedDescriptorIsValid(Descriptor)
		? Descriptor : false
}

_LLM_Menu_HotkeyPhysicalIdentity(Spec, KeyResolverFn := 0) {
	Descriptor := _LLM_Menu_HotkeyResolvedDescriptor(Spec, KeyResolverFn)
	return Descriptor is Map ? Descriptor["identity"] : ""
}

_LLM_Menu_HotkeyPhysicalIdentityIsValid(Identity) {
	if !(Identity is String)
		return false
	if !RegExMatch(Identity,
			"^\*?\^?!?\+?#?(vk|sc)([0-9A-F]{4})$", &Match)
		return false
	Code := Integer("0x" . Match[2])
	return Code > 0 && ((Match[1] == "vk" && Code <= 0xFF)
		|| (Match[1] == "sc" && Code <= 0x1FF))
}

; Compatibility name retained for the profile and navigation predicates.
_LLM_Menu_NavNativeIdentity(Spec) {
	return _LLM_Menu_HotkeyNativeIdentity(Spec)
}

_LLM_Menu_ContextualModifierSnapshot(MenuState := 0) {
	global _LLM_Menu
	if MenuState is Map
		Source := MenuState
	else if (MenuState is Integer) && MenuState == 0
		Source := _LLM_Menu
	else
		return false
	if !(Source is Map)
		return false
	PreviousCritical := Critical("On")
	try {
		NavModifiers := Source.Has("nav_modifiers")
			? Source["nav_modifiers"] : ""
		ValModifiers := Source.Has("val_modifiers")
			? Source["val_modifiers"] : "alt"
		return Map("nav_modifiers", NavModifiers,
			"val_modifiers", ValModifiers)
	} finally Critical(PreviousCritical)
}

_LLM_Menu_BuildNavModifierPrefixes(MenuState) {
	if !(MenuState is Map)
		return false
	if (MenuState.Has("nav_modifiers")
			&& !(MenuState["nav_modifiers"] is String))
		return false
	if (MenuState.Has("val_modifiers")
			&& !(MenuState["val_modifiers"] is String))
		return false
	NavModifiers := MenuState.Has("nav_modifiers")
		? Trim(MenuState["nav_modifiers"]) : ""
	ValModifiers := MenuState.Has("val_modifiers")
		? Trim(MenuState["val_modifiers"]) : "alt"
	if (!LLM_Menu_IsValidModifierString(NavModifiers)
			|| !LLM_Menu_IsValidModifierString(ValModifiers))
		return false

	NavPrefix := LLM_Menu_ShortcutToAhk(NavModifiers == ""
		? "a" : NavModifiers . "+a")
	ValPrefix := LLM_Menu_ShortcutToAhk(ValModifiers == ""
		? "a" : ValModifiers . "+a")
	if NavPrefix != ""
		NavPrefix := SubStr(NavPrefix, 1, -1)
	if ValPrefix != ""
		ValPrefix := SubStr(ValPrefix, 1, -1)
	if (NavModifiers != "" && NavPrefix == "")
			|| (ValModifiers != "" && ValPrefix == "")
		return false
	return Map("nav_prefix", NavPrefix, "val_prefix", ValPrefix)
}

_LLM_Menu_AddContextualHotkeyOwner(Owners, Spec, OwnerName,
		KeyResolverFn := 0) {
	Identity := _LLM_Menu_HotkeyPhysicalIdentity(Spec, KeyResolverFn)
	return _LLM_Menu_AddContextualPhysicalOwner(Owners, Identity, OwnerName)
}

_LLM_Menu_AddContextualPhysicalOwner(Owners, Identity, OwnerName) {
	if !(Owners is Map) || !_LLM_Menu_HotkeyPhysicalIdentityIsValid(Identity)
			|| !(OwnerName is String) || OwnerName == ""
		return false
	if Owners.Has(Identity) && Owners[Identity] != OwnerName
		Owners[Identity] .= " and " . OwnerName
	else
		Owners[Identity] := OwnerName
	return true
}

_LLM_Menu_AddPublishedPlanOwners(Owners, Plan, OwnerName, ExpectedLength) {
	if !(Plan is Array) || !(ExpectedLength is Integer)
			|| ExpectedLength < 1 || Plan.Length != ExpectedLength
		return false
	Loop Plan.Length {
		if !Plan.Has(A_Index)
			return false
		Entry := Plan[A_Index]
		if !_LLM_Menu_PlanEntryDescriptorIsValid(Entry)
			return false
		Identity := Entry.Get("physical_id", "")
		if !_LLM_Menu_AddContextualPhysicalOwner(Owners, Identity, OwnerName)
			return false
	}
	return true
}

_LLM_Menu_PlanEntryDescriptorIsValid(Entry) {
	if !(Entry is Map)
		return false
	Descriptor := Entry.Get("descriptor", 0)
	if !HotkeyRegistrarResolvedDescriptorIsValid(Descriptor)
		return false
	Spec := Entry.Get("spec", "")
	NativeSpec := Entry.Get("native_spec", "")
	NativeId := Entry.Get("native_id", "")
	PhysicalId := Entry.Get("physical_id", "")
	return Spec is String && Spec != ""
		&& Descriptor["logical_spec"] == StrLower(Spec)
		&& Descriptor["native_spec"] == NativeSpec
		&& Descriptor["identity"] == PhysicalId
		&& NativeId != ""
		&& NativeId == _LLM_Menu_NavNativeIdentity(NativeSpec)
}

_LLM_Menu_ContextualPublishedOwnerSnapshot() {
	global _LLM_Menu_ProfileHotkeyOwner
	global _LLM_Menu_NavHotkeysBound, _LLM_Menu_NavActiveSlot
	PreviousCritical := Critical("On")
	try {
		ProfileOwner := _LLM_Menu_ProfileHotkeyOwner
		NavPlan := _LLM_Menu_NavHotkeysBound
		NavSlot := _LLM_Menu_NavActiveSlot
	} finally Critical(PreviousCritical)

	ProfilePublished := false
	ProfilePlan := 0
	if ProfileOwner is Map {
		Ready := ProfileOwner.Get("ready", false)
		Degraded := ProfileOwner.Get("degraded", false)
		if ((Ready is Integer) && Ready == 1
				&& (Degraded is Integer) && Degraded == 0) {
			ProfilePublished := true
			ProfilePlan := ProfileOwner.Get("plan", 0)
		}
	}
	NavPublished := (NavSlot == 1 || NavSlot == 2)
		&& (NavPlan is Array) && NavPlan.Length > 0
	return Map(
		"profile_published", ProfilePublished,
		"profile_plan", ProfilePlan,
		"nav_published", NavPublished,
		"nav_plan", NavPlan)
}

_LLM_Menu_AttachPlanPhysicalIdentities(Plan, KeyResolverFn := 0) {
	if !(Plan is Array)
		return false
	KeyResolverFn := _LLM_Menu_HotkeyKeyResolverSnapshot(KeyResolverFn)
	if !HasMethod(KeyResolverFn, "Call")
		return false
	Staged := []
	SeenNative := Map()
	SeenPhysical := Map()
	Loop Plan.Length {
		if !Plan.Has(A_Index)
			return false
		Entry := Plan[A_Index]
		if !(Entry is Map)
			return false
		Descriptor := _LLM_Menu_HotkeyResolvedDescriptor(
			Entry.Get("spec", ""), KeyResolverFn)
		if !(Descriptor is Map)
			return false
		NativeId := _LLM_Menu_HotkeyNativeIdentity(
			Descriptor["native_spec"])
		PhysicalId := Descriptor["identity"]
		if NativeId == "" || SeenNative.Has(NativeId)
				|| SeenPhysical.Has(PhysicalId)
			return false
		SeenNative[NativeId] := true
		SeenPhysical[PhysicalId] := true
		Staged.Push(Map("entry", Entry, "physical_id", PhysicalId,
			"native_spec", Descriptor["native_spec"],
			"native_id", NativeId, "descriptor", Descriptor))
	}
	for Item in Staged {
		Entry := Item["entry"]
		Entry["physical_id"] := Item["physical_id"]
		Entry["native_spec"] := Item["native_spec"]
		Entry["native_id"] := Item["native_id"]
		Entry["descriptor"] := Item["descriptor"]
	}
	return true
}

_LLM_Menu_BuildContextualHotkeyOwners(MenuState, KeyResolverFn := 0) {
	KeyResolverFn := _LLM_Menu_HotkeyKeyResolverSnapshot(KeyResolverFn)
	if !HasMethod(KeyResolverFn, "Call")
		return false
	Published := _LLM_Menu_ContextualPublishedOwnerSnapshot()
	Owners := Map()
	if !_LLM_Menu_AddContextualHotkeyOwner(Owners, "Tab",
			"tooltip acceptance", KeyResolverFn)
		return false
	; The contextual profile surface is a fixed Ctrl+1..9 contract. Deriving it
	; from currently available profiles would let a later CRUD action introduce
	; a collision that the global trigger had already claimed.
	if Published["profile_published"] {
		if !_LLM_Menu_AddPublishedPlanOwners(Owners,
				Published["profile_plan"], "profile selection", 9)
			return false
	} else {
		Loop 9 {
			if !_LLM_Menu_AddContextualHotkeyOwner(Owners, "^" . A_Index,
					"profile selection", KeyResolverFn)
				return false
		}
	}
	if Published["nav_published"] {
		if !_LLM_Menu_AddPublishedPlanOwners(Owners,
				Published["nav_plan"], "prediction navigation", 12)
			return false
	} else {
		Prefixes := _LLM_Menu_BuildNavModifierPrefixes(MenuState)
		if !(Prefixes is Map)
			return false
		NavPrefix := Prefixes["nav_prefix"]
		ValPrefix := Prefixes["val_prefix"]
		for Spec in ["~" . NavPrefix . "Up", "~" . NavPrefix . "Down"] {
			if !_LLM_Menu_AddContextualHotkeyOwner(Owners, Spec,
					"prediction navigation", KeyResolverFn)
				return false
		}
		Loop 10 {
			Digit := A_Index == 10 ? "0" : String(A_Index)
			if !_LLM_Menu_AddContextualHotkeyOwner(Owners, ValPrefix . Digit,
					"prediction navigation", KeyResolverFn)
				return false
		}
	}
	return Owners
}

_LLM_Menu_CheckTriggerContextCollision(TriggerAhk, MenuState,
		KeyResolverFn := 0, CapturedIdentity := "") {
	if !(TriggerAhk is String)
		return Map("ok", false, "identity", "", "owner", "",
			"descriptor", false)
	if TriggerAhk == ""
		return Map("ok", true, "identity", "", "owner", "",
			"descriptor", false)
	KeyResolverFn := _LLM_Menu_HotkeyKeyResolverSnapshot(KeyResolverFn)
	if !HasMethod(KeyResolverFn, "Call")
		return Map("ok", false, "identity", "", "owner", "",
			"descriptor", false)
	if !(CapturedIdentity is String)
		return Map("ok", false, "identity", "", "owner", "",
			"descriptor", false)
	Descriptor := false
	if CapturedIdentity != ""
		Identity := CapturedIdentity
	else {
		Descriptor := _LLM_Menu_HotkeyResolvedDescriptor(TriggerAhk,
			KeyResolverFn)
		Identity := Descriptor is Map ? Descriptor["identity"] : ""
	}
	Owners := _LLM_Menu_BuildContextualHotkeyOwners(MenuState, KeyResolverFn)
	if !_LLM_Menu_HotkeyPhysicalIdentityIsValid(Identity) || !(Owners is Map)
		return Map("ok", false, "identity", Identity, "owner", "",
			"descriptor", Descriptor)
	return Map("ok", true, "identity", Identity,
		"owner", Owners.Get(Identity, ""), "descriptor", Descriptor)
}

_LLM_Menu_RuntimeTriggerNativeIdentities() {
	global _LLM_Menu_TriggerHandle, _LLM_Menu_TriggerAhk
	global _LLM_Menu_TriggerRecoveryHandles
	PreviousCritical := Critical("On")
	try {
		PrimaryHandle := _LLM_Menu_TriggerHandle
		PrimaryAhk := _LLM_Menu_TriggerAhk
		if !(_LLM_Menu_TriggerRecoveryHandles is Array)
			return false
		RecoveryHandles := _LLM_Menu_TriggerRecoveryHandles.Clone()
	} finally Critical(PreviousCritical)
	Identities := Map()
	if !(PrimaryAhk is String)
		return false
	if PrimaryAhk != "" {
		if !(PrimaryHandle is String) || PrimaryHandle == ""
			return false
		PrimaryIdentity := HotkeyRegistrarPhysicalIdentityOf(PrimaryHandle)
		if !_LLM_Menu_HotkeyPhysicalIdentityIsValid(PrimaryIdentity)
			return false
		Identities[PrimaryIdentity] := true
	} else if PrimaryHandle != "" {
		return false
	}
	for Handle in RecoveryHandles {
		Identity := HotkeyRegistrarPhysicalIdentityOf(Handle)
		if !_LLM_Menu_HotkeyPhysicalIdentityIsValid(Identity)
			return false
		Identities[Identity] := true
	}
	return Identities
}

_LLM_Menu_RuntimeTriggerPlanCollision(CandidatePlan, KeyResolverFn := 0) {
	if !(CandidatePlan is Array)
		return Map("ok", false, "identity", "")
	KeyResolverFn := _LLM_Menu_HotkeyKeyResolverSnapshot(KeyResolverFn)
	if !HasMethod(KeyResolverFn, "Call")
		return Map("ok", false, "identity", "")
	if !_LLM_Menu_AttachPlanPhysicalIdentities(CandidatePlan, KeyResolverFn)
		return Map("ok", false, "identity", "")
	TriggerIdentities := _LLM_Menu_RuntimeTriggerNativeIdentities()
	if !(TriggerIdentities is Map)
		return Map("ok", false, "identity", "")
	for Entry in CandidatePlan {
		if !(Entry is Map)
			return Map("ok", false, "identity", "")
		Identity := Entry.Get("physical_id", "")
		if !_LLM_Menu_HotkeyPhysicalIdentityIsValid(Identity)
			return Map("ok", false, "identity", "")
		if TriggerIdentities.Has(Identity)
			return Map("ok", true, "identity", Identity)
	}
	return Map("ok", true, "identity", "")
}

_LLM_Menu_RuntimeTriggerNavCollision(CandidatePlan, KeyResolverFn := 0) {
	return _LLM_Menu_RuntimeTriggerPlanCollision(CandidatePlan, KeyResolverFn)
}

_LLM_Menu_TriggerCallback(CallbackFn := 0) {
	if HasMethod(CallbackFn, "Call")
		return CallbackFn
	; In AHK v2 Func is the native class, not a name-lookup helper. Calling
	; Func("name") raises ValueError "Invalid base" during boot replay and makes
	; the tray-root coordinator retry forever. The declaration is available
	; across the complete include graph, so return its function object directly.
	return _LLM_Menu_InvokeTriggerPrediction.Bind()
}

_LLM_Menu_InvokeTriggerPrediction(Args*) {
	return LLM_Menu_TriggerPrediction(Args*)
}

_LLM_Menu_ReportTriggerFailure(raw, Stage, Detail) {
	try LoggerError("LLM",
		"Could not {1} trigger shortcut '{2}': {3}.", Stage, raw, Detail)
}

_LLM_Menu_NotifyTriggerApplyFailure(RawText, NotifyFn := 0) {
	global _LLM_Menu_TriggerStatus, _LLM_Menu_TriggerFailureNoticeKey
	NoticeKey := RawText . "|" . _LLM_Menu_TriggerStatus
	PreviousCritical := Critical("On")
	try {
		if (_LLM_Menu_TriggerFailureNoticeKey = NoticeKey)
			return false
		_LLM_Menu_TriggerFailureNoticeKey := NoticeKey
	} finally Critical(PreviousCritical)
	try {
		RawLabel := RawText != "" ? RawText : t("common.none")
		Message := Format(t("metrics.shortcut_register_error"), RawLabel,
			t("common.error_title"))
		Options := Map("title", t("menu.llm.trigger_shortcut_title"),
			"level", "warning")
		if HasMethod(NotifyFn, "Call")
			Delivered := NotifyFn.Call(Message, Options)
		else
			Delivered := NotifierSend(Message, Options)
		if !((Delivered is Integer) && Delivered == 1) {
			PreviousCritical := Critical("On")
			try {
				if (_LLM_Menu_TriggerFailureNoticeKey = NoticeKey)
					_LLM_Menu_TriggerFailureNoticeKey := ""
			} finally Critical(PreviousCritical)
			try LoggerError("LLM",
				"Trigger shortcut failure notification was refused or returned a malformed status.")
		}
	} catch as Err {
		PreviousCritical := Critical("On")
		try {
			if (_LLM_Menu_TriggerFailureNoticeKey = NoticeKey)
				_LLM_Menu_TriggerFailureNoticeKey := ""
		} finally Critical(PreviousCritical)
		try LoggerError("LLM",
			"Could not surface incomplete trigger shortcut activation: {1}.",
			Err.Message)
	}
	return false
}

_LLM_Menu_TriggerStatusForAhk(Ahk) {
	global LLM_TRIGGER_STATUS_INACTIVE, LLM_TRIGGER_STATUS_ACTIVE
	return (Ahk = "") ? LLM_TRIGGER_STATUS_INACTIVE : LLM_TRIGGER_STATUS_ACTIVE
}

_LLM_Menu_AppendTriggerRecovery(State, Handle) {
	if (Handle = "")
		return false
	for Existing in State["recovery_handles"] {
		if (Existing = Handle)
			return false
	}
	State["recovery_handles"].Push(Handle)
	return true
}

_LLM_Menu_TriggerRecoveryPending() {
	global _LLM_Menu_TriggerRecoveryHandles, _LLM_Menu_TriggerRecovery
	global _LLM_Menu_TriggerStatus
	global LLM_TRIGGER_STATUS_ROLLBACK_PENDING
	global LLM_TRIGGER_STATUS_CLEANUP_PENDING
	PreviousCritical := Critical("On")
	try return (_LLM_Menu_TriggerRecovery is Map)
		|| _LLM_Menu_TriggerRecoveryHandles.Length > 0
		|| _LLM_Menu_TriggerStatus = LLM_TRIGGER_STATUS_ROLLBACK_PENDING
		|| _LLM_Menu_TriggerStatus = LLM_TRIGGER_STATUS_CLEANUP_PENDING
	finally Critical(PreviousCritical)
}

LLM_Menu_TriggerNeedsAttention() {
	global _LLM_Menu_TriggerStatus, _LLM_Menu_TriggerRecoveryHandles
	global _LLM_Menu_TriggerRecovery
	global LLM_TRIGGER_STATUS_ERROR, LLM_TRIGGER_STATUS_ROLLBACK_PENDING
	global LLM_TRIGGER_STATUS_CLEANUP_PENDING
	PreviousCritical := Critical("On")
	try return (_LLM_Menu_TriggerRecovery is Map)
		|| _LLM_Menu_TriggerRecoveryHandles.Length > 0
		|| _LLM_Menu_TriggerStatus = LLM_TRIGGER_STATUS_ERROR
		|| _LLM_Menu_TriggerStatus = LLM_TRIGGER_STATUS_ROLLBACK_PENDING
		|| _LLM_Menu_TriggerStatus = LLM_TRIGGER_STATUS_CLEANUP_PENDING
		|| LLM_TriggerJournalIsReadOnly()
	finally Critical(PreviousCritical)
}

LLM_Menu_TriggerDisplayValue() {
	global _LLM_Menu, _LLM_Menu_TriggerStatus, _LLM_Menu_TriggerRecoveryHandles
	global _LLM_Menu_TriggerRecovery
	global LLM_TRIGGER_STATUS_ERROR, LLM_TRIGGER_STATUS_ROLLBACK_PENDING
	global LLM_TRIGGER_STATUS_CLEANUP_PENDING, LLM_TRIGGER_WARNING_PREFIX
	PreviousCritical := Critical("On")
	try {
		RawText := _LLM_Menu["trigger_shortcut"]
		NeedsAttention := (_LLM_Menu_TriggerRecovery is Map)
			|| _LLM_Menu_TriggerRecoveryHandles.Length > 0
			|| _LLM_Menu_TriggerStatus = LLM_TRIGGER_STATUS_ERROR
			|| _LLM_Menu_TriggerStatus = LLM_TRIGGER_STATUS_ROLLBACK_PENDING
			|| _LLM_Menu_TriggerStatus = LLM_TRIGGER_STATUS_CLEANUP_PENDING
			|| LLM_TriggerJournalIsReadOnly()
	} finally Critical(PreviousCritical)
	Display := (RawText = "") ? t("common.none") : RawText
	return NeedsAttention ? LLM_TRIGGER_WARNING_PREFIX . Display : Display
}

_LLM_Menu_PublishTriggerRecovery(Status, RecoveryHandles) {
	global _LLM_Menu_TriggerStatus, _LLM_Menu_TriggerRecoveryHandles
	PreviousCritical := Critical("On")
	try {
		_LLM_Menu_TriggerStatus := Status
		_LLM_Menu_TriggerRecoveryHandles := RecoveryHandles
	} finally Critical(PreviousCritical)
}





; =======================================
; =======================================
; ======= 2/ Recovery Coordinator =======
; =======================================
; =======================================

_LLM_Menu_InstallTriggerRecovery(Stage, State, WriterFn, HotkeyFn,
		SchedulerFn, RefreshFn) {
	global _LLM_Menu_TriggerRecovery, _LLM_Menu_TriggerRecoveryNextId
	global ConfigurationFile
	Path := (IsSet(ConfigurationFile) && ConfigurationFile != "")
		? ConfigurationFile : ""
	AlreadyOwned := false
	PreviousCritical := Critical("On")
	try {
		if (_LLM_Menu_TriggerRecovery is Map) {
			AlreadyOwned := true
		} else {
			_LLM_Menu_TriggerRecoveryNextId += 1
			Record := Map(
				"id", _LLM_Menu_TriggerRecoveryNextId,
				"stage", Stage,
				"old_string", State["old_string"],
				"path", Path,
				"handles", State["recovery_handles"],
				"writer", WriterFn,
				"hotkey", HotkeyFn,
				"scheduler", SchedulerFn,
				"refresh", RefreshFn,
				"journal_port", State.Get("journal_port", 0),
				"journal_read", State.Get("journal_read", 0),
				"journal_path", State.Get("journal_path", ""),
				"journal_record", State.Get("journal_record", false),
				"complete_status", State.Get("recovery_complete_status", ""),
				"attempts", 0,
				"exhausted_reported", false,
				"scheduled", false,
				"running", false)
			_LLM_Menu_TriggerRecovery := Record
		}
	} finally Critical(PreviousCritical)
	if AlreadyOwned {
		try LoggerError("LLM",
			"Could not retain trigger shortcut recovery: another record is still authoritative.")
		return false
	}
	; The record is the recovery guarantee; the timer is only a bounded wake-up.
	; A scheduling refusal must not make the gateway discard already-retained
	; handles or durable rollback state. The next user edit retries synchronously.
	_LLM_Menu_ScheduleTriggerRecovery(Record)
	return true
}

_LLM_Menu_ScheduleTriggerRecovery(Record) {
	global _LLM_Menu_TriggerRecovery, LLM_TRIGGER_RECOVERY_DELAY_MS
	global LLM_TRIGGER_RECOVERY_MAX_DELAY_MS
	global LLM_TRIGGER_RECOVERY_MAX_ATTEMPTS
	Exhausted := false
	ReportExhausted := false
	PreviousCritical := Critical("On")
	try {
		if !(_LLM_Menu_TriggerRecovery is Map)
				|| (_LLM_Menu_TriggerRecovery != Record)
				|| Record["scheduled"] || Record["running"]
			return true
		if (Record["attempts"] >= LLM_TRIGGER_RECOVERY_MAX_ATTEMPTS) {
			Exhausted := true
			if !Record["exhausted_reported"] {
				Record["exhausted_reported"] := true
				ReportExhausted := true
			}
		} else {
			Record["attempts"] += 1
			Attempt := Record["attempts"]
			Record["scheduled"] := true
		}
	} finally Critical(PreviousCritical)
	if Exhausted {
		if ReportExhausted
			try LoggerError("LLM",
				"Trigger shortcut automatic recovery exhausted after {1} attempts; the next user edit will retry.",
				LLM_TRIGGER_RECOVERY_MAX_ATTEMPTS)
		return false
	}
	DelayMs := Min(LLM_TRIGGER_RECOVERY_DELAY_MS * (2 ** (Attempt - 1)),
		LLM_TRIGGER_RECOVERY_MAX_DELAY_MS)
	Callback := LLM_Menu_RunTriggerRecovery.Bind(Record["id"])
	try {
		SchedulerFn := Record["scheduler"]
		if HasMethod(SchedulerFn, "Call")
			Scheduled := SchedulerFn.Call(Callback, DelayMs)
		else {
			SetTimer(Callback, -DelayMs)
			Scheduled := true
		}
	} catch as Err {
		PreviousCritical := Critical("On")
		try {
			if (_LLM_Menu_TriggerRecovery is Map)
					&& (_LLM_Menu_TriggerRecovery == Record)
				Record["scheduled"] := false
		} finally Critical(PreviousCritical)
		try LoggerError("LLM", "Could not schedule trigger shortcut recovery: {1}.",
			Err.Message)
		return false
	}
	if !((Scheduled is Integer) && Scheduled == 1) {
		PreviousCritical := Critical("On")
		try {
			if (_LLM_Menu_TriggerRecovery is Map)
					&& (_LLM_Menu_TriggerRecovery == Record)
				Record["scheduled"] := false
		} finally Critical(PreviousCritical)
		try LoggerError("LLM", "Trigger shortcut recovery scheduling was refused.")
		return false
	}
	return true
}

_LLM_Menu_ClaimTriggerRecovery(ExpectedId, RequireScheduled) {
	global _LLM_Menu_TriggerRecovery
	PreviousCritical := Critical("On")
	try {
		if !(_LLM_Menu_TriggerRecovery is Map)
			return false
		Record := _LLM_Menu_TriggerRecovery
		if (ExpectedId != 0 && Record["id"] != ExpectedId)
			return false
		if Record["running"] || (Record["scheduled"] != RequireScheduled)
			return false
		Record["scheduled"] := false
		Record["running"] := true
		return Record
	} finally Critical(PreviousCritical)
}

_LLM_Menu_ReleaseTriggerRecoveryClaim(Record) {
	global _LLM_Menu_TriggerRecovery
	PreviousCritical := Critical("On")
	try {
		if !(_LLM_Menu_TriggerRecovery is Map)
				|| (_LLM_Menu_TriggerRecovery != Record)
			return false
		Record["running"] := false
		return true
	} finally Critical(PreviousCritical)
}

_LLM_Menu_CompleteTriggerRecovery(Record) {
	global _LLM_Menu_TriggerRecovery, _LLM_Menu_TriggerAhk
	global _LLM_Menu_TriggerStatus, _LLM_Menu_TriggerRecoveryHandles
	global _LLM_Menu_TriggerFailureNoticeKey, LLM_TRIGGER_STATUS_ERROR
	PreviousCritical := Critical("On")
	try {
		if !(_LLM_Menu_TriggerRecovery is Map)
				|| (_LLM_Menu_TriggerRecovery != Record)
			return false
		_LLM_Menu_TriggerRecovery := false
		TerminalStatus := Record["complete_status"] != ""
			? Record["complete_status"]
			: _LLM_Menu_TriggerStatusForAhk(_LLM_Menu_TriggerAhk)
		_LLM_Menu_TriggerStatus := TerminalStatus
		_LLM_Menu_TriggerRecoveryHandles := []
		if (TerminalStatus != LLM_TRIGGER_STATUS_ERROR)
			_LLM_Menu_TriggerFailureNoticeKey := ""
		return true
	} finally Critical(PreviousCritical)
}

_LLM_Menu_UpdateTriggerRecoveryHandles(Record, RemainingHandles) {
	global _LLM_Menu_TriggerRecovery, _LLM_Menu_TriggerRecoveryHandles
	PreviousCritical := Critical("On")
	try {
		if !(_LLM_Menu_TriggerRecovery is Map)
				|| (_LLM_Menu_TriggerRecovery != Record)
			return false
		Record["handles"] := RemainingHandles
		_LLM_Menu_TriggerRecoveryHandles := RemainingHandles
		return true
	} finally Critical(PreviousCritical)
}

_LLM_Menu_RetireTriggerRecoveryHandles(Record) {
	Remaining := []
	for Handle in Record["handles"] {
		Retired := _HotkeyRegistrarRetire(Handle, Record["hotkey"])
		; Another owner may already have completed a stale handle before this
		; retry. An absent token is terminal; a still-known token whose native
		; Off was refused must remain explicit for the next attempt.
		if !Retired && HotkeyRegistrarChordOf(Handle) != ""
			Remaining.Push(Handle)
	}
	return Remaining
}

; The timer is the post-lease handoff, never the owner. Every attempt reacquires
; config.toml before touching recovery state, so a user edit and a retry cannot
; both advance the same record. A failed attempt remains visible and is rearmed
LLM_Menu_RunTriggerRecovery(ExpectedId := 0) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return LLM_Menu_RunTriggerRecovery(ExpectedId)
		finally Critical(InheritedCritical)
	}
	Record := _LLM_Menu_ClaimTriggerRecovery(ExpectedId, true)
	if !(Record is Map)
		return false
	return _LLM_Menu_RunClaimedTriggerRecovery(Record)
}

_LLM_Menu_RunClaimedTriggerRecovery(Record) {
	; Native Suspend does not stop SetTimer. Leave the retained record unarmed;
	; the lifecycle resume reactor transfers it to exactly one fresh owner.
	if A_IsSuspended {
		_LLM_Menu_ReleaseTriggerRecoveryClaim(Record)
		return false
	}
	Path := Record["path"]
	if (Path = "") {
		_LLM_Menu_ReleaseTriggerRecoveryClaim(Record)
		_LLM_Menu_ScheduleTriggerRecovery(Record)
		return false
	}
	OwnerToken := _ConfigWriteLeaseTryAcquire(Path,
		"llm-trigger-recovery")
	if !(OwnerToken is Object) {
		_LLM_Menu_ReleaseTriggerRecoveryClaim(Record)
		_LLM_Menu_ScheduleTriggerRecovery(Record)
		return false
	}
	try Completed := _LLM_Menu_AdvanceClaimedTriggerRecovery(Record,
		OwnerToken)
	finally _ConfigWriteLeaseRelease(OwnerToken)
	if Completed {
		try {
			RefreshFn := Record["refresh"]
			if HasMethod(RefreshFn, "Call")
				RefreshFn.Call()
			else
				LLM_Menu_RequestBuild("trigger_recovery")
		} catch as Err {
			try LoggerError("LLM", "Could not refresh the recovered trigger shortcut row: {1}.",
				Err.Message)
		}
	} else {
		_LLM_Menu_ReleaseTriggerRecoveryClaim(Record)
		_LLM_Menu_ScheduleTriggerRecovery(Record)
	}
	return Completed
}

; Advances a claimed recovery under a caller-owned config lease. Native
; candidates are always retired before old durable authority is restored: a
; FileOpen/COM yield inside the writer must never expose a rejected native-On
; callback whose config has already rolled back.
_LLM_Menu_AdvanceClaimedTriggerRecovery(Record, OwnerToken) {
	Path := Record["path"]
	if (Path = "") || !_ConfigWriteLeaseOwns(OwnerToken, Path)
		return false
	Completed := false
	try {
		if (Record["stage"] = "cleanup") {
			Remaining := _LLM_Menu_RetireTriggerRecoveryHandles(Record)
			if (Remaining.Length = 0)
				Completed := _LLM_Menu_CompleteTriggerRecovery(Record)
			else
				_LLM_Menu_UpdateTriggerRecoveryHandles(Record, Remaining)
		} else if (Record["stage"] = "rollback") {
			; rollback_failed can retain an activated candidate when its native-Off
			; compensation was refused. Quiesce it before the reverse write.
			Remaining := _LLM_Menu_RetireTriggerRecoveryHandles(Record)
			if (Remaining.Length = 0) {
				Updates := [{ Section: "llm", Key: "trigger_shortcut",
					Value: Record["old_string"] }]
				FailureDetail := ""
				if _ConfigInvokeCommitWriter(Path, Updates, Record["writer"],
						"the trigger recovery writer", &FailureDetail)
					Completed := _LLM_Menu_CompleteTriggerRecovery(Record)
				else
					try LoggerError("LLM", "Trigger shortcut rollback recovery failed: {1}.",
						FailureDetail)
			} else
				_LLM_Menu_UpdateTriggerRecoveryHandles(Record, Remaining)
		} else if (Record["stage"] = "journal") {
			Remaining := _LLM_Menu_RetireTriggerRecoveryHandles(Record)
			if (Remaining.Length = 0) {
				if LLM_TriggerJournalReconcile(Record["journal_port"],
						Record["journal_read"], Record["writer"],
						Record["journal_path"], OwnerToken)
					Completed := _LLM_Menu_CompleteTriggerRecovery(Record)
			} else
				_LLM_Menu_UpdateTriggerRecoveryHandles(Record, Remaining)
		} else if (Record["stage"] = "journal_rollback") {
			; committed_new is durable but the synchronous old write failed. Do
			; not let ordinary reconciliation accept new: this recovery explicitly
			; owes the user the old authority after all native handles are quiescent.
			Remaining := _LLM_Menu_RetireTriggerRecoveryHandles(Record)
			if (Remaining.Length = 0) {
				JournalRecord := Record["journal_record"]
				if (JournalRecord is Map)
						&& _LLM_TriggerJournalRollback(JournalRecord,
							Record["journal_port"], Record["journal_read"],
							Record["writer"], Record["journal_path"])
						&& LLM_TriggerJournalReconcile(Record["journal_port"],
							Record["journal_read"], Record["writer"],
							Record["journal_path"], OwnerToken)
					Completed := _LLM_Menu_CompleteTriggerRecovery(Record)
			} else
				_LLM_Menu_UpdateTriggerRecoveryHandles(Record, Remaining)
		} else {
			try LoggerError("LLM", "Unknown trigger shortcut recovery stage '{1}'.",
				Record["stage"])
		}
	} catch as Err {
		try LoggerError("LLM",
			"Trigger shortcut recovery attempt raised: {1}.", Err.Message)
	}
	return Completed
}

; Lifecycle transitions must settle both native and durable trigger authority.
; Calling the raw journal reconciler is insufficient when compensation retained
; a native-On candidate. The caller may lend an existing config owner so the
; quiescence, path relocation/reset and Reload remain one indivisible sequence.
LLM_Menu_QuiesceTriggerForLifecycle(ExistingOwners := 0, Port := 0,
		ReadTriggerFn := 0, WriterFn := 0, ExplicitPath := "",
		AllowReadOnlyJournal := false) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return LLM_Menu_QuiesceTriggerForLifecycle(ExistingOwners, Port,
			ReadTriggerFn, WriterFn, ExplicitPath, AllowReadOnlyJournal)
		finally Critical(InheritedCritical)
	}
	global ConfigurationFile
	if !IsSet(ConfigurationFile)
		return false
	OwnBundle := false
	OwnerBundle := ExistingOwners
	if !(OwnerBundle is Object) {
		OwnerBundle := LLM_Menu_AcquireLifecycleBundle(0, Port,
			ExplicitPath)
		OwnBundle := OwnerBundle is Object
	}
	if !(OwnerBundle is Object)
		return false
	CurrentOwner := _ConfigWriteLeaseSelectOwner(OwnerBundle,
		ConfigurationFile)
	if !(CurrentOwner is Object) {
		if OwnBundle
			_ConfigWriteTerminalRelease(OwnerBundle)
		return false
	}
	try {
		Record := _LLM_Menu_ClaimTriggerRecovery(0, true)
		if !(Record is Map)
			Record := _LLM_Menu_ClaimTriggerRecovery(0, false)
		if !(Record is Map) {
			; A running record or orphaned recovery projection is authoritative;
			; never reconcile the WAL behind its native state.
			if _LLM_Menu_TriggerRecoveryPending()
				return false
			if AllowReadOnlyJournal
				return LLM_TriggerJournalDrainForShutdown(Port, ReadTriggerFn,
					WriterFn, ExplicitPath, OwnerBundle)
			return LLM_TriggerJournalReconcile(Port, ReadTriggerFn,
				WriterFn, ExplicitPath, OwnerBundle)
		}
		RecoveryOwner := _ConfigWriteLeaseSelectOwner(OwnerBundle,
			Record["path"])
		if !(RecoveryOwner is Object) {
			_LLM_Menu_ReleaseTriggerRecoveryClaim(Record)
			_LLM_Menu_ScheduleTriggerRecovery(Record)
			return false
		}
		Completed := _LLM_Menu_AdvanceClaimedTriggerRecovery(Record,
			RecoveryOwner)
		if !Completed {
			_LLM_Menu_ReleaseTriggerRecoveryClaim(Record)
			_LLM_Menu_ScheduleTriggerRecovery(Record)
			return false
		}
		; Cleanup/rollback records normally have no WAL, but a stable record is
		; still authoritative if a prior fault crossed both recovery layers.
		if AllowReadOnlyJournal
			return LLM_TriggerJournalDrainForShutdown(Port, ReadTriggerFn,
				WriterFn, ExplicitPath, OwnerBundle)
		return LLM_TriggerJournalReconcile(Port, ReadTriggerFn,
			WriterFn, ExplicitPath, OwnerBundle)
	} finally {
		if OwnBundle
			_ConfigWriteTerminalRelease(OwnerBundle)
	}
}

; Builds the complete dry terminal barrier required by an ordinary reload or
; exit. It includes current config authority, a stable WAL owner from a prior
; relocation, and any RAM recovery record path. The bundle acquisition itself
; rechecks that no writer owns any path and globally blocks sibling-path writes.
LLM_Menu_AcquireLifecycleBundle(AdditionalPaths := 0, Port := 0,
		ExplicitPath := "") {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return LLM_Menu_AcquireLifecycleBundle(AdditionalPaths, Port,
			ExplicitPath)
		finally Critical(InheritedCritical)
	}
	global ConfigurationFile, _LLM_Menu_TriggerRecovery
	; Lifecycle persistence is unavailable during Bundle_Init's parse-time
	; #HotIf message pump; fail closed before touching either late global.
	if !IsSet(ConfigurationFile) || !IsSet(_LLM_Menu_TriggerRecovery)
		return false
	Paths := [ConfigurationFile]
	JournalOwner := LLM_TriggerJournalOwnerHint(Port, ExplicitPath)
	if (JournalOwner is String) && JournalOwner != ""
		Paths.Push(JournalOwner)
	else if !(JournalOwner is String)
		return false
	PreviousCritical := Critical("On")
	try {
		if (_LLM_Menu_TriggerRecovery is Map)
				&& _LLM_Menu_TriggerRecovery["path"] != ""
			Paths.Push(_LLM_Menu_TriggerRecovery["path"])
	} finally Critical(PreviousCritical)
	if (AdditionalPaths is Array) {
		for Path in AdditionalPaths
			Paths.Push(Path)
	} else if (AdditionalPaths is String) && AdditionalPaths != "" {
		Paths.Push(AdditionalPaths)
	} else if !((AdditionalPaths is Integer) && AdditionalPaths == 0) {
		return false
	}
	return _ConfigWriteTerminalTryAcquire(Paths)
}

LLM_Menu_ServiceTriggerRecovery() {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return LLM_Menu_ServiceTriggerRecovery()
		finally Critical(InheritedCritical)
	}
	global _LLM_Menu_TriggerRecovery
	if A_IsSuspended
		return false
	PreviousCritical := Critical("On")
	try {
		if !(_LLM_Menu_TriggerRecovery is Map)
			return true
		Record := _LLM_Menu_TriggerRecovery
		if Record["scheduled"] || Record["running"]
			return true
	} finally Critical(PreviousCritical)
	return _LLM_Menu_ScheduleTriggerRecovery(Record)
}





; ==========================================
; ==========================================
; ======= 3/ Replay and Transactions =======
; ==========================================
; ==========================================

_LLM_Menu_PublishTriggerRuntime(RawText, NewAhk, NewHandle, Status,
		RecoveryHandles) {
	global _LLM_Menu, _LLM_Menu_TriggerHandle, _LLM_Menu_TriggerAhk
	global _LLM_Menu_TriggerStatus, _LLM_Menu_TriggerRecoveryHandles
	global _LLM_Menu_TriggerFailureNoticeKey
	global LLM_TRIGGER_STATUS_ERROR, LLM_TRIGGER_STATUS_ROLLBACK_PENDING
	global LLM_TRIGGER_STATUS_CLEANUP_PENDING
	PreviousCritical := Critical("On")
	try {
		_LLM_Menu["trigger_shortcut"] := RawText
		_LLM_Menu_TriggerHandle := NewHandle
		_LLM_Menu_TriggerAhk := NewAhk
		_LLM_Menu_TriggerStatus := Status
		_LLM_Menu_TriggerRecoveryHandles := RecoveryHandles
		if (RecoveryHandles.Length = 0
				&& Status != LLM_TRIGGER_STATUS_ERROR
				&& Status != LLM_TRIGGER_STATUS_ROLLBACK_PENDING
				&& Status != LLM_TRIGGER_STATUS_CLEANUP_PENDING)
			_LLM_Menu_TriggerFailureNoticeKey := ""
	} finally Critical(PreviousCritical)
}

_LLM_Menu_AcceptTriggerReplay(RawText) {
	try LoggerDebug("LLM", "Trigger shortcut replayed as '{1}'.", RawText)
	return true
}

_LLM_Menu_RejectTriggerReplay(RawText, Detail, OldHandle,
		HotkeyFn, SchedulerFn, RefreshFn, NotifyFn, ReportFailure := true) {
	global LLM_TRIGGER_STATUS_ERROR, LLM_TRIGGER_STATUS_CLEANUP_PENDING
	RemainingHandles := []
	if OldHandle != "" {
		Retired := _HotkeyRegistrarRetire(OldHandle, HotkeyFn)
		if !Retired && HotkeyRegistrarChordOf(OldHandle) != ""
			RemainingHandles.Push(OldHandle)
	}
	if RemainingHandles.Length > 0 {
		RecoveryState := Map(
			"old_string", RawText,
			"recovery_complete_status", LLM_TRIGGER_STATUS_ERROR,
			"recovery_handles", RemainingHandles)
		_LLM_Menu_PublishTriggerRuntime(RawText, "", "",
			LLM_TRIGGER_STATUS_CLEANUP_PENDING, RemainingHandles)
		_LLM_Menu_InstallTriggerRecovery("cleanup", RecoveryState, 0,
			HotkeyFn, SchedulerFn, RefreshFn)
	} else {
		_LLM_Menu_PublishTriggerRuntime(RawText, "", "",
			LLM_TRIGGER_STATUS_ERROR, [])
	}
	if ReportFailure
		_LLM_Menu_ReportTriggerFailure(RawText, "apply", Detail)
	return _LLM_Menu_NotifyTriggerApplyFailure(RawText, NotifyFn)
}

; Boot/reload replay has no write to perform because the loader already made
; RawText authoritative. It still uses reserve-Off then Activate, and publishes
; both handles if exception-before-mutation Off leaves the previous one live
LLM_Menu_ApplyTriggerShortcut(raw, HotkeyFn := 0, ProbeFn := 0, CallbackFn := 0,
		SchedulerFn := 0, RefreshFn := 0, NotifyFn := 0, KeyResolverFn := 0) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return LLM_Menu_ApplyTriggerShortcut(raw, HotkeyFn, ProbeFn,
			CallbackFn, SchedulerFn, RefreshFn, NotifyFn, KeyResolverFn)
		finally Critical(InheritedCritical)
	}
	global _LLM_Menu_TriggerHandle, _LLM_Menu_TriggerAhk
	global LLM_TRIGGER_STATUS_ERROR, LLM_TRIGGER_STATUS_CLEANUP_PENDING

	RawText := Trim(String(raw))
	if _LLM_Menu_TriggerRecoveryPending() {
		_LLM_Menu_ReportTriggerFailure(RawText, "apply",
			"an earlier native or durable recovery is still pending")
		return _LLM_Menu_NotifyTriggerApplyFailure(RawText, NotifyFn)
	}
	OldHandle := _LLM_Menu_TriggerHandle
	OldAhk := _LLM_Menu_TriggerAhk
	NewAhk := (RawText = "") ? "" : LLM_Menu_ShortcutToAhk(RawText)
	if (RawText != "" && NewAhk = "") {
		return _LLM_Menu_RejectTriggerReplay(RawText,
			"the trigger shortcut is invalid", OldHandle,
			HotkeyFn, SchedulerFn, RefreshFn, NotifyFn, false)
	}
	ContextState := _LLM_Menu_ContextualModifierSnapshot()
	CapturedIdentity := ""
	if (NewAhk != "" && NewAhk == OldAhk && OldHandle != "") {
		CapturedIdentity := HotkeyRegistrarPhysicalIdentityOf(OldHandle)
		if CapturedIdentity == "" {
			return _LLM_Menu_RejectTriggerReplay(RawText,
				"the active trigger owner has no native identity", OldHandle,
				HotkeyFn, SchedulerFn, RefreshFn, NotifyFn)
		}
	}
	Conflict := _LLM_Menu_CheckTriggerContextCollision(NewAhk, ContextState,
		KeyResolverFn, CapturedIdentity)
	if !Conflict["ok"] {
		return _LLM_Menu_RejectTriggerReplay(RawText,
			"the contextual hotkey surface is malformed", OldHandle,
			HotkeyFn, SchedulerFn, RefreshFn, NotifyFn)
	}
	if Conflict["owner"] != "" {
		return _LLM_Menu_RejectTriggerReplay(RawText,
			"the chord is reserved by " . Conflict["owner"], OldHandle,
			HotkeyFn, SchedulerFn, RefreshFn, NotifyFn)
	}
	if (NewAhk = OldAhk && (NewAhk = "" || OldHandle != "")) {
		_LLM_Menu_PublishTriggerRuntime(RawText, OldAhk, OldHandle,
			_LLM_Menu_TriggerStatusForAhk(OldAhk), [])
		return _LLM_Menu_AcceptTriggerReplay(RawText)
	}
	if (NewAhk = "") {
		if (OldHandle != "" && !_HotkeyRegistrarRetire(OldHandle, HotkeyFn)) {
			RecoveryState := Map("old_string", RawText,
				"recovery_handles", [OldHandle])
			_LLM_Menu_PublishTriggerRuntime(RawText, "", "",
				LLM_TRIGGER_STATUS_CLEANUP_PENDING, [OldHandle])
			_LLM_Menu_InstallTriggerRecovery("cleanup", RecoveryState, 0,
				HotkeyFn, SchedulerFn, RefreshFn)
			_LLM_Menu_ReportTriggerFailure(RawText, "clear",
				"the previous native binding remains live and is retained for recovery")
			return _LLM_Menu_NotifyTriggerApplyFailure(RawText, NotifyFn)
		}
		_LLM_Menu_PublishTriggerRuntime(RawText, "", "",
			_LLM_Menu_TriggerStatusForAhk(""), [])
		return _LLM_Menu_AcceptTriggerReplay(RawText)
	}

	NewHandle := _HotkeyRegistrarReserveResolvedOwned(RawText,
		_LLM_Menu_TriggerCallback(CallbackFn), "llm:trigger",
		Conflict["descriptor"], HotkeyFn, ProbeFn)
	if (NewHandle = "") {
		_LLM_Menu_PublishTriggerRecovery(LLM_TRIGGER_STATUS_ERROR, [])
		_LLM_Menu_ReportTriggerFailure(RawText, "reserve",
			"the shared registrar refused the candidate")
		return _LLM_Menu_NotifyTriggerApplyFailure(RawText, NotifyFn)
	}
	if !_HotkeyRegistrarActivate(NewHandle, HotkeyFn) {
		RecoveryHandles := []
		if !_HotkeyRegistrarAbort(NewHandle)
			RecoveryHandles.Push(NewHandle)
		_LLM_Menu_PublishTriggerRecovery(LLM_TRIGGER_STATUS_ERROR,
			RecoveryHandles)
		if (RecoveryHandles.Length > 0) {
			RecoveryState := Map(
				"old_string", RawText,
				"recovery_complete_status", LLM_TRIGGER_STATUS_ERROR,
				"recovery_handles", RecoveryHandles)
			_LLM_Menu_InstallTriggerRecovery("cleanup", RecoveryState, 0,
				HotkeyFn, SchedulerFn, RefreshFn)
		}
		_LLM_Menu_ReportTriggerFailure(RawText, "activate",
			"the candidate remained native-Off")
		return _LLM_Menu_NotifyTriggerApplyFailure(RawText, NotifyFn)
	}
	if (OldHandle != "" && !_HotkeyRegistrarRetire(OldHandle, HotkeyFn)) {
		RecoveryState := Map("old_string", RawText,
			"recovery_handles", [OldHandle])
		_LLM_Menu_PublishTriggerRuntime(RawText, NewAhk, NewHandle,
			LLM_TRIGGER_STATUS_CLEANUP_PENDING, [OldHandle])
		_LLM_Menu_InstallTriggerRecovery("cleanup", RecoveryState, 0,
			HotkeyFn, SchedulerFn, RefreshFn)
		_LLM_Menu_ReportTriggerFailure(RawText, "replace",
			"the previous native binding remains live and is retained for recovery")
		return _LLM_Menu_NotifyTriggerApplyFailure(RawText, NotifyFn)
	}
	_LLM_Menu_PublishTriggerRuntime(RawText, NewAhk, NewHandle,
		_LLM_Menu_TriggerStatusForAhk(NewAhk), [])
	return _LLM_Menu_AcceptTriggerReplay(RawText)
}

_LLM_Menu_ActivatePreparedTrigger(State, HotkeyFn) {
	; The WAL is the crash-recovery authority. Publish committed-new while the
	; candidate is still native-Off; only then may the callback become observable.
	State["journal_new_ok"] := _LLM_TriggerJournalCommitNew(
		State["journal_record"], State["journal_port"],
		State["journal_path"])
	if !State["journal_new_ok"] {
		State["journal_commit_failed"] := true
		try LoggerError("LLM", "Could not publish committed-new trigger journal before native activation.")
		return false
	}
	if State["new_reserved"] {
		State["activate_ok"] := _HotkeyRegistrarActivate(
			State["new_handle"], HotkeyFn)
		State["new_active"] := State["activate_ok"]
		if !State["activate_ok"]
			return false
	}
	return true
}

; Compensation handles both sides of the activation boundary. A reserved-Off
; candidate can be discarded locally; once active, the same opaque owner must
; be retired through the native registrar before durable rollback is trusted.
_LLM_Menu_AbortPreparedTrigger(State, HotkeyFn) {
	State["rollback_ok"] := true
	if State["new_reserved"] {
		State["rollback_ok"] := State["new_active"]
			? _HotkeyRegistrarRetire(State["new_handle"], HotkeyFn)
			: _HotkeyRegistrarAbort(State["new_handle"])
	}
	if !State["rollback_ok"] && State["journal_commit_failed"]
		State["journal_recovery_needed"] := true
	else if !State["rollback_ok"] && State["journal_new_ok"]
		State["journal_force_rollback"] := true
	; A forward writer can mutate and then report failure. In that pre-commit
	; branch the generic gateway has no rollback-writer phase, so force recovery
	; retention until the stable pending journal has become terminal.
	return State["rollback_ok"] && !State["journal_recovery_needed"]
}

_LLM_Menu_RetirePreviousTrigger(State, HotkeyFn) {
	if !State["binding_changed"] || State["old_handle"] = ""
		return true
	State["cleanup_ok"] := _HotkeyRegistrarRetire(State["old_handle"], HotkeyFn)
	if !State["cleanup_ok"] {
		global LLM_TRIGGER_STATUS_CLEANUP_PENDING
		_LLM_Menu_AppendTriggerRecovery(State, State["old_handle"])
		State["status"] := LLM_TRIGGER_STATUS_CLEANUP_PENDING
	}
	return State["cleanup_ok"]
}

_LLM_Menu_RetainTriggerRecovery(State, WriterFn, HotkeyFn, SchedulerFn,
		RefreshFn, Stage) {
	global LLM_TRIGGER_STATUS_ERROR, LLM_TRIGGER_STATUS_ROLLBACK_PENDING
	global LLM_TRIGGER_STATUS_CLEANUP_PENDING

	if (Stage != "compensation_failed" && Stage != "rollback_failed"
			&& Stage != "cleanup_failed") {
		try LoggerError("LLM", "Refusing unknown trigger recovery stage '{1}'.", Stage)
		return false
	}
	JournalRecovery := State.Get("journal_recovery_needed", false)
	ForceJournalRollback := State.Get("journal_force_rollback", false)
	if (Stage = "compensation_failed") {
		if State["new_reserved"] && !State["rollback_ok"]
			_LLM_Menu_AppendTriggerRecovery(State, State["new_handle"])
		State["status"] := (JournalRecovery || ForceJournalRollback)
			? LLM_TRIGGER_STATUS_ROLLBACK_PENDING : LLM_TRIGGER_STATUS_ERROR
	} else if (Stage = "rollback_failed") {
		if State["new_reserved"] && !State["rollback_ok"]
			_LLM_Menu_AppendTriggerRecovery(State, State["new_handle"])
		State["status"] := LLM_TRIGGER_STATUS_ROLLBACK_PENDING
	} else {
		_LLM_Menu_AppendTriggerRecovery(State, State["old_handle"])
		State["status"] := LLM_TRIGGER_STATUS_CLEANUP_PENDING
	}
	; Cleanup is followed by the ordinary forward publisher. The other stages
	; have no publisher, so expose only their recovery projection before yielding
	; to the notifier; the old primary handle and menu value stay authoritative
	if (Stage != "cleanup_failed") {
		_LLM_Menu_PublishTriggerRecovery(State["status"],
			State["recovery_handles"])
	}
	if ForceJournalRollback
		return _LLM_Menu_InstallTriggerRecovery("journal_rollback", State,
			WriterFn, HotkeyFn, SchedulerFn, RefreshFn)
	if JournalRecovery
		return _LLM_Menu_InstallTriggerRecovery("journal", State, WriterFn,
			HotkeyFn, SchedulerFn, RefreshFn)
	if (Stage = "compensation_failed")
		return _LLM_Menu_InstallTriggerRecovery("cleanup", State, WriterFn,
			HotkeyFn, SchedulerFn, RefreshFn)
	if (Stage = "cleanup_failed")
		return _LLM_Menu_InstallTriggerRecovery("cleanup", State, WriterFn,
			HotkeyFn, SchedulerFn, RefreshFn)
	if (Stage = "rollback_failed")
		return _LLM_Menu_InstallTriggerRecovery("rollback", State, WriterFn,
			HotkeyFn, SchedulerFn, RefreshFn)
	return true
}

_LLM_Menu_PublishTriggerShortcut(State) {
	_LLM_Menu_PublishTriggerRuntime(State["new_string"], State["new_ahk"],
		State["new_handle"], State["status"], State["recovery_handles"])
}

_LLM_Menu_TriggerJournalWriter(Outcome, OriginalWriter, Path, Updates) {
	if !(Outcome is Map) || !Outcome.Has("state")
		return false
	State := Outcome["state"]
	State["writer_calls"] += 1
	if (State["writer_calls"] == 1) {
		ForwardOk := _LLM_TriggerJournalInvokeWriter(Path, Updates, OriginalWriter)
		if ForwardOk
			ForwardOk := _LLM_TriggerJournalVerifyNew(
				State["journal_record"], State["journal_read"])
		if ForwardOk
			return true
		; A writer status is not proof that disk stayed unchanged. Resolve the
		; stable pending record while this exact config lease is still owned.
		RollbackOk := _LLM_TriggerJournalRollback(State["journal_record"],
			State["journal_port"], State["journal_read"], OriginalWriter,
			State["journal_path"])
		State["journal_recovery_needed"] := !RollbackOk
		return false
	}
	RollbackOk := _LLM_TriggerJournalRollback(State["journal_record"],
		State["journal_port"], State["journal_read"], OriginalWriter,
		State["journal_path"])
	State["journal_recovery_needed"] := !RollbackOk
	State["journal_force_rollback"] := !RollbackOk
	return RollbackOk
}

_LLM_Menu_RetainStableTriggerJournal(State, WriterFn, HotkeyFn,
		SchedulerFn, RefreshFn) {
	global LLM_TRIGGER_STATUS_ROLLBACK_PENDING
	State["journal_recovery_needed"] := true
	State["status"] := LLM_TRIGGER_STATUS_ROLLBACK_PENDING
	_LLM_Menu_PublishTriggerRecovery(State["status"],
		State["recovery_handles"])
	return _LLM_Menu_InstallTriggerRecovery("journal", State, WriterFn,
		HotkeyFn, SchedulerFn, RefreshFn)
}

_LLM_Menu_BuildTriggerShortcutPlan(Outcome, RawText, CallbackFn, WriterFn,
		HotkeyFn, ProbeFn, SchedulerFn, RefreshFn, JournalPort := 0,
		ReadTriggerFn := 0, JournalPath := "", KeyResolverFn := 0) {
	global _LLM_Menu, _LLM_Menu_TriggerHandle, _LLM_Menu_TriggerAhk
	global _LLM_Menu_TriggerStatus, _LLM_Menu_TriggerRecoveryHandles
	global _LLM_Menu_TriggerRecovery
	global LLM_TRIGGER_STATUS_CLEANUP_PENDING, LLM_TRIGGER_STATUS_ROLLBACK_PENDING
	global ConfigurationFile

	Outcome["accepted"] := false
	PreviousCritical := Critical("On")
	try {
		RecoveryPending := (_LLM_Menu_TriggerRecovery is Map)
			|| _LLM_Menu_TriggerRecoveryHandles.Length > 0
			|| _LLM_Menu_TriggerStatus = LLM_TRIGGER_STATUS_CLEANUP_PENDING
			|| _LLM_Menu_TriggerStatus = LLM_TRIGGER_STATUS_ROLLBACK_PENDING
		OldString := _LLM_Menu["trigger_shortcut"]
		OldHandle := _LLM_Menu_TriggerHandle
		OldAhk := _LLM_Menu_TriggerAhk
		ContextState := Map(
			"nav_modifiers", _LLM_Menu.Has("nav_modifiers")
				? _LLM_Menu["nav_modifiers"] : "",
			"val_modifiers", _LLM_Menu.Has("val_modifiers")
				? _LLM_Menu["val_modifiers"] : "alt")
	} finally Critical(PreviousCritical)
	if RecoveryPending {
		_LLM_Menu_ReportTriggerFailure(RawText, "edit",
			"an earlier native or durable recovery is still pending")
		return false
	}
	NewAhk := (RawText = "") ? "" : LLM_Menu_ShortcutToAhk(RawText)
	CandidateValid := (RawText == "") || NewAhk != ""

	BindingChanged := (NewAhk != OldAhk) || (NewAhk != "" && OldHandle = "")
	NewHandle := BindingChanged ? "" : OldHandle
	State := Map(
		"binding_changed", BindingChanged,
		"old_string", OldString,
		"old_ahk", OldAhk,
		"old_handle", OldHandle,
		"new_string", RawText,
		"new_ahk", NewAhk,
		"new_handle", NewHandle,
		"new_reserved", false,
		"new_active", false,
		"activate_ok", true,
		"cleanup_ok", true,
		"rollback_ok", true,
		"status", _LLM_Menu_TriggerStatusForAhk(NewAhk),
		"recovery_handles", [],
		"journal_record", false,
		"journal_port", JournalPort,
		"journal_read", ReadTriggerFn,
		"journal_path", JournalPath,
		"journal_new_ok", false,
		"journal_commit_failed", false,
		"journal_recovery_needed", false,
		"journal_force_rollback", false,
		"writer_calls", 0)
	OwnerToken := _ConfigWriteLeaseCurrent(ConfigurationFile)
	if !(OwnerToken is Object)
			|| !_ConfigWriteLeaseOwns(OwnerToken, ConfigurationFile) {
		_LLM_Menu_ReportTriggerFailure(RawText, "journal",
			"the configuration transaction no longer owns its path")
		return false
	}
	; A stable record from a prior process or a failed writer is authoritative.
	; Reconcile it before even reserving a new native candidate.
	if !LLM_TriggerJournalReconcile(JournalPort, ReadTriggerFn,
			WriterFn, JournalPath, OwnerToken) {
		if LLM_TriggerJournalIsReadOnly() {
			_LLM_Menu_ReportTriggerFailure(RawText, "journal",
				"the preserved journal is quarantined read-only")
			return false
		}
		_LLM_Menu_RetainStableTriggerJournal(State, WriterFn, HotkeyFn,
			SchedulerFn, RefreshFn)
		return false
	}
	; Candidate syntax has no authority over a prior durable transaction. Refuse
	; it only after that transaction has reached its stable old state, but still
	; before native reservation or a candidate WAL/config write.
	if !CandidateValid
		return false
	CapturedIdentity := ""
	if (!BindingChanged && NewAhk != "") {
		CapturedIdentity := HotkeyRegistrarPhysicalIdentityOf(OldHandle)
		if CapturedIdentity == "" {
			_LLM_Menu_ReportTriggerFailure(RawText, "edit",
				"the active trigger owner has no native identity")
			return false
		}
	}
	Conflict := _LLM_Menu_CheckTriggerContextCollision(NewAhk, ContextState,
		KeyResolverFn, CapturedIdentity)
	if !Conflict["ok"] {
		_LLM_Menu_ReportTriggerFailure(RawText, "edit",
			"the contextual hotkey surface is malformed")
		return false
	}
	if Conflict["owner"] != "" {
		_LLM_Menu_ReportTriggerFailure(RawText, "edit",
			"the chord is reserved by " . Conflict["owner"])
		return false
	}
	if (BindingChanged && NewAhk != "") {
		NewHandle := _HotkeyRegistrarReserveResolvedOwned(RawText,
			_LLM_Menu_TriggerCallback(CallbackFn), "llm:trigger",
			Conflict["descriptor"], HotkeyFn, ProbeFn)
		if (NewHandle = "") {
			_LLM_Menu_ReportTriggerFailure(RawText, "reserve",
				"the shared registrar refused the candidate")
			return false
		}
		State["new_handle"] := NewHandle
		State["new_reserved"] := true
	}
	Record := _LLM_TriggerJournalPrepareTransaction(ConfigurationFile,
		RawText, OwnerToken, JournalPort, ReadTriggerFn, WriterFn, JournalPath)
	if !(Record is Map) {
		if State["new_reserved"] && !_HotkeyRegistrarAbort(State["new_handle"])
			_LLM_Menu_AppendTriggerRecovery(State, State["new_handle"])
		_LLM_Menu_RetainStableTriggerJournal(State, WriterFn, HotkeyFn,
			SchedulerFn, RefreshFn)
		return false
	}
	State["journal_record"] := Record
	Outcome["accepted"] := true
	Outcome["state"] := State
	return {
		updates: [{ Section: "llm", Key: "trigger_shortcut", Value: RawText }],
		rollback_updates: [{ Section: "llm", Key: "trigger_shortcut",
			Value: OldString }],
		finalize: _LLM_Menu_ActivatePreparedTrigger.Bind(State, HotkeyFn),
		cleanup: _LLM_Menu_RetirePreviousTrigger.Bind(State, HotkeyFn),
		compensate: _LLM_Menu_AbortPreparedTrigger.Bind(State, HotkeyFn),
		retain: _LLM_Menu_RetainTriggerRecovery.Bind(State, WriterFn, HotkeyFn,
			SchedulerFn, RefreshFn),
		publish: _LLM_Menu_PublishTriggerShortcut.Bind(State)
	}
}

LLM_Menu_CommitTriggerShortcut(raw, WriterFn := 0, NotifyFn := 0,
		HotkeyFn := 0, ProbeFn := 0, CallbackFn := 0, SchedulerFn := 0,
		RefreshFn := 0, JournalPort := 0, ReadTriggerFn := 0,
		JournalPath := "", KeyResolverFn := 0) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return LLM_Menu_CommitTriggerShortcut(raw, WriterFn, NotifyFn,
			HotkeyFn, ProbeFn, CallbackFn, SchedulerFn, RefreshFn,
			JournalPort, ReadTriggerFn, JournalPath, KeyResolverFn)
		finally Critical(InheritedCritical)
	}
	RawText := Trim(String(raw))
	; Timer delivery is only a bounded wake-up. A later explicit edit owns one
	; synchronous recovery attempt so a refused SetTimer cannot latch the row
	; forever. Claim the unscheduled record atomically before leaving Critical;
	; watchdog/resume service then sees running=true and cannot queue a second
	; callback in the gap before the direct attempt starts.
	RecoveryRecord := false
	if !A_IsSuspended
		RecoveryRecord := _LLM_Menu_ClaimTriggerRecovery(0, false)
	if (RecoveryRecord is Map)
		_LLM_Menu_RunClaimedTriggerRecovery(RecoveryRecord)
	Outcome := Map("accepted", false)
	GatewayWriter := _LLM_Menu_TriggerJournalWriter.Bind(Outcome, WriterFn)
	Committed := CS_SaveBuilt("the LLM trigger shortcut",
		_LLM_Menu_BuildTriggerShortcutPlan.Bind(Outcome, RawText, CallbackFn,
			WriterFn, HotkeyFn, ProbeFn, SchedulerFn, RefreshFn,
			JournalPort, ReadTriggerFn, JournalPath, KeyResolverFn),
		GatewayWriter, NotifyFn)
	Succeeded := ((Committed is Integer) && Committed == 1)
		&& Outcome.Get("accepted", false)
	if Succeeded
		try LoggerDebug("LLM", "Trigger shortcut committed as '{1}'.", RawText)
	return Succeeded
}
