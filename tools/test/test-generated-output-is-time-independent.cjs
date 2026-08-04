// tools/test/test-generated-output-is-time-independent.cjs

/**
 * ==============================================================================
 * MODULE: Generated Output Must Not Depend on the Calendar
 * DESCRIPTION:
 * A generator whose output embeds the current date makes its file a function of
 * WHEN it ran rather than of what it read. The drift gate compares committed
 * output against freshly generated output, so such a file drifts every day the
 * repository is not regenerated — for a reason that says nothing about the thing
 * being generated.
 *
 * WHAT IT ACTUALLY COSTS, which is more than a spurious diff:
 * `gen-architecture-diagram.cjs` stamped `Generated on <today>` into
 * architecture.md. The drift check failed on 2026-08-04 with a one-line diff: the
 * date. Every previous day it failed the same way, and every time the fix was to
 * re-run the generator and commit — which trains the reader to clear a drift
 * failure without reading it. The next time drift fires because a port spec
 * changed and an adapter did not, it gets the same reflex.
 *
 * The information was not even accurate: the stamp recorded when the GENERATOR
 * ran, not when the output last changed. `git log -1 <file>` answers the real
 * question and answers it correctly.
 *
 * WHAT THIS HOLDS:
 * no generator writes today's date into its output. The check is on the
 * generators rather than on their products, because a product can be committed
 * with yesterday's stamp and look clean while the generator is still stamping.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const CODEGEN = path.join(ROOT, 'tools', 'codegen');
const BUILD = path.join(ROOT, 'tools', 'build');

// Ways a generator reaches for "now". A generator may legitimately READ a date
// out of its inputs; what it may not do is ask the clock.
const CLOCK_CALLS = [
	{ pattern: /new Date\(\s*\)/, why: 'new Date() with no argument is the current time' },
	{ pattern: /Date\.now\(\s*\)/, why: 'Date.now() is the current time' },
	{ pattern: /\btoLocaleDateString\(/, why: 'formats a date for output' }
];

// Generators allowed to read the clock, each with the reason. A generator that
// stamps a date into something the drift gate does NOT compare is harmless; one
// that stamps into a tracked, generated file is what this exists to stop. The
// list may only shrink.
const ALLOWED = {};

// Floor: a scan that walks no generators would report nothing and pass.
const MIN_GENERATORS = 10;

const errors = [];

/** Every .cjs/.js generator under tools/codegen and tools/build. */
function generators() {
	const out = [];
	for (const dir of [CODEGEN, BUILD]) {
		if (!fs.existsSync(dir)) continue;
		for (const entry of fs.readdirSync(dir)) {
			if (/\.(cjs|js)$/.test(entry)) out.push(path.join(dir, entry));
		}
	}
	return out;
}

const files = generators();
if (files.length < MIN_GENERATORS) {
	errors.push(
		`found ${files.length} generator(s) (floor ${MIN_GENERATORS}) — the walk is broken and this ` +
			'gate is reading nothing'
	);
}

for (const file of files) {
	const rel = path.relative(ROOT, file).split(path.sep).join('/');
	const name = path.basename(file);
	// Comment lines do not count: a generator may explain why it does NOT stamp.
	const code = fs
		.readFileSync(file, 'utf8')
		.split(/\r?\n/)
		.filter((l) => !/^\s*(\/\/|\*|\/\*)/.test(l))
		.join('\n');

	for (const { pattern, why } of CLOCK_CALLS) {
		if (!pattern.test(code)) continue;
		if (ALLOWED[name]) continue;
		errors.push(
			`${rel} reads the clock (${why}). A generated file that carries today's date is a ` +
				'function of WHEN it ran rather than of what it read, so the drift gate fails on every ' +
				'day the repository was not regenerated — and a gate that cries wolf daily is one people ' +
				'learn to clear without reading. Use `git log -1 <output>` for the date instead: it is ' +
				'both accurate and free.'
		);
	}
}

for (const name of Object.keys(ALLOWED)) {
	if (!files.some((f) => path.basename(f) === name)) {
		errors.push(`the clock exemption for "${name}" names a generator that no longer exists — remove it`);
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] generated output depends on the calendar:\x1b[0m');
	for (const e of errors) console.error(`  - ${e}`);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] none of the ${files.length} generator(s) stamps the current date into its output ` +
		`(${Object.keys(ALLOWED).length} recorded exemption(s)).\x1b[0m`
);
