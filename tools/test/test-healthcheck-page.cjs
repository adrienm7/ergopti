// tools/test/test-healthcheck-page.cjs

/**
 * ==============================================================================
 * MODULE: Diagnostics Page Behaviour
 * DESCRIPTION:
 * Runs the shared diagnostics page (_shared/ui/healthcheck/) over a minimal
 * DOM, with the scripts in the order index.html loads them, and drives it as
 * the three hosts do:
 * 1. the page asks for its first snapshot with "ready", and renders nothing
 *    actionable before the host's init message;
 * 2. the preview shows exactly the text the Copy, Save and Report buttons
 *    send, redacted with the host's rules and context;
 * 3. buttons send action names and ids only; Report carries the file name and
 *    the prefilled issue fields, redacted too;
 * 4. unticking "Include details" drops the opt-in values before any export;
 * 5. a probe answer fills its fields; an action result reaches the status
 *    line; the Linux bridge response is routed to the same entry point;
 * 6. report mode opens the preview.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ROOT = path.resolve(__dirname, '..', '..');
const SHARED = path.join(ROOT, 'static', 'ergopti_plus', '_shared');
const PAGE = path.join(SHARED, 'ui', 'healthcheck');

const failures = [];
const fail = (message) => failures.push(message);

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
		innerHTML: '',
		textContent: '',
		className: '',
		checked: false,
		disabled: false,
		open: false,
		focused: false,
		listeners: {},
		attributes: {},
		addEventListener(type, handler) {
			(this.listeners[type] = this.listeners[type] || []).push(handler);
		},
		dispatch(type, event) {
			for (const handler of this.listeners[type] || []) handler(Object.assign({ target: this }, event || {}));
		},
		getAttribute(name) {
			return this.attributes[name];
		},
		focus() {
			this.focused = true;
		},
		closest() {
			return null;
		},
	};
}

/** Builds the document of index.html, element ids read from the real file. */
function makeDocument() {
	const html = fs.readFileSync(path.join(PAGE, 'index.html'), 'utf8');
	const elements = {};
	for (const match of html.matchAll(/<(\w+)[^>]*\bid="([^"]+)"/g)) elements[match[2]] = element(match[2], match[1]);
	const toolbarButtons = Object.values(elements).filter((el) => el.tagName === 'BUTTON');
	return {
		elements,
		readyState: 'complete',
		addEventListener() {},
		getElementById(id) {
			return elements[id] || null;
		},
		querySelectorAll(selector) {
			if (selector === '.toolbar button') return toolbarButtons;
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
	sandbox.window.webkit = { messageHandlers: { healthcheck: { postMessage: (payload) => posted.push(payload) } } };
	// The locale base the hosts inject before the page's scripts run
	sandbox.__i18n_base = 'https://ergopti.healthcheck/data/locales/';
	sandbox._i18n_locale = 'en';
	sandbox.atob = (text) => Buffer.from(text, 'base64').toString('binary');
	sandbox.TextDecoder = TextDecoder;
	// i18n.js fetches the locale; the test serves en.json, as the virtual host does
	const en = JSON.parse(fs.readFileSync(path.join(SHARED, 'data', 'locales', 'en.json'), 'utf8'));
	sandbox.fetch = () => Promise.resolve({ ok: true, json: () => Promise.resolve(en) });
	vm.createContext(sandbox);
	const html = fs.readFileSync(path.join(PAGE, 'index.html'), 'utf8');
	const scripts = [...html.matchAll(/<script src="([^"]+)"><\/script>/g)].map((m) => m[1]);
	for (const rel of scripts) {
		const file = path.join(PAGE, rel);
		vm.runInContext(fs.readFileSync(file, 'utf8'), sandbox, { filename: file });
	}
	// The strings the hosts inject; en.json is the canonical catalogue
	sandbox.window.i18n_apply(JSON.parse(fs.readFileSync(path.join(SHARED, 'data', 'locales', 'en.json'), 'utf8')));
	return { sandbox, document, posted, elements: document.elements };
}

// ==================================
// ==================================
// ======= 2/ Host Messages =========
// ==================================
// ==================================

const schema = JSON.parse(fs.readFileSync(path.join(SHARED, 'modules', 'diagnostics', 'schema.json'), 'utf8'));
const redaction = JSON.parse(fs.readFileSync(path.join(SHARED, 'modules', 'diagnostics', 'redaction.json'), 'utf8'));
const context = { home: '/home/jdoe', user: 'jdoe', case_insensitive: false };

function snapshot(detailed) {
	return {
		schema_version: 2,
		driver: 'linux',
		generated_at: '2026-09-24T10:00:00Z',
		detailed,
		sections: {
			paths: { logs_dir: `${context.home}/.local/state/ergopti_plus/logs`, diagnostics_dir: `${context.home}/x/diagnostics` },
			versions: { ergopti_version: '2.1.0', commit: 'f4d0bfd63 (git)' },
			system: { os: 'Fedora Linux 41', uptime: 60, elevated: false },
			input: { paused: false },
			network: {},
			peripherals: { items: [{ bus: 'usb', kind: 'keyboard', vendor_id: '046d', product_id: 'c52b', name: 'Secret Keyboard' }] },
			issues: { warn_count: 1, err_count: 0, last_error: 'token=abcdef123456 at /home/jdoe/x' },
			developer: { modules_failed: [] },
		},
		probes: { github_api: { state: 'pending' }, ai_health: { state: 'pending' }, system_details: { state: 'pending' } },
	};
}

function init(page, detailed, mode) {
	page.sandbox.window.receiveDiagnostics({
		type: 'init',
		config: { schema, redaction, context, mode: mode || null },
		snapshot: snapshot(detailed),
	});
}

// =============================
// =============================
// ======= 3/ The Checks =======
// =============================
// =============================

{
	const page = loadPage();
	if (page.posted[0] !== 'ready') fail(`the page's first message is ${JSON.stringify(page.posted[0])}, not "ready"`);
	if (!page.elements['btn-copy'].disabled) fail('Copy is enabled before the host sent anything to copy');
	if (page.elements['btn-close'].disabled) fail('Close must work before the first snapshot');

	init(page, true);
	if (page.elements['btn-copy'].disabled) fail('Copy stays disabled after the init message');
	const preview = page.elements['preview-text'].textContent;
	if (!preview.includes('# ErgoptiPlus')) fail('the preview is not the Markdown report');
	if (preview.includes('/home/jdoe') || preview.includes('abcdef123456')) fail('the preview is not redacted');
	if (!preview.includes('~/.local/state/ergopti_plus/logs')) fail('the preview lost the redacted home path');
	if (!page.elements.content.innerHTML.includes('<h2>')) fail('the page rendered no section');

	page.elements['btn-copy'].dispatch('click');
	const copy = page.posted[page.posted.length - 1];
	if (!copy || copy.action !== 'copy') fail('Copy did not post a copy action');
	else if (copy.text !== preview) fail('Copy sends a text other than the preview');

	page.elements['btn-report'].dispatch('click');
	const report = page.posted[page.posted.length - 1];
	if (!report || report.action !== 'report') fail('Report did not post a report action');
	else {
		if (report.text !== preview) fail('Report sends a text other than the preview');
		if (!/^ergopti-diagnostics-linux-2\.1\.0-20260924T100000Z\.md$/.test(report.name)) fail(`bad report name ${report.name}`);
		for (const id of ['version', 'os', 'driver', 'diagnostics']) {
			if (typeof report.fields[id] !== 'string') fail(`the report does not prefill ${id}`);
		}
		if (JSON.stringify(report.fields).includes('/home/jdoe')) fail('the prefilled fields are not redacted');
	}

	page.elements['btn-save'].dispatch('click');
	const save = page.posted[page.posted.length - 1];
	if (!save || save.action !== 'save' || save.text !== preview || save.name !== report.name) fail('Save does not send the preview and its name');

	page.elements['btn-open-logs'].dispatch('click');
	const logs = page.posted[page.posted.length - 1];
	if (!logs || logs.action !== 'open_path' || logs.id !== 'logs_dir') fail('Open logs does not open the logs folder by id');
	if (logs && Object.keys(logs).some((key) => !['action', 'id'].includes(key))) fail('Open logs sends more than an id');

	// A row button carries its action and id; the page sends nothing else
	const row = element('row', 'button');
	row.attributes = { 'data-action': 'open_settings', 'data-id': 'input_devices' };
	page.elements.content.dispatch('click', { target: { closest: () => row } });
	const settings = page.posted[page.posted.length - 1];
	if (!settings || settings.action !== 'open_settings' || settings.id !== 'input_devices') fail('a row button did not post its action');

	// Details: unticking drops the opt-in values at once, then asks the host
	if (!preview.includes('Secret Keyboard')) fail('the detailed preview misses the device name');
	page.elements['chk-details'].checked = false;
	page.elements['chk-details'].dispatch('change', { target: page.elements['chk-details'] });
	if (page.elements['preview-text'].textContent.includes('Secret Keyboard')) fail('unticking details kept a device name in the preview');
	const refresh = page.posted[page.posted.length - 1];
	if (!refresh || refresh.action !== 'refresh' || refresh.detailed !== false) fail('unticking details did not ask for a plain snapshot');

	// A probe answer fills its field
	page.sandbox.window.receiveDiagnostics({
		type: 'probe', id: 'github_api', result: { state: 'ok', ms: 42 }, sections: { network: { github_api: 'HTTP 200, 59/60' } },
	});
	if (!page.elements.content.innerHTML.includes('HTTP 200, 59/60 (42 ms)')) fail('a probe answer did not reach its field');

	// Action results reach the status line; AHK sends 1 for true
	page.sandbox.window.receiveDiagnostics({ type: 'action', action: 'save', ok: 1, path: '/tmp/r.md' });
	if (!page.elements.status.textContent.includes('/tmp/r.md')) fail('a saved report does not say where it went');
	page.sandbox.window.receiveDiagnostics({ type: 'action', action: 'copy', ok: false });
	if (!/fail/.test(page.elements.status.className)) fail('a failed action is not shown as a failure');
	// Today's errors file does not exist before the day's first warning: no
	// failure, and the page says why nothing opened (open-missing-file)
	{
		const en = JSON.parse(fs.readFileSync(path.join(SHARED, 'data', 'locales', 'en.json'), 'utf8'));
		page.sandbox.window.receiveDiagnostics({ type: 'action', action: 'open_path', ok: 0, missing: 1 });
		if (typeof en['healthcheck.status.missing'] !== 'string') fail('no healthcheck.status.missing label');
		else if (page.elements.status.textContent !== en['healthcheck.status.missing']) {
			fail(`a file not created yet reads "${page.elements.status.textContent}"`);
		}
		if (/fail/.test(page.elements.status.className)) fail('a file not created yet is shown as a failure');
	}

	page.elements['btn-close'].dispatch('click');
	if (page.posted[page.posted.length - 1].action !== 'close') fail('Close does not ask the host to close');
}

{
	// Linux answers through the bridge response hook, base64-encoded
	const page = loadPage();
	const message = { type: 'init', config: { schema, redaction, context, mode: 'report' }, snapshot: snapshot(false) };
	page.sandbox.window.__hostBridgeResponse('healthcheck', true, Buffer.from(JSON.stringify(message)).toString('base64'));
	if (page.elements['btn-copy'].disabled) fail('the Linux bridge response did not initialise the page');
	if (!page.elements.preview.open) fail('report mode does not open the preview');
	if (!page.elements['btn-report'].focused) fail('report mode does not focus the report button');
	if (page.elements['preview-text'].textContent.includes('Secret Keyboard')) fail('a snapshot without details shows a device name');
}

if (failures.length > 0) {
	console.error(`[FAIL] diagnostics page behaviour: ${failures.length} failure(s)`);
	for (const failure of failures) console.error(`  - ${failure}`);
	process.exit(1);
}
console.log('[OK] diagnostics page behaviour: ready, preview, buttons, details, probes, results and report mode.');
