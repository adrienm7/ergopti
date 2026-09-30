// tools/test/test-hardening-g-fixable-errors-offer-an-action.cjs

/**
 * ==============================================================================
 * MODULE: Fixable Errors Offer An Action (hardening-g-fixable-errors-offer-an-action)
 * DESCRIPTION:
 * A dialog or a notification that tells the user about a state the app can fix
 * (rules an older version left, a missing runtime or model, a server that does
 * not answer, a broken install of an optional component) must offer the fix,
 * not only an OK or a sentence naming a menu. Every modal dialog and every
 * non-modal notice of the three drivers is inventoried with the i18n keys it
 * shows; one whose keys name such a state must offer an action (a button, or
 * the click of a notification), or be registered below with the reason it
 * cannot.
 *
 * ROOT CAUSE ENCODED (incidents of 2026-09-30):
 * Legacy Karabiner rules blocked every deploy and the user only got an error
 * with no button (9ed15dcf9); a missing local model and an unreachable Ollama
 * ended in a failure instead of an offer to pull, start or install
 * (2ffedefc1, d9a8fd580). The notifications saying the MLX runtime was not
 * installed only told the user to select a menu row: the scan covered dialogs
 * alone, so no gate saw a notification without its action.
 *
 * FEATURES & RATIONALE:
 * 1. Dialog APIs: macOS dialog_util.block_alert / hs.dialog.blockAlert (two
 *    buttons, then a style) and dialog_util.choose (actions by design); Linux
 *    dialogs.error / info (one button) and confirm / prompt (a choice), plus
 *    raw zenity and kdialog commands; Windows MsgBox (its Options name the
 *    buttons).
 * 2. Notice APIs: macOS notifications.notify(title, body, kind, on_click),
 *    called directly, handed to pcall, or through a local wrapper with the same
 *    four parameters, and hs.notify.new(callback, attributes); hs.alert has no
 *    action. Linux Notifier.send (notify-send cannot report a click) and
 *    Windows NotifierSend / TrayTip carry no action either, so a fixable
 *    notice there must become a dialog or name why it cannot.
 * 3. A message's keys are those of its call and of the statements just before
 *    it, where the body is usually built: back to the function's start or the
 *    previous message, whichever is closer. A key built at run time counts by
 *    its literal suffix (prefix .. ".runtime_missing_body").
 * 4. A fixable state is named by its key: legacy, unreachable, missing,
 *    not installed, broken, repair, outdated, not pulled, corrupt.
 * 5. The offers today's fixes added must stay detected as offering an action
 *    (REQUIRED_OFFERS), and every exception names its exact site and why; an
 *    exception whose site is gone fails, so the registry cannot rot.
 * 6. `--rev <commit>` inventories a committed revision straight from Git.
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
// title is shared by the offer and by the report of what the offer did; so is
// a `done` key, which reports a fix that succeeded (mlx.repair_done).
const FIXABLE =
	/(^|[._])(legacy|unreachable|missing|not_installed|broken|repair|outdated|not_pulled|corrupt)/i;
const isFixableKey = (key) => FIXABLE.test(key) && !/(^|[._])(title|done)$/.test(key);

// Button labels that only dismiss.
const DISMISS =
	/^(common\.(ok|close|cancel|later|no)|button\.(ok|close|cancel|later|no)|onboarding\.btn\.ok|.*\.keep_off|.*\.later)$/;

// How many lines before a dialog call still build its text.
const LOOKBACK_LINES = 12;

// Fewest notices each driver must still show the scan: fewer means it went blind.
const NOTICE_FLOORS = { macos: 100, windows: 30, linux: 8 };

// Offers today's fixes added: each file must keep a fixable-state dialog or
// notice that offers an action.
const REQUIRED_OFFERS = [
	{ file: 'macos/ui/legacy_rules_cleanup.lua', why: 'legacy Karabiner rules (9ed15dcf9)' },
	{
		file: 'macos/modules/llm/local_model_offer.lua',
		why: 'a local model that is not pulled (2ffedefc1)'
	},
	{
		file: 'macos/ui/menu/menu_llm/unreachable_backend_offer.lua',
		why: 'an unreachable Ollama (d9a8fd580)'
	},
	{
		file: 'macos/ui/menu/menu_llm/runtime_install_offer.lua',
		why: 'an AI runtime missing at startup, whose notice opens its install offer'
	}
];

// Fixable-state messages without an action, each with its reason. The entry
// must match a detected dialog or notice: `file` and one of its keys.
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
	},
	{
		file: 'macos/ui/menu/menu_llm/api_panel.lua',
		key: 'menu.llm.api_unreachable_body',
		why: "the verdict of the check the user ran by adding a remote API entry, rolled back; the add row is the retry and the server, key or network is the user's to fix"
	},
	{
		file: 'windows/ui/menu/menu_llm/menu_api_entries.ahk',
		key: 'menu.llm.api_unreachable_body',
		why: 'the verdict of the test the user ran from the entry row, whose own edit rows are the fix'
	},
	{
		file: 'macos/ui/menu/menu_llm/models_manager_mlx.lua',
		key: 'mlx.deps_missing_body',
		why: 'posted only while the MLX runtime the user selected installs: the fix is already running in its progress window'
	},
	{
		file: 'macos/ui/menu/menu_llm/models_manager_ollama.lua',
		key: 'ollama.model_repair',
		why: 'announces the re-download of a model that does not load, which the line after it starts: the fix is already running'
	},
	{
		file: 'macos/ui/menu/menu_llm/models_manager_mlx_hf.lua',
		key: 'mlx.token_missing_body',
		why: 'the user submitted the HuggingFace login window with no token; only the user has the token, and the login row asks again'
	},
	{
		file: 'macos/ui/menu/menu_llm/runtime_install_offer.lua',
		key: 'ollama.runtime_missing_body',
		why: 'the user just declined the Ollama download in the offer dialog; posting it again as a click would override that answer'
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
	// i18n.get, I18n.format, i18n().get, i18n_mod.get, t, tr, text, and the
	// onboarding translator.
	const helper = String.raw`(?:\w*[Ii]18[Nn]\w*(?:\(\s*\))?\.(?:get|format)|t|tr|text|_Onboarding_Translate\([^,]+,)`;
	const pattern = new RegExp(
		String.raw`\b${helper}\s*\(\s*["']([a-z0-9_]+(?:\.[a-z0-9_]+)+)["']`,
		'g'
	);
	for (const match of text.matchAll(pattern)) keys.add(match[1]);
	// A key built at run time: its literal suffix names the state.
	for (const match of text.matchAll(
		new RegExp(String.raw`\b${helper}\s*\(\s*[\w.]+\s*\.\.\s*["'](\.[a-z0-9_]+)["']`, 'g')
	)) {
		keys.add('*' + match[1]);
	}
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
// ======= 2/ Message inventory ==============
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

/** Whether a notice argument carries an action: a value, not nil or false. */
function isPresent(arg) {
	return typeof arg === 'string' && arg !== '' && !/^(nil|false)$/.test(arg);
}

