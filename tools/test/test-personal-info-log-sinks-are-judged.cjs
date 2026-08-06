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
		file: 'infra/personal_info_preview.ahk',
		match: 'Resolving the dynamic value',
		verdict: 'not-personal',
		why: 'only reachable in the HasMethod(Replacement) branch, i.e. a callable replacement — the three DATE tags, whose Category is PI_PREVIEW_DYNAMIC_CATEGORY. Spec.Trigger there is "@<date tag>★"; redacting it would cost the only diagnostic the line carries and hide nothing.'
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
		file: 'ui/menu/menu_llm/actions.ahk',
		match: 'direct install trigger',
		verdict: 'not-personal',
		why: 'the word "trigger" in prose about a debug hotkey; no interpolated value.'
	},
	{
		file: 'ui/menu/menu_llm/actions.ahk',
		match: 'is not installed — switching to',
		verdict: 'not-personal',
		why: '`replacement` here is a replacement MODEL tag (e.g. "llama3:8b"), not a hotstring replacement.'
	},
	{
		file: 'ui/menu/menu_llm/menu_settings.ahk',
		match: 'Trigger shortcut binding failed',
		verdict: 'not-personal',
		why: 'the LLM tooltip trigger SHORTCUT (a hotkey string), and only e.Message is interpolated.'
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
