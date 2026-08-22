# Audit report contract

An audit is immutable evidence, not a mutable implementation checklist. Record
the exact audited commit and let implementation status derive from Git trailers.

## Location

Use one new directory and never overwrite an earlier pass:

- `docs/audits/ahk/<YYYY_MM_DD>/report.md`
- `docs/audits/hammerspoon/<YYYY_MM_DD>/report.md`

Place `findings.json` beside `report.md`. Folder dates use underscores; the
metadata date uses ISO `YYYY-MM-DD`.

## Human report

Include the audited SHA, scope and coverage; executive summary; confirmed
findings by severity; performance claims with provenance; memory watch-list;
refuted hypotheses and their proof; and explicit coverage gaps. Line numbers are
navigation hints, never the only evidence.

## Machine manifest

Only confirmed, actionable findings belong in `findings`. Keep hypotheses and
refutations in the human report.

```json
{
	"schema_version": 1,
	"scope": "ahk",
	"audited_sha": "0123456789abcdef0123456789abcdef01234567",
	"created_at": "2026-08-22",
	"report_path": "docs/audits/ahk/2026_08_22/report.md",
	"findings": [
		{
			"id": "AHK-001",
			"title": "Short observable failure",
			"severity": "high",
			"confidence": "high",
			"guarantees": ["G2", "G3"],
			"reproduction": "Exact state and action sequence",
			"root_cause": "Current mechanism that permits the failure",
			"silent_failure": "Why existing diagnostics/tests do not expose it",
			"regression_test": "Behavior or invariant the new test must encode"
		}
	]
}
```

Use scope `hammerspoon` and IDs `HS-001`, `HS-002`, and so on for macOS.
Severity is `critical`, `high`, `medium`, or `low`; confidence is `high`,
`medium`, or `low`. IDs are unique and stable.

Validate before delivery:

```text
node tools/audit/workflow.cjs validate-report --report <path-to-findings.json>
```
