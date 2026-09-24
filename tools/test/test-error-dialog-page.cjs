// tools/test/test-error-dialog-page.cjs

/**
 * ==============================================================================
 * MODULE: Error Window Page Behaviour
 * DESCRIPTION:
 * Runs the shared error window (_shared/ui/error_dialog/) over a minimal DOM,
 * with the scripts in the order index.html loads them, and drives it as the
 * three hosts do:
 * 1. the page asks for its error with "ready" and offers nothing to act on
 *    before the host's init message; Close always works;
 * 2. the details block shows exactly the report text the host sent (the
 *    report the Copy and Report buttons use), and the error, its module and
 *    the file it is logged in are shown as sent;
 * 3. a crash notice reads as one (its own heading and open-file label);
 * 4. buttons send action names only, never a path, a text or a URL;
 * 5. errors folded into the window are counted; action results reach the
 *    status line; the Linux bridge response reaches the same entry point;
 * 6. every label the page asks for exists in every locale.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ROOT = path.resolve(__dirname, '..', '..');
const SHARED = path.join(ROOT, 'static', 'ergopti_plus', '_shared');
const PAGE = path.join(SHARED, 'ui', 'error_dialog');
const LOCALES = path.join(SHARED, 'data', 'locales');

const failures = [];
const fail = (message) => failures.push(message);

const en = JSON.parse(fs.readFileSync(path.join(LOCALES, 'en.json'), 'utf8'));

// =============================
// =============================
// ======= 1/ A Tiny DOM =======
// =============================
// =============================

/** One element: the few properties and methods the page touches. */
function element(id, tag) {
	return {
		id,
		tagName: (tag || 'div').toUpperCase(),
		textContent: '',
		className: '',
		disabled: false,
		hidden: false,
		listeners: {},
		addEventListener(type, handler) {
			(this.listeners[type] = this.listeners[type] || []).push(handler);
		},
		dispatch(type) {
			for (const handler of this.listeners[type] || []) handler({ target: this });
		},
	};
}

/** Builds the document of index.html, element ids and states read from the real file. */
function makeDocument() {
	const html = fs.readFileSync(path.join(PAGE, 'index.html'), 'utf8');
	const elements = {};
	for (const match of html.matchAll(/<(\w+)([^>]*)\bid="([^"]+)"([^>]*)>/g)) {
		const el = element(match[3], match[1]);
		const attributes = match[2] + match[4];
		el.disabled = /\bdisabled\b/.test(attributes);
		el.hidden = /\bhidden\b/.test(attributes);
		elements[match[3]] = el;
	}
	return {
		elements,
		readyState: 'complete',
		addEventListener() {},
		getElementById(id) {
			return elements[id] || null;
		},
		querySelectorAll() {
			return [];
		},
	};
}

/** Loads the page into a sandbox and returns what the host sees of it. */
function loadPage() {
	const posted = [];
	const document = makeDocument();
	const sandbox = { document, console, posted };
	sandbox.window = sandbox;
	sandbox.window.webkit = { messageHandlers: { error_dialog: { postMessage: (payload) => posted.push(payload) } } };
	sandbox.__i18n_base = 'https://ergopti.errordialog/data/locales/';
	sandbox._i18n_locale = 'en';
	sandbox.atob = (text) => Buffer.from(text, 'base64').toString('binary');
	sandbox.TextDecoder = TextDecoder;
	sandbox.fetch = () => Promise.resolve({ ok: true, json: () => Promise.resolve(en) });
	vm.createContext(sandbox);
	const html = fs.readFileSync(path.join(PAGE, 'index.html'), 'utf8');
	const scripts = [...html.matchAll(/<script src="([^"]+)"><\/script>/g)].map((m) => m[1]);
	if (scripts.length < 3) fail(`index.html loads ${scripts.length} script(s); the page needs its bridge, i18n and script`);
	for (const rel of scripts) {
		const file = path.join(PAGE, rel);
		vm.runInContext(fs.readFileSync(file, 'utf8'), sandbox, { filename: file });
	}
	sandbox.window.i18n_apply(en);
	return { sandbox, posted, elements: document.elements };
}

/** The label a key renders as, placeholders filled in order. */
function label(key, ...args) {
	let index = 0;
	return String(en[key]).replace(/%s/g, () => String(args[index++]));
}

const REPORT = '# ErgoptiPlus diagnostics\n\n| Field | Value |\n```text\nerror:\n  module: keylogger\n```\n';
const ERROR = {
	type: 'init',
	kind: 'error',
	module: 'keylogger',
	message: 'Flush failed: disk full\nstack traceback:\n\tkeylogger.lua:12',
	log_path: '~/.local/state/ergopti_plus/logs/ErgoptiPlus_errors_2026-09-24.log',
	text: REPORT,
	more: 0,
};

// =============================
// =============================
// ======= 2/ The Checks =======
// =============================
// =============================

