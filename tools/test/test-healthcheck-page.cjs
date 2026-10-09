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
			for (const handler of this.listeners[type] || [])
				handler(Object.assign({ target: this }, event || {}));
		},
		getAttribute(name) {
			return this.attributes[name];
		},
		focus() {
			this.focused = true;
		},
		closest() {
			return null;
		}
	};
}

/** Builds the document of index.html, element ids read from the real file. */
function makeDocument() {
	const html = fs.readFileSync(path.join(PAGE, 'index.html'), 'utf8');
	const elements = {};
	for (const match of html.matchAll(/<(\w+)[^>]*\bid="([^"]+)"/g))
		elements[match[2]] = element(match[2], match[1]);
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
		}
	};
}

/** Loads the page into a sandbox and returns what the host sees of it. */
function loadPage() {
	const posted = [];
	const document = makeDocument();
	const scheduled = new Map();
	let timerId = 0;
	const sandbox = {
		document,
		console,
		posted,
		setTimeout(fn) {
			scheduled.set(++timerId, fn);
			return timerId;
		},
		clearTimeout(id) {
			scheduled.delete(id);
		}
	};
	sandbox.window = sandbox;
	sandbox.window.webkit = {
		messageHandlers: { healthcheck: { postMessage: (payload) => posted.push(payload) } }
	};
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
	sandbox.window.i18n_apply(
		JSON.parse(fs.readFileSync(path.join(SHARED, 'data', 'locales', 'en.json'), 'utf8'))
	);
	return { sandbox, document, posted, scheduled, elements: document.elements };
}

// ==================================
// ==================================
// ======= 2/ Host Messages =========
// ==================================
// ==================================

const schema = JSON.parse(
	fs.readFileSync(path.join(SHARED, 'modules', 'diagnostics', 'schema.json'), 'utf8')
);
const redaction = JSON.parse(
	fs.readFileSync(path.join(SHARED, 'modules', 'diagnostics', 'redaction.json'), 'utf8')
);
const context = { home: '/home/jdoe', user: 'jdoe', case_insensitive: false };

function snapshot(detailed) {
	return {
		schema_version: 2,
		driver: 'linux',
		generated_at: '2026-09-24T10:00:00Z',
		detailed,
		sections: {
			paths: {
				logs_dir: `${context.home}/.local/state/ergopti_plus/logs`,
				diagnostics_dir: `${context.home}/x/diagnostics`
			},
			versions: { ergopti_version: '2.1.0', commit: 'f4d0bfd63 (git)' },
			system: { os: 'Fedora Linux 41', uptime: 60, elevated: false },
			input: { paused: false },
			network: {},
			peripherals: {
				items: [
					{
						bus: 'usb',
						kind: 'keyboard',
						vendor_id: '046d',
						product_id: 'c52b',
						name: 'Secret Keyboard'
					}
				]
			},
			issues: { warn_count: 1, err_count: 0, last_error: 'token=abcdef123456 at /home/jdoe/x' },
			developer: { modules_failed: [] }
		},
		probes: {
			github_api: { state: 'pending' },
			ai_health: { state: 'pending' },
			system_details: { state: 'pending' }
		}
	};
}

function init(page, detailed, mode) {
	page.sandbox.window.receiveDiagnostics({
		type: 'init',
		config: { schema, redaction, context, mode: mode || null },
		snapshot: snapshot(detailed)
	});
}

// =============================
// =============================
// ======= 3/ The Checks =======
// =============================
// =============================

