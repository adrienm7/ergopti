; infra/perf_budget.ahk

; ==============================================================================
; MODULE: Performance Budget Report
; DESCRIPTION:
; The one warning the Windows driver writes when a measured operation (the
; boot, an AI request) took longer than its budget of the [budgets] section of
; _shared/modules/timings/constants.toml: the AutoHotkey port of
; _shared/lua/perf_budget.lua, with the same line, so one search and
; tools/dev/field-log-analyse.py read every OS's overruns alike.
;
; FEATURES & RATIONALE:
; 1. The caller reads the budget at the call site (TimingsGet("budgets", key)),
;    so the timings liveness gate sees which driver reads which budget, and this
;    file holds no copy of a number.
; 2. Names only: the measure is a closed code, never typed text, a path or a
;    model answer; a name outside the grammar throws.
; ==============================================================================

#Requires AutoHotkey v2.0

/**
 * Writes the overrun warning when a measure exceeds its budget.
 * @param {String} Tag - The caller's logger tag.
 * @param {String} What - The measure, a closed code such as "boot" or "llm.remote".
 * @param {Number} ElapsedMs - What the operation took.
 * @param {Number} BudgetMs - Its budget, read from [budgets].
 * @returns {Boolean} True when the warning was written.
 */
PerfBudget_Report(Tag, What, ElapsedMs, BudgetMs) {
	if !RegExMatch(What, "^[A-Za-z0-9_.:\-]+$")
		throw ValueError("PerfBudget_Report: the measure must be a closed code, got " . What)
	if !IsNumber(ElapsedMs) || ElapsedMs < 0
		throw ValueError("PerfBudget_Report: ElapsedMs must be a nonnegative number")
	if !IsNumber(BudgetMs) || BudgetMs <= 0
		throw ValueError("PerfBudget_Report: BudgetMs must be positive")
	if (ElapsedMs <= BudgetMs)
		return false
	LoggerWarn(Tag, "Over budget: {1} took {2} ms (budget {3} ms).", What, Round(ElapsedMs), Floor(BudgetMs))
	return true
}
