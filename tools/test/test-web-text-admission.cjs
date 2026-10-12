// tools/test/test-web-text-admission.cjs

/** Execute the web text owners against escapes, rejected lines and literal DOM input. */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.resolve(__dirname, '../..');
const keyboard = fs.readFileSync(path.join(root, 'src/lib/keyboard/KeyboardEmulation.js'), 'utf8');
const start = keyboard.indexOf('function unescapeTomlString(');
const end = keyboard.indexOf('\nif (typeof window', start);
assert.ok(start >= 0 && end > start, 'the actual TOML decoding and parsing owners are present');
const context = vm.createContext({});
vm.runInContext(keyboard.slice(start, end), context);

function checkDecoding() {
	for (const [source, expected] of [
		[String.raw`\\n`, String.raw`\n`],
		[String.raw`\\r`, String.raw`\r`],
		[String.raw`\\t`, String.raw`\t`],
		[String.raw`\\"`, '\\"'],
		[String.raw`\\'`, "\\'"],
		[String.raw`\n\r\t\"\'\\`, '\n\n\t"\'\\'],
		[String.raw`unknown\q`, String.raw`unknown\q`],
		['a\r\nb\rc', 'a\nb\nc'],
		['', '']
	]) {
		assert.equal(
			context.unescapeTomlString(source),
			expected,
			`decode source exactly once: ${JSON.stringify(source)}`
		);
	}
	assert.equal(context.unescapeTomlString(undefined), undefined);
	assert.equal(context.unescapeTomlString(null), null);
	const parsed = context.parseTomlMagic(String.raw`literal = "\\n"
"object" = { output = "a\"b\\c", label = "kept" }
[[repeat]]
ignored = "repeat"
[other]
accepted = "yes"`);
	assert.equal(parsed.literal, String.raw`\n`);
	assert.equal(parsed.object, 'a"b\\c');
	assert.equal(parsed.ignored, undefined);
	assert.equal(parsed.accepted, 'yes');
}

function checkQuotedParsing(line) {
	context.input = line;
	const refused = vm.runInContext('parseTomlMagic(input)', context, {
		timeout: 1000
	});
	assert.equal(
		Object.keys(refused).length,
		0,
		'unterminated quoted input is refused within a finite parser budget'
	);
}

function checkLiteralDemo() {
	const listeners = new Map();
	const drive = { style: {}, textContent: '\u00a0' };
	let markupWrites = 0;
	Object.defineProperty(drive, 'innerHTML', {
		set() {
			markupWrites += 1;
		}
	});
	const text = {
		value: '',
		addEventListener(event, callback) {
			listeners.set(event, callback);
		}
	};
	const font = {
		value: '48',
		addEventListener(event, callback) {
			listeners.set(`font:${event}`, callback);
		}
	};
	const ligatures = [];
	const demo = fs.readFileSync(path.join(root, 'src/lib/icons/icomoon/demo-files/demo.js'), 'utf8');
	vm.runInNewContext(demo, {
		document: {
			body: { style: { boxShadow: '' }, addEventListener() {} },
			getElementById(id) {
				return { fontSize: font, testDrive: drive, testText: text }[id];
			}
		},
		window: {
			icomoonLiga(element) {
				ligatures.push(element.textContent);
			}
		}
	});
	assert.equal(drive.style.fontSize, '48px');
	for (const event of ['input', 'change']) {
		text.value = '<img src=x onerror="throw new Error(1)"> & ligature';
		listeners.get(event)();
		assert.equal(markupWrites, 0, 'demo input never enters HTML parsing');
		assert.equal(drive.textContent, text.value, 'markup and ampersands remain literal demo text');
		assert.equal(ligatures.at(-1), text.value, 'the existing ligature hook observes literal text');
	}
	text.value = '';
	listeners.get('input')();
	assert.equal(drive.textContent, '\u00a0', 'the empty sample retains its nonbreaking-space glyph');
	font.value = '64';
	listeners.get('font:change')();
	assert.equal(drive.style.fontSize, '64px');
}

const controls = {
	decode: checkDecoding,
	simple: () => checkQuotedParsing(`plain = "${'\\!'.repeat(65536)}`),
	object: () => checkQuotedParsing(`"object" = { output = "${'\\!'.repeat(65536)} }`),
	dom: checkLiteralDemo
};
const requested = process.argv.slice(2);
const selected = requested.length ? requested : Object.keys(controls);
assert.ok(
	selected.length > 0 && selected.every((name) => Object.hasOwn(controls, name)),
	'only nonempty registered text controls may be selected'
);
for (const name of selected) controls[name]();
console.log(`PASS ${selected.length} web text controls: ${selected.join(', ')}.`);
