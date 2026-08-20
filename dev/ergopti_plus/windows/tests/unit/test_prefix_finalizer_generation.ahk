; tests/unit/test_prefix_finalizer_generation.ahk

; ==============================================================================
; MODULE: Prefix deferred-finalizer generation fences
; DESCRIPTION:
; Buffer commits deliberately leave Critical before tooltip/metrics work. A
; physical character can publish a newer suggestion in that gap; an unfenced old
; finalizer then hides and records dismissal for the new state. These tests use a
; sentinel suggestion and stale immutable commits so any side effect is visible
; without opening a real tooltip.
; ==============================================================================

#Requires AutoHotkey v2.0

_PFG_StaleContextFinalizerCannotDismissNewSuggestion() {
	global _PrefixInputContextGeneration, _PrefixContentGeneration
	global _KLLastShownSuggestion
	SavedSuggestion := _KLLastShownSuggestion
	Sentinel := { NewSuggestion: true }
	try {
		_KLLastShownSuggestion := Sentinel
		StaleCommit := {
			ClearedBuffer: "old",
			Generation: _PrefixInputContextGeneration - 1,
			ContentGeneration: _PrefixContentGeneration - 1
		}
		AssertFalse(_PrefixFinishInputContext(StaleCommit),
			"a context finalizer superseded across the Critical boundary must no-op")
		AssertTrue(_KLLastShownSuggestion == Sentinel,
			"the stale context finalizer must not hide/dismiss the newer suggestion")
	} finally {
		_KLLastShownSuggestion := SavedSuggestion
	}
}

Test("Prefix finalizer: stale context effects cannot dismiss newer input (prefix-finalizer-generation)",
	_PFG_StaleContextFinalizerCannotDismissNewSuggestion)

_PFG_StaleBackspaceFinalizerCannotDismissNewSuggestion() {
	global _PrefixContentGeneration, _KLLastShownSuggestion
	SavedSuggestion := _KLLastShownSuggestion
	Sentinel := { NewSuggestion: true }
	try {
		_KLLastShownSuggestion := Sentinel
		StaleCommit := {
			Buffer: "newer",
			ContentGeneration: _PrefixContentGeneration - 1
		}
		AssertFalse(_PrefixFinishBackspace(StaleCommit),
			"a backspace finalizer superseded across the Critical boundary must no-op")
		AssertTrue(_KLLastShownSuggestion == Sentinel,
			"the stale backspace finalizer must not hide/dismiss the newer suggestion")
	} finally {
		_KLLastShownSuggestion := SavedSuggestion
	}
}

Test("Prefix finalizer: stale backspace effects cannot dismiss newer input (prefix-finalizer-generation)",
	_PFG_StaleBackspaceFinalizerCannotDismissNewSuggestion)
