; tests/unit/test_tooltip_dequeue_contract.ahk

; ==============================================================================
; MODULE: Tooltip Dequeue Contract Test (AHK)
; DESCRIPTION:
; Validates the AHK stacked-tooltip dequeue logic against the canonical test
; vectors defined in _shared/tests/corpus/tooltip/dequeue_vectors.json.
; Loads the shared JSON at registration time so the vectors are always in sync
; with the cross-driver corpus.
;
; Mirrors the macOS test_tooltip_dequeue_contract.lua, which replays the same
; vectors through the Hammerspoon dequeue module.
; ==============================================================================

#Requires AutoHotkey v2.0






; =================================================================
; =================================================================
; ======= 1/ Corpus Loading =======================================
; =================================================================
; =================================================================

_DequeueContract_LoadCorpus() {
	; A_ScriptDir is the runner's directory (windows/tests/), not this file's.
	; ..\..\_shared resolves to ergopti_plus\_shared — same convention as all
	; other corpus tests (test_corpus_keylogger_aggregation.ahk, etc.).
	Path := A_ScriptDir . "\..\..\_shared\tests\corpus\tooltip\dequeue_vectors.json"
	if !FileExist(Path)
		return ""
	Raw := FileRead(Path, "UTF-8")
	return JsonParse(Raw)
}




; =================================================================
; =================================================================
; ======= 2/ Dequeue Helpers (mirror _shared/modules/tooltip/dequeue.js) =
; =================================================================
; =================================================================

; Effective duration: callerDurationSec - decrement, floored.
_DequeueContract_EffDur(CallerDurationSec) {
	if (!(CallerDurationSec > 0))
		return 0
	return Max(0.05, CallerDurationSec - 0.2)
}

; Stamp expiry times on rows.
_DequeueContract_Stamp(Rows, NowMs) {
	Stamped := []
	MaxRem := 0
	for Row in Rows {
		Copy := Map()
		for k, v in Row
			Copy[k] := v
		d := Row.Has("durationSec") ? Row["durationSec"] : 0
		if (d > 0) {
			Eff := _DequeueContract_EffDur(d)
			ExpMs := NowMs + Round(Eff * 1000)
			Copy["expireMs"] := ExpMs
			Rem := Max(50, ExpMs - NowMs)
			if (Rem > MaxRem)
				MaxRem := Rem
		} else {
			Copy["expireMs"] := 0
		}
		Stamped.Push(Copy)
	}
	return { rows: Stamped, maxRemainingMs: MaxRem }
}

; Prune rows whose expireMs deadline has passed.
_DequeueContract_Prune(Rows, NowMs) {
	Remaining := []
	for Row in Rows {
		Expiry := Row.Has("expireMs") ? Row["expireMs"] : 0
		if (Expiry = 0 or NowMs < Expiry)
			Remaining.Push(Row)
	}
	return Remaining
}

; Milliseconds until the earliest not-yet-expired row deadline.
_DequeueContract_NextDelayMs(Rows, NowMs) {
	Earliest := 0
	for Row in Rows {
		Expiry := Row.Has("expireMs") ? Row["expireMs"] : 0
		if (Expiry > 0 and NowMs < Expiry) {
			if (Earliest = 0 or Expiry < Earliest)
				Earliest := Expiry
		}
	}
	if (Earliest = 0)
		return 0
	return Max(50, Earliest - NowMs)
}

; Determine whether the dequeue (per-row expiry) path is required.
_DequeueContract_ShouldDequeue(Rows) {
	for Row in Rows {
		if (Row.Has("expireMs") and Row["expireMs"] > 0)
			return true
	}
	FirstDur := 0
	HasAny := false
	HasMixed := false
	for Row in Rows {
		d := Row.Has("durationSec") ? Row["durationSec"] : 0
		if (d > 0) {
			HasAny := true
			if (FirstDur = 0)
				FirstDur := d
			else if (d != FirstDur)
				HasMixed := true
		}
	}
	return HasAny and HasMixed
}




; =================================================================
; =================================================================
; ======= 3/ Vector Runner ========================================
; =================================================================
; =================================================================

