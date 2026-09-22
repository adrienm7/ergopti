// tools/test/test-onboarding-wizard-page.cjs

/**
 * ==============================================================================
 * MODULE: Onboarding Wizard Page Regression
 * DESCRIPTION:
 * Executes the shared first-run wizard page against a minimal DOM and drives it
 * through the host protocol every driver speaks. Pins the three reported
 * regressions at the page boundary: the title follows the previewed locale and
 * names the product once, a folder picked natively lands in the field and in
 * the finish payload, and the metrics consent warning names the store of the
 * folder chosen on the config step rather than the one known at open time.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const SHARED = path.resolve(__dirname, '../../static/ergopti_plus/_shared');
const source = fs.readFileSync(path.join(SHARED, 'ui/onboarding/script.js'), 'utf8');
const hostBridge = fs.readFileSync(path.join(SHARED, 'ui/host_bridge.js'), 'utf8');
const html = fs.readFileSync(path.join(SHARED, 'ui/onboarding/index.html'), 'utf8');
const LOCALE_DIR = path.join(SHARED, 'data/locales');
const PRODUCT = 'ErgoptiPlus';

/**
 * Reads one locale file as a flat key -> string map.
 * @param {string} code
 * @returns {Object<string, string>}
 */
function locale(code) {
	return JSON.parse(
		fs.readFileSync(path.join(LOCALE_DIR, code + '.json'), 'utf8').replace(/^\uFEFF/, '')
	);
}

/**
 * Counts non-overlapping occurrences of needle in haystack.
 * @param {string} haystack
 * @param {string} needle
 * @returns {number}
 */
function occurrences(haystack, needle) {
	return haystack.split(needle).length - 1;
}

// ======================================
// ======= 1/ Minimal DOM ===============
// ======================================

/**
 * Builds a fresh page with every id declared in index.html.
 * @returns {{context: object, elements: Map, messages: Array, click: Function}}
 */
function loadPage() {
	const elements = new Map();
	const radios = [];
	const messages = [];

	function makeElement(tag, id) {
		const classes = new Set();
		const listeners = {};
		const el = {
			tagName: tag,
			id,
			textContent: '',
			value: '',
			placeholder: '',
			hidden: false,
			disabled: false,
			checked: false,
			src: '',
			style: {},
			dataset: {},
			children: [],
			className: '',
			classList: {
				add: (...names) => names.forEach((n) => classes.add(n)),
				remove: (...names) => names.forEach((n) => classes.delete(n)),
				toggle: (n, force) => {
					const on = force === undefined ? !classes.has(n) : !!force;
					if (on) classes.add(n);
					else classes.delete(n);
					return on;
				},
				contains: (n) => classes.has(n)
			},
			addEventListener(type, fn) {
				(listeners[type] = listeners[type] || []).push(fn);
			},
			dispatch(type) {
				(listeners[type] || []).slice().forEach((fn) => fn({ target: el }));
			},
			click() {
				el.dispatch('click');
			},
			appendChild(child) {
				el.children.push(child);
				return child;
			},
			set innerHTML(_) {
				el.children = [];
			},
			get innerHTML() {
				return '';
			},
			hasClass(n) {
				return classes.has(n) || el.className.split(/\s+/).includes(n);
			},
			querySelectorAll(selector) {
				const wanted = selector.split('.').filter(Boolean);
				const out = [];
				(function walk(node) {
					node.children.forEach((child) => {
						if (wanted.every((n) => child.hasClass(n))) out.push(child);
						walk(child);
					});
				})(el);
				return out;
			},
			querySelector(selector) {
				return el.querySelectorAll(selector)[0] || null;
			},
			scrollIntoView() {},
			focus() {}
		};
		return el;
	}

	for (const match of html.matchAll(/<(\w+)[^>]*\sid="([^"]+)"/g)) {
		elements.set(match[2], makeElement(match[1], match[2]));
	}
	for (const match of html.matchAll(
		/<input type="radio" name="(\w+)" value="([^"]*)"( checked)?/g
	)) {
		const radio = makeElement('input', '');
		radio.name = match[1];
		radio.value = match[2];
		radio.checked = !!match[3];
		radio.type = 'radio';
		radios.push(radio);
	}

	function radioQuery(selector) {
		const m = selector.match(/^input\[name='(\w+)'\](:checked)?$/);
		if (!m) throw new Error('unsupported selector ' + selector);
		return radios.filter((r) => r.name === m[1] && (!m[2] || r.checked));
	}

	const document = {
		readyState: 'complete',
		title: '',
		getElementById: (id) => elements.get(id) || null,
		createElement: (tag) => makeElement(tag, ''),
		querySelectorAll: radioQuery,
		querySelector: (selector) => radioQuery(selector)[0] || null,
		addEventListener() {}
	};
	const window = {
		webkit: {
			messageHandlers: {
				hsOnboarding: { postMessage: (m) => messages.push(JSON.parse(JSON.stringify(m))) }
			}
		}
	};
	const context = vm.createContext({ console, window, document });
	vm.runInContext(hostBridge, context);
	vm.runInContext(source, context);
	return {
		context,
		window,
		document,
		elements,
		messages,
		radios,
		click: (id) => elements.get(id).click(),
		chooseRadio(name, value) {
			radios
				.filter((r) => r.name === name)
				.forEach((r) => {
					r.checked = r.value === value;
				});
		}
	};
}

