// tools/test/test-hotstring-editor-collapsed-sections.cjs

/**
 * Drives the real shared hotstring editor render in a VM. Every category of
 * the personal hotstring editor opens collapsed (maintainer request of
 * 2026-11-23); a fold click, a search, a new category and a new entry still
 * reveal rows, and a host data refresh keeps the user's fold choices.
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const SCRIPT = path.resolve(
	__dirname,
	'../../static/ergopti_plus/_shared/ui/hotstring_editor/script.js'
);
// The page loads the shared DOM helpers (escapeHtml) before its own script.
const DOM_UTILS = path.resolve(__dirname, '../../static/ergopti_plus/_shared/ui/dom_utils.js');
const EVENT_WIRING_MARKER = '// ======= 15/ Event Wiring';

const source = fs.readFileSync(SCRIPT, 'utf8');
const markerAt = source.indexOf(EVENT_WIRING_MARKER);
assert.ok(markerAt > 0, 'the editor script must retain a separable event-wiring section');
const modelSource = source.slice(0, markerAt);

/**
 * Builds a minimal element that records what the editor writes into it.
 * @returns {Object} The fake element.
 */
function element() {
	return {
		innerHTML: '',
		value: '',
		checked: false,
		style: {},
		textContent: '',
		classList: { add() {}, remove() {} },
		addEventListener() {},
		focus() {}
	};
}

/**
 * Loads the editor model with the given host data.
 * @param {Object} data - The initData() payload.
 * @returns {Object} The VM context and the sections container.
 */
function loadEditor(data) {
	const elements = {};
	const byId = (id) => {
		if (id === 'loading' || id === 'app' || id === 'search-clear' || id === 'secs-container')
			return (elements[id] ||= element());
		// Section cards and drag handles are only looked up to wire drag events.
		if (/^(sc|dh)-/.test(id)) return null;
		return (elements[id] ||= element());
	};
	const context = vm.createContext({
		console,
		document: { getElementById: byId, querySelectorAll: () => [] },
		makeHostBridge: () => () => {},
		setTimeout: () => 1,
		clearTimeout() {},
		__data: data
	});
	context.window = context;
	// Every label resolves to its key, as the hosts send the locale strings
	// before the data.
	context._i18n_strings = new Proxy({}, { get: (_, key) => String(key) });
	vm.runInContext(fs.readFileSync(DOM_UTILS, 'utf8'), context, { filename: DOM_UTILS });
	vm.runInContext(modelSource, context, { filename: SCRIPT });
	vm.runInContext(
		`
		buildCmdGrid = function () {};
		updateHints = function () {};
		updateCompactBtn = function () {};
		window.initData(JSON.parse(JSON.stringify(__data)));
		`,
		context,
		{ filename: 'collapsed-sections-harness.js' }
	);
	return { context, container: elements['secs-container'] };
}

/**
 * Counts the rendered entry rows of one section card.
 * @param {string} html - The rendered sections markup.
 * @param {number} si - The section index.
 * @returns {number} The number of entry rows in that card.
 */
function rowsIn(html, si) {
	const start = html.indexOf('id="sc-' + si + '"');
	assert.ok(start >= 0, 'section ' + si + ' must be rendered');
	const next = html.indexOf('<li class="sec-card"', start);
	const card = html.slice(start, next < 0 ? html.length : next);
	return card.split('class="entry-row"').length - 1;
}

const entry = (trigger, output) => ({ trigger, output });
const DATA = {
	trigger_char: '★',
	star: '★',
	compact_view: false,
	auto_close: false,
	open_mode: 'menu',
	sections: [
		{
			name: 'signatures',
			description: 'Signatures',
			entries: [entry('sig★', 'Cordialement'), entry('np★', 'Camille Martin')]
		},
		{ name: 'code', description: 'Code', entries: [entry('cl★', 'console.log();')] }
	]
};

let passed = 0;
function test(name, callback) {
	callback();
	passed++;
	console.log(`  ✓  ${name}`);
}

console.log('\n=== Hotstring Editor Collapsed Categories ===');

test('every category opens collapsed', () => {
	const { container } = loadEditor(DATA);
	const html = container.innerHTML;
	assert.equal(rowsIn(html, 0), 0);
	assert.equal(rowsIn(html, 1), 0);
	assert.equal(html.split('aria-expanded="true"').length - 1, 0);
	assert.equal(html.split('aria-expanded="false"').length - 1, 2);
});

test('the fold button opens one category, then closes it again', () => {
	const { context, container } = loadEditor(DATA);
	vm.runInContext('togSec(0)', context);
	assert.equal(rowsIn(container.innerHTML, 0), 2);
	assert.equal(rowsIn(container.innerHTML, 1), 0);
	vm.runInContext('togSec(0)', context);
	assert.equal(rowsIn(container.innerHTML, 0), 0);
});

test('a search still reveals matches in collapsed categories', () => {
	const { context, container } = loadEditor(DATA);
	vm.runInContext("window.onSearch('cl')", context);
	assert.equal(rowsIn(container.innerHTML, 1), 1);
	vm.runInContext('window.clearSearch()', context);
	assert.equal(rowsIn(container.innerHTML, 1), 0, 'clearing the search folds back');
});

test('a host data refresh keeps the categories the user opened', () => {
	const { context, container } = loadEditor(DATA);
	vm.runInContext('togSec(1)', context);
	context.__data = DATA;
	vm.runInContext('window.updateData(JSON.parse(JSON.stringify(__data)))', context);
	assert.equal(rowsIn(container.innerHTML, 0), 0);
	assert.equal(rowsIn(container.innerHTML, 1), 1);
});

test('adding an entry opens its category so the new row is visible', () => {
	const { context, container } = loadEditor(DATA);
	vm.runInContext(
		`
		clearEntryErrors = function () {};
		serializeTrigEditor = function () { return 'new★'; };
		serializeEditor = function () { return 'new output'; };
		parsePrio = function () { return null; };
		closeModal = function () {};
		toLua = function () {};
		edEntry = { si: 1, ei: null };
		saveEntry(false);
		`,
		context
	);
	assert.equal(rowsIn(container.innerHTML, 0), 0);
	assert.equal(rowsIn(container.innerHTML, 1), 2);
});

console.log(`\n${passed} passed`);
