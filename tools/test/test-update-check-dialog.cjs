// tools/test/test-update-check-dialog.cjs

/**
 * ==============================================================================
 * MODULE: Update Check Page Behaviour
 * DESCRIPTION:
 * Runs the shared update-check window (_shared/ui/update_check/) over a
 * minimal DOM, with the scripts in the order index.html loads them, and
 * drives it as the three hosts do:
 * 1. the page asks for its state with "ready" and offers nothing but Close
 *    before the host's first state;
 * 2. each phase renders its two lines and its buttons: checking names the
 *    channel being checked, up to date names the version and the channel,
 *    a new release names itself and the installed version and offers Update
 *    and What's new, a channel without release says so, and a failure gives
 *    its reason, today's log and the Report button;
 * 3. every other channel the host lists gets one line and one switch button
 *    that posts that channel's id, and nothing else;
 * 4. buttons send action names only; action results reach the status line;
 *    the Linux bridge response reaches the same entry point;
 * 5. every label the page asks for exists in every locale with the English
 *    placeholders, and the French wording is the approved one;
 * 6. everything is centered: the text, the answer's column and the buttons.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ROOT = path.resolve(__dirname, '..', '..');
const SHARED = path.join(ROOT, 'static', 'ergopti_plus', '_shared');
const PAGE = path.join(SHARED, 'ui', 'update_check');
const LOCALES = path.join(SHARED, 'data', 'locales');
const LOCALE_COUNT = 21;

// The reasons a host may give for a failed check; each is a locale key
const REASON_KEYS = [
	'updater.no_connection',
	'updater.parse_failed',
	'update_check.error_unexpected',
	'update_check.error_no_asset'
];

// Translations that are the English word in that language too
const SAME_AS_ENGLISH = { 'nl:update_check.window_title': true };

// The approved French wording (DECISIONS and the C4 specification)
const FRENCH = {
	'update_check.checking': 'Recherche de mises à jour sur le canal {channel}…',
	'update_check.is_latest': 'est déjà la dernière version du canal {channel}',
	'update_check.available': 'est disponible — vous avez {current} ({channel})',
	'update_check.update': 'Mettre à jour',
	'update_check.whats_new': 'Nouveautés',
	'update_check.also_available': 'Aussi disponible sur {channel} : {tag}'
};

const failures = [];
let checks = 0;
const expect = (condition, message) => {
	checks += 1;
	if (!condition) failures.push(message);
};

const locales = {};
for (const file of fs.readdirSync(LOCALES).filter((name) => name.endsWith('.json'))) {
	locales[file.replace(/\.json$/, '')] = JSON.parse(
		fs.readFileSync(path.join(LOCALES, file), 'utf8')
	);
}
const en = locales.en;

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
		type: '',
		disabled: false,
		hidden: false,
		listeners: {},
		childNodes: [],
		get firstChild() {
			return this.childNodes[0] || null;
		},
		appendChild(child) {
			this.childNodes.push(child);
			return child;
		},
		removeChild(child) {
			this.childNodes = this.childNodes.filter((node) => node !== child);
			return child;
		},
		addEventListener(type, handler) {
			(this.listeners[type] = this.listeners[type] || []).push(handler);
		},
		dispatch(type) {
			for (const handler of this.listeners[type] || []) handler({ target: this });
		}
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
		body: element('body', 'body'),
		readyState: 'complete',
		addEventListener() {},
		createElement: (tag) => element('', tag),
		getElementById(id) {
			return elements[id] || null;
		},
		querySelectorAll() {
			return [];
		}
	};
}

/** Loads the page into a sandbox and returns what the host sees of it. */
function loadPage(strings) {
	const posted = [];
	const logged = [];
	const document = makeDocument();
	const pageConsole = {
		log: console.log,
		warn: console.warn,
		error: (...args) => logged.push(args.join(' '))
	};
	const sandbox = { document, console: pageConsole, posted };
	sandbox.window = sandbox;
	sandbox.window.webkit = {
		messageHandlers: { update_check_bridge: { postMessage: (payload) => posted.push(payload) } }
	};
	sandbox.__i18n_base = 'https://ergopti.updatecheck/data/locales/';
	sandbox._i18n_locale = 'en';
	sandbox.atob = (text) => Buffer.from(text, 'base64').toString('binary');
	sandbox.TextDecoder = TextDecoder;
	sandbox.fetch = () => Promise.resolve({ ok: true, json: () => Promise.resolve(strings) });
	vm.createContext(sandbox);
	const html = fs.readFileSync(path.join(PAGE, 'index.html'), 'utf8');
	const scripts = [...html.matchAll(/<script src="([^"]+)"><\/script>/g)].map((m) => m[1]);
	expect(
		scripts.length >= 5,
		`index.html loads ${scripts.length} script(s); the page needs its bridge, i18n, the channel registry and its script`
	);
	for (const rel of scripts) {
		const file = path.join(PAGE, rel);
		vm.runInContext(fs.readFileSync(file, 'utf8'), sandbox, { filename: file });
	}
	sandbox.window.i18n_apply(strings);
	return { sandbox, posted, logged, elements: document.elements, body: document.body };
}

