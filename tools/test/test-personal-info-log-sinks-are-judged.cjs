/**
 * ==============================================================================
 * MODULE: Personal-Info Log Sinks Are Judged
 * DESCRIPTION:
 * Derives every site — across all three drivers — where a hotstring trigger, a
 * replacement, or a resolved personal_info value flows into a log line or a
 * persisted row, and refuses to let one exist that nobody has ruled on.
 *
 * WHY IT IS BUILT THIS WAY:
 * The privacy work that produced this gate was attempted three times from a
 * hand-written list of sites, and each list was short. The first named two
 * sinks; widening the search to the whole driver found eight; and the scanner's
 * own fixed three-line window then hid four more, because
 * KL_LogHotstringNearMiss puts "trigger" on the fourth line of its
 * KL_AppendLog(Map(...)). Enumeration by memory does not converge.
 *
 * So the LIST is derived and only the JUDGEMENT is written down. A new sink
 * appears in the scan the moment it is added and fails this gate until someone
 * says what it does with the value. A judgement that no longer matches any site
 * also fails, so the ledger cannot outlive the code it describes.
 *
 * ROOT CAUSE ENCODED:
 * A personal_info mapping puts the user's IBAN, card number or SSN into the
 * replacement, and a log is not a screen: today.log is ingested into the metrics
 * store, replicated to every other device and kept for fourteen days.
 *
 * SEVERITY IS NOT A SAFEGUARD UNTIL YOU CHECK THE DEFAULT. On Windows,
 * LoggerError and HotPath_LogIfSlow sit ABOVE the default INFO level, so those
 * lines reach the file with no user action while a LoggerDebug needs the level
 * switched on. On the Lua side there is no such distinction at all: the shared
 * logger's default minimum is 10, debug included, so a "verbose only" line is an
 * always-on line — which is exactly how the shared engine came to print every
 * resolved @-tag value in full, on both Lua drivers, for as long as it existed.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SHARED_ROOT = path.join(ROOT, 'static', 'ergopti_plus');
const DRIVER = path.join(SHARED_ROOT, 'windows');

// Everything that writes somewhere durable: the rotating log, or today.log.
const SINKS = [
	'LoggerDebug', 'LoggerInfo', 'LoggerWarn', 'LoggerError',
	'LoggerTrace', 'LoggerDone', 'LoggerStart', 'LoggerSuccess',
	'HotPath_LogIfSlow', 'KL_AppendLog', 'OutputDebug'
];

// The names a hotstring's two secret-bearing columns travel under.
const CARRIERS = /\b(?:\w+\.)?(?:Trigger|Replacement|Output)\b|\btrigger\b|\breplacement\b/;

// A call that mentions one of these has already dealt with the value: it either
// redacts in place or reads a name that only ever holds a redacted copy.
const REDACTORS = [
	'PersonalInfoRedactForLog',
	'_PrefixLogSafe',
	'logged_trigger',
	'logged_replacement'
];

// ── The Lua half ─────────────────────────────────────────────────────────────
//
// Scoped to the modules that handle personal_info values BY CONSTRUCTION rather
// than to the whole tree: a driver-wide net on names as ordinary as `value` and
// `result` returns 160-odd sites, almost all of them a pcall error being
// stringified, and a gate whose output is mostly noise is a gate that gets
// skimmed. These directories are where a resolved @-tag can actually appear.
const LUA_TREES = [
	'_shared/lua/dynamic_hotstrings',
	'linux/modules/dynamic_hotstrings',
	'macos/modules/dynamic_hotstrings',
	'linux/infra/personal_info_fields.lua',
	'macos/infra/personal_info_fields.lua'
];

const LUA_SINKS = [
	'Logger.debug', 'Logger.info', 'Logger.warn', 'Logger.error',
	'Logger.trace', 'Logger.done', 'Logger.start', 'Logger.success'
];

const LUA_CARRIERS = /\b(?:result|parts|values|replacement|expansion|value)\b|_info\[/;

// A Lua call is safe when the carrier reaches it only as a LENGTH (`#result`)
// or through a redactor. `content withheld` is the phrase the redacted lines
// use, and matching it keeps the check readable in both directions.
const LUA_REDACTORS = [
	'#result', '#match.result', '#value', '#text',
	'for_log(', 'redact_for_log(', 'content withheld'
];

/**
 * Judgements on the sites that carry a trigger but do NOT redact in place.
 *
 * Keyed by file plus a fragment that must appear in the call text — line numbers
 * churn on every edit above them and would turn this into a maintenance tax that
 * the next person disables. Each entry states a verdict and why it holds.
 *
 * `match` is tested against the call with runs of whitespace collapsed to one
 * space, so a fragment stays valid when the call is re-wrapped or re-indented.
 *
 * `verdict` is one of:
 *   withheld-by-caller — the sink is reached only after the caller returned
 *                        early for a private mapping, so no private value can
 *                        arrive. The guard is upstream, not here.
 *   not-personal       — the identifier matched the carrier pattern but does not
 *                        hold a hotstring value at all.
 */
