// tools/test/test-hook-scripts-exist.cjs

/**
 * ==============================================================================
 * MODULE: Git Hook Script Guard
 * DESCRIPTION:
 * Every script a git hook invokes must exist at the path the hook names.
 *
 * ROOT CAUSE ENCODED:
 * `.husky/pre-commit` called `python tools/dev/format_toml.py` to sort staged
 * hotstring TOMLs. The script had moved to `tools/format_toml.py`, and the hook
 * kept the old path. Nothing noticed, because the hook only reaches that line
 * when a commit actually stages a file matching
 * `_shared/modules/hotstrings/*.toml` — so the breakage sat dormant until the
 * next such commit, which then failed with a Python "can't open file" and an
 * exit code that aborted the commit outright.
 *
 * That is the worst shape for this kind of rot: invisible for as long as nobody
 * touches the trigger, then blocking at the exact moment somebody does, in a
 * hook rather than in a test — so the error arrives while committing something
 * unrelated to it.
 *
 * A moved script is not hypothetical here. `tools/` has been reorganised more
 * than once, and hooks are the one caller that no import graph, no test runner
 * and no lint pass ever walks.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const HUSKY = path.join(ROOT, '.husky');

// An interpreter followed by a repo-relative script path.
const INVOCATION = /\b(?:node|python3?|sh|bash)\s+((?:tools|scripts|bin)\/[A-Za-z0-9_./-]+\.(?:js|cjs|mjs|py|sh))/g;

// Floor: the hooks do real work, so finding nothing means the scan broke.
const MIN_INVOCATIONS = 3;

const errors = [];

if (!fs.existsSync(HUSKY)) {
	console.error('\x1b[31m[ERROR] .husky/ does not exist — the hooks are gone.\x1b[0m');
	process.exit(1);
}

const hooks = fs
	.readdirSync(HUSKY, { withFileTypes: true })
	.filter((e) => e.isFile() && !e.name.startsWith('.'))
	.map((e) => e.name);

if (hooks.length === 0) {
	errors.push('.husky/ contains no hook files — nothing is enforced at commit time');
}

let invocations = 0;
for (const hook of hooks) {
	const src = fs.readFileSync(path.join(HUSKY, hook), 'utf8');
	src.split(/\r?\n/).forEach((line, i) => {
		// A commented-out invocation is documentation, not a call.
		if (/^\s*#/.test(line)) return;
		for (const m of line.matchAll(INVOCATION)) {
			invocations++;
			const rel = m[1];
			if (fs.existsSync(path.join(ROOT, rel))) continue;
			errors.push(
				`.husky/${hook}:${i + 1}: invokes "${rel}", which does not exist. The hook only reaches ` +
					'this line when a commit stages the file type it guards, so the breakage stays dormant ' +
					'until somebody trips it — and then it aborts their commit, in a hook, over something ' +
					'they did not change.'
			);
		}
	});
}

if (invocations < MIN_INVOCATIONS) {
	errors.push(
		`found only ${invocations} script invocation(s) in the hooks (floor ${MIN_INVOCATIONS}) — the ` +
			'pattern has stopped matching, and this guard would then verify nothing'
	);
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] git hooks reference missing scripts:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] all ${invocations} script(s) invoked by ${hooks.length} git hook(s) exist.\x1b[0m`
);
