// tools/test/test-hardening-g-fixable-errors-offer-an-action.cjs

/**
 * ==============================================================================
 * MODULE: Fixable Errors Offer An Action (hardening-g-fixable-errors-offer-an-action)
 * DESCRIPTION:
 * A dialog that tells the user about a state the app can fix (rules an older
 * version left, a missing runtime or model, a server that does not answer, a
 * broken install of an optional component) must offer the fix as a button, not
 * only an OK. Every modal dialog of the three drivers is inventoried with the
 * i18n keys it shows; one whose keys name such a state must offer an action
 * button, or be registered below with the reason it cannot.
 *
 * ROOT CAUSE ENCODED (incidents of 2026-09-30):
 * Legacy Karabiner rules blocked every deploy and the user only got an error
 * with no button (9ed15dcf9); a missing local model and an unreachable Ollama
 * ended in a failure instead of an offer to pull, start or install
 * (2ffedefc1, d9a8fd580).
 *
 * FEATURES & RATIONALE:
 * 1. Dialog APIs: macOS dialog_util.block_alert / hs.dialog.blockAlert (two
 *    buttons, then a style) and dialog_util.choose (actions by design); Linux
 *    dialogs.error / info (one button) and confirm / prompt (a choice), plus
 *    raw zenity and kdialog commands; Windows MsgBox (its Options name the
 *    buttons).
 * 2. A dialog's keys are those of its call and of the statements just before
 *    it, where the body is usually built: back to the function's start or the
 *    previous dialog, whichever is closer.
 * 3. A fixable state is named by its key: legacy, unreachable, missing,
 *    not installed, broken, repair, outdated, not pulled, corrupt.
 * 4. The dialogs today's fixes added must stay detected as offering an action
 *    (REQUIRED_OFFERS), and every exception names its exact site and why; an
 *    exception whose site is gone fails, so the registry cannot rot.
 * 5. `--rev <commit>` inventories a committed revision straight from Git.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const revArg = process.argv.indexOf('--rev');
const REV = revArg > 0 ? process.argv[revArg + 1] : null;
const SP = 'static/ergopti_plus';

// A message key that names a state the app can fix. Titles are left out: a
// title is shared by the offer and by the report of what the offer did.
const FIXABLE =
	/(^|[._])(legacy|unreachable|missing|not_installed|broken|repair|outdated|not_pulled|corrupt)/i;
const isFixableKey = (key) => FIXABLE.test(key) && !/(^|[._])title$/.test(key);

// Button labels that only dismiss.
const DISMISS =
	/^(common\.(ok|close|cancel|later|no)|button\.(ok|close|cancel|later|no)|onboarding\.btn\.ok|.*\.keep_off|.*\.later)$/;

// How many lines before a dialog call still build its text.
const LOOKBACK_LINES = 12;

// Dialogs today's fixes added: each file must keep a fixable-state dialog that
// offers an action.
const REQUIRED_OFFERS = [
	{ file: 'macos/ui/legacy_rules_cleanup.lua', why: 'legacy Karabiner rules (9ed15dcf9)' },
	{
		file: 'macos/modules/llm/local_model_offer.lua',
		why: 'a local model that is not pulled (2ffedefc1)'
	},
	{
		file: 'macos/ui/menu/menu_llm/unreachable_backend_offer.lua',
		why: 'an unreachable Ollama (d9a8fd580)'
	}
];

// Fixable-state dialogs without an action button, each with its reason. The
// entry must match a detected dialog: `file` and one of its keys.
const EXCEPTIONS = [
	{
		file: 'macos/ui/menu/menu_metrics.lua',
		key: 'apps.encryptor.err_openssl_missing',
		why: 'openssl ships with macOS; nothing the app could install replaces a system tool that is gone'
	},
	{
		file: 'windows/infra/ui_style.ahk',
		key: 'dialog.fatal_error.toml_key_missing',
		why: 'a shipped style file lacks a key: the installation itself is damaged and only a reinstall fixes it'
	},
	{
		file: 'windows/ErgoptiPlus.ahk',
		key: 'startup.manifest_missing',
		why: 'the generated features manifest is absent: a checkout the build step never ran, not a user state'
	},
	{
		file: 'linux/ui/menu/llm_backend_rows.lua',
		key: 'menu.llm.api_unreachable_body',
		why: 'the verdict of the test the user ran from the entry row, whose own edit rows are the fix'
	}
];

// ===========================================
// ===========================================
// ======= 1/ Sources =========================
// ===========================================
// ===========================================

/** Production sources of the three drivers and _shared: [{ rel, content }]. */
function sources() {
	const keep = (rel) =>
		/\.(lua|ahk)$/.test(rel) && !/(^|\/)(tests|vendor|_generated|launcher)\//.test(rel);
	if (!REV) {
		const out = [];
		const walk = (dir) => {
			for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
				const full = path.join(dir, entry.name);
				if (entry.isDirectory()) walk(full);
				else {
					const rel = path.relative(path.join(ROOT, SP), full).replace(/\\/g, '/');
					if (keep(rel)) out.push({ rel, content: fs.readFileSync(full, 'utf8') });
				}
			}
		};
		walk(path.join(ROOT, SP));
		return out;
	}
	const listing = execFileSync('git', ['ls-tree', '-r', REV, '--', SP], {
		cwd: ROOT,
		encoding: 'utf8',
		maxBuffer: 64 * 1024 * 1024
	})
		.split('\n')
		.filter(Boolean)
		.map((line) => {
			const [meta, file] = line.split('\t');
			return { sha: meta.split(' ')[2], rel: file.slice(SP.length + 1) };
		})
		.filter((entry) => keep(entry.rel));
	const blob = execFileSync('git', ['cat-file', '--batch'], {
		cwd: ROOT,
		input: listing.map((entry) => entry.sha).join('\n') + '\n',
		maxBuffer: 512 * 1024 * 1024
	});
	const out = [];
	let offset = 0;
	for (const entry of listing) {
		const headerEnd = blob.indexOf(0x0a, offset);
		const size = Number(blob.slice(offset, headerEnd).toString('utf8').split(' ')[2]);
		const start = headerEnd + 1;
		out.push({ rel: entry.rel, content: blob.slice(start, start + size).toString('utf8') });
		offset = start + size + 1;
	}
	return out;
}