const JUDGED = [
	{
		file: 'infra/config_io.ahk',
		match: 'Reset to defaults refused because LLM trigger',
		verdict: 'not-personal',
		why: 'both constant diagnostics refer to the LLM keyboard-shortcut recovery state and interpolate no value.'
	},
	{
		file: 'infra/hotstrings/hotstrings_io.ahk',
		match: 'Global delimiter sets published after durable override replacement.',
		verdict: 'not-personal',
		why: 'replacement describes the completed atomic file operation; the constant diagnostic carries no mapping value.'
	},
	{
		file: 'infra/hotstrings/hotstring_dispatch.ahk',
		match: 'Resolving a dynamic replacement failed; exception detail withheld.',
		verdict: 'not-personal',
		why: 'the call deliberately withholds the resolver exception and interpolates no trigger or replacement content.'
	},
	{
		file: 'infra/hotstrings/hotstring_dispatch.ahk',
		match: "A hotstring replacement resolved to '{1}', not String",
		verdict: 'not-personal',
		why: 'the only interpolation is Type(ResolvedBase), a runtime type name rather than the resolved value.'
	},
	{
		file: 'infra/hotstrings/personal_toml_io.ahk',
		match: "Atomic replacement of '{1}' succeeded, but live publication",
		verdict: 'not-personal',
		why: 'both calls interpolate the bounded personal-TOML config path and, on failure, publication error metadata; no file contents or mapping values.'
	},
	{
		file: 'infra/lifecycle.ahk',
		match: 'Reload refused because LLM trigger recovery is incomplete.',
		verdict: 'not-personal',
		why: 'the constant diagnostic refers to LLM keyboard-shortcut recovery and carries no user value.'
	},
	{
		file: 'infra/lifecycle.ahk',
		match: 'LLM trigger journal shutdown recovery failed: {1}.',
		verdict: 'not-personal',
		why: 'the interpolation is recovery-service error metadata; trigger means the LLM keyboard shortcut.'
	},
	{
		file: 'infra/lifecycle.ahk',
		match: 'Shutdown refused because LLM trigger journal recovery is incomplete.',
		verdict: 'not-personal',
		why: 'the constant diagnostic carries no value; trigger means the LLM keyboard shortcut.'
	},
	{
		file: 'infra/wrap_symbols_config.ahk',
		match: "Atomic replacement of '{1}' failed: {2}.",
		verdict: 'not-personal',
		why: 'the interpolation is the bounded wrap-symbols config path plus filesystem error metadata, never hotstring content.'
	},
	{
		file: 'infra/wrap_symbols_config.ahk',
		match: "Atomic replacement of '{1}' was refused.",
		verdict: 'not-personal',
		why: 'the interpolation is the bounded wrap-symbols config path, never hotstring content.'
	},
	{
		file: 'platform/remap/tap_hold_writer.ahk',
		match: "Atomic replacement of '{1}' failed: {2}.",
		verdict: 'not-personal',
		why: 'the interpolation is the bounded tap-hold config path plus filesystem error metadata, never hotstring content.'
	},
	{
		file: 'platform/remap/tap_hold_writer.ahk',
		match: "Atomic replacement of '{1}' was refused.",
		verdict: 'not-personal',
		why: 'the interpolation is the bounded tap-hold config path, never hotstring content.'
	},
	{
		file: 'ui/menu/menu_llm/actions.ahk',
		match: "is not installed — switched to",
		verdict: 'not-personal',
		why: 'replacement is the fallback LLM model name; all interpolations are model identifiers and fixed backend tags.'
	},
	{
		file: 'infra/hotstrings/hotstring_dispatch.ahk',
		match: 'FIRE private mapping',
		verdict: 'not-personal',
		why: 'the private branch itself: prints counts and says in the message that the trigger and the content are withheld. It matched only because the prose contains the word "trigger".'
	},
	{
		file: 'infra/hotstrings/hotstring_dispatch.ahk',
		match: 'FIRE trig=',
		verdict: 'withheld-by-caller',
		why: 'the private branch is the sibling call ~5 lines above ("FIRE private mapping … trigger and content withheld"), which returns; this one is the else.'
	},
	{
		file: 'infra/hotstrings/hotstring_inputhook.ahk',
		match: 'Fire-log drain failed',
		verdict: 'withheld-by-caller',
		why: '`Named` is assigned on the preceding line as Rec.IsPrivate ? PersonalInfoRedactForLog(Rec.Trigger) : Rec.Trigger.'
	},
	{
		file: 'infra/hotstrings/hotstring_inputhook.ahk',
		match: 'Index rebuilt:',
		verdict: 'not-personal',
		why: 'prints NewSet.Count — how many triggers were indexed, never one of them.'
	},
	{
		file: 'infra/hotstrings/hotstring_inputhook.ahk',
		match: '"type", kind,',
		verdict: 'withheld-by-caller',
		why: 'KL_LogHotstringNearMiss; both call sites return early via _NearMissIsWithheld before reaching it.'
	},
	{
		file: 'ui/menu/menu_rebuild.ahk',
		match: 'LLM trigger recovery watchdog service failed: {1}.',
		verdict: 'not-personal',
		why: 'the interpolation is recovery-service error metadata; trigger means the LLM keyboard shortcut, never hotstring content.'
	},
	{
		file: 'infra/hotstrings/hotstrings_io.ahk',
		match: "Atomic replacement of override file '{1}' raised: {2}.",
		verdict: 'not-personal',
		why: 'the interpolated value is the fixed config-directory overrides filename plus OS error metadata, never a trigger or replacement.'
	},
	{
		file: 'infra/hotstrings/hotstrings_io.ahk',
		match: "Atomic replacement of override file '{1}' failed (Windows error {2}).",
		verdict: 'not-personal',
		why: 'the interpolated value is the fixed config-directory overrides filename plus an OS error code, never a trigger or replacement.'
	},
	{
		file: 'modules/keylogger/keylogger_hotstring_log.ahk',
		match: 'private mapping cat=',
		verdict: 'not-personal',
		why: 'the private branch itself: prints category and section, and says the trigger is withheld.'
	},
	{
		file: 'modules/keylogger/keylogger_hotstring_log.ahk',
		match: "KL_LogHotstring: trigger='{1}'",
		verdict: 'withheld-by-caller',
		why: 'the else of the branch above — is_private already returned.'
	},
	{
		file: 'modules/keylogger/keylogger_trigger_roi.ahk',
		match: '"type", "trigger_halflife"',
		verdict: 'withheld-by-caller',
		why: 'trig is a key of KLRoi.trigger_last_use, and KL_Roi_OnHotstring skips that map entirely when is_private.'
	},
	{
		file: 'modules/keylogger/keylogger.ahk',
		match: '"hotstring_suggested"',
		verdict: 'withheld-by-caller',
		why: '_NotifySuggestionShown returns before calling it when IsPrivate — the pair is withheld whole because the replacement IS the secret.'
	},
	{
		file: 'modules/keylogger/keylogger.ahk',
		match: '"hotstring_dismissed"',
		verdict: 'withheld-by-caller',
		why: '_KLEmitSuggestionDismissed returns on Rec.IsPrivate; writing only the second half of the pair would leak by the back door.'
	},
	{
		file: 'modules/updater/self_update.ahk',
		match: 'Background checks refused during channel replacement.',
		verdict: 'not-personal',
		why: '"replacement" describes replacing the updater channel lifecycle; the constant log call interpolates no hotstring trigger, replacement text or other value.'
	},
	{
		file: 'ui/menu/menu_llm/actions.ahk',
		match: 'direct install trigger',
		verdict: 'not-personal',
		why: 'the word "trigger" in prose about a debug hotkey; no interpolated value.'
	},
	{
		file: 'ui/menu/menu_llm/actions.ahk',
		match: 'Trigger shortcut recovery resume service failed: {1}.',
		verdict: 'not-personal',
		why: 'the interpolation is recovery-service error metadata; trigger means the LLM keyboard shortcut.'
	},
	{
		file: 'ui/menu/menu_llm/trigger_shortcut.ahk',
		match: 'Could not publish committed-new trigger journal before native activation.',
		verdict: 'not-personal',
		why: 'the constant diagnostic carries no user value; trigger means the LLM keyboard shortcut.'
	},
	{
		file: 'ui/menu/menu_llm/trigger_shortcut.ahk',
		match: "Rejected trigger shortcut '{1}': {2}.",
		verdict: 'not-personal',
		why: '`raw` is the LLM keyboard chord rejected by the shared chord parser, never a hotstring trigger or replacement.'
	},
	{
		file: 'ui/menu/menu_llm/trigger_shortcut.ahk',
		match: "Rejected trigger shortcut '{1}': native AutoHotkey key syntax is not allowed.",
		verdict: 'not-personal',
		why: '`raw` is the LLM keyboard chord rejected by the native-syntax admission policy, never a hotstring trigger or replacement.'
	},
	{
		file: 'ui/menu/menu_llm/trigger_shortcut.ahk',
		match: "Rejected trigger shortcut '{1}': the pointer key is reserved by the input dispatcher.",
		verdict: 'not-personal',
		why: '`raw` is the LLM keyboard chord rejected because the dispatcher owns that pointer variant, never a hotstring trigger or replacement.'
	},
	{
		file: 'ui/menu/menu_llm/trigger_shortcut.ahk',
		match: "Rejected trigger shortcut '{1}': a modifier has no Windows equivalent.",
		verdict: 'not-personal',
		why: '`raw` is the LLM keyboard chord whose platform modifier mapping failed, never hotstring content.'
	},
	{
		file: 'ui/menu/menu_llm/trigger_shortcut.ahk',
		match: "Could not {1} trigger shortcut '{2}': {3}.",
		verdict: 'not-personal',
		why: 'the interpolated value is an LLM keyboard chord plus closed transaction-stage/error metadata, not a hotstring mapping.'
	},
	{
		file: 'ui/menu/menu_llm/trigger_shortcut.ahk',
		match: 'Trigger shortcut failure notification was refused or returned a malformed status.',
		verdict: 'not-personal',
		why: 'the constant diagnostic contains no interpolated user value; trigger means the LLM keyboard shortcut.'
	},
	{
		file: 'ui/menu/menu_llm/trigger_shortcut.ahk',
		match: 'Could not surface incomplete trigger shortcut activation: {1}.',
		verdict: 'not-personal',
		why: 'the interpolation is notifier error metadata; trigger means the LLM keyboard shortcut.'
	},
	{
		file: 'ui/menu/menu_llm/trigger_shortcut.ahk',
		match: 'Could not retain trigger shortcut recovery: another record is still authoritative.',
		verdict: 'not-personal',
		why: 'the constant diagnostic contains no interpolated user value.'
	},
	{
		file: 'ui/menu/menu_llm/trigger_shortcut.ahk',
		match: 'Trigger shortcut automatic recovery exhausted after {1} attempts;',
		verdict: 'not-personal',
		why: 'the only interpolation is a bounded retry count.'
	},
	{
		file: 'ui/menu/menu_llm/trigger_shortcut.ahk',
		match: 'Could not schedule trigger shortcut recovery: {1}.',
		verdict: 'not-personal',
		why: 'the interpolation is scheduler error metadata, not hotstring content.'
	},
	{
		file: 'ui/menu/menu_llm/trigger_shortcut.ahk',
		match: 'Trigger shortcut recovery scheduling was refused.',
		verdict: 'not-personal',
		why: 'the constant diagnostic contains no interpolated user value.'
	},
	{
		file: 'ui/menu/menu_llm/trigger_shortcut.ahk',
		match: 'Trigger shortcut rollback recovery failed: {1}.',
		verdict: 'not-personal',
		why: 'the interpolation is config-writer failure metadata, not a hotstring trigger or replacement.'
	},
	{
		file: 'ui/menu/menu_llm/trigger_shortcut.ahk',
		match: "Unknown trigger shortcut recovery stage '{1}'.",
		verdict: 'not-personal',
		why: 'the interpolation is a closed transaction-stage token.'
	},
	{
		file: 'ui/menu/menu_llm/trigger_shortcut.ahk',
		match: 'Trigger shortcut recovery attempt raised: {1}.',
		verdict: 'not-personal',
		why: 'the interpolation is recovery error metadata, not hotstring content.'
	},
	{
		file: 'ui/menu/menu_llm/trigger_shortcut.ahk',
		match: 'Could not refresh the recovered trigger shortcut row: {1}.',
		verdict: 'not-personal',
		why: 'the interpolation is menu-refresh error metadata; the row belongs to the LLM keyboard shortcut.'
	},
	{
		file: 'ui/menu/menu_llm/trigger_shortcut.ahk',
		match: "Trigger shortcut replayed as '{1}'.",
		verdict: 'not-personal',
		why: 'the interpolation is the accepted LLM keyboard chord, never a hotstring trigger or replacement.'
	},
	{
		file: 'ui/menu/menu_llm/trigger_shortcut.ahk',
		match: 'Refusing unknown trigger recovery stage',
		verdict: 'not-personal',
		why: 'Stage is a closed transaction-state token supplied only by ConfigCommitBuilt, never user text.'
	},
	{
		file: 'ui/menu/menu_llm/trigger_shortcut.ahk',
		match: "Trigger shortcut committed as '{1}'.",
		verdict: 'not-personal',
		why: 'the interpolation is the accepted LLM keyboard chord, never a hotstring trigger or replacement.'
	},
	{
		file: 'ui/menu/menu_llm/trigger_journal.ahk',
		match: 'Trigger journal rollback found a third durable value and refused to overwrite it.',
		verdict: 'not-personal',
		why: 'the constant diagnostic carries no trigger or replacement value.'
	},
	{
		file: 'ui/menu/menu_llm/trigger_journal.ahk',
		match: 'Trigger journal left read-only quarantine',
		verdict: 'not-personal',
		why: 'the constant diagnostic reports only a closed recovery-state transition.'
	},
	{
		file: 'ui/menu/menu_llm/trigger_journal.ahk',
		match: 'Recovered a pending trigger shortcut transaction',
		verdict: 'not-personal',
		why: 'the constant diagnostic reports recovery of the LLM keyboard shortcut without printing its value.'
	},
	{
		file: 'ui/menu/menu_llm/trigger_journal.ahk',
		match: 'A terminal trigger journal could not be removed',
		verdict: 'not-personal',
		why: 'the constant diagnostic reports artifact cleanup state and interpolates no value.'
	},
	{
		file: 'ui/menu/menu_llm/trigger_journal.ahk',
		match: 'Trigger journal entered read-only quarantine ({1})',
		verdict: 'not-personal',
		why: 'the interpolation is a closed internal quarantine-reason token, never journal contents or a hotstring value.'
	},
	{
		file: 'ui/menu/menu_llm/trigger_journal.ahk',
		match: 'Trigger journal existence probe failed: {1}.',
		verdict: 'not-personal',
		why: 'the interpolation is filesystem error metadata from an existence check; no journal contents were read.'
	},
	{
		file: 'ui/menu/menu_llm/trigger_journal.ahk',
		match: 'Trigger journal existence probe returned a malformed status.',
		verdict: 'not-personal',
		why: 'the constant diagnostic reports adapter status and carries no value.'
	},
	{
		file: 'ui/menu/menu_llm/trigger_journal.ahk',
		match: 'Trigger journal bounded read failed: {1}.',
		verdict: 'not-personal',
		why: 'the interpolation is reader error metadata; the journal payload itself is never passed to the logger.'
	},
	{
		file: 'ui/menu/menu_llm/trigger_journal.ahk',
		match: 'Trigger journal bounded read was refused.',
		verdict: 'not-personal',
		why: 'the constant diagnostic reports adapter refusal and carries no value.'
	},
	{
		file: 'ui/menu/menu_llm/trigger_journal.ahk',
		match: "Trigger journal filesystem operation '{1}' failed: {2}.",
		verdict: 'not-personal',
		why: 'Method is a closed adapter operation name and the second interpolation is filesystem error metadata, not journal contents.'
	},
	{
		file: 'ui/menu/menu_llm/trigger_journal.ahk',
		match: "Trigger journal filesystem operation '{1}' returned a malformed or refused status.",
		verdict: 'not-personal',
		why: 'the only interpolation is a closed adapter operation name.'
	},
	{
		file: 'ui/menu/menu_llm/trigger_journal.ahk',
		match: 'Trigger journal staging verification failed.',
		verdict: 'not-personal',
		why: 'the constant diagnostic reports transaction state and carries no value.'
	},
	{
		file: 'ui/menu/menu_llm/trigger_journal.ahk',
		match: 'Trigger journal is malformed; recovery was refused',
		verdict: 'not-personal',
		why: 'the constant diagnostic reports validation state and does not print the malformed payload.'
	},
	{
		file: 'ui/menu/menu_llm/trigger_journal.ahk',
		match: 'Trigger journal delete reported success but the artifact remains.',
		verdict: 'not-personal',
		why: 'the constant diagnostic reports cleanup state and carries no value.'
	},
	{
		file: 'ui/menu/menu_llm/trigger_journal.ahk',
		match: 'Trigger journal config reader failed: {1}.',
		verdict: 'not-personal',
		why: 'the interpolation is config-reader error metadata; no configuration value is logged.'
	},
	{
		file: 'ui/menu/menu_llm/trigger_journal.ahk',
		match: 'Trigger journal config reader returned a malformed snapshot.',
		verdict: 'not-personal',
		why: 'the constant diagnostic reports adapter status and carries no snapshot content.'
	},
	{
		file: 'ui/menu/menu_llm/trigger_journal.ahk',
		match: 'Trigger journal could not read its owner configuration.',
		verdict: 'not-personal',
		why: 'the constant diagnostic reports a read failure and carries no configuration value.'
	},
	{
		file: 'ui/menu/menu_llm/trigger_journal.ahk',
		match: 'Trigger journal found a non-string durable shortcut value.',
		verdict: 'not-personal',
		why: 'the constant diagnostic reports only the rejected value type category, not the value.'
	},
	{
		file: 'ui/menu/menu_llm/trigger_journal.ahk',
		match: 'Trigger journal configuration writer failed: {1}.',
		verdict: 'not-personal',
		why: 'the interpolation is writer error metadata; no shortcut or journal value is logged.'
	},
	{
		file: 'ui/menu/menu_llm/trigger_journal.ahk',
		match: 'Trigger journal configuration writer returned a malformed or refused status.',
		verdict: 'not-personal',
		why: 'the constant diagnostic reports adapter status and carries no value.'
	},
	{
		file: 'ui/menu/menu_llm/trigger_journal.ahk',
		match: 'Trigger journal rollback verification failed.',
		verdict: 'not-personal',
		why: 'the constant diagnostic reports transaction state and carries no value.'
	},
	{
		file: 'ui/menu/menu_llm/trigger_journal.ahk',
		match: 'Pending trigger journal conflicts with a third durable value',
		verdict: 'not-personal',
		why: 'the constant diagnostic reports a conflict class without printing any of the conflicting values.'
	},
	{
		file: 'ui/menu/menu_llm/trigger_journal.ahk',
		match: 'Committed-new trigger journal conflicts with durable configuration',
		verdict: 'not-personal',
		why: 'the constant diagnostic reports a conflict class without printing either value.'
	},
	{
		file: 'ui/menu/menu_llm/trigger_journal.ahk',
		match: 'Committed-old trigger journal conflicts with durable configuration',
		verdict: 'not-personal',
		why: 'the constant diagnostic reports a conflict class without printing either value.'
	},
	{
		file: 'ui/menu/menu_llm/trigger_journal.ahk',
		match: 'Trigger journal recovery could not acquire its owner configuration lease.',
		verdict: 'not-personal',
		why: 'the constant diagnostic reports lease state and carries no value.'
	},
	{
		file: 'ui/menu/menu_llm/trigger_journal.ahk',
		match: 'Trigger journal owner changed while recovery was acquiring its lease.',
		verdict: 'not-personal',
		why: 'the constant diagnostic reports an ownership race and carries no value.'
	},
	{
		file: 'ui/menu/menu_llm/trigger_journal.ahk',
		match: 'Trigger journal preparation refused a stale configuration owner.',
		verdict: 'not-personal',
		why: 'the constant diagnostic reports ownership state and carries no value.'
	},
	{
		file: 'ui/paths_editor/init.ahk',
		match: 'Could not change the config directory while LLM trigger recovery is incomplete.',
		verdict: 'not-personal',
		why: 'the constant diagnostic carries no user value; trigger means the LLM keyboard shortcut.'
	},
	{
		file: 'ui/menu/menu_llm/init.ahk',
		match: 'Initial trigger shortcut activation remained incomplete',
		verdict: 'not-personal',
		why: 'the constant diagnostic contains no interpolated value; trigger means the LLM keyboard shortcut, not a hotstring mapping.'
	}
];

