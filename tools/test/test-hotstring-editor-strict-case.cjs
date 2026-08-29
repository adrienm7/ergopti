// tools/test/test-hotstring-editor-strict-case.cjs

/**
 * Drives the real shared editor model and persistence functions in a VM. The
 * strict-case flag has no visible control, so editing an existing entry must
 * preserve its hidden true value while a new entry starts false.
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

function element(value = '') {
	return {
		value,
		checked: false,
		classList: { add() {}, remove() {} },
		focus() {},
	};
}

function runModel(seed, editIndex) {
	const fields = {
		'e-trig': element(editIndex === null ? 'New' : 'Case'),
		'e-out': element(editIndex === null ? 'new output' : 'edited output'),
		'cb-word': element(),
		'cb-auto': element(),
		'cb-case': element(),
		'cb-final': element(),
		'e-prio': element(''),
		'save-toast': element(),
	};
	fields['cb-case'].checked = true;

	const context = vm.createContext({
		console,
		document: { getElementById: (id) => fields[id] || element() },
		makeHostBridge: () => function () {},
		setTimeout: (callback) => {
			callback();
			return 1;
		},
		clearTimeout() {},
		__seed: seed,
		__editIndex: editIndex,
		__payloads: [],
	});
	context.window = context;

	vm.runInContext(modelSource, context, { filename: SCRIPT });
	vm.runInContext(
		`
		D = JSON.parse(JSON.stringify(__seed));
		edEntry = { si: 0, ei: __editIndex };
		clearEntryErrors = function () {};
		serializeTrigEditor = function (el) { return el.value; };
		serializeEditor = function (el) { return el.value; };
		parsePrio = function () { return null; };
		closeModal = function () {};
		render = function () {};
		toLua = function (action, payload) {
			if (action === 'save') __payloads.push(payload);
		};
		if (__editIndex === undefined) persist();
		else saveEntry(false);
		__result = {
			entry: D.sections[0].entries[__editIndex === null ? 0 : __editIndex],
			payload: __payloads[0]
		};
		`,
		context,
		{ filename: 'strict-case-harness.js' }
	);
	return context.__result;
}

let passed = 0;
function test(name, callback) {
	callback();
	passed++;
	console.log(`  ✓  ${name}`);
}

console.log('\n=== Hotstring Editor Strict-Case Preservation ===');

test('persist carries strict-case state to every host bridge', () => {
	const result = runModel({
		sections: [{
			name: 'strict',
			description: 'Strict',
			entries: [{
				trigger: 'Case',
				output: 'exact',
				is_case_sensitive: true,
				is_case_sensitive_strict: true,
			}],
		}],
	}, undefined);
	assert.strictEqual(result.payload.sections.strict.entries[0].is_case_sensitive_strict, true);
});

test('editing preserves a hidden strict-case value', () => {
	const result = runModel({
		sections: [{
			name: 'strict',
			description: 'Strict',
			entries: [{
				trigger: 'Case',
				output: 'exact',
				is_case_sensitive: true,
				is_case_sensitive_strict: true,
			}],
		}],
	}, 0);
	assert.strictEqual(result.entry.is_case_sensitive_strict, true);
	assert.strictEqual(result.payload.sections.strict.entries[0].is_case_sensitive_strict, true);
});

test('a newly created entry starts with strict case disabled', () => {
	const result = runModel({
		sections: [{ name: 'strict', description: 'Strict', entries: [] }],
	}, null);
	assert.strictEqual(result.entry.is_case_sensitive_strict, false);
	assert.strictEqual(result.payload.sections.strict.entries[0].is_case_sensitive_strict, false);
});

console.log(`\nResults: ${passed} passed, 0 failed.`);
