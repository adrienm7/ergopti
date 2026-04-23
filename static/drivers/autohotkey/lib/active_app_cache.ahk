; static/drivers/autohotkey/lib/active_app_cache.ahk

; ==============================================================================
; MODULE: Active Application Cache
; DESCRIPTION:
; Tiny, time-bounded cache around ``WinGetClass`` / ``WinGetProcessName``
; used by the hotstring engine and shortcut handlers to decide whether to
; route output through Notepad-specific paths or apply Microsoft-Office
; quirks. Cuts the cost of seven sequential ``WinActive`` calls per
; hotstring firing down to a single check at most every 100 ms.
;
; FEATURES & RATIONALE:
; 1. Lazy refresh: the cache is consulted on every keystroke, but the actual
;    Win32 calls happen at most every ``ACTIVE_APP_CACHE_TTL_MS``. The TTL is
;    intentionally short so window switches are picked up almost instantly
;    (the user cannot type fast enough for the staleness to matter).
; 2. One-call-fits-all: returns a small object exposing ``Class``, ``Exe``,
;    ``IsNotepad`` and ``IsMicrosoftOffice`` so callers never have to
;    re-derive those flags. New flags (e.g. ``IsTerminal``) can be added
;    in one place.
; 3. Failure tolerance: ``WinGetClass`` / ``WinGetProcessName`` can throw
;    when no window is active (e.g. UAC prompt foreground). Calls are
;    wrapped so a transient failure produces an "unknown app" cache entry
;    instead of crashing the keyboard driver.
; ==============================================================================




; ==============================================
; ==============================================
; ======= 1/ Constants and shared state =======
; ==============================================
; ==============================================

; Refresh window — the cache can be at most this many milliseconds stale.
; 100 ms is well below the human window-switch reaction time and well above
; the per-keystroke firing rate at any realistic typing speed.
global ACTIVE_APP_CACHE_TTL_MS := 100

; Set of Microsoft Office (and Teams) executable names. Keys are the
; ``WinGetProcessName`` values; values are unused (Map-as-Set idiom).
global MICROSOFT_OFFICE_EXES := Map(
	"Teams.exe", true,
	"ms-teams.exe", true,
	"ONENOTE.exe", true,
	"olk.exe", true,
	"OUTLOOK.EXE", true,
	"WINWORD.EXE", true,
	"EXCEL.EXE", true,
	"POWERPNT.EXE", true,
)

; Cached snapshot of the active app. ``ts`` is the A_TickCount at which the
; values below were captured; everything else is reset on each refresh.
global _ActiveAppCache := {
	ts: 0,
	Class: "",
	Exe: "",
	IsNotepad: false,
	IsMicrosoftOffice: false,
}




; ==================================
; ==================================
; ======= 2/ Public API =======
; ==================================
; ==================================

; Return a snapshot of the active application, refreshing the cache when
; it has been stale for more than ``ACTIVE_APP_CACHE_TTL_MS`` milliseconds.
; The returned object is a stable reference — callers can read fields off
; it directly without copying.
GetActiveApp() {
	global _ActiveAppCache, ACTIVE_APP_CACHE_TTL_MS, MICROSOFT_OFFICE_EXES
	Now := A_TickCount
	if (Now - _ActiveAppCache.ts < ACTIVE_APP_CACHE_TTL_MS and _ActiveAppCache.ts != 0) {
		return _ActiveAppCache
	}

	WindowClass := ""
	WindowExe := ""
	try WindowClass := WinGetClass("A")
	try WindowExe := WinGetProcessName("A")

	_ActiveAppCache.ts := Now
	_ActiveAppCache.Class := WindowClass
	_ActiveAppCache.Exe := WindowExe
	_ActiveAppCache.IsNotepad := (WindowClass == "Notepad")
	_ActiveAppCache.IsMicrosoftOffice := MICROSOFT_OFFICE_EXES.Has(WindowExe)
	return _ActiveAppCache
}

; Force-invalidate the cache so the next ``GetActiveApp`` re-reads from
; Win32. Useful after operations that change the foreground window
; programmatically (``WinActivate``, ``Run``).
InvalidateActiveAppCache() {
	global _ActiveAppCache
	_ActiveAppCache.ts := 0
}
