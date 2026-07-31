// tools/build/gen-all.cjs

/**
 * ==============================================================================
 * MODULE: Run Every Generator
 * DESCRIPTION:
 * `npm run gen` — regenerates every generated file in the repo, in one command,
 * in a declared order.
 *
 * WHY:
 * There were twelve generators behind eleven npm scripts, and knowing which ones
 * a given change required was folklore. `npm run codegen` ran exactly one of
 * them (build:domain), which covers most but not all: the metrics category
 * aliases, the port contracts, the logger sub-file tables, the locale tables and
 * the architecture diagram were all outside it. A contributor who ran the
 * documented command and committed would still ship a stale file, and only the
 * drift gate would catch it — after the fact, in CI.
 *
 * The registry in generators.cjs is shared with that gate, so "what gets
 * regenerated" and "what gets checked for drift" cannot disagree.
 *
 * USAGE:
 *   node tools/build/gen-all.cjs          run them all
 *   node tools/build/gen-all.cjs --list   print the registry and exit
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const { GENERATORS, allOutputs } = require('./generators.cjs');

const ROOT = path.resolve(__dirname, '..', '..');

if (process.argv.includes('--list')) {
	for (const g of GENERATORS) {
		console.log(`${g.script}${g.note ? '  — ' + g.note : ''}`);
		for (const o of g.outputs) console.log('    ' + o);
	}
	console.log(`\n${GENERATORS.length} generator(s), ${allOutputs().length} distinct output(s).`);
	process.exit(0);
}

let failed = 0;
for (const g of GENERATORS) {
	const abs = path.join(ROOT, 'tools', g.script);
	if (!fs.existsSync(abs)) {
		console.error(`\x1b[31m[ERROR] ${g.script} is in the registry but not on disk.\x1b[0m`);
		failed++;
		continue;
	}
	try {
		execFileSync('node', [abs], { cwd: ROOT, stdio: 'pipe' });
		console.log(`  \x1b[32mok\x1b[0m  ${g.script}`);
	} catch (err) {
		console.error(`  \x1b[31mFAILED\x1b[0m  ${g.script}`);
		const out = (err.stdout && err.stdout.toString()) + (err.stderr && err.stderr.toString());
		console.error(out.trim().split('\n').map((l) => '      ' + l).join('\n'));
		failed++;
	}
}

// A declared output that no generator actually produced is a registry that has
// drifted from reality — the same failure the registry exists to prevent, so it
// is checked rather than assumed.
const missing = allOutputs().filter((o) => !fs.existsSync(path.join(ROOT, o)));
if (missing.length > 0) {
	console.error('\x1b[31m[ERROR] declared output(s) that do not exist after a full run:\x1b[0m');
	for (const m of missing) console.error('    - ' + m);
	failed++;
}

if (failed > 0) {
	console.error(`\n\x1b[31m${failed} generator step(s) failed.\x1b[0m`);
	process.exit(1);
}

console.log(
	`\n\x1b[32m[OK] ${GENERATORS.length} generator(s) ran, ${allOutputs().length} output(s) regenerated.\x1b[0m`
);
