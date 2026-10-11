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

const controls = { decode: checkDecoding };
const requested = process.argv.slice(2);
const selected = requested.length ? requested : Object.keys(controls);
assert.ok(
	selected.length > 0 && selected.every((name) => Object.hasOwn(controls, name)),
	'only nonempty registered text controls may be selected'
);
for (const name of selected) controls[name]();
console.log(`PASS ${selected.length} web text controls: ${selected.join(', ')}.`);