; Replays a single corpus vector and asserts every step. Called inside a
; single Test() callback per vector (avoiding the AHK v2 for-loop closure
; capture issue — loop variables are not available in deferred callbacks).
_DequeueContract_RunVector(Vec) {
	Id := Vec.Has("id") ? Vec["id"] : "unknown"
	Rows := Vec.Has("rows") ? Vec["rows"] : []

	; ── should_use_dequeue_path ──
	ExpectDQ := Vec.Has("expectDequeue") ? Vec["expectDequeue"] : false
	ActualDQ := _DequeueContract_ShouldDequeue(Rows)
	AssertEqual(ExpectDQ, ActualDQ, Id . " should_use_dequeue_path")

	; ── steps ──
	if !Vec.Has("steps")
		return

	Stamped := []
	for Step in Vec["steps"] {
		AtMs := Step.Has("atMs") ? Step["atMs"] : 0
		Action := Step.Has("action") ? Step["action"] : ""

		if (Action = "stamp") {
			Result := _DequeueContract_Stamp(Rows, AtMs)
			Stamped := Result.rows
			ExpectIds := Step.Has("expectIds") ? Step["expectIds"] : []
			AssertEqual(ExpectIds.Length, Stamped.Length,
				Id . " stamp @" . AtMs . " — row count")
			for i, Sid in ExpectIds {
				AssertEqual(Sid, Stamped[i]["id"],
					Id . " stamp @" . AtMs . " — id[" . i . "]")
			}
			if Step.Has("expectExpiries") {
				for id, ExpMs in Step["expectExpiries"] {
					Found := false
					for Row in Stamped {
						if (Row.Has("id") and Row["id"] = id) {
							AssertEqual(ExpMs, Row["expireMs"],
								Id . " stamp @" . AtMs . " — expiry " . id)
							Found := true
							break
						}
					}
					if !Found
						AssertTrue(false, Id . " stamp @" . AtMs . " — row " . id . " not found")
				}
			}
		} else if (Action = "prune") {
			Remaining := _DequeueContract_Prune(Stamped, AtMs)
			ExpectIds := Step.Has("expectIds") ? Step["expectIds"] : []
			AssertEqual(ExpectIds.Length, Remaining.Length,
				Id . " prune @" . AtMs . " — row count")
			for i, Sid in ExpectIds {
				AssertEqual(Sid, Remaining[i]["id"],
					Id . " prune @" . AtMs . " — id[" . i . "]")
			}
			if Step.Has("expectNextDelayMs") {
				DelayMs := _DequeueContract_NextDelayMs(Remaining, AtMs)
				AssertEqual(Step["expectNextDelayMs"], DelayMs,
					Id . " prune @" . AtMs . " — next delay")
			}
			Stamped := Remaining
		}
	}
}




; =================================================================
; =================================================================
; ======= 4/ Test Registration ====================================
; =================================================================
; =================================================================

_DequeueContract_RegisterAll() {
	Corpus := _DequeueContract_LoadCorpus()
	if (Corpus = "") {
		Test("dequeue contract: corpus file exists", () => AssertTrue(false,
			"Corpus file not found — _shared/tests/corpus/tooltip/dequeue_vectors.json"))
		return
	}
	if !Corpus.Has("vectors") {
		Test("dequeue contract: valid structure", () => AssertTrue(false,
			"No 'vectors' key in corpus JSON"))
		return
	}

	; One Test() per vector — all assertions run synchronously inside the
	; callback, avoiding the AHK v2 for-loop closure capture issue.
	for Vec in Corpus["vectors"] {
		Id := Vec.Has("id") ? Vec["id"] : "unknown"
		Desc := Vec.Has("description") ? Vec["description"] : Id
		NameCopy := "[corpus:dequeue:" . Id . "] " . SubStr(Desc, 1, 50)
		; .Bind, never an inline fat-arrow over a loop-scoped copy — see
		; project_ahk_loop_capture_copy_freezes_nothing. Every closure would share
		; the one VecCopy slot and replay the LAST vector under every name.
		Test(NameCopy, _DequeueContract_RunVector.Bind(Vec))
	}
}

_DequeueContract_RegisterAll()
