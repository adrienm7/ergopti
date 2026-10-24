// tools/test/test-hex-colours.cjs

/**
 * ==============================================================================
 * MODULE: Hex Colour Scanner Guard
 * DESCRIPTION:
 * Pins what `tools/lint/hex-colours.cjs` counts as a colour literal, and that
 * its census reads the real driver tree.
 *
 * ROOT CAUSE ENCODED:
 * The parity audit counted the colours with a one-off grep that no later step
 * could rerun, so "810 literals" could neither be confirmed nor driven down.
 * A scanner that counted comments, issue numbers or HTML entities would make
 * every later number meaningless, and one that read an empty tree would report
 * a clean theme while measuring nothing.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const hex = require('../lint/hex-colours.cjs');

const ROOT = path.resolve(__dirname, '..', '..');

/** The lower-cased literal values one text yields. */
function values(text, extension) {
	return hex.scanText(text, extension).map((found) => found.value);
}

// 1. CSS: three, six and eight digits count; comments, selectors and longer
//    runs (an issue number) do not.
assert.deepEqual(
	values(
		'a { color: #FFF; border: 1px solid #1E88E5; }\n' +
			'/* was #123456 */\n' +
			'#add-button { background: #11223344; }\n' +
			'b { content: "#1234"; }\n',
		'.css'
	),
	['#fff', '#1e88e5', '#11223344']
);

// 2. HTML: an entity is not a colour, and a commented-out style is not either.
assert.deepEqual(
	values('<p>it&#039;s</p><!-- #ff0000 --><b style="color:#0a84ff">x</b>', '.html'),
	['#0a84ff']
);

// 3. JavaScript: a line comment is dropped, a URL is kept as code.
assert.deepEqual(
	values("const a = '#1e88e5'; // #ff0000\nconst u = 'https://x.test/a'; const b = '#000';", '.js'),
	['#1e88e5', '#000']
);

// 4. Lua: line and long comments are dropped.
assert.deepEqual(
	values('local c = "#e53935" -- #000000\n--[[ #111111\n]] local d = "#43a047"', '.lua'),
	['#e53935', '#43a047']
);

// 5. AutoHotkey: a `;` comment is dropped, a `;` inside code is not a comment.
assert.deepEqual(values('Hex := "#AD61FF" ; #000000\nX := "a;b"\n/* #222222 */', '.ahk'), [
	'#ad61ff'
]);

// 6. TOML, Python and shell open comments with `#`: only quoted literals count.
assert.deepEqual(values('color = "#1e88e5" # was #ff0000\n# #00ff00\n', '.toml'), ['#1e88e5']);

// 7. Line numbers survive a removed multi-line comment.
assert.deepEqual(
	hex.scanText('/* one\ntwo\nthree */\nx { color: #abc; }', '.css').map((found) => found.line),
	[4]
);

// 8. A language without a rule is refused rather than silently skipped.
assert.throws(() => hex.scanText('#fff', '.md'), /no scanning rule/);

// 9. The census reads the real tree: the shared pages are in it, tests are not,
//    and the --accent survey finds stylesheets to survey.
const files = hex.scannedFiles(ROOT);
assert.ok(files.length > 100, `the scan covers ${files.length} file(s); the scan path is stale`);
assert.ok(
	files.some((file) => file.startsWith(`${hex.DRIVERS_REL}/_shared/ui/`) && file.endsWith('.css')),
	'the shared stylesheets are scanned'
);
assert.ok(
	!files.some((file) => /(^|\/)tests?\//.test(file)),
	'test fixtures are not part of the census'
);
const result = hex.census(ROOT);
assert.ok(result.gate.literals > 0 && result.audit.literals > 0, 'the census measured nothing');
assert.match(hex.formatCensus(result), /--accent declarations: \d+/);

console.log(
	`[OK] hex colour scanner: ${result.gate.literals} literal(s) in ${result.gate.files} of ` +
		`${result.scannedFiles} source file(s).`
);