/** The "(" of the innermost call still open at `index`, or -1. */
function enclosingOpen(code, index) {
	const stack = [];
	let quote = '';
	for (let i = 0; i < index; i++) {
		const ch = code[i];
		if (quote) {
			if (ch === '\\') i += 1;
			else if (ch === quote || ch === '\n') quote = '';
			continue;
		}
		if (ch === '"' || ch === "'") quote = ch;
		else if ('({['.includes(ch)) stack.push(i);
		else if (')}]'.includes(ch)) stack.pop();
	}
	const open = stack.length > 0 ? stack[stack.length - 1] : -1;
	return open >= 0 && code[open] === '(' ? open : -1;
}

/**
 * The arguments a notice API receives at one reference: called directly
 * (`api(a, b)`) or handed to another call (`pcall(api, a, b)`).
 * @returns {{ text: string, args: string[] } | null}
 */
function referencedCall(code, match) {
	const end = match.index + match[0].length;
	const next = /^\s*(.)/.exec(code.slice(end, end + 40));
	if (next && next[1] === '(') {
		const text = callArguments(code, code.indexOf('(', end));
		return text === null ? null : { text, args: splitArguments(text) };
	}
	const open = enclosingOpen(code, match.index);
	if (open < 0) return null;
	const text = callArguments(code, open);
	if (text === null) return null;
	const all = splitArguments(text);
	const ref = match[0].replace(/\s+/g, '');
	const position = all.findIndex((arg) => arg.replace(/\s+/g, '') === ref);
	return position < 0 ? null : { text, args: all.slice(position + 1) };
}

