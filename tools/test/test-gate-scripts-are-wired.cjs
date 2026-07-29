// tools/test/test-gate-scripts-are-wired.cjs

/**
 * ==============================================================================
 * MODULE: Gate-Script Reachability Guard
 * DESCRIPTION:
 * A test file under `tools/test/` is only a gate once something actually runs
 * it. Five of them were run by NOTHING — not by `run-js-suite.cjs` (the umbrella
 * CI executes as `npm run test:js`), not by any workflow in `.github/workflows/`,
 * not by the pre-commit hook. They all passed when invoked by hand, so a
 * maintainer spot-checking them saw green, and nothing anywhere reported that CI
 * had skipped them.
 *
 * ROOT CAUSE ENCODED: "written" and "running" were independent properties with
 * nothing tying them together. Adding a gate was one step (write the script,
 * maybe add an npm alias) when it needed two (and wire it into a runner). This
 * check is that missing second half, so a future orphan fails the build the day
 * it is created rather than being discovered by an audit.
 *
 * The worst of the five was `test-feature-read-sites.js`, which validates every
 * literal `Features[...]` read against the manifest-built map — five of them
 * inside `#HotIf` expressions, where an `UnsetItemError` is raised inside the
 * hotkey evaluator on the keystroke path. `_shared/modules/features/README.md`
 * documents it as a "CI gate": the documentation asserted a guarantee that did
 * not hold.
 *
 * FEATURES & RATIONALE:
 * 1. Reachability is resolved the way a runner really resolves it: a direct
 *    filename reference, OR an `npm run <script>` whose package.json entry names
 *    the file. The first version of this analysis missed the npm-script
 *    indirection and over-reported orphans, so both forms are checked here.
 * 2. Sources searched are every runner that can execute a gate: the umbrella,
 *    every workflow file, and the pre-commit hook.
 * 3. Exemptions are explicit and must stay justified — an allow-list entry whose
 *    script has since been wired is itself reported, so a stale exemption cannot
 *    quietly suppress the rule.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const PASS_SYMBOL = '✓';
const FAIL_SYMBOL = '✗';

const REPO_ROOT = path.resolve(__dirname, '../..');
const SUITE = 'tools/test/run-js-suite.cjs';
const WORKFLOW_DIR = '.github/workflows';
const HOOK = '.husky/pre-commit';

// Scripts deliberately not wired into any runner, each with the reason. Keep this
// empty if you can: the whole point is that a gate nobody runs is not a gate.
const ALLOWED_UNWIRED = {};

let total_pass = 0;
let total_fail = 0;

function check(label, cond, detail) {
	if (cond) {
		total_pass++;
		console.log(`  ${PASS_SYMBOL}  ${label}`);
	} else {
		total_fail++;
		console.log(`  ${FAIL_SYMBOL}  ${label}`);
		if (detail) console.log(`       ${detail}`);
	}
}

function readIfPresent(rel) {
	const p = path.join(REPO_ROOT, rel);
	return fs.existsSync(p) ? fs.readFileSync(p, 'utf8') : '';
}

console.log('Gate-script reachability guard');
console.log('='.repeat(50));

const pkg = JSON.parse(fs.readFileSync(path.join(REPO_ROOT, 'package.json'), 'utf8'));
const suiteSrc = readIfPresent(SUITE);
check(
	'the umbrella runner is readable',
	suiteSrc.length > 1000,
	`${SUITE} is missing or truncated — without it this check silently measures nothing`
);

const workflowDir = path.join(REPO_ROOT, WORKFLOW_DIR);
const workflowSrc = fs.existsSync(workflowDir)
	? fs
			.readdirSync(workflowDir)
			.filter((f) => /\.ya?ml$/.test(f))
			.map((f) => fs.readFileSync(path.join(workflowDir, f), 'utf8'))
			.join('\n')
	: '';
check('at least one CI workflow is readable', workflowSrc.length > 500, 'no workflow files found under .github/workflows');

const hookSrc = readIfPresent(HOOK);

// npm script names each runner invokes.
const suiteScripts = new Set([...suiteSrc.matchAll(/['"](test:[a-z0-9:_-]+)['"]/g)].map((m) => m[1]));
const ciScripts = new Set([...workflowSrc.matchAll(/npm run ([a-z0-9:_-]+)/g)].map((m) => m[1]));
const hookScripts = new Set([...hookSrc.matchAll(/npm run ([a-z0-9:_-]+)/g)].map((m) => m[1]));

const gateFiles = fs
	.readdirSync(path.join(REPO_ROOT, 'tools/test'))
	.filter((f) => /^test-.*\.(js|cjs|mjs)$/.test(f))
	.sort();

check(
	`tools/test holds gate scripts to check (found ${gateFiles.length})`,
	gateFiles.length >= 50,
	'a scan that finds almost nothing cannot fail'
);

function npmScriptsNaming(file) {
	return Object.entries(pkg.scripts || {})
		.filter(([, cmd]) => cmd.includes(file))
		.map(([name]) => name);
}

function reachability(file) {
	const scripts = npmScriptsNaming(file);
	const via = [];
	if (suiteSrc.includes(file)) via.push('run-js-suite (direct)');
	if (scripts.some((s) => suiteScripts.has(s))) via.push('run-js-suite (npm script)');
	if (workflowSrc.includes(file)) via.push('CI workflow (direct)');
	if (scripts.some((s) => ciScripts.has(s))) via.push('CI workflow (npm script)');
	if (hookSrc.includes(file)) via.push('pre-commit hook (direct)');
	if (scripts.some((s) => hookScripts.has(s))) via.push('pre-commit hook (npm script)');
	return via;
}

const orphans = [];
for (const f of gateFiles) {
	if (reachability(f).length === 0) orphans.push(f);
}

const unexpected = orphans.filter((f) => !(f in ALLOWED_UNWIRED));
check(
	`every gate script is reachable from a runner (${gateFiles.length - orphans.length}/${gateFiles.length} wired)`,
	unexpected.length === 0,
	unexpected.length
		? `these scripts are invoked by NOTHING — not run-js-suite.cjs, not any CI workflow, not the pre-commit hook: ${unexpected.join(
				', '
			)}. Add an entry to run-js-suite.cjs's CHECKS list. An npm alias alone is local repro, not coverage. If a script genuinely must stay unwired, add it to ALLOWED_UNWIRED with the reason.`
		: ''
);

// A stale exemption is as dangerous as a missing check: it suppresses the rule
// for a script that no longer needs it.
for (const [file, why] of Object.entries(ALLOWED_UNWIRED)) {
	const stillOrphan = orphans.includes(file);
	check(
		`the exemption for ${file} is still needed (${why})`,
		stillOrphan,
		`${file} is now reachable via ${reachability(file).join(', ')} — delete its ALLOWED_UNWIRED entry`
	);
	check(
		`${file} still exists`,
		gateFiles.includes(file),
		`${file} is exempted but no longer present — delete the exemption`
	);
}

// This guard must itself be wired, or it is the very thing it warns about.
check(
	'this guard is itself wired into the umbrella',
	suiteSrc.includes('test-gate-scripts-are-wired.cjs'),
	'add test-gate-scripts-are-wired.cjs to run-js-suite.cjs — an unwired reachability guard cannot report its own absence'
);

console.log('='.repeat(50));
console.log(`${total_pass} passed, ${total_fail} failed`);
process.exit(total_fail === 0 ? 0 : 1);