const errors = [];
const notes = [];

/** Recursively collects production source files with the given extension. */
function walk(dir, ext = '.ahk', out = []) {
	if (!fs.existsSync(dir)) return out;
	if (fs.statSync(dir).isFile()) {
		if (dir.endsWith(ext)) out.push(dir);
		return out;
	}
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) {
			// tests/ asserts ON this behaviour and vendor/ is not ours.
			if (entry.name === 'tests' || entry.name === 'vendor') continue;
			walk(full, ext, out);
		} else if (entry.name.endsWith(ext)) {
			out.push(full);
		}
	}
	return out;
}

/**
 * Returns the full source text of the call whose opening paren is at `open`,
 * following nesting to the matching close.
 *
 * A fixed line window was tried first and it is what hid four of the thirteen
 * sites — KL_AppendLog(Map( … )) spreads one call over eight lines.
 */
function readCall(body, open) {
	let depth = 0;
	for (let i = open; i < body.length; i++) {
		const c = body[i];
		if (c === '(') depth++;
		else if (c === ')') {
			depth--;
			if (depth === 0) return body.slice(open, i + 1);
		}
	}
	// Unbalanced source: hand the rest back rather than silently returning
	// nothing, which would read as "this call mentions no trigger".
	return body.slice(open);
}

// ─── 1. Derive every site ────────────────────────────────────────────────────
const sites = [];
for (const file of walk(DRIVER)) {
	const body = fs.readFileSync(file, 'utf8');
	const rel = path.relative(DRIVER, file).split(path.sep).join('/');
	for (const sink of SINKS) {
		const re = new RegExp('\\b' + sink + '\\s*\\(', 'g');
		let m;
		while ((m = re.exec(body)) !== null) {
			// Skip commented-out calls: a `;` before the name on its own line.
			const lineStart = body.lastIndexOf('\n', m.index) + 1;
			if (body.slice(lineStart, m.index).trim().startsWith(';')) continue;
			const call = readCall(body, m.index + m[0].length - 1);
			if (!CARRIERS.test(call)) continue;
			sites.push({
				file: rel,
				line: body.slice(0, m.index).split('\n').length,
				sink,
				call,
				// Judgements match against this so a re-wrap or a re-indent of the
				// call does not silently orphan its verdict.
				callNorm: call.replace(/\s+/g, ' ')
			});
		}
	}
}