/**
 * Loads the page and performs the host's initData handshake.
 * @param {object} [extra] Extra initData fields.
 * @returns {ReturnType<typeof loadPage>}
 */
function openWizard(extra) {
	const page = loadPage();
	assert.deepEqual(page.messages.splice(0), [{ action: 'ready' }]);
	page.window.initData(
		Object.assign(
			{
				locale: 'en',
				strings: locale('en'),
				default_config_dir: '/Users/me/.config/ergopti_plus/',
				locales: [
					{ code: 'en', flag: '', name: 'English' },
					{ code: 'fr', flag: '', name: 'Français' }
				],
				answers: { locale: 'en', config_dir: '' },
				metrics_path: '/Users/me/.config/ergopti_plus/metrics',
				platform: 'macos'
			},
			extra || {}
		)
	);
	return page;
}

/**
 * Walks from the config step to the metrics step.
 * @param {ReturnType<typeof loadPage>} page
 */
function advanceToMetrics(page) {
	page.click('sc-next');
	page.click('s2-next');
	page.click('s3-next');
}

// ======================================
// ======= 2/ Window title ==============
// ======================================

(function titleFollowsTheSelectedLanguage() {
	const page = openWizard();
	assert.equal(
		page.document.title,
		locale('en')['onboarding.welcome.title'],
		'title at open uses the current locale'
	);

	const frRow = page.elements.get('lang-list').children.find((row) => row.dataset.code === 'fr');
	assert.ok(frRow, 'the injected locale list renders a French row');
	frRow.click();
	assert.deepEqual(page.messages.splice(0), [{ action: 'previewLocale', locale: 'fr' }]);
	page.window.applyStrings({ locale: 'fr', strings: locale('fr') });
	assert.equal(
		page.document.title,
		locale('fr')['onboarding.welcome.title'],
		'title follows the previewed locale'
	);
	assert.equal(page.elements.get('s1-title').textContent, locale('fr')['onboarding.welcome.title']);

	// A stale reply for a locale the user already left must not retitle the page.
	page.window.applyStrings({ locale: 'en', strings: locale('en') });
	assert.equal(
		page.document.title,
		locale('fr')['onboarding.welcome.title'],
		'stale locale replies are ignored'
	);

	// The title stays in step on later steps too.
	page.click('s1-next');
	page.window.applyStrings({ locale: 'fr', strings: locale('de') });
	assert.equal(page.document.title, locale('de')['onboarding.welcome.title']);
})();

(function everyLocaleNamesTheProductOnce() {
	const codes = fs
		.readdirSync(LOCALE_DIR)
		.filter((n) => n.endsWith('.json'))
		.map((n) => n.slice(0, -5));
	assert.equal(codes.length, 21, 'all 21 locales are checked');
	for (const code of codes) {
		const strings = locale(code);
		const heading = strings['onboarding.welcome.title'];
		const windowTitle = strings['onboarding.window_title'];
		assert.equal(
			occurrences(heading, PRODUCT),
			1,
			code + ': the page title names the product once'
		);
		assert.equal(typeof windowTitle, 'string', code + ': onboarding.window_title exists');
		assert.equal(
			occurrences(windowTitle, 'Ergopti'),
			0,
			code + ': the native title key is brand-less'
		);
		// Every host composes "<product> — <window_title>".
		assert.equal(occurrences(PRODUCT + ' — ' + windowTitle, PRODUCT), 1, code + ': composed title');
	}
	assert.equal(
		occurrences(html.match(/<title>([^<]*)<\/title>/)[1], PRODUCT),
		1,
		'static <title> names the product once'
	);
})();

// ======================================
// ======= 3/ Native folder picker ======
// ======================================

(function pickedFolderFillsTheFieldAndTheAnswers() {
	const page = openWizard();
	page.click('s1-next');
	const input = page.elements.get('sc-input');
	assert.equal(input.value, '', 'the field starts empty over the default');
	assert.equal(input.placeholder, '/Users/me/.config/ergopti_plus/');
	page.messages.splice(0);

	page.click('sc-browse');
	assert.deepEqual(page.messages.splice(0), [{ action: 'pickConfigDir', current: '' }]);

	page.window.setConfigDir('/Users/me/Ergopti Data/');
	assert.equal(
		input.value,
		'/Users/me/Ergopti Data/',
		'the chosen folder is written into the field'
	);

	// A locale switch re-renders the step from the answers, not from the DOM.
	page.window.applyStrings({ locale: 'en', strings: locale('en') });
	assert.equal(input.value, '/Users/me/Ergopti Data/', 'the chosen folder survives a re-render');

	advanceToMetrics(page);
	page.click('s4-next');
	page.messages.splice(0);
	page.click('s5-finish');
	const finish = page.messages.pop();
	assert.equal(finish.action, 'finish');
	assert.equal(
		finish.answers.config_dir,
		'/Users/me/Ergopti Data/',
		'the finish payload uses the chosen folder'
	);
})();