/** Blanks comments (Lua `--`, AHK `;`), keeping strings and line numbers. */
function stripComments(src, lua) {
	let out = '';
	let quote = '';
	for (let i = 0; i < src.length; i++) {
		const ch = src[i];
		if (quote) {
			out += ch;
			if ((lua && ch === '\\') || (!lua && ch === '`')) {
				out += src[i + 1] || '';
				i += 1;
			} else if (ch === quote || ch === '\n') quote = '';
			continue;
		}
		if (ch === '"' || ch === "'") {
			quote = ch;
			out += ch;
			continue;
		}
		const comment = lua
			? src.startsWith('--', i)
			: ch === ';' && (i === 0 || /\s/.test(src[i - 1]));
		if (comment) {
			const end = src.indexOf('\n', i);
			const stop = end < 0 ? src.length : end;
			out += ' '.repeat(stop - i);
			i = stop - 1;
			continue;
		}
		out += ch;
	}
	return out;
}

/** The argument text of the call whose "(" is at `open`, or null. */
function callArguments(src, open) {
	let depth = 0;
	let quote = '';
	for (let i = open; i < src.length; i++) {
		const ch = src[i];
		if (quote) {
			if (ch === '\\' || ch === '`') i += 1;
			else if (ch === quote) quote = '';
			continue;
		}
		if (ch === '"' || ch === "'") quote = ch;
		else if (ch === '(' || ch === '{' || ch === '[') depth += 1;
		else if (ch === ')' || ch === '}' || ch === ']') {
			depth -= 1;
			if (depth === 0) return src.slice(open + 1, i);
		}
	}
	return null;
}

/** Splits argument text at top-level commas. */
function splitArguments(text) {
	const args = [];
	let depth = 0;
	let quote = '';
	let current = '';
	for (let i = 0; i < text.length; i++) {
		const ch = text[i];
		if (quote) {
			current += ch;
			if (ch === '\\' || ch === '`') {
				current += text[i + 1] || '';
				i += 1;
			} else if (ch === quote) quote = '';
			continue;
		}
		if (ch === '"' || ch === "'") quote = ch;
		else if ('({['.includes(ch)) depth += 1;
		else if (')}]'.includes(ch)) depth -= 1;
		else if (ch === ',' && depth === 0) {
			args.push(current.trim());
			current = '';
			continue;
		}
		current += ch;
	}
	if (current.trim() !== '') args.push(current.trim());
	return args;
}