if (sites.length === 0) {
	errors.push(
		'the scan found no trigger-carrying sink at all — the driver has a dozen, so this ' +
		'gate is broken rather than the tree clean. A scanner that matches nothing reports green forever.'
	);
}

// ─── 1b. The Lua drivers ─────────────────────────────────────────────────────
const luaSites = [];
for (const tree of LUA_TREES) {
	for (const file of walk(path.join(SHARED_ROOT, tree.split('/').join(path.sep)), '.lua')) {
		const body = fs.readFileSync(file, 'utf8');
		const rel = path.relative(SHARED_ROOT, file).split(path.sep).join('/');
		for (const sink of LUA_SINKS) {
			const re = new RegExp(sink.replace('.', '\\.') + '\\s*\\(', 'g');
			let m;
			while ((m = re.exec(body)) !== null) {
				const lineStart = body.lastIndexOf('\n', m.index) + 1;
				if (body.slice(lineStart, m.index).trim().startsWith('--')) continue;
				const call = readCall(body, m.index + m[0].length - 1);
				if (!LUA_CARRIERS.test(call)) continue;
				luaSites.push({ file: rel, line: body.slice(0, m.index).split('\n').length, sink, call });
			}
		}
	}
}

if (luaSites.length === 0) {
	errors.push(
		'the Lua scan matched nothing across the dynamic-hotstrings modules of both Lua drivers. ' +
		'Those modules exist and they log; a scan that finds none of it has lost its trees, not found a clean repo.'
	);
}

