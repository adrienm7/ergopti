// tools/test/test-hotstring-editor-strict-case.cjs

/**
 * Drives the real shared editor model and persistence functions in a VM. The
 * « Sensible à la casse » box owns the strict-case flag: checked is an exact
 * match, unchecked is not, for a new entry and an edited one alike.
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
		focus() {}
	};
}

function runModel(seed, editIndex, caseChecked = true, identityMode = false) {
	const fields = {
		'e-trig': element(editIndex === null ? 'New' : 'Case'),
		'e-out': element(editIndex === null ? 'new output' : 'edited output'),
		'cb-word': element(),
		'cb-auto': element(),
		'cb-case': element(),
		'cb-final': element(),
		'e-prio': element(''),
		'save-toast': element()
	};
	fields['cb-case'].checked = caseChecked;

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
		__identityMode: identityMode,
		__payloads: []
	});
	context.window = context;

	vm.runInContext(modelSource, context, { filename: SCRIPT });
	vm.runInContext(
		`
		D = JSON.parse(JSON.stringify(__seed));
		edEntry = { si: 0, ei: __editIndex };
		rowIdentityMode = __identityMode;
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
	const result = runModel(
		{
			sections: [
				{
					name: 'strict',
					description: 'Strict',
					entries: [
						{
							trigger: 'Case',
							output: 'exact',
							is_case_sensitive: true,
							is_case_sensitive_strict: true
						}
					]
				}
			]
		},
		undefined
	);
	assert.strictEqual(result.payload.sections.strict.entries[0].is_case_sensitive_strict, true);
});

test('editing with the case box checked keeps the entry strict', () => {
	const result = runModel(
		{
			sections: [
				{
					name: 'strict',
					description: 'Strict',
					entries: [
						{
							trigger: 'Case',
							output: 'exact',
							is_case_sensitive: true,
							is_case_sensitive_strict: true
						}
					]
				}
			]
		},
		0
	);
	assert.strictEqual(result.entry.is_case_sensitive_strict, true);
	assert.strictEqual(result.payload.sections.strict.entries[0].is_case_sensitive_strict, true);
});

test('a new entry with the case box checked matches its exact case', () => {
	const result = runModel(
		{
			sections: [{ name: 'strict', description: 'Strict', entries: [] }]
		},
		null
	);
	assert.strictEqual(result.entry.is_case_sensitive_strict, true);
	assert.strictEqual(result.payload.sections.strict.entries[0].is_case_sensitive_strict, true);
});

test('unchecking the case box clears an existing strict entry', () => {
	const result = runModel(
		{
			sections: [
				{
					name: 'strict',
					description: 'Strict',
					entries: [
						{
							trigger: 'Case',
							output: 'exact',
							is_case_sensitive: true,
							is_case_sensitive_strict: true
						}
					]
				}
			]
		},
		0,
		false
	);
	assert.strictEqual(result.entry.is_case_sensitive_strict, false);
});

test('saved trigger ordering keeps Unicode letters and digits', () => {
	const result = runModel(
		{
			sections: [
				{
					name: 'strict',
					description: 'Strict',
					entries: [
						{ trigger: 'éclair', output: 'one' },
						{ trigger: '漢字', output: 'two' }
					]
				}
			]
		},
		null
	);
	assert.deepStrictEqual(
		Array.from(result.payload.sections.strict.entries, (entry) => entry.trigger),
		['New', 'éclair', '漢字']
	);
});

test('ASCII keys keep their old order and equivalent Unicode stays unchanged', () => {
	const original = ['!Zoo', 'e\u0301clair', 'éclair', 'a-b', 'Ab', '_bar'];
	const result = runModel(
		{
			sections: [
				{
					name: 'strict',
					description: 'Strict',
					entries: original.map((trigger) => ({ trigger, output: 'value' }))
				}
			]
		},
		null
	);
	assert.deepStrictEqual(
		Array.from(result.payload.sections.strict.entries, (entry) => entry.trigger),
		['_bar', 'a-b', 'Ab', 'New', '!Zoo', 'e\u0301clair', 'éclair']
	);
});

test('moving entries sorts Unicode triggers without stripping their letters', () => {
	const selector = { value: '1' };
	const context = vm.createContext({
		console,
		document: {
			getElementById: () => selector,
			querySelectorAll: () => [{ dataset: { si: '0', ei: '0' } }]
		},
		makeHostBridge: () => function () {},
		setTimeout: () => 1,
		clearTimeout() {}
	});
	context.window = context;
	vm.runInContext(modelSource, context, { filename: SCRIPT });
	vm.runInContext(
		`
		D = { sections: [
			{ name: 'from', entries: [{trigger: 'New', output: 'n'}] },
			{ name: 'to', entries: [{trigger: 'éclair', output: 'e'}, {trigger: '漢字', output: 'h'}] }
		] };
		window.clearBulk = function () {};
		persist = function () {};
		window.bulkMove();
		__result = D.sections[1].entries.map((entry) => entry.trigger);
	`,
		context
	);
	assert.deepStrictEqual(Array.from(context.__result), ['New', 'éclair', '漢字']);
});

test('opening and saving output retains explicit trailing Enter tokens', () => {
	function node(tag) {
		return {
			nodeType: 1,
			tagName: tag.toUpperCase(),
			dataset: {},
			classList: { contains: () => false },
			textContent: ''
		};
	}
	const context = vm.createContext({
		console,
		document: {
			createElement: node,
			createTextNode: (text) => ({ nodeType: 3, textContent: text })
		},
		makeHostBridge: () => function () {},
		setTimeout: () => 1,
		clearTimeout() {}
	});
	context.window = context;
	vm.runInContext(modelSource, context, { filename: SCRIPT });
	context.original = 'Café\t"漢字"\r\nline{Enter}{Enter}';
	vm.runInContext('result = serializeEditor({childNodes: parseToNodes(original)})', context);
	assert.strictEqual(context.result, context.original);
	vm.runInContext(
		"result = serializeEditor({childNodes: [...parseToNodes(original), document.createElement('br')]})",
		context
	);
	assert.strictEqual(
		context.result,
		context.original,
		'a trailing browser placeholder is still discarded'
	);
	const editor = {
		childNodes: [],
		focus() {},
		appendChild(child) {
			this.childNodes.push(child);
		}
	};
	context.document.getElementById = () => editor;
	context.getSelection = () => null;
	vm.runInContext(
		'checkPh = function () {}; insertBrAtCursor(); result = serializeEditor(document.getElementById("e-out"))',
		context
	);
	assert.strictEqual(context.result, '{Enter}', 'a new Enter at the end is explicit');
});

test('legacy hosts never receive Linux row identities, including unedited rows', () => {
	const seed = {
		sections: [
			{
				name: 'strict',
				description: 'Strict',
				entries: [
					{ trigger: 'Case', output: 'old', origin_id: 'row:7' },
					{ trigger: 'Other', output: 'other', origin_id: 'row:8' }
				]
			}
		]
	};
	for (const editIndex of [undefined, 0, null]) {
		const result = runModel(seed, editIndex, true, false);
		for (const row of result.payload.sections.strict.entries) {
			assert.strictEqual(Object.hasOwn(row, 'origin_id'), false);
		}
	}
});

test('editing retains the snapshot identity, while new rows receive their own identity', () => {
	const seed = {
		sections: [
			{
				name: 'strict',
				description: 'Strict',
				entries: [{ trigger: 'Case', output: 'old', origin_id: 'row:7' }]
			}
		]
	};
	const edited = runModel(seed, 0, true, true);
	assert.strictEqual(edited.payload.sections.strict.entries[0].origin_id, 'row:7');
	const created = runModel(seed, null, true, true);
	assert.strictEqual(
		created.payload.sections.strict.entries.find((entry) => entry.trigger === 'New').origin_id,
		'new:1'
	);
});

test('rendered token text escapes entities exactly once', () => {
	const context = vm.createContext({
		console,
		document: {},
		makeHostBridge: () => function () {},
		setTimeout() {},
		clearTimeout() {}
	});
	context.window = context;
	vm.runInContext(
		fs.readFileSync(path.join(ROOT, 'static/ergopti_plus/_shared/ui/dom_utils.js'), 'utf8'),
		context
	);
	vm.runInContext(modelSource, context, { filename: SCRIPT });
	const rendered = context.dispOutput('before {a&b} and {x<😀} after');
	assert.match(rendered, /data-tok="a&amp;b">a&amp;b<\/span>/);
	assert.match(rendered, /data-tok="x&lt;😀">x&lt;😀<\/span>/);
	assert.doesNotMatch(rendered, /&amp;amp;|&amp;lt;/);
});

test('editing literal brace content preserves its spelling and symbols', () => {
	const context = vm.createContext({
		console,
		document: {
			createTextNode: (text) => ({ nodeType: 3, textContent: text }),
			createElement: (tag) => {
				const node = {
					nodeType: 1,
					tagName: tag.toUpperCase(),
					dataset: {},
					className: '',
					textContent: ''
				};
				node.classList = { contains: (name) => node.className.split(' ').includes(name) };
				return node;
			}
		},
		makeHostBridge: () => function () {},
		setTimeout() {},
		clearTimeout() {}
	});
	context.window = context;
	vm.runInContext(modelSource, context, { filename: SCRIPT });
	context.original = 'x {a&b} {x<😀} {foo}';
	vm.runInContext('result = serializeEditor({childNodes: parseToNodes(original)})', context);
	assert.equal(context.result, context.original);
});

console.log(`\nResults: ${passed} passed, 0 failed.`);