/** The label a key renders as, named placeholders filled. */
function label(strings, key, values) {
	return String(strings[key]).replace(/\{([a-z_]+)\}/g, (whole, name) =>
		Object.prototype.hasOwnProperty.call(values || {}, name) ? values[name] : whole
	);
}

/** The visible texts of the other-channel list, and its buttons. */
function otherLines(el) {
	return el.others.childNodes.map((item) => ({
		text: item.childNodes[0].textContent,
		button: item.childNodes[1]
	}));
}

const STABLE = en['updater.channel.main'];
const DEV = en['updater.channel.dev'];
const OTHERS = [{ channel: 'main', tag: 'v1.2.0' }];

// =============================
// =============================
// ======= 2/ The Phases =======
// =============================
// =============================

{
	const page = loadPage(en);
	const el = page.elements;
	const receive = (message) => page.sandbox.window.receiveUpdateCheck(message);
	const last = () => page.posted[page.posted.length - 1];

	expect(
		page.posted[0] === 'ready',
		`the page's first message is ${JSON.stringify(page.posted[0])}`
	);
	expect(
		el.line1.textContent === en['common.loading'],
		'the page shows it is loading before the host'
	);
	for (const id of ['btn-update', 'btn-report', 'btn-open-log', 'btn-whats-new']) {
		expect(el[id].hidden, `${id} shows before the host sent a state`);
	}
	expect(!el['btn-close'].hidden, 'Close must work before the first state');
	expect(el['btn-close'].textContent === en['common.close'], 'Close is not labelled');

	// Checking: the channel is named, nothing to act on but Close
	receive({ type: 'state', state: 'checking', channel: 'dev', current: 'v0.0.0-dev.144' });
	expect(
		el.line1.textContent === label(en, 'update_check.checking', { channel: DEV }),
		`checking reads "${el.line1.textContent}"`
	);
	expect(!el.spinner.hidden, 'checking shows no progress');
	expect(el['btn-update'].hidden && el['btn-report'].hidden, 'checking offers an action');
	expect(page.body.className === 'state-checking', 'the body does not carry the phase');

	// Up to date: the version, then that it is the channel's latest
	receive({
		type: 'state',
		state: 'up_to_date',
		channel: 'dev',
		current: 'v0.0.0-dev.144',
		others: OTHERS
	});
	expect(el.line1.textContent === 'v0.0.0-dev.144', 'up to date does not lead with the version');
	expect(
		el.line2.textContent === label(en, 'update_check.is_latest', { channel: DEV }),
		`up to date reads "${el.line2.textContent}"`
	);
	expect(el.spinner.hidden, 'the progress stays after the answer');
	expect(el['btn-update'].hidden, 'up to date offers an update');
	expect(el['btn-whats-new'].hidden, 'up to date links to release notes');
	let lines = otherLines(el);
	expect(!el.others.hidden && lines.length === 1, 'the other channel is not listed once');
	if (lines.length === 1) {
		expect(
			lines[0].text ===
				label(en, 'update_check.also_available', { channel: STABLE, tag: 'v1.2.0' }),
			`the other-channel line reads "${lines[0].text}"`
		);
		expect(
			lines[0].button.textContent === en['update_check.switch_channel'],
			'the switch button is not labelled'
		);
		lines[0].button.dispatch('click');
		expect(
			JSON.stringify(last()) === JSON.stringify({ action: 'switch_channel', channel: 'main' }),
			`the switch posts ${JSON.stringify(last())}`
		);
	}

	// Available: the release, then what is installed; Update and What's new
	receive({
		type: 'state',
		state: 'available',
		channel: 'dev',
		current: 'v0.0.0-dev.144',
		latest: 'v0.0.0-dev.150',
		others: []
	});
	expect(el.line1.textContent === 'v0.0.0-dev.150', 'a new release does not lead with its tag');
	expect(
		el.line2.textContent ===
			label(en, 'update_check.available', { current: 'v0.0.0-dev.144', channel: DEV }),
		`available reads "${el.line2.textContent}"`
	);
	expect(!el['btn-update'].hidden, 'a new release offers no Update button');
	expect(el['btn-update'].textContent === en['update_check.update'], 'Update is not labelled');
	expect(!el['btn-whats-new'].hidden, 'a new release has no What’s new link');
	expect(el.others.hidden && el.others.childNodes.length === 0, 'a stale other-channel line stays');
	expect(el['btn-report'].hidden, 'a new release offers a report');

	// Buttons send their action name only
	for (const [id, action] of [
		['btn-update', 'update'],
		['btn-whats-new', 'whats_new'],
		['btn-report', 'report'],
		['btn-open-log', 'open_log'],
		['btn-close', 'close']
	]) {
		el[id].dispatch('click');
		const sent = last();
		expect(sent && sent.action === action, `${id} did not post ${action}`);
		expect(
			sent && Object.keys(sent).length === 1,
			`${id} sends more than its action name: ${JSON.stringify(sent)}`
		);
	}

	// No release on the channel yet
	receive({
		type: 'state',
		state: 'no_release',
		channel: 'main',
		current: 'v0.0.0-dev.144',
		others: [{ channel: 'dev', tag: 'v0.0.0-dev.150' }]
	});
	expect(
		el.line2.textContent === label(en, 'updater.no_release_on_channel', { channel: STABLE }),
		`no release reads "${el.line2.textContent}"`
	);
	expect(el['btn-update'].hidden, 'a channel without release offers an update');
	lines = otherLines(el);
	expect(lines.length === 1 && lines[0].text.includes(DEV), 'the newer dev release is not listed');

	// A failure: its reason, today's log and the Report button; no switch line
	const LOG = '~/.local/state/ergopti_plus/logs/ErgoptiPlus_2026-09-29.log';
	receive({
		type: 'state',
		state: 'error',
		channel: 'dev',
		current: 'v0.0.0-dev.144',
		reason_key: 'updater.no_connection',
		log_path: LOG,
		others: OTHERS
	});
	expect(el.line1.textContent === en['update_check.error_heading'], 'the failure has no heading');
	expect(el.line2.textContent === en['updater.no_connection'], 'the failure gives no reason');
	expect(
		!el.logged.hidden &&
			el.logged.textContent === label(en, 'update_check.logged_in', { path: LOG }),
		`the failure does not name today's log: "${el.logged.textContent}"`
	);
	expect(!el['btn-report'].hidden, 'the failure offers no Report button');
	expect(
		el['btn-report'].textContent === en['healthcheck.toolbar.report'],
		'Report is not the report label'
	);
	expect(!el['btn-open-log'].hidden, 'the failure cannot open its log');
	expect(el['btn-update'].hidden, 'a failure offers an update');
	expect(el.others.hidden, 'a failure lists other channels it never read');

	// Every reason renders in full
	for (const key of REASON_KEYS) {
		receive({
			type: 'state',
			state: 'error',
			channel: 'dev',
			current: 'v0.0.0-dev.144',
			latest: 'v0.0.0-dev.150',
			reason_key: key,
			log_path: LOG
		});
		expect(el.line2.textContent !== key, `the reason ${key} is not translated`);
		expect(!/\{[a-z_]+\}/.test(el.line2.textContent), `the reason ${key} keeps a placeholder`);
	}

	// An unknown phase is refused, the window keeps its last answer
	const before = el.line1.textContent;
	receive({ type: 'state', state: 'installing' });
	expect(el.line1.textContent === before, 'an unknown phase replaced the answer');
	expect(
		page.logged.some((line) => line.includes('unknown state')),
		'an unknown phase is refused silently'
	);

	// Action results; AHK sends 1 for true
	receive({ type: 'action', action: 'report', ok: 1 });
	expect(
		el.status.textContent === en['notify.report_bug_body'] && /ok/.test(el.status.className),
		'a report does not say what happened'
	);
	receive({ type: 'action', action: 'open_log', ok: false });
	expect(/fail/.test(el.status.className), 'a failed action is not shown as a failure');
	receive({ type: 'action', action: 'open_log', ok: false, missing: true });
	expect(el.status.textContent === en['healthcheck.status.missing'], 'a missing log is not told');

	// The Linux bridge response reaches the same entry point
	const payload = Buffer.from(
		JSON.stringify({ type: 'state', state: 'up_to_date', channel: 'main', current: 'v1.2.0' })
	).toString('base64');
	page.sandbox.window.__hostBridgeResponse('update_check_bridge', true, payload);
	expect(el.line1.textContent === 'v1.2.0', 'the Linux bridge response is not rendered');
	page.sandbox.window.__hostBridgeResponse('another_bridge', true, payload);
}