/** The i18n keys a piece of code names through the translation helpers. */
function i18nKeys(text) {
	const keys = new Set();
	const pattern =
		/\b(?:i18n\.(?:get|format)|I18n\.(?:get|format)|t|tr|_Onboarding_Translate\([^,]+,)\s*\(\s*["']([a-z0-9_]+(?:\.[a-z0-9_]+)+)["']/g;
	for (const match of text.matchAll(pattern)) keys.add(match[1]);
	// A key chosen by a condition: i18n.get(x and "a" or "b").
	for (const match of text.matchAll(
		/\bi18n\.(?:get|format)\(\s*[^)"']*?\band\s+"([a-z0-9_.]+)"\s+or\s+"([a-z0-9_.]+)"/g
	)) {
		keys.add(match[1]);
		keys.add(match[2]);
	}
	return keys;
}

// ===========================================
// ===========================================
// ======= 2/ Dialog inventory ===============
// ===========================================
// ===========================================

/** Whether one button argument is an action, not a dismissal. */
function isActionButton(arg) {
	if (!arg || arg === 'nil' || arg === '""') return false;
	const keys = [...i18nKeys(arg)];
	if (keys.length > 0) return keys.some((key) => !DISMISS.test(key));
	// A variable or a literal label: an action unless it reads as a dismissal.
	return !/^["'](ok|close|cancel|later|non|annuler|fermer)["']$/i.test(arg);
}

/**
 * Every modal dialog of one file: { rel, line, keys, action }.
 */
function dialogsOf(file) {
	const lua = file.rel.endsWith('.lua');
	const code = stripComments(file.content, lua);
	const lines = code.split('\n');
	const found = [];
	const lineOf = (index) => code.slice(0, index).split('\n').length;
	const functionStart = lua
		? /^\s*(?:local\s+)?function\b|\bfunction\s*\([^)]*\)\s*$|=\s*function\b/
		: /^[A-Za-z_]\w*\([^)]*\)\s*\{?\s*$/;
	// Dialog calls in source order, so a lookback stops at the previous one.
	const spans = [];
	const context = (index) => {
		const line = lineOf(index);
		let from = Math.max(0, line - 1 - LOOKBACK_LINES);
		for (const span of spans) if (span.end < line && span.end > from) from = span.end;
		for (let k = line - 1; k >= from; k--) {
			if (functionStart.test(lines[k])) {
				from = k;
				break;
			}
		}
		return lines.slice(from, line - 1).join('\n');
	};
	const pending = [];
	const add = (index, args, action) => pending.push({ index, args, action });
	const settle = () => {
		pending.sort((a, b) => a.index - b.index);
		for (const entry of pending) {
			const line = lineOf(entry.index);
			const keys = new Set([...i18nKeys(entry.args), ...i18nKeys(context(entry.index))]);
			found.push({ rel: file.rel, line, keys, action: entry.action });
			spans.push({ end: line + entry.args.split('\n').length - 1 });
		}
	};
	if (lua) {
		// block_alert(title, body, b1, b2, style), directly or through pcall.
		for (const match of code.matchAll(
			/(pcall\(\s*)?\b[\w.]*(?:block_alert|blockAlert)\b(\s*\()?/g
		)) {
			const pcallForm = Boolean(match[1]);
			const open = pcallForm
				? code.lastIndexOf('(', match.index + match[1].length)
				: match.index + match[0].length - 1;
			if (!pcallForm && !match[2]) continue;
			if (
				/function\s+M\.block_alert/.test(
					code.slice(Math.max(0, match.index - 20), match.index + match[0].length)
				)
			)
				continue;
			const text = callArguments(code, open);
			if (text === null) continue;
			const args = splitArguments(text);
			const [, , first, second] = pcallForm ? args.slice(1) : args;
			add(match.index, text, isActionButton(first) || isActionButton(second));
		}
		// dialog_util.choose(title, message, choices, ...): a choice by design.
		for (const match of code.matchAll(
			/\b(?:dialog_util|Dialog|dialog|dialogs)(?:\(\))?\.choose\s*\(/g
		)) {
			const text = callArguments(code, match.index + match[0].length - 1);
			if (text !== null) add(match.index, text, true);
		}
		// Linux dialogs: error/info have one button, confirm/prompt ask.
		for (const match of code.matchAll(
			/\bdialogs\.(error|info|warning|confirm|prompt|question)\s*\(/g
		)) {
			const text = callArguments(code, match.index + match[0].length - 1);
			if (text !== null) add(match.index, text, !/^(error|info|warning)$/.test(match[1]));
		}
		// Raw zenity / kdialog commands.
		for (const match of code.matchAll(
			/["'][^"'\n]*\b(zenity|kdialog)\b[^"'\n]*--(error|info|warning|sorry|msgbox|question|yesno|warningyesno)\b/g
		)) {
			add(match.index, '', /question|yesno/.test(match[2]));
		}
	} else {
		// MsgBox(Text, Title, Options): the Options name the buttons.
		for (const match of code.matchAll(/\bMsgBox\s*\(/g)) {
			const text = callArguments(code, match.index + match[0].length - 1);
			if (text === null) continue;
			const options = splitArguments(text)[2] || '';
			const numeric = /^["']?(\d+)/.exec(options.replace(/\s+/g, ''));
			const buttons = numeric
				? (Number(numeric[1]) & 0x7) !== 0
				: /(YesNo|OKCancel|RetryCancel|AbortRetryIgnore|CancelTryAgainContinue|YesNoCancel)/i.test(
						options
					);
			add(match.index, text, buttons);
		}
	}
	settle();
	return found;
}

// ===========================================
// ===========================================
// ======= 3/ Main ===========================
// ===========================================
// ===========================================

function selfCheck() {
	const fixture = {
		rel: 'macos/ui/fixture.lua',
		content: [
			'local function a()',
			'\tlocal body = i18n.format("karabiner.legacy_cleanup.body_one", list)',
			'\treturn dialog.block_alert(i18n.get("karabiner.legacy_cleanup.title"), body, i18n.get("common.ok"))',
			'end',
			'local function b()',
			'\tlocal ok, c = pcall(Dialog.block_alert, t, i18n.format("llm.local_model.missing_body", m),',
			'\t\tdownload, i18n.get("common.cancel"), "warning")',
			'end'
		].join('\n')
	};
	const found = dialogsOf(fixture);
	const verdicts = found.map((d) => `${d.line}:${[...d.keys].some(isFixableKey)}:${d.action}`);
	const expected = ['3:true:false', '6:true:true'];
	if (JSON.stringify(verdicts) !== JSON.stringify(expected)) {
		throw new Error(`self-check: expected ${expected.join(' ')}, got ${verdicts.join(' ')}`);
	}
}

function main() {
	selfCheck();
	const files = sources();
	const dialogs = files.flatMap(dialogsOf);
	const fixable = dialogs.filter((d) => [...d.keys].some(isFixableKey));
	const failures = [];
	const used = new Set();
	for (const dialog of fixable) {
		if (dialog.action) continue;
		const exception = EXCEPTIONS.find((e) => e.file === dialog.rel && dialog.keys.has(e.key));
		if (exception) {
			used.add(exception);
			continue;
		}
		const named = [...dialog.keys].filter(isFixableKey).join(', ');
		failures.push(
			`${SP}/${dialog.rel}:${dialog.line}: a dialog reports a fixable state (${named}) with no action ` +
				'button: offer the fix, or register the reason it cannot be offered in EXCEPTIONS'
		);
	}
	for (const exception of EXCEPTIONS) {
		if (!used.has(exception)) {
			failures.push(
				`stale exception ${exception.file} (${exception.key}): no such dialog without an action`
			);
		}
	}
	for (const required of REQUIRED_OFFERS) {
		if (!fixable.some((d) => d.rel === required.file && d.action)) {
			failures.push(
				`${SP}/${required.file}: the offer for ${required.why} is no longer a dialog with an action`
			);
		}
	}
	const byDriver = (driver) => dialogs.filter((d) => d.rel.startsWith(driver + '/')).length;
	for (const [driver, floor] of [
		['macos', 20],
		['windows', 50],
		['linux', 5]
	]) {
		if (byDriver(driver) < floor) {
			failures.push(
				`only ${byDriver(driver)} ${driver} dialog(s) inventoried (floor ${floor}): the scan went blind`
			);
		}
	}
	if (failures.length > 0) {
		console.error('[hardening-g-fixable-errors-offer-an-action]');
		for (const failure of failures) console.error(`  ${failure}`);
		process.exit(1);
	}
	console.log(
		`[hardening-g-fixable-errors-offer-an-action] ${dialogs.length} dialog(s) inventoried ` +
			`(macOS ${byDriver('macos')}, Windows ${byDriver('windows')}, Linux ${byDriver('linux')}); ` +
			`${fixable.length} report a fixable state and each offers an action or names why it cannot.`
	);
}

main();
