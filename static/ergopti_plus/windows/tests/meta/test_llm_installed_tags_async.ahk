; tests/meta/test_llm_installed_tags_async.ahk

; ==============================================================================
; MODULE: LLM Installed-Tags Async (Non-Blocking Menu) Test
; DESCRIPTION:
; Regression guard for the recurring "IA menu is empty / took >10 s to build"
; freeze. The tray model submenu painted a green "installed" dot per catalogue
; row via LLM_IsModelInstalled -> _LLM_GetInstalledTagsCached, which ran a
; SYNCHRONOUS WinHTTP GET /api/tags (LLM_OllamaListModels, 5 s x 4 phases). Once
; the Ollama daemon had ever been confirmed reachable the deps-ready gate stayed
; open (the state is sticky), so every rebuild past the 2 s install-cache TTL —
; including the toggle-OFF rebuild — re-fired that blocking probe on the keyboard
; thread and froze it for up to ~20 s on a cold/slow daemon. During the freeze the
; menu looked empty AND input-cancellation callbacks were starved.
;
; THE FIX (the contract this test pins): the menu read path is non-blocking.
;   - _LLM_GetInstalledTagsCached() is a PURE in-memory read — it never calls the
;     synchronous LLM_OllamaListModels().
;   - The cache is refreshed in the background by LLM_OllamaListModels_Async
;     (tree-owned curl), fired from the tray build via LLM_Menu_FireInstalledTagsProbe
;     and stashed by LLM_SetInstalledTagsCache — the exact mirror of the backend
;     health-dot probe (_LLM_Menu_FireHealthProbe), repainting only on a real change.
;   - Bridge start waits for the first async snapshot and is retried by its exact
;     terminal owner; no synchronous /api/tags helper remains.
;
; Mix of a source-level contract (mirrors the sibling async-guard meta tests, which
; are source-level because the menu layer references dozens of cross-module funcs)
; and a network-free behavioural check of the real cache state machine.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==================================
; ==================================
; ======= 1/ Source contract =======
; ==================================
; ==================================