// =====================================
// =====================================
// ======= 3/ Language and Words =======
// =====================================
// =====================================

{
	const script = fs.readFileSync(path.join(PAGE, 'script.js'), 'utf8');
	const html = fs.readFileSync(path.join(PAGE, 'index.html'), 'utf8');
	const keys = new Set(REASON_KEYS);
	for (const match of script.matchAll(/\bt\('([a-z0-9_.]+)'/g)) keys.add(match[1]);
	for (const match of html.matchAll(/data-i18n="([a-z0-9_.]+)"/g)) keys.add(match[1]);
	for (const key of Object.keys(en)) if (key.startsWith('update_check.')) keys.add(key);
	expect(keys.size >= 15, `the page asks for only ${keys.size} labels`);
	expect(Object.keys(locales).length === LOCALE_COUNT, 'the page is not checked in 21 locales');
	const placeholders = (value) => (String(value).match(/\{[a-z_]+\}/g) || []).sort().join(',');
	for (const key of keys) {
		expect(typeof en[key] === 'string' && en[key] !== '', `en lacks ${key}`);
		for (const [code, strings] of Object.entries(locales)) {
			const value = strings[key];
			expect(typeof value === 'string' && value.trim() !== '', `${code} lacks ${key}`);
			expect(
				placeholders(value) === placeholders(en[key]),
				`${code} ${key} does not carry the English placeholders`
			);
			if (code !== 'en' && key.startsWith('update_check.') && !SAME_AS_ENGLISH[code + ':' + key]) {
				expect(value !== en[key], `${code} ${key} is an English copy`);
			}
		}
	}
	for (const [key, wording] of Object.entries(FRENCH)) {
		expect(locales.fr[key] === wording, `fr ${key} is not the approved "${wording}"`);
	}

	// The French window reads as specified
	const page = loadPage(locales.fr);
	page.sandbox.window.receiveUpdateCheck({
		type: 'state',
		state: 'checking',
		channel: 'dev',
		current: 'v0.0.0-dev.144'
	});
	expect(
		page.elements.line1.textContent === 'Recherche de mises à jour sur le canal Dev…',
		`the French checking line reads "${page.elements.line1.textContent}"`
	);
}

// ============================
// ============================
// ======= 4/ Centering =======
// ============================
// ============================

{
	const css = fs.readFileSync(path.join(PAGE, 'style.css'), 'utf8');
	const blocks = css
		.replace(/\/\*[\s\S]*?\*\//g, '')
		.split('}')
		.map((block) => block.split('{'))
		.filter((parts) => parts.length === 2);
	/** The declarations of every block whose selector list names one selector. */
	const rule = (selector) => {
		const declarations = {};
		for (const [selectors, body] of blocks) {
			if (!selectors.split(',').some((name) => name.trim() === selector)) continue;
			for (const part of body.split(';')) {
				const [name, ...value] = part.split(':');
				if (name && value.length) declarations[name.trim()] = value.join(':').trim();
			}
		}
		return declarations;
	};
	const body = rule('body');
	const main = rule('main');
	const buttons = rule('.buttons');
	const others = rule('.others li');
	expect(body['text-align'] === 'center', 'the body text is not centered');
	expect(body['align-items'] === 'center', 'the body column is not centered');
	expect(
		main.display === 'flex' && main['flex-direction'] === 'column',
		'the answer is not a column'
	);
	expect(main['justify-content'] === 'center', 'the answer is not centered vertically');
	expect(main['align-items'] === 'center', 'the answer is not centered horizontally');
	expect(main['text-align'] === 'center', 'the answer text is not centered');
	expect(buttons['justify-content'] === 'center', 'the buttons are not centered');
	expect(others['justify-content'] === 'center', 'the other-channel lines are not centered');
}

if (failures.length) {
	console.error(
		`\x1b[31m[ERROR] update-check page: ${failures.length} failure(s) in ${checks} check(s):\x1b[0m`
	);
	for (const failure of failures) console.error(`  - ${failure}`);
	process.exit(1);
}
console.log(
	`\x1b[32m[OK] update-check page: phases, other channels, actions, 21 locales and centering (${checks} checks).\x1b[0m`
);