// Same split as the Windows side: the list is derived, these are the verdicts.
// All four are prose matches — the message happens to contain "value" or
// "expansion" — which is the cost of a carrier net wide enough not to miss the
// real one, and cheaper than tuning the net until it misses something.
const LUA_JUDGED = [
	{
		file: 'linux/modules/dynamic_hotstrings/manager.lua',
		match: 'Injector not available',
		why: 'interpolates match.rule.suffix (the tag, e.g. "@i"), never the resolution; "expansion" is in the prose.'
	},
	{
		file: 'linux/modules/dynamic_hotstrings/manager.lua',
		match: 'prefix_rules module unavailable',
		why: 'no interpolation at all; "expansion" is in the prose.'
	},
	{
		file: 'macos/modules/dynamic_hotstrings/personal_info.lua',
		match: 'personal_info.toml not found',
		why: 'no interpolation at all; "values" is in the prose.'
	},
	{
		file: 'macos/modules/dynamic_hotstrings/rules_engine.lua',
		match: 'set_trigger_char: received an invalid value',
		why: 'the "value" is the magic-key CHARACTER the caller passed, not a personal_info field.'
	}
];

const luaUsed = new Set();
let luaSafe = 0;
for (const site of luaSites) {
	if (LUA_REDACTORS.some((r) => site.call.includes(r))) { luaSafe++; continue; }
	const idx = LUA_JUDGED.findIndex((j) => j.file === site.file && site.call.replace(/\s+/g, ' ').includes(j.match));
	if (idx !== -1) { luaUsed.add(idx); continue; }
	errors.push(
		`${site.file}:${site.line} — ${site.sink} interpolates a resolved value without reducing it ` +
		'to a length or passing it through a redactor.\n' +
		`      ${site.call.replace(/\s+/g, ' ').slice(0, 160)}\n` +
		'      Every resolver registered against the dynamic engine can return personal_info data: ' +
		'for "@i" it is the user\'s IBAN. Print `#value` and say "content withheld", as the sibling ' +
		'sites do — and remember the shared logger\'s default level is 10, so DEBUG is not a safeguard.'
	);
}

