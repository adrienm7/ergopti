; tests/meta/test_list_providers_touch_no_menu.ahk

; ==============================================================================
; MODULE: List Providers Touch No Menu
; DESCRIPTION:
; A `list` provider RETURNS row data. A `dynamic` handler RECEIVES a Menu and
; mutates it. The two are registered in different arguments of
; MenuRenderer_Build and have different signatures, and a function converted
; from one to the other has to change BOTH — its return value and everything it
; does with the menu object it no longer gets.
;
; WHAT HAPPENED WHEN HALF THE CONVERSION LANDED (2026-08-07):
; _HS_CategoryRowsDynamic became a provider when the five hotstring category
; blocks moved onto the manifest. Its body did not follow. It returned an EMPTY
; array — so the dynamic-hotstrings row was simply absent from the tray — and it
; still ended with `M.Check(DynTitle)`, where `M` is a parameter a provider is
; never handed. In AutoHotkey v2 that reads an unset local and THROWS.
;
; The throw travelled up through MenuRenderer_Build into the deferred tray
; build's catch in infra/lifecycle.ahk, which logs and continues — so the entire
; tray menu vanished, leaving only the submenus that add themselves to
; A_TrayMenu directly (the IA menu). One unset variable, the whole menu gone,
; and a log line naming neither the file nor the row.
;
; It was latent: the `M.Check` sits behind `IsGated and DynAllEnabled and
; DynCount > 0`, so it fired only once a configuration satisfied all three.
; Every headless test stayed green throughout, because none of them builds the
; tray.
;
; WHAT THIS PINS:
;   1. Every list provider registered in menu_init.ahk follows the *Rows naming
;      convention, so the rule below cannot be escaped by renaming a function.
;   2. No such provider mutates a menu — no .Add(, .Check(, .Disable( on a
;      parameter it does not receive, and no RegisterMenuItem.
;   3. Every such provider pushes at least one row. A provider that can only
;      ever return an empty array is a row the user never sees, and nothing else
;      in the build says so.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ======= 1/ The providers, taken from the source ==
; ==================================================

; Provider function names, read from initMenu's registration rather than listed
; here: a list written in this file would go stale the moment one is added, and
; the bug this test exists for arrived with exactly such an addition.
_LPTM_ProviderNames() {
	Body := _DriverFuncBodyOrEmpty("initMenu")
	Names := []
	Pos := 1
	while (Pos := RegExMatch(Body, "\(\*\)\s*=>\s*(_\w+)\(\)", &M, Pos)) {
		Names.Push(M[1])
		Pos += M.Len[0]
	}
	return Names
}




; ==================================================
; ======= 2/ Contract assertions ===================
; ==================================================

_LPTM_ProvidersAreNamedRows() {
	Names := _LPTM_ProviderNames()
	Assert(Names.Length >= 5,
		"initMenu must register list providers as `(*) => _Name()` — found " . Names.Length
		. ", so this test is reading the wrong thing and would pass while measuring nothing")
	for Name in Names {
		Assert(InStr(Name, "Rows") > 0,
			"list provider '" . Name . "' must carry 'Rows' in its name: the rule below reads "
			. "the registration, and a name that does not say it returns rows makes the next "
			. "half-finished conversion harder to see, not easier")
	}
}
Test("list-providers: every registered provider follows the *Rows convention", _LPTM_ProvidersAreNamedRows)

; A provider MAY build a menu of its own and hand it over as a `submenu` row —
; that is how the personal tree and the category blocks still work. What it may
; not do is mutate a menu it never created, because a provider receives none:
; the name resolves to an unset local. So the rule is not "no menu calls", it is
; "every menu you touch is one you made", which is checkable without naming the
; parameter the old dynamic handlers happened to use.
; Whether ``Name`` is assigned somewhere in ``Body``. Scans rather than matches a
; pattern: the name is interpolated, so a regex would break on a metacharacter,
; and this driver aligns its assignments — ``ExtHsMenu    := Menu()`` — so a
; fixed-spacing InStr reports a menu the provider does create as one it does not.
_LPTM_IsAssignedIn(Body, Name) {
	Pos := 1
	while (Pos := InStr(Body, Name, true, Pos)) {
		After := Pos + StrLen(Name)
		while (SubStr(Body, After, 1) == " " or SubStr(Body, After, 1) == "`t") {
			After++
		}
		if (SubStr(Body, After, 2) == ":=") {
			return true
		}
		Pos := After
	}
	return false
}

_LPTM_ProvidersTouchNoMenu() {
	; Pins the scan below. ONE provider is named rather than a count required,
	; because the count falls as the migration proceeds: a provider that returns
	; pure data touches no menu at all, so a numeric floor fires on progress and
	; gets lowered until it guards nothing. _HS_PersonalRows is the case that
	; cannot go away — the personal tree's callbacks repaint the open menu, so it
	; creates one and hands it over as `submenu`. If it ever stops, this fails and
	; the next reader picks a new witness instead of the check quietly emptying.
	WITNESS := "_HS_PersonalRows"
	WitnessSeen := false
	for Name in _LPTM_ProviderNames() {
		Body := _DriverFuncBodyOrEmpty(Name)
		Assert(Body != "", "list provider '" . Name . "()' must exist in the driver")

		Targets := []
		Pos := 1
		while (Pos := RegExMatch(Body, "(\w+)\.(?:Add|Check|Disable|Enable)\(", &Mt, Pos)) {
			Targets.Push(Mt[1])
			Pos += Mt.Len[0]
		}
		Pos := 1
		while (Pos := RegExMatch(Body, "RegisterMenuItem\(\s*(\w+)", &Mr, Pos)) {
			Targets.Push(Mr[1])
			Pos += Mr.Len[0]
		}
		; The renderer entry points take the menu to fill as their FIRST argument,
		; and the rule is the same one: it must be a menu this provider created. A
		; provider that builds its rows as data and renders them — which is what
		; they all do since 2026-08-07 — touches a menu only through these two, so
		; without them the scan finds nothing to check and the floor below fires.
		Pos := 1
		while (Pos := RegExMatch(Body, "MenuRenderer_(?:AppendRows|FillFromList)\(\s*(\w+)", &Mf, Pos)) {
			Targets.Push(Mf[1])
			Pos += Mf.Len[0]
		}

		if (Name == WITNESS) {
			WitnessSeen := true
			Assert(Targets.Length >= 1,
				"the menu-target scan found no menu in '" . WITNESS . "', which demonstrably builds "
				. "one: the pattern has stopped matching, and every provider below would then pass "
				. "this test without being read at all")
		}
		for Target in Targets {
			Assert(_LPTM_IsAssignedIn(Body, Target),
				"list provider '" . Name . "' mutates '" . Target . "', which it never creates. "
				. "A provider RETURNS row data and is handed no menu, so that name is an unset "
				. "local: in AHK v2 it throws, the deferred tray build catches it, and the WHOLE "
				. "tray menu disappears — which is what _HS_CategoryRowsDynamic did with "
				. "`M.Check(DynTitle)` on 2026-08-07")
		}
	}
	Assert(WitnessSeen,
		"'" . WITNESS . "' is no longer a registered list provider, so the check above never ran. "
		. "Name another provider that builds a menu of its own — the pin has to point at something "
		. "that exists, or an empty scan passes in silence")
}
Test("list-providers: no provider mutates a menu it is never handed", _LPTM_ProvidersTouchNoMenu)

; The method-call rule above missed the second instance, which passed the menu as
; an ARGUMENT: `_HS_RenderTree(TreeCopy, M)`. Same unset local, same thrown build,
; same vanished tray — and the first fix made it the next thing to fail rather
; than something the suite caught. `M` is this driver's name for the menu
; parameter of a dynamic handler; inside a provider it names nothing at all.
_LPTM_ProvidersNameNoMenuParameter() {
	for Name in _LPTM_ProviderNames() {
		Body := _DriverFuncBodyOrEmpty(Name)
		Assert(Body != "", "list provider '" . Name . "()' must exist in the driver")
		if (_LPTM_IsAssignedIn(Body, "M")) {
			continue
		}
		Assert(RegExMatch(Body, "(?<![A-Za-z0-9_])M(?![A-Za-z0-9_])") == 0,
			"list provider '" . Name . "' uses the bare name 'M'. That is the menu parameter a "
			. "DYNAMIC handler receives; a provider receives none, so the name is an unset local "
			. "and using it — even only as an argument — throws and takes the whole tray with it")
	}
}
Test("list-providers: no provider names the menu parameter it does not have", _LPTM_ProvidersNameNoMenuParameter)

_LPTM_ProvidersReturnRows() {
	for Name in _LPTM_ProviderNames() {
		Body := _DriverFuncBodyOrEmpty(Name)
		Assert(InStr(Body, "Rows.Push(") or InStr(Body, "return ["),
			"list provider '" . Name . "' never produces a row — it can only return an empty "
			. "array, which draws nothing and reports nothing. _HS_CategoryRowsDynamic shipped "
			. "in exactly that state")
	}
}
Test("list-providers: every provider can actually produce a row", _LPTM_ProvidersReturnRows)