/**
 * Every modal dialog and non-modal notice of one file:
 * { rel, line, keys, action, surface }.
 */
function messagesOf(file) {
	const lua = file.rel.endsWith('.lua');
	const code = stripComments(file.content, lua);
	const lines = code.split('\n');
	const found = [];
	const lineOf = (index) => code.slice(0, index).split('\n').length;
	const functionStart = lua
		? /^\s*(?:local\s+)?function\b|\bfunction\s*\([^)]*\)\s*$|=\s*function\b/
		: /^[A-Za-z_]\w*\([^)]*\)\s*\{?\s*$/;
	// Message calls in source order, so a lookback stops at the previous one.
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
	const add = (index, args, action, surface = 'dialog') =>
		pending.push({ index, args, action, surface });
	const settle = () => {
		pending.sort((a, b) => a.index - b.index);
		for (const entry of pending) {
			const line = lineOf(entry.index);
			const keys = new Set([...i18nKeys(entry.args), ...i18nKeys(context(entry.index))]);
			found.push({ rel: file.rel, line, keys, action: entry.action, surface: entry.surface });
			spans.push({ end: line + entry.args.split('\n').length - 1 });
		}
	};
	const definedHere = (index) => /function\s+$/.test(code.slice(Math.max(0, index - 16), index));
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
		if (file.rel.startsWith('macos/')) {
			// notifications.notify(title, body, kind, on_click): the click is the action.
			for (const match of code.matchAll(
				/(?:\brequire\(\s*["']infra\.notifications["']\s*\)|\b[A-Za-z_]\w*(?:\(\s*\))?)\s*\.\s*notify\b(?=\s*[(,)])/g
			)) {
				if (definedHere(match.index)) continue;
				const call = referencedCall(code, match);
				if (call) add(match.index, call.text, isPresent(call.args[3]), 'notice');
			}
			// A local wrapper with the same four parameters.
			if (/\blocal\s+function\s+notify\s*\(\s*\w+\s*,\s*\w+\s*,\s*\w+\s*,\s*\w+\s*\)/.test(code)) {
				for (const match of code.matchAll(/(?<![\w.:])notify(?=\s*\()/g)) {
					if (definedHere(match.index)) continue;
					const call = referencedCall(code, match);
					if (call) add(match.index, call.text, isPresent(call.args[3]), 'notice');
				}
			}
			// hs.notify.new(callback, attributes): the callback is the action.
			for (const match of code.matchAll(/\bhs\.notify\.new(?=\s*\()/g)) {
				const call = referencedCall(code, match);
				if (!call) continue;
				const first = call.args[0] || '';
				add(match.index, call.text, isPresent(first) && !first.startsWith('{'), 'notice');
			}
			// hs.alert: a transient banner, never an action.
			for (const match of code.matchAll(/\bhs\.alert(?:\.show)?\b(?=\s*[(,)])/g)) {
				const call = referencedCall(code, match);
				if (call) add(match.index, call.text, false, 'notice');
			}
		}
		if (file.rel.startsWith('linux/')) {
			// Notifier.send(message, opts): notify-send cannot report a click.
			for (const match of code.matchAll(/\b[Nn]otifier\.send\b(?=\s*[(,)])/g)) {
				const call = referencedCall(code, match);
				if (call) add(match.index, call.text, false, 'notice');
			}
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
		// NotifierSend / TrayTip: a tray balloon has no action.
		for (const match of code.matchAll(/\b(?:NotifierSend|TrayTip)\s*\(/g)) {
			const line = lineOf(match.index);
			const own = lines[line - 1];
			const following = (lines[line] || '').trim();
			// The adapter's own definition, not a call.
			if (
				/^\s*\w+\([^)]*\)\s*\{\s*$/.test(own) ||
				(/^\s*\w+\([^)]*\)\s*$/.test(own) && following === '{')
			)
				continue;
			const text = callArguments(code, match.index + match[0].length - 1);
			if (text !== null) add(match.index, text, false, 'notice');
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
			'end',
			'local function c()',
			'\tpcall(notifications.notify, i18n.get("mlx.runtime_missing_title"),',
			'\t\ti18n.get("mlx.runtime_missing_body"), "warning")',
			'end',
			'local function d(prefix)',
			'\treturn notifications().notify(title, i18n.get(prefix .. ".runtime_missing_click"), "warning",',
			'\t\tfunction() install() end)',
			'end',
			'local function e()',
			'\ths.notify.new(nil, { informativeText = i18n.get("llm.unreachable.body") }):send()',
			'end'
		].join('\n')
	};
	const found = messagesOf(fixture);
	const verdicts = found.map(
		(d) => `${d.line}:${d.surface}:${[...d.keys].some(isFixableKey)}:${d.action}`
	);
	const expected = [
		'3:dialog:true:false',
		'6:dialog:true:true',
		'10:notice:true:false',
		'14:notice:true:true',
		'18:notice:true:false'
	];
	if (JSON.stringify(verdicts) !== JSON.stringify(expected)) {
		throw new Error(`self-check: expected ${expected.join(' ')}, got ${verdicts.join(' ')}`);
	}
}

function main() {
	selfCheck();
	const files = sources();
	const messages = files.flatMap(messagesOf);
	const fixable = messages.filter((d) => [...d.keys].some(isFixableKey));
	const failures = [];
	const used = new Set();
	for (const message of fixable) {
		if (message.action) continue;
		const exception = EXCEPTIONS.find((e) => e.file === message.rel && message.keys.has(e.key));
		if (exception) {
			used.add(exception);
			continue;
		}
		const named = [...message.keys].filter(isFixableKey).join(', ');
		failures.push(
			message.surface === 'dialog'
				? `${SP}/${message.rel}:${message.line}: a dialog reports a fixable state (${named}) with no action ` +
						'button: offer the fix, or register the reason it cannot be offered in EXCEPTIONS'
				: `${SP}/${message.rel}:${message.line}: a notice reports a fixable state (${named}) with no action: ` +
						'give it the click that opens the fix (or show a dialog with the button), or register ' +
						'the reason it cannot be offered in EXCEPTIONS'
		);
	}
	for (const exception of EXCEPTIONS) {
		if (!used.has(exception)) {
			failures.push(
				`stale exception ${exception.file} (${exception.key}): no such message without an action`
			);
		}
	}
	for (const required of REQUIRED_OFFERS) {
		if (!fixable.some((d) => d.rel === required.file && d.action)) {
			failures.push(
				`${SP}/${required.file}: the offer for ${required.why} no longer carries an action`
			);
		}
	}
	const count = (driver, surface) =>
		messages.filter((d) => d.rel.startsWith(driver + '/') && d.surface === surface).length;
	for (const [driver, surface, floor] of [
		['macos', 'dialog', 20],
		['windows', 'dialog', 50],
		['linux', 'dialog', 5],
		['macos', 'notice', NOTICE_FLOORS.macos],
		['windows', 'notice', NOTICE_FLOORS.windows],
		['linux', 'notice', NOTICE_FLOORS.linux]
	]) {
		if (count(driver, surface) < floor) {
			failures.push(
				`only ${count(driver, surface)} ${driver} ${surface}(s) inventoried (floor ${floor}): the scan went blind`
			);
		}
	}
	if (failures.length > 0) {
		console.error('[hardening-g-fixable-errors-offer-an-action]');
		for (const failure of failures) console.error(`  ${failure}`);
		process.exit(1);
	}
	const summary = (surface) =>
		`macOS ${count('macos', surface)}, Windows ${count('windows', surface)}, Linux ${count('linux', surface)}`;
	console.log(
		`[hardening-g-fixable-errors-offer-an-action] ${messages.filter((d) => d.surface === 'dialog').length} ` +
			`dialog(s) (${summary('dialog')}) and ${messages.filter((d) => d.surface === 'notice').length} ` +
			`notice(s) (${summary('notice')}) inventoried; ${fixable.length} report a fixable state and each ` +
			'offers an action or names why it cannot.'
	);
}

main();