_MetaCheckInstalledTagsNonBlocking() {
	; (1) The cache READ path must never perform the synchronous /api/tags probe —
	; that blocking call, run per catalogue row at every rebuild, was the freeze.
	GetBody := _DriverFuncBody("_LLM_GetInstalledTagsCached")
	Assert(GetBody != "", "models.ahk must define _LLM_GetInstalledTagsCached()")
	Assert(!InStr(GetBody, "LLM_OllamaListModels("),
		"_LLM_GetInstalledTagsCached must be a pure non-blocking cache read — it must "
		. "NOT call the synchronous LLM_OllamaListModels() (the GET /api/tags freeze)")

	; (2) The async probe must exist and genuinely run non-blocking: a curl CHILD on
	; /api/tags (NOT WinHTTP — its async Send() still connects synchronously and could
	; block the now-Critical tray build), polled via its durable terminal receipt. Same contract as
	; LLM_OllamaIsRunning_Async (ollama-reachability-winhttp-connect-blocks).
	AsyncBody := _DriverFuncBody("LLM_OllamaListModels_Async")
	Assert(AsyncBody != "", "api_ollama.ahk must define LLM_OllamaListModels_Async()")
	Assert(!InStr(AsyncBody, ".Send(") and !InStr(AsyncBody, 'ComObject("WinHttp'),
		"LLM_OllamaListModels_Async must NOT use the WinHTTP COM Send() — its synchronous "
		. "connect can block the (now Critical) tray build; use a curl child instead")
	Assert(InStr(AsyncBody, "/api/tags") and InStr(AsyncBody, "curl") and InStr(AsyncBody, "Run("),
		"LLM_OllamaListModels_Async must fetch GET /api/tags via a curl child process")
	Assert(InStr(AsyncBody, "_LLM_Ollama_TagsPoll("),
		"LLM_OllamaListModels_Async must hand off to _LLM_Ollama_TagsPoll (poll the child, don't block)")
	PollBody := _DriverFuncBody("_LLM_Ollama_TagsPoll")
	Assert(PollBody != "", "api_ollama.ahk must define _LLM_Ollama_TagsPoll()")
	Assert(InStr(PollBody, "_LLM_CurlTerminalComplete(") > 0
		and InStr(PollBody, "ProcessExist(") = 0,
		"_LLM_Ollama_TagsPoll must poll the durable terminal receipt, never a recyclable PID")
	Assert(InStr(PollBody, "ReadTerminalFn.Call(") > 0
		and InStr(PollBody, "_LLM_CurlTerminalOk(") > 0
		and InStr(PollBody, "_LLM_Ollama_ParseTagNames(") > 0,
		"the tags poll must require typed terminal evidence before parsing the canonical models array")

	; (3) No blocking list helper remains reachable or available for a future caller.
	Assert(_DriverFuncBodyOrEmpty("_LLM_WarmInstalledTagsSync") == "",
		"the synchronous installed-tags warm helper must stay retired")
	Assert(_DriverFuncBodyOrEmpty("LLM_OllamaListModels") == "",
		"the synchronous /api/tags transport must stay retired")

	; (4) The catalogue fallback picker must read the cache, not probe synchronously.
	PickBody := _DriverFuncBody("LLM_PickBestInstalledDisplayName")
	Assert(PickBody != "", "models.ahk must define LLM_PickBestInstalledDisplayName()")
	Assert(!InStr(PickBody, "LLM_OllamaListModels("),
		"LLM_PickBestInstalledDisplayName must read _LLM_GetInstalledTagsCached(), not "
		. "the synchronous LLM_OllamaListModels()")

	; (5) The tray build must FIRE the async probe in the model row (mirrors the
	; health probe) so the cache refreshes without the build ever blocking. The call
	; must use the EXACT _-prefixed name (see the def cross-check in (6)).
	EmitBody := _DriverFuncBody("_LLM_Menu_EmitRow")
	Assert(EmitBody != "", "menu_main.ahk must define _LLM_Menu_EmitRow()")
	Assert(InStr(EmitBody, "_LLM_Menu_FireInstalledTagsProbe("),
		"the model row must fire _LLM_Menu_FireInstalledTagsProbe() (async, non-blocking)")

	; (6) The probe + its result handler mirror the health-dot pattern: async fetch,
	; suspend-guarded, repaint only via LLM_SetInstalledTagsCache + change-flip guard.
	; CRITICAL: the name CALLED in the model row must have a matching top-level
	; DEFINITION under the EXACT same name. AHK v2 turns a call to an unknown name
	; into a dynamic call through an unset variable — NO load error — which then
	; throws "this local variable has not been assigned a value" only at runtime,
	; aborting the whole build. A def/call _-prefix mismatch shipped exactly that and
	; emptied the menu; asserting the def exists under the called name catches it.
	FireBody := _DriverFuncBody("_LLM_Menu_FireInstalledTagsProbe")
	Assert(FireBody != "",
		"actions.ahk must define _LLM_Menu_FireInstalledTagsProbe() under the SAME name "
		. "the model row calls — a mismatch becomes a runtime unset-variable throw that "
		. "aborts the build and empties the IA menu")
	Assert(InStr(FireBody, "LLM_OllamaListModels_Async("),
		"_LLM_Menu_FireInstalledTagsProbe must dispatch the async probe")
	Assert(InStr(FireBody, "A_IsSuspended"),
		"_LLM_Menu_FireInstalledTagsProbe must early-return on A_IsSuspended — its rebuild "
		. "path bypasses native Suspend like the health probe")

	DoneBody := _DriverFuncBody("_LLM_Menu_OnInstalledTagsProbeDone")
	OwnerGuard := _DriverFuncBody("_LLM_Menu_AuxOwnerIsCurrent")
	Assert(DoneBody != "", "actions.ahk must define _LLM_Menu_OnInstalledTagsProbeDone()")
	Assert(OwnerGuard != "", "the shared auxiliary menu-owner guard must exist")
	Assert(InStr(DoneBody, "LLM_SetInstalledTagsCache("),
		"_LLM_Menu_OnInstalledTagsProbeDone must stash the result via LLM_SetInstalledTagsCache")
	Assert(InStr(DoneBody, "_LLM_InstalledTagsListChanged(")
			and InStr(DoneBody, "_LLM_Menu_AuxOwnerIsCurrent(Owner)")
			and InStr(OwnerGuard, "A_IsSuspended"),
		"_LLM_Menu_OnInstalledTagsProbeDone must repaint only on a real change and never "
		. "while suspended (flip-guard, mirrors the health dot)")

	; (7) EnsureModelReady waits for the async cache after the deps-ready guard.
	EnsureBody := _DriverFuncBody("LLM_Menu_EnsureModelReady")
	Assert(EnsureBody != "", "actions.ahk must define LLM_Menu_EnsureModelReady()")
	GuardPos := InStr(EnsureBody, "!LLM_Deps_IsReady()")
	ReadyPos := InStr(EnsureBody, "!LLM_InstalledTagsCacheReady()")
	ProbePos := InStr(EnsureBody, "_LLM_Menu_FireInstalledTagsProbe()")
	Assert(GuardPos > 0 and ReadyPos > GuardPos and ProbePos > ReadyPos,
		"EnsureModelReady must wait for the async installed-tags snapshot after deps-ready")
	Assert(InStr(EnsureBody, "return false", , ProbePos) > ProbePos,
		"the bridge must not start before the first installed-tags snapshot commits")
	Assert(InStr(DoneBody, "LLM_Menu_TryStartBridge()") > 0,
		"the first exact tags terminal must retry the deferred bridge start")

	; (8) Model-browser open/filter runs in a GUI/input callback, so it must
	; consume the same cache rather than reaching the synchronous list helper.
	BrowserBody := _DriverFuncBody("_LLM_ModelBrowser_GetInstalledTags")
	Assert(BrowserBody != "", "model_browser must define _LLM_ModelBrowser_GetInstalledTags()")
	Assert(InStr(BrowserBody, "_LLM_GetInstalledTagsCached()") > 0
			&& !InStr(BrowserBody, "LLM_OllamaListModels("),
		"Model browser open/filter must use the installed-tags cache and never synchronously call /api/tags")
}