(function cancelledPickerLeavesTheFieldAlone() {
	const page = openWizard();
	page.click('s1-next');
	const input = page.elements.get('sc-input');
	input.value = '/typed/by/hand';
	page.window.setConfigDir('');
	page.window.setConfigDir(null);
	assert.equal(input.value, '/typed/by/hand');
})();

(function backFromLayoutKeepsThePickedFolder() {
	const page = openWizard();
	page.click('s1-next');
	page.window.setConfigDir('/picked/');
	page.click('sc-next');
	page.click('s2-back');
	assert.equal(page.elements.get('sc-input').value, '/picked/');
})();

// ======================================
// ======= 4/ Metrics consent path ======
// ======================================

(function consentNamesTheInitialStore() {
	const page = openWizard();
	page.click('s1-next');
	advanceToMetrics(page);
	const warning = page.elements.get('s4-warning').textContent;
	assert.ok(warning.includes('/Users/me/.config/ergopti_plus/metrics'), warning);
	assert.ok(!warning.includes('{1}'), 'the placeholder is filled');
})();

(function consentFollowsTheChosenFolder() {
	const page = openWizard();
	page.click('s1-next');
	page.window.setConfigDir('/Volumes/Data/Ergopti/');
	page.messages.splice(0);
	page.click('sc-next');
	const request = page.messages.find((m) => m.action === 'resolveMetricsPath');
	assert.deepEqual(request, {
		action: 'resolveMetricsPath',
		config_dir: '/Volumes/Data/Ergopti/',
		request: 1
	});
	page.window.setMetricsPath({ request: 1, path: '/Volumes/Data/Ergopti/metrics' });
	page.click('s2-next');
	page.click('s3-next');
	const warning = page.elements.get('s4-warning').textContent;
	assert.ok(warning.includes('/Volumes/Data/Ergopti/metrics'), warning);
	assert.ok(
		!warning.includes('/Users/me/.config/ergopti_plus/metrics'),
		'the default store is no longer named'
	);
})();

(function consentUpdatesWhenTheReplyArrivesOnStepFour() {
	const page = openWizard();
	page.click('s1-next');
	page.elements.get('sc-input').value = '/late/';
	advanceToMetrics(page);
	page.window.setMetricsPath({ request: 1, path: '/late/metrics' });
	assert.ok(
		page.elements.get('s4-warning').textContent.includes('/late/metrics'),
		'the visible step re-renders'
	);
})();

(function goingBackAndChangingTheFolderIsLive() {
	const page = openWizard();
	page.click('s1-next');
	page.window.setConfigDir('/first/');
	page.click('sc-next');
	page.window.setMetricsPath({ request: 1, path: '/first/metrics' });
	page.click('s2-back');
	page.window.setConfigDir('/second/');
	page.messages.splice(0);
	page.click('sc-next');
	assert.equal(page.messages.find((m) => m.action === 'resolveMetricsPath').request, 2);
	// The late reply for the first folder must not overwrite the second one.
	page.window.setMetricsPath({ request: 2, path: '/second/metrics' });
	page.window.setMetricsPath({ request: 1, path: '/first/metrics' });
	page.click('s2-next');
	page.click('s3-next');
	const warning = page.elements.get('s4-warning').textContent;
	assert.ok(warning.includes('/second/metrics'), warning);
	assert.ok(!warning.includes('/first/metrics'), 'a stale reply is dropped');
})();

(function consentFollowsALanguageSwitch() {
	const page = openWizard({ metrics_path: '/m' });
	page.click('s1-next');
	advanceToMetrics(page);
	page.window.applyStrings({ locale: 'en', strings: locale('fr') });
	const expected = locale('fr')['dialog.metrics.enable_warning'].split('{1}').join('/m');
	assert.equal(page.elements.get('s4-warning').textContent, expected);
})();

(function pathIsInsertedLiterally() {
	const page = openWizard({ metrics_path: "/odd/$&$'/metrics" });
	page.click('s1-next');
	advanceToMetrics(page);
	assert.ok(
		page.elements.get('s4-warning').textContent.includes("/odd/$&$'/metrics"),
		'no replacement patterns'
	);
})();

(function malformedRepliesAreIgnored() {
	const page = openWizard({ metrics_path: '/kept' });
	page.click('s1-next');
	page.click('sc-next');
	page.window.setMetricsPath(null);
	page.window.setMetricsPath({ request: 1 });
	page.window.setMetricsPath({ request: '1', path: '/wrong' });
	page.click('s2-next');
	page.click('s3-next');
	assert.ok(page.elements.get('s4-warning').textContent.includes('/kept'));
})();

console.log('Onboarding wizard page: title, folder picker and metrics consent path passed.');