{
	const page = loadPage();
	if (page.posted[0] !== 'ready')
		fail(`the page's first message is ${JSON.stringify(page.posted[0])}, not "ready"`);
	if (!page.elements['btn-copy'].disabled)
		fail('Copy is enabled before the host sent anything to copy');
	// The window's own close button closes it: the toolbar once repeated it
	// with a « Fermer » button, and « Actualiser » takes its place on the
	// right (diagnostics-no-close-button).
	const markup = fs.readFileSync(path.join(PAGE, 'index.html'), 'utf8');
	const toolbarIds = [...markup.matchAll(/<button[^>]*\bid="(btn-[a-z-]+)"/g)].map((m) => m[1]);
	if (toolbarIds.includes('btn-close') || page.elements['btn-close'])
		fail('the page still draws a Close button');
	if (/healthcheck\.toolbar\.close/.test(markup)) fail('the page still names the Close label');
	if (toolbarIds[0] !== 'btn-open-logs')
		fail(`the first toolbar button is ${toolbarIds[0]}, not Open logs`);
	if (toolbarIds[toolbarIds.length - 1] !== 'btn-refresh')
		fail(`the last toolbar button is ${toolbarIds[toolbarIds.length - 1]}, not Refresh`);
	for (const [area, expected] of [
		['left', ['btn-open-logs']],
		['center', ['btn-copy', 'btn-save', 'btn-report']],
		['right', ['btn-cancel', 'btn-refresh']]
	]) {
		const group = new RegExp(`<div class="toolbar-${area}">([\\s\\S]*?)</div>`).exec(markup);
		const ids = group ? [...group[1].matchAll(/\bid="(btn-[a-z-]+)"/g)].map((m) => m[1]) : [];
		if (ids.join(',') !== expected.join(','))
			fail(`the ${area} toolbar area contains ${ids.join(',')}, expected ${expected.join(',')}`);
	}
	const styles = fs
		.readFileSync(path.join(PAGE, 'style.css'), 'utf8')
		.replace(/\/\*[\s\S]*?\*\//g, '');
	if (
		!/\.toolbar \.buttons\s*\{[^}]*grid-template-columns:\s*minmax\(0, 1fr\) auto minmax\(0, 1fr\)/.test(
			styles
		)
	)
		fail('the centered toolbar actions do not have equal side columns');
	if (!/\.toolbar-center\s*\{[^}]*justify-content:\s*center/.test(styles))
		fail('Copy, Save and Report are not centered together');
	if (!/\.toolbar-right\s*\{[^}]*justify-content:\s*flex-end/.test(styles))
		fail('Refresh is not aligned to the right of its toolbar area');
	if (!/@media[^}]*\{[\s\S]*?\.toolbar-center\s*\{[^}]*grid-column:\s*1 \/ -1/.test(styles))
		fail('narrow windows do not give the central actions their own row');
	if (!page.elements['btn-refresh'].disabled)
		fail('Refresh is enabled before the host sent its first snapshot');

	init(page, true);
	if (page.elements['btn-copy'].disabled) fail('Copy stays disabled after the init message');
	const preview = page.elements['preview-text'].textContent;
	if (!preview.includes('# ErgoptiPlus')) fail('the preview is not the Markdown report');
	if (preview.includes('/home/jdoe') || preview.includes('abcdef123456'))
		fail('the preview is not redacted');
	if (preview.includes('~/.local/state/ergopti_plus/logs'))
		fail('the share preview leaked even a redacted path');
	if (!page.elements.content.innerHTML.includes('<h2>')) fail('the page rendered no section');

	page.elements['btn-copy'].dispatch('click');
	{
		const request = page.posted.at(-1);
		if (request.action !== 'export_snapshot')
			fail('copy bypassed the actual cleanup snapshot fence');
		page.sandbox.receiveDiagnostics({
			type: 'action',
			action: 'export_snapshot',
			ok: true,
			export_sequence: request.export_sequence,
			snapshot: snapshot(true),
			share_text: page.sandbox.ErgoptiDiagnostics.formatShareable(
				snapshot(true),
				schema,
				(key) => page.sandbox._i18n_strings[key] || key
			)
		});
	}
	const copy = page.posted[page.posted.length - 1];
	if (!copy || copy.action !== 'copy') fail('Copy did not post a copy action');
	else if (copy.text !== preview) fail('Copy sends a text other than the preview');

	page.elements['btn-report'].dispatch('click');
	{
		const request = page.posted.at(-1);
		if (request.action !== 'export_snapshot')
			fail('report bypassed the actual cleanup snapshot fence');
		page.sandbox.receiveDiagnostics({
			type: 'action',
			action: 'export_snapshot',
			ok: true,
			export_sequence: request.export_sequence,
			snapshot: snapshot(true),
			share_text: page.sandbox.ErgoptiDiagnostics.formatShareable(
				snapshot(true),
				schema,
				(key) => page.sandbox._i18n_strings[key] || key
			)
		});
	}
	const report = page.posted[page.posted.length - 1];
	if (!report || report.action !== 'report') fail('Report did not post a report action');
	else {
		// The host prefills the preview itself as the form's report field:
		// a report names no file, since nothing is saved
		if (report.text !== preview) fail('Report sends a text other than the preview');
		if (Object.keys(report).sort().join(',') !== 'action,fields,text') {
			fail(`Report sends ${Object.keys(report).sort().join(',')}, not only its text and fields`);
		}
		if (Object.keys(report.fields).sort().join(',') !== 'driver,os,version') {
			fail(
				`Report prefills ${Object.keys(report.fields).sort().join(',')}, not only the identity fields`
			);
		}
		if (JSON.stringify(report.fields).includes('/home/jdoe'))
			fail('the prefilled fields are not redacted');
	}

	page.elements['btn-save'].dispatch('click');
	{
		const request = page.posted.at(-1);
		if (request.action !== 'export_snapshot')
			fail('save bypassed the actual cleanup snapshot fence');
		page.sandbox.receiveDiagnostics({
			type: 'action',
			action: 'export_snapshot',
			ok: true,
			export_sequence: request.export_sequence,
			snapshot: snapshot(true),
			share_text: page.sandbox.ErgoptiDiagnostics.formatShareable(
				snapshot(true),
				schema,
				(key) => page.sandbox._i18n_strings[key] || key
			)
		});
	}
	const save = page.posted[page.posted.length - 1];
	if (!save || save.action !== 'save' || save.text !== preview)
		fail('Save does not send the preview');
	else if (!/^ergopti-diagnostics-linux-2\.1\.0-20260924T100000Z\.md$/.test(save.name))
		fail(`bad saved report name ${save.name}`);

	page.elements['btn-open-logs'].dispatch('click');
	const logs = page.posted[page.posted.length - 1];
	if (!logs || logs.action !== 'open_path' || logs.id !== 'logs_dir')
		fail('Open logs does not open the logs folder by id');
	if (logs && Object.keys(logs).some((key) => !['action', 'id'].includes(key)))
		fail('Open logs sends more than an id');

	// A row button carries its action and id; the page sends nothing else
	const row = element('row', 'button');
	row.attributes = { 'data-action': 'open_settings', 'data-id': 'input_devices' };
	page.elements.content.dispatch('click', { target: { closest: () => row } });
	const settings = page.posted[page.posted.length - 1];
	if (!settings || settings.action !== 'open_settings' || settings.id !== 'input_devices')
		fail('a row button did not post its action');

	// Details: unticking drops the opt-in values at once, then asks the host
	if (preview.includes('Secret Keyboard'))
		fail('the detailed share preview leaked the device name');
	if (!page.elements.content.innerHTML.includes('Secret Keyboard'))
		fail('the local detailed view lost its independently collected device name');
	page.elements['chk-details'].checked = false;
	page.elements['chk-details'].dispatch('change', { target: page.elements['chk-details'] });
	if (page.elements['preview-text'].textContent.includes('Secret Keyboard'))
		fail('unticking details kept a device name in the preview');
	const refresh = page.posted[page.posted.length - 1];
	if (
		!refresh ||
		refresh.action !== 'refresh' ||
		refresh.detailed !== false ||
		refresh.extensive !== false
	)
		fail('unticking details did not ask for a plain snapshot');

	// A probe answer fills its field
	page.sandbox.window.receiveDiagnostics({
		type: 'probe',
		id: 'github_api',
		result: { state: 'ok', ms: 42 },
		sections: { network: { github_api: 'HTTP 200, 59/60' } }
	});
	if (!page.elements.content.innerHTML.includes('HTTP 200, 59/60 (42 ms)'))
		fail('a probe answer did not reach its field');

	// Action results reach the status line; AHK sends 1 for true
	page.sandbox.window.receiveDiagnostics({
		type: 'action',
		action: 'save',
		ok: 1,
		path: '/tmp/r.md'
	});
	if (!page.elements.status.textContent.includes('/tmp/r.md'))
		fail('a saved report does not say where it went');
	{
		// A report opened the prefilled form: the status says so, not where a
		// file went
		const en = JSON.parse(fs.readFileSync(path.join(SHARED, 'data', 'locales', 'en.json'), 'utf8'));
		page.sandbox.window.receiveDiagnostics({ type: 'action', action: 'report', ok: true });
		if (page.elements.status.textContent !== en['notify.report_bug_body']) {
			fail(`a sent report reads "${page.elements.status.textContent}"`);
		}
	}
	page.sandbox.window.receiveDiagnostics({ type: 'action', action: 'copy', ok: false });
	if (!/fail/.test(page.elements.status.className))
		fail('a failed action is not shown as a failure');
	// Today's errors file does not exist before the day's first warning: no
	// failure, and the page says why nothing opened (open-missing-file)
	{
		const en = JSON.parse(fs.readFileSync(path.join(SHARED, 'data', 'locales', 'en.json'), 'utf8'));
		page.sandbox.window.receiveDiagnostics({
			type: 'action',
			action: 'open_path',
			ok: 0,
			missing: 1
		});
		if (typeof en['healthcheck.status.missing'] !== 'string')
			fail('no healthcheck.status.missing label');
		else if (page.elements.status.textContent !== en['healthcheck.status.missing']) {
			fail(`a file not created yet reads "${page.elements.status.textContent}"`);
		}
		if (/fail/.test(page.elements.status.className))
			fail('a file not created yet is shown as a failure');
	}

	if (page.posted.some((message) => message && message.action === 'close'))
		fail('the page asked the host to close: only the window itself closes it');
}

{
	// Linux answers through the bridge response hook, base64-encoded
	const page = loadPage();
	const message = {
		type: 'init',
		config: { schema, redaction, context, mode: 'report' },
		snapshot: snapshot(false)
	};
	page.sandbox.window.__hostBridgeResponse(
		'healthcheck',
		true,
		Buffer.from(JSON.stringify(message)).toString('base64')
	);
	if (page.elements['btn-copy'].disabled)
		fail('the Linux bridge response did not initialise the page');
	if (!page.elements.preview.open) fail('report mode does not open the preview');
	if (!page.elements['btn-report'].focused) fail('report mode does not focus the report button');
	if (page.elements['preview-text'].textContent.includes('Secret Keyboard'))
		fail('a snapshot without details shows a device name');
}

{
	// The window opens wide enough for the paths it lists: at 860 pixels the
	// value column held about 75 characters and most paths were cut in two
	// (diagnostics-wide-enough). The estimate reads the page's own layout:
	// the label column's share, the side paddings, and an average character
	// of the 13 px interface font.
	const PATH_CHARACTERS = 95;
	const CHARACTER_PX = 6.5;
	const CHROME_PX = 16 * 2 + 17;
	const styles = fs
		.readFileSync(path.join(PAGE, 'style.css'), 'utf8')
		.replace(/\/\*[\s\S]*?\*\//g, '');
	const labels = /table\.fields th\s*\{[^}]*width:\s*(\d+)%/.exec(styles);
	const manifest = JSON.parse(
		fs.readFileSync(path.join(SHARED, 'ui', 'apps.manifest.json'), 'utf8')
	);
	const geometry = Object.values(manifest).find((group) => group && group.healthcheck);
	if (!labels || !geometry) {
		fail('the diagnostics layout or its window geometry is no longer where this test reads it');
	} else {
		const valuePx = (geometry.healthcheck.width - CHROME_PX) * (1 - Number(labels[1]) / 100);
		const characters = Math.floor(valuePx / CHARACTER_PX);
		if (characters < PATH_CHARACTERS)
			fail(
				`the window opens ${geometry.healthcheck.width} px wide: its value column holds about ` +
					`${characters} characters, and a path needs ${PATH_CHARACTERS} to stay on one line`
			);
	}
}

{
	const host = fs.readFileSync(
		path.join(SHARED, '..', 'windows', 'ui', 'healthcheck', 'core.ahk'),
		'utf8'
	);
	if (/\bWebView_ShouldUseNativeFallback\s*\(/.test(host))
		fail('installed WebView2 diagnostics must be attempted under memory pressure');
	if (!host.includes('_HC_ShowNativeSnapshot(G, Snapshot)') || !host.includes('G.Add("TreeView"'))
		fail('a real WebView2 failure must leave structured native diagnostics');
	if (/EditCtl[\s\S]*?HealthCheck_FormatPlain\(Snapshot\)/.test(host))
		fail('the diagnostics window must not fall back to a raw-text report');
}

{
	const page = loadPage();
	const quick = snapshot(true);
	quick.extensive = false;
	for (const id of Object.keys(quick.probes))
		quick.probes[id] = { state: 'not_run', reason: 'opt_in_required' };
	page.sandbox.receiveDiagnostics({
		type: 'init',
		config: { schema, redaction, context },
		snapshot: quick
	});
	if (page.elements['chk-extensive'].checked || page.scheduled.size !== 0)
		fail('quick diagnostics ran controls or selected extensive tests implicitly');
	if (!page.elements['chk-details'].checked)
		fail('extensive selection overwrote the independent privacy opt-in');
	page.elements['chk-extensive'].checked = true;
	page.elements['chk-extensive'].dispatch('change');
	const request = page.posted.at(-1);
	if (request.extensive !== true || request.detailed !== true)
		fail('explicit extensive selection lost its independent privacy flag');
	const deep = snapshot(false);
	deep.extensive = true;
	page.sandbox.receiveDiagnostics({ type: 'snapshot', snapshot: deep });
	if (page.scheduled.size !== 1 || page.elements['btn-cancel'].disabled)
		fail('extensive diagnostics have no live progress/cancel owner');
	page.elements['btn-cancel'].dispatch('click');
	if (page.posted.at(-1).action !== 'cancel' || page.scheduled.size !== 0)
		fail('Cancel did not stop the model queue and request actual host cancellation');
	const text = page.elements['preview-text'].textContent;
	if (!text.includes('cancelled') || !text.includes('not_collected'))
		fail('cancelled partial exports lose their precise outcomes');
}

{
	const page = loadPage();
	const current = snapshot(false);
	current.extensive = false;
	current.probes.github_api = { state: 'timeout', cleanup: 'pending' };
	page.sandbox.receiveDiagnostics({
		type: 'init',
		config: { schema, redaction, context },
		snapshot: current
	});
	page.elements['btn-copy'].dispatch('click');
	const request = page.posted.at(-1);
	if (
		request.action !== 'export_snapshot' ||
		page.posted.some((row) => row && row.action === 'copy')
	)
		fail('an export bypassed the pre-format cleanup snapshot receipt');
	const fresh = snapshot(false);
	fresh.extensive = false;
	fresh.probes.github_api = {
		state: 'timeout',
		cleanup: 'settled',
		native_status: -1712,
		runtime_pid: 4321,
		detail: 'native_timeout',
		sender_context: 'driver_spawned_osascript',
		qualification_scope: 'local_runtime_nonce'
	};
	page.sandbox.receiveDiagnostics({
		type: 'action',
		action: 'export_snapshot',
		ok: true,
		export_sequence: request.export_sequence + 1,
		snapshot: fresh,
		share_text: page.sandbox.ErgoptiDiagnostics.formatShareable(
			fresh,
			schema,
			(key) => page.sandbox._i18n_strings[key] || key
		)
	});
	if (page.posted.some((row) => row && row.action === 'copy'))
		fail('a foreign export sequence was accepted');
	page.sandbox.receiveDiagnostics({
		type: 'action',
		action: 'export_snapshot',
		ok: true,
		export_sequence: request.export_sequence,
		snapshot: fresh,
		share_text: page.sandbox.ErgoptiDiagnostics.formatShareable(
			fresh,
			schema,
			(key) => page.sandbox._i18n_strings[key] || key
		)
	});
	const copy = page.posted.at(-1);
	if (
		copy.action !== 'copy' ||
		!copy.text.includes('"state":"timeout"') ||
		!copy.text.includes('"native_status":-1712') ||
		!copy.text.includes('"runtime_pid":4321') ||
		!copy.text.includes('"cleanup":"settled"') ||
		!copy.text.includes('"qualification_scope":"local_runtime_nonce"')
	)
		fail('the fresh precise owner receipt was not exported');
	if (copy.text.includes('Resource cleanup is pending'))
		fail('the export used text from before genuine cleanup observation');
	page.elements['btn-copy'].dispatch('click');
	const stale = page.posted.at(-1);
	page.elements['btn-refresh'].dispatch('click');
	const before = page.posted.length;
	page.sandbox.receiveDiagnostics({
		type: 'action',
		action: 'export_snapshot',
		ok: true,
		export_sequence: stale.export_sequence,
		snapshot: fresh,
		share_text: page.sandbox.ErgoptiDiagnostics.formatShareable(
			fresh,
			schema,
			(key) => page.sandbox._i18n_strings[key] || key
		)
	});
	if (page.posted.length !== before) fail('an obsolete export survived a new snapshot request');
}

{
	for (const location of ['current', 'retired', 'model', 'unknown']) {
		const page = loadPage();
		const value = snapshot(false);
		value.extensive = false;
		for (const id of Object.keys(value.probes))
			value.probes[id] = { state: 'not_run', reason: 'opt_in_required' };
		const debt = {
			state: 'timeout',
			cleanup: location === 'unknown' ? 'unknown' : 'pending',
			ms: 17
		};
		if (location === 'retired') value.retired_probes = [{ probes: { github_api: debt } }];
		else value.probes.github_api = debt;
		page.sandbox.receiveDiagnostics({
			type: 'init',
			config: { schema, redaction, context },
			snapshot: value
		});
		if (location === 'model') {
			delete value.probes.github_api.cleanup;
			value.diagnostic_checks.schema_fields = debt;
			debt.cleanup = 'pending';
			page.sandbox.receiveDiagnostics({ type: 'probe', id: 'github_api', result: { state: 'ok' } });
		}
		if (page.elements['btn-cancel'].disabled)
			fail(location + ' terminal business result hid an unsettled cleanup owner');
		const originalState = debt.state;
		page.elements['btn-cancel'].dispatch('click');
		if (page.posted.at(-1).action !== 'cancel')
			fail(location + ' cleanup cancellation was not requested');
		if (debt.state !== originalState || debt.cleanup === 'settled')
			fail(location + ' page cancellation fabricated a result or a cleanup acknowledgement');
		if (page.elements['btn-cancel'].disabled)
			fail(location + ' cleanup retry became inaccessible before a host acknowledgement');
		const settled = JSON.parse(JSON.stringify(value));
		if (location === 'retired') settled.retired_probes[0].probes.github_api.cleanup = 'settled';
		else if (location === 'model') {
			// The action handler deliberately retains the current model results.
			// Their owner has no native resources; this control records its exact ACK.
			value.diagnostic_checks.schema_fields.cleanup = 'settled';
		} else settled.probes.github_api.cleanup = 'settled';
		page.sandbox.receiveDiagnostics({
			type: 'action',
			action: 'cancel',
			ok: true,
			snapshot: settled
		});
		if (!page.elements['btn-cancel'].disabled)
			fail(location + ' settled acknowledgement left idle cancellation enabled');
		if (debt.state !== originalState)
			fail(location + ' host cleanup observation changed a sticky business result');
	}
	const idle = loadPage();
	const value = snapshot(false);
	value.extensive = false;
	for (const id of Object.keys(value.probes))
		value.probes[id] = { state: 'not_run', reason: 'opt_in_required' };
	idle.sandbox.receiveDiagnostics({
		type: 'init',
		config: { schema, redaction, context },
		snapshot: value
	});
	if (!idle.elements['btn-cancel'].disabled)
		fail('a quick idle snapshot enabled cancellation without work or cleanup debt');
}

if (failures.length > 0) {
	console.error(`[FAIL] diagnostics page behaviour: ${failures.length} failure(s)`);
	for (const failure of failures) console.error(`  - ${failure}`);
	process.exit(1);
}
console.log(
	'[OK] diagnostics page behaviour: ready, preview, buttons, details, probes, results and report mode.'
);
