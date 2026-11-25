// tools/test/test-hotstring-editor-action-entry.cjs

/**
 * Drives the real shared editor model in a VM. An entry can run an action or
 * one of the user's workflows: the picker writes action/workflow, the
 * « effacer le déclencheur » box writes erase_trigger only when unchecked (the
 * default erases), an action entry may type nothing, and a stored action this
 * OS does not offer survives an edit instead of being dropped.
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ROOT = path.resolve(__dirname, '../..');
const SCRIPT = path.join(ROOT, 'static/ergopti_plus/_shared/ui/hotstring_editor/script.js');
const EVENT_WIRING_MARKER = '// ======= 15/ Event Wiring';

const source = fs.readFileSync(SCRIPT, 'utf8');
const markerAt = source.indexOf(EVENT_WIRING_MARKER);
assert(markerAt > 0, 'the editor script must retain a separable event-wiring section');
const modelSource = source.slice(0, markerAt);

/**
 * A minimal element; a select keeps its options so a value can only be set
 * to an existing one, as in a browser.
 * @param {string} value
 * @returns {object}
 */
function element(value = '') {
	const el = {
		_value: value,
		checked: false,
		hidden: false,
		textContent: '',
		options: [],
		classList: { add() {}, remove() {} },
		focus() {},
		appendChild(child) {
			this.options.push(child);
			return child;
		}
	};
	Object.defineProperty(el, 'value', {
		get() {
			return this._value;
		},
		set(next) {
			const isSelect = this.isSelect;
			this._value =
				!isSelect || next === '' || this.options.some((o) => o.value === next) ? next : '';
		}
	});
	return el;
}

function runModel({ seed, editIndex, picker, eraseChecked, output, body }) {
	const fields = {
		'e-trig': element(editIndex == null ? 'New' : seed.sections[0].entries[editIndex].trigger),
		'e-out': element(output),
		'e-action': element(),
		'cb-erase': element(),
		'action-box': element(),
		'cb-word': element(),
		'cb-auto': element(),
		'cb-case': element(),
		'cb-final': element(),
		'e-prio': element(''),
		'save-toast': element()
	};
	fields['e-action'].isSelect = true;
	fields['e-action'].options.push({ value: '' }, { value: 'w:wf_1' }, { value: 'a:select_all' });
	fields['e-action'].value = picker;
	fields['cb-erase'].checked = eraseChecked;

	const context = vm.createContext({
		console,
		document: {
			getElementById: (id) => fields[id] || element(),
			createElement: () => element()
		},
		makeHostBridge: () => function () {},
		setTimeout: (callback) => {
			callback();
			return 1;
		},
		clearTimeout() {},
		__seed: seed,
		__editIndex: editIndex,
		__payloads: [],
		__fields: fields
	});
	context.window = context;
	vm.runInContext(modelSource, context, { filename: SCRIPT });
	vm.runInContext(
		`
		D = JSON.parse(JSON.stringify(__seed));
		edEntry = { si: 0, ei: __editIndex };
		clearEntryErrors = function () {};
		showFieldError = function (_id, message) { __error = message; };
		serializeTrigEditor = function (el) { return el.value; };
		serializeEditor = function (el) { return el.value; };
		parsePrio = function () { return null; };
		closeModal = function () {};
		render = function () {};
		toLua = function (action, payload) {
			if (action === 'save') __payloads.push(payload);
		};
		${body}
		`,
		context,
		{ filename: 'action-entry-harness.js' }
	);
	return context;
}

const EMPTY = { sections: [{ name: 'mine', description: 'Mine', entries: [] }] };

let passed = 0;
function test(name, callback) {
	callback();
	passed++;
	console.log(`  ✓  ${name}`);
}

console.log('\n=== Hotstring Editor Action Entries ===');

test('a workflow entry with the erase box unchecked stores erase_trigger = false', () => {
	const ctx = runModel({
		seed: EMPTY,
		editIndex: null,
		picker: 'w:wf_1',
		eraseChecked: false,
		output: '',
		body: 'saveEntry(false);'
	});
	const entry = ctx.__payloads[0].sections.mine.entries[0];
	assert.strictEqual(entry.action, 'run_workflow');
	assert.strictEqual(entry.workflow, 'wf_1');
	assert.strictEqual(entry.erase_trigger, false);
	assert.strictEqual(entry.output, '');
});

test('the default (box checked) writes no erase_trigger field', () => {
	const ctx = runModel({
		seed: EMPTY,
		editIndex: null,
		picker: 'a:select_all',
		eraseChecked: true,
		output: 'x',
		body: 'saveEntry(false);'
	});
	const entry = ctx.__payloads[0].sections.mine.entries[0];
	assert.strictEqual(entry.action, 'select_all');
	assert.strictEqual(entry.workflow, undefined);
	assert.strictEqual('erase_trigger' in entry, false);
});

test('a text entry still requires an output', () => {
	const ctx = runModel({
		seed: EMPTY,
		editIndex: null,
		picker: '',
		eraseChecked: true,
		output: '',
		body: 'saveEntry(false);'
	});
	assert.strictEqual(ctx.__payloads.length, 0, 'an empty text entry must not be saved');
});

test('editing an entry whose action this OS does not offer keeps it', () => {
	const seed = {
		sections: [
			{
				name: 'mine',
				description: 'Mine',
				entries: [{ trigger: 'zz', output: '', action: 'mac_only_action', erase_trigger: false }]
			}
		]
	};
	const ctx = runModel({
		seed,
		editIndex: 0,
		picker: '',
		eraseChecked: true,
		output: '',
		body: `
		selectActionValue(actionValueOf(D.sections[0].entries[0]));
		__fields['cb-erase'].checked = false;
		saveEntry(false);
		`
	});
	const entry = ctx.__payloads[0].sections.mine.entries[0];
	assert.strictEqual(entry.action, 'mac_only_action');
	assert.strictEqual(entry.erase_trigger, false);
	assert.strictEqual(ctx.__fields['action-box'].hidden, false, 'the picker shows a stored action');
});

test('persist carries the action fields of untouched entries', () => {
	const seed = {
		sections: [
			{
				name: 'mine',
				description: 'Mine',
				entries: [
					{
						trigger: 'wf',
						output: '',
						action: 'run_workflow',
						workflow: 'wf_1',
						erase_trigger: false
					}
				]
			}
		]
	};
	const ctx = runModel({
		seed,
		editIndex: undefined,
		picker: '',
		eraseChecked: true,
		output: '',
		body: 'persist();'
	});
	const entry = ctx.__payloads[0].sections.mine.entries[0];
	assert.deepStrictEqual(
		{ action: entry.action, workflow: entry.workflow, erase_trigger: entry.erase_trigger },
		{ action: 'run_workflow', workflow: 'wf_1', erase_trigger: false }
	);
});

console.log(`\nResults: ${passed} passed, 0 failed.`);