Test("meta llm: installed-tags menu probe is non-blocking (menu-build-sync-api-tags-freeze)",
	_MetaCheckInstalledTagsNonBlocking)





; ==================================
; ==================================
; ======= 2/ Cache behaviour =======
; ==================================
; ==================================

_MetaInstalledTagsCacheReadAndWrite() {
	global _LLM_InstalledTagsCache, _LLM_InstalledTagsCacheAt
	_LLM_InstalledTagsCache := unset
	_LLM_InstalledTagsCacheAt := 0
	AssertFalse(LLM_InstalledTagsCacheReady(),
		"the isolated fixture must begin with an unpublished installed-tags snapshot")
	; Pure read returns exactly what the single writer stashed — no network.
	LLM_SetInstalledTagsCache(["qwen3.5:0.8b", "llama3.1:8b"])
	AssertTrue(LLM_InstalledTagsCacheReady())
	got := _LLM_GetInstalledTagsCached()
	AssertTrue(got is Array, "_LLM_GetInstalledTagsCached must return an Array")
	AssertEqual(2, got.Length, "the cache read must return both stashed tags")
	AssertEqual("qwen3.5:0.8b", got[1], "first cached tag must round-trip")
	AssertEqual("llama3.1:8b", got[2], "second cached tag must round-trip")

	; A non-array write is coerced to an empty list (fail-safe, never throws on read).
	LLM_SetInstalledTagsCache("not-an-array")
	AssertEqual(0, _LLM_GetInstalledTagsCached().Length,
		"LLM_SetInstalledTagsCache must coerce a non-array to []")

	; Restore the cold-cache state so later suite tests see the default empty list.
	_LLM_InstalledTagsCache := unset
	_LLM_InstalledTagsCacheAt := 0
}
Test("meta llm: installed-tags cache is a pure read/write of the in-memory snapshot",
	_MetaInstalledTagsCacheReadAndWrite)

_MetaInstalledTagsListChangedSetSemantics() {
	; The flip-guard helper must compare as SETS (order-insensitive) so the tray
	; repaints on a real install/uninstall but not on a reordered identical list.
	AssertTrue(_LLM_InstalledTagsListChanged([], ["a"]),
		"empty -> one tag must count as changed (first probe paints the dot)")
	AssertTrue(!_LLM_InstalledTagsListChanged(["a"], ["a"]),
		"identical single-tag lists must NOT count as changed (no rebuild loop)")
	AssertTrue(_LLM_InstalledTagsListChanged(["a"], ["a", "b"]),
		"a newly-installed tag must count as changed")
	AssertTrue(!_LLM_InstalledTagsListChanged(["a", "b"], ["b", "a"]),
		"the same set in a different order must NOT count as changed (set semantics)")
	AssertTrue(_LLM_InstalledTagsListChanged(["a", "b"], ["a", "c"]),
		"a swapped tag must count as changed")
}
Test("meta llm: _LLM_InstalledTagsListChanged uses order-insensitive set semantics",
	_MetaInstalledTagsListChangedSetSemantics)