// ─── 2. Classify ─────────────────────────────────────────────────────────────
const used = new Set();
let redactedCount = 0;

for (const site of sites) {
	if (REDACTORS.some((r) => site.call.includes(r))) {
		redactedCount++;
		continue;
	}
	const idx = JUDGED.findIndex((j) => j.file === site.file && site.callNorm.includes(j.match));
	if (idx === -1) {
		errors.push(
			`${site.file}:${site.line} — ${site.sink} interpolates a hotstring trigger or replacement ` +
			'without redacting it, and no judgement covers it.\n' +
			`      ${site.call.replace(/\s+/g, ' ').slice(0, 150)}\n` +
			'      Either redact with PersonalInfoRedactForLog when the mapping is private, or add an ' +
			'entry to JUDGED in this file saying which caller already withheld it — and say why.'
		);
		continue;
	}
	used.add(idx);
}

// ─── 3. The ledger may not outlive the code ──────────────────────────────────
LUA_JUDGED.forEach((j, i) => {
	if (!luaUsed.has(i)) {
		errors.push(
			`the Lua judgement for ${j.file} ("${j.match}") matches no site any more. Delete it.`
		);
	}
});
JUDGED.forEach((j, i) => {
	if (!used.has(i)) {
		errors.push(
			`the judgement for ${j.file} ("${j.match}") matches no site any more. ` +
			'Delete it: a verdict kept past the code it described is what lets the next unguarded ' +
			'sink look accounted for.'
		);
	}
});

notes.push(`windows: ${sites.length} trigger-carrying sink(s) — ${redactedCount} redact in place, ${used.size} judged safe upstream`);
notes.push(`lua: ${luaSites.length} value-carrying sink(s) across both Lua drivers, ${luaSafe} reduced to a length or redacted`);

if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] personal-info log sinks are judged:\x1b[0m');
	for (const e of errors) console.error('  - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] every one of the ${sites.length} sink(s) that can carry a hotstring trigger ` +
	'either redacts it or is withheld by its caller.\x1b[0m'
);
for (const n of notes) console.log('     ' + n);
