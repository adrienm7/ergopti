; modules/keystats/keystats_reader_partial.ahk

; ==============================================================================
; MODULE: Keystats Reader — Partial history reads
; DESCRIPTION:
; Lets a dashboard projection keep the rows of every query SQLite answered
; when another query of the same read is refused, and says which part of the
; dashboard data that read left incomplete.
;
; FEATURES & RATIONALE:
; 1. Opt-in scope. Outside KLR_BeginPartialRead every refused query still
;    throws, as every ordinary caller and test expects; only the projection
;    worker opens the scope.
; 2. Whole-query granularity. SQLite_Query returns no row of a failed
;    statement, so a refused query contributes nothing and every other query
;    keeps its exact counts. Nothing is estimated or filled in.
; 3. Two parts. The manifest (KPI counters) and the n-gram range data are
;    flagged separately, the same split the shared dashboard displays.
; 4. Structural records. A refusal keeps its part, its query label and the
;    SQLite result code, never SQL text, paths, applications or typed text.
; ==============================================================================

#Requires AutoHotkey v2.0

; A refusal that the projection may show around. SQLite query failures carry
; their own message shape; other reader steps raise this class explicitly.
class KLRReadRefusal extends Error {
}

class KLRPartialRead {
		; True while a projection worker reads with refusals tolerated.
		static active := false
		; Array of Map(part, label, rc) collected during the open read.
		static refused := []
}

/**
 * Opens a read whose refused queries are recorded instead of thrown.
 * @throws {Error} When a partial read is already open: reads never nest.
 */
KLR_BeginPartialRead() {
		if KLRPartialRead.active
				throw Error("A partial metrics read is already open.")
		KLRPartialRead.refused := []
		KLRPartialRead.active := true
}

/**
 * Closes the open partial read.
 * @returns {Array} Refusals recorded since KLR_BeginPartialRead, empty when complete.
 * @throws {Error} When no partial read is open.
 */
KLR_EndPartialRead() {
		if !KLRPartialRead.active
				throw Error("No partial metrics read is open.")
		Refused := KLRPartialRead.refused
		KLRPartialRead.active := false
		KLRPartialRead.refused := []
		return Refused
}

/**
 * Tells whether a closed read missed rows of one dashboard part.
 * @param Refused {Array} Result of KLR_EndPartialRead.
 * @param Part {String} "manifest" or "range".
 * @returns {Boolean} True when at least one query of that part was refused.
 */
KLR_PartialReadMissed(Refused, Part) {
		for Refusal in Refused
				if Refusal["part"] == Part
						return true
		return false
}

/**
 * Describes refusals for a diagnostic line, with no private data.
 * @param Refused {Array} Result of KLR_EndPartialRead.
 * @returns {String} "part/label rc=N" items joined by commas.
 */
KLR_DescribePartialRead(Refused) {
		Text := ""
		for Refusal in Refused
				Text .= (Text = "" ? "" : ", ") . Refusal["part"] . "/" . Refusal["label"]
						. (Refusal["rc"] != "" ? " rc=" . Refusal["rc"] : "")
		return Text
}

/**
 * Runs one reader step, tolerating its refusal inside a partial read.
 * @param Part {String} "manifest" or "range".
 * @param Label {String} Stable structural name of the step.
 * @param Step {Func} Callable producing the step's result.
 * @param Empty Value standing for the refused step's contribution.
 * @returns The step's result, or Empty after a recorded refusal.
 */
KLR_PartialStep(Part, Label, Step, Empty) {
		if !KLRPartialRead.active
				return Step.Call()
		try return Step.Call()
		catch Error as Err {
				Code := ""
				if RegExMatch(Err.Message, "^SQLite query (?:prepare|step) failed \(rc=(-?\d+)\)", &Match)
						Code := Match[1]
				else if !(Err is KLRReadRefusal)
						throw Err
				KLRPartialRead.refused.Push(Map("part", Part, "label", Label, "rc", Code))
				return Empty
		}
}

/**
 * Runs one projection query through KLR_PartialStep.
 * @param db {Integer} Open reader database.
 * @param Sql {String} SELECT statement.
 * @param Part {String} "manifest" or "range".
 * @param Label {String} Stable structural name of the query.
 * @returns {Array} Rows, or an empty Array after a recorded refusal.
 */
KLR_ProjectionQuery(db, Sql, Part, Label) {
		return KLR_PartialStep(Part, Label, SQLite_Query.Bind(db, Sql), [])
}