{
	const page = loadPage();
	const el = page.elements;
	if (page.posted[0] !== 'ready') fail(`the page's first message is ${JSON.stringify(page.posted[0])}, not "ready"`);
	for (const id of ['btn-report', 'btn-copy', 'btn-open-log']) {
		if (!el[id].disabled) fail(`${id} is enabled before the host sent an error`);
	}
	if (el['btn-close'].disabled) fail('Close must work before the error arrives');

	page.sandbox.window.receiveErrorDialog(ERROR);
	for (const id of ['btn-report', 'btn-copy', 'btn-open-log']) {
		if (el[id].disabled) fail(`${id} stays disabled after the init message`);
	}
	if (el.heading.textContent !== en['error_dialog.heading']) fail(`the heading reads "${el.heading.textContent}"`);
	if (el.module.textContent !== 'keylogger') fail('the module is not shown');
	if (el.message.textContent !== ERROR.message) fail('the message is not shown whole');
	if (el['details-text'].textContent !== REPORT) fail('the details block is not the report the host sent');
	if (el.logged.textContent !== label('error_dialog.logged_in', ERROR.log_path)) fail('the errors file is not named');
	if (el['btn-open-log'].textContent !== en['error_dialog.open_log']) fail('the open button does not name the errors file');
	if (!el.more.hidden) fail('the folded-errors line shows while nothing was folded');
	const hint = label('error_dialog.disable_hint', en['menu.debug.title'], en['menu.debug.show_error_dialog']);
	if (el['disable-hint'].textContent !== hint) fail('the window does not say where to turn it off');

	// Buttons send action names only
	for (const [id, action] of [['btn-report', 'report'], ['btn-copy', 'copy'], ['btn-open-log', 'open_log'], ['btn-close', 'close']]) {
		el[id].dispatch('click');
		const sent = page.posted[page.posted.length - 1];
		if (!sent || sent.action !== action) fail(`${id} did not post ${action}`);
		else if (Object.keys(sent).length !== 1) fail(`${id} sends more than its action name: ${JSON.stringify(sent)}`);
	}

	// Errors folded into the window are counted
	page.sandbox.window.receiveErrorDialog({ type: 'more', count: 2 });
	if (el.more.hidden || el.more.textContent !== label('error_dialog.more', 2)) fail('folded errors are not counted');

	// Action results; AHK sends 1 for true
	page.sandbox.window.receiveErrorDialog({ type: 'action', action: 'copy', ok: 1 });
	if (el.status.textContent !== en['healthcheck.status.copied'] || !/ok/.test(el.status.className)) fail('a copy is not confirmed');
	page.sandbox.window.receiveErrorDialog({ type: 'action', action: 'report', ok: true });
	if (el.status.textContent !== en['notify.report_bug_body']) fail('a report does not say what happened');
	page.sandbox.window.receiveErrorDialog({ type: 'action', action: 'report', ok: false });
	if (!/fail/.test(el.status.className)) fail('a failed action is not shown as a failure');
	page.sandbox.window.receiveErrorDialog({ type: 'action', action: 'open_log', ok: 0, missing: 1 });
	if (el.status.textContent !== en['healthcheck.status.missing'] || /fail/.test(el.status.className)) {
		fail('a log file not created yet is shown as a failure');
	}
}

{
	// A crash notice, delivered as Linux does: through the bridge response hook
	const page = loadPage();
	const el = page.elements;
	const crash = Object.assign({}, ERROR, { kind: 'crash', log_path: '~/crash_reports/2026-09-23T21-04-11Z.json', more: 1 });
	page.sandbox.window.__hostBridgeResponse('error_dialog', true, Buffer.from(JSON.stringify(crash)).toString('base64'));
	if (el['btn-copy'].disabled) fail('the Linux bridge response did not initialise the page');
	if (el.heading.textContent !== en['error_dialog.heading_crash']) fail('a crash notice does not read as one');
	if (el.intro.textContent !== en['error_dialog.intro_crash']) fail('a crash notice keeps the error introduction');
	if (el.logged.textContent !== label('error_dialog.crash_saved_in', crash.log_path)) fail('the crash report is not named');
	if (el['btn-open-log'].textContent !== en['error_dialog.open_crash_report']) fail('the open button does not name the crash report');
	if (el.more.hidden) fail('an initial fold count is not shown');
	page.sandbox.window.__hostBridgeResponse('healthcheck', true, Buffer.from(JSON.stringify(ERROR)).toString('base64'));
	if (el.heading.textContent !== en['error_dialog.heading_crash']) fail('another bridge reached the error window');
}

{
	// Every label the page asks for exists in every locale, as a string
	const sources = ['index.html', 'script.js'].map((file) => fs.readFileSync(path.join(PAGE, file), 'utf8')).join('\n');
	const keys = new Set();
	for (const match of sources.matchAll(/data-i18n="([^"]+)"|\bt\('([a-z0-9_.]+)'/g)) keys.add(match[1] || match[2]);
	for (const match of sources.matchAll(/'((?:error_dialog|healthcheck|notify|common|menu)\.[a-z0-9_.]+)'/g)) keys.add(match[1]);
	if (keys.size < 15) fail(`only ${keys.size} label keys found in the page; the scan is broken`);
	const locales = fs.readdirSync(LOCALES).filter((file) => file.endsWith('.json'));
	if (locales.length !== 21) fail(`${locales.length} locales found, 21 expected`);
	for (const file of locales) {
		const strings = JSON.parse(fs.readFileSync(path.join(LOCALES, file), 'utf8'));
		for (const key of keys) {
			if (typeof strings[key] !== 'string' || strings[key] === '') fail(`${file} lacks ${key}`);
		}
	}
}

if (failures.length > 0) {
	console.error(`[FAIL] error window page behaviour: ${failures.length} failure(s)`);
	for (const failure of failures) console.error(`  - ${failure}`);
	process.exit(1);
}
console.log('[OK] error window page behaviour: ready, report shown as sent, crash notice, buttons by name, folds, results.');
