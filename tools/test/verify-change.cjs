// tools/test/verify-change.cjs

/**
 * ==============================================================================
 * MODULE: Change-Scoped Verification Gate
 * DESCRIPTION:
 * Looks at what actually changed in the working tree (or in a commit range) and
 * runs exactly the gates that can catch a regression in those files, instead of
 * leaving the choice to whoever is in a hurry.
 *
 * FEATURES & RATIONALE:
 * 1. The AHK runner and the JS gate cover DISJOINT ground. A fully green
 *    3380/3380 AHK suite shipped a broken cross-driver port map, because port
 *    compliance lives in the JS gate and the AHK runner knows nothing about it.
 *    Mapping file -> gate is what removes that guesswork.
 * 2. Two static pre-checks run first because they are instant and because the
 *    failures they catch are SILENT: an unregistered test file never runs, and a
 *    source-scanning test that names a function which does not exist asserts
 *    nothing while still reporting "ok".
 * 3. Advisory by default about scope, strict about outcome: it prints the plan
 *    it derived, then exits non-zero if any selected gate fails.
 * ==============================================================================
 */

'use strict';

const { execSync, spawnSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const REPO_ROOT = path.resolve(__dirname, '..', '..');
const WINDOWS_TESTS = path.join(REPO_ROOT, 'static', 'ergopti_plus', 'windows', 'tests');
const RUN_ALL = path.join(WINDOWS_TESTS, 'run_all.ahk');

// Candidate install locations for the AHK v2 interpreter, in preference order.
// Absent on CI and on non-Windows checkouts, where the AHK gates are skipped
// rather than failed — a missing interpreter is not a regression.
const AHK_CANDIDATES = [
	'C:\\Program Files\\AutoHotkey\\v2\\AutoHotkey64.exe',
	'C:\\Program Files\\AutoHotkey\\AutoHotkey64.exe',
	'C:\\Program Files (x86)\\AutoHotkey\\v2\\AutoHotkey64.exe',
];

// ==================================================
// ==================================================
// ======= 1/ Discovering the changed files =========
// ==================================================
// ==================================================

/**
 * Returns the repo-relative paths this run should reason about.
 * With no argument: everything uncommitted (staged, unstaged and untracked).
 * With a range like "origin/dev..HEAD": every file that range touches.
 * @param {string|null} range - Optional git range.
 * @returns {string[]} Repo-relative POSIX-style paths.
 */
function changedFiles(range) {
	const out = range
		? execSync(`git diff --name-only ${range}`, { cwd: REPO_ROOT, encoding: 'utf8' })
		: execSync('git status --porcelain=v1 --untracked-files=all', { cwd: REPO_ROOT, encoding: 'utf8' });
	const lines = out.split('\n').map((l) => l.trim()).filter(Boolean);
	const files = range ? lines : lines.map((l) => l.replace(/^\S+\s+/, '').replace(/^.*? -> /, ''));
	return [...new Set(files.map((f) => f.replace(/\\/g, '/')))];
}

// ==================================================
// ==================================================
// ======= 2/ Silent-failure pre-checks =============
// ==================================================
// ==================================================

/**
 * A test file that run_all.ahk does not #Include never executes, so the suite
 * reports a pass that proves nothing about the fix it was written for.
 * @param {string[]} files - Changed repo-relative paths.
 * @returns {string[]} Human-readable problems.
 */
function checkTestsAreRegistered(files) {
	if (!fs.existsSync(RUN_ALL)) return [];
	const runAll = fs.readFileSync(RUN_ALL, 'utf8');
	const problems = [];
	for (const f of files) {
		const m = f.match(/static\/ergopti_plus\/windows\/tests\/((?:meta|unit|startup)\/[\w.-]+\.ahk)$/);
		if (!m) continue;
		if (!runAll.includes(m[1])) {
			problems.push(
				`${f} is not #Include'd by tests/run_all.ahk — it will never run, and the suite will pass without it`,
			);
		}
	}
	return problems;
}

/**
 * Finds a braced AHK function definition without assuming that its parameter
 * list fits on one line. The scanner deliberately balances nested parentheses
 * and ignores strings/comments: defaults such as `Map("key", Value())` must not
 * truncate the signature, while a column-zero call site must not count as a
 * definition.
 * @param {string} source - One or more AHK source files.
 * @param {string} name - Exact function name to find.
 * @returns {boolean} Whether a matching definition exists.
 */
function hasAhkFunctionDefinition(source, name) {
	const escapedName = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
	const candidates = source.matchAll(new RegExp(`^[ \\t]*${escapedName}[ \\t]*\\(`, 'gm'));

	for (const candidate of candidates) {
		let lexicalIndex = 0;
		let candidateStringQuote = '';
		let candidateInLineComment = false;
		let candidateInBlockComment = false;
		while (lexicalIndex < candidate.index) {
			const char = source[lexicalIndex];
			const next = source[lexicalIndex + 1] || '';
			if (candidateInLineComment) {
				if (char === '\n') candidateInLineComment = false;
			} else if (candidateInBlockComment) {
				if (char === '*' && next === '/') {
					candidateInBlockComment = false;
					lexicalIndex += 1;
				}
			} else if (candidateStringQuote) {
				if (char === '`') lexicalIndex += 1;
				else if (char === candidateStringQuote) candidateStringQuote = '';
			} else if (char === ';') candidateInLineComment = true;
			else if (char === '/' && next === '*') {
				candidateInBlockComment = true;
				lexicalIndex += 1;
			} else if (char === '"' || char === "'") candidateStringQuote = char;
			lexicalIndex += 1;
		}
		if (candidateStringQuote || candidateInLineComment || candidateInBlockComment) continue;

		let index = candidate.index + candidate[0].lastIndexOf('(');
		let depth = 0;
		let stringQuote = '';
		let inLineComment = false;
		let inBlockComment = false;
		let closedAt = -1;

		for (; index < source.length; index += 1) {
			const char = source[index];
			const next = source[index + 1] || '';

			if (inLineComment) {
				if (char === '\n') inLineComment = false;
				continue;
			}
			if (inBlockComment) {
				if (char === '*' && next === '/') {
					inBlockComment = false;
					index += 1;
				}
				continue;
			}
			if (stringQuote) {
				if (char === '`') {
					index += 1;
					continue;
				}
				if (char === stringQuote) stringQuote = '';
				continue;
			}

			if (char === ';') {
				inLineComment = true;
				continue;
			}
			if (char === '/' && next === '*') {
				inBlockComment = true;
				index += 1;
				continue;
			}
			if (char === '"' || char === "'") {
				stringQuote = char;
				continue;
			}
			if (char === '(') depth += 1;
			else if (char === ')') {
				depth -= 1;
				if (depth === 0) {
					closedAt = index;
					break;
				}
			}
		}

		if (closedAt < 0) continue;
		index = closedAt + 1;
		while (index < source.length) {
			if (/\s/.test(source[index])) {
				index += 1;
				continue;
			}
			if (source[index] === ';') {
				const newline = source.indexOf('\n', index + 1);
				index = newline < 0 ? source.length : newline + 1;
				continue;
			}
			if (source[index] === '/' && source[index + 1] === '*') {
				const end = source.indexOf('*/', index + 2);
				index = end < 0 ? source.length : end + 2;
				continue;
			}
			break;
		}
		if (source[index] === '{') return true;
	}

	return false;
}

/**
 * _DriverFuncBody returns "" for a name it cannot find, which makes every
 * ABSENCE assertion built on it pass vacuously. AHK v2 makes this worse: a call
 * to a function that does not exist is not a load-time error, so a typo or a
 * half-finished rename produces a green test and no diagnostic anywhere.
 * @param {string[]} files - Changed repo-relative paths.
 * @returns {string[]} Human-readable problems.
 */
function checkScannedSymbolsExist(files) {
	const testFiles = files.filter((f) =>
		/static\/ergopti_plus\/windows\/tests\/.*\.ahk$/.test(f) && fs.existsSync(path.join(REPO_ROOT, f)),
	);
	if (testFiles.length === 0) return [];

	const driverRoot = path.join(REPO_ROOT, 'static', 'ergopti_plus', 'windows');
	let driverSource = '';
	const walk = (dir) => {
		for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
			const p = path.join(dir, entry.name);
			const posix = p.replace(/\\/g, '/');
			if (posix.includes('/tests/') || posix.includes('/vendor/') || posix.includes('/_generated/')) continue;
			if (entry.isDirectory()) walk(p);
			else if (entry.name.endsWith('.ahk')) driverSource += '\n' + fs.readFileSync(p, 'utf8');
		}
	};
	walk(driverRoot);

	const problems = [];
	for (const f of testFiles) {
		const src = fs.readFileSync(path.join(REPO_ROOT, f), 'utf8');
		for (const m of src.matchAll(/_DriverFuncBody\(\s*"([A-Za-z_][\w]*)"\s*\)/g)) {
			const name = m[1];
			// Match the same definition grammar as _DriverFuncBody, including
			// multiline signatures and nested default expressions.
			const defined = hasAhkFunctionDefinition(driverSource, name);
			if (!defined) {
				problems.push(
					`${f} scans _DriverFuncBody("${name}") but no such function is defined in the driver — the body comes back empty and every absence assertion on it passes vacuously`,
				);
			}
		}
	}
	return problems;
}

// ==================================================
// ==================================================
// ======= 3/ Mapping a change to its gates =========
// ==================================================
// ==================================================

/**
 * True for the two `_shared/` sub-trees ADR-006 declares binding on EVERY
 * driver: `core/` holds the port contracts, `tests/` holds the cross-driver
 * corpora the three suites replay. Editing either changes what all three
 * drivers are measured against, so all three suites have to run.
 *
 * Without this, the one file class the architecture calls mandatory everywhere
 * was the only one whose edit selected no driver suite at all — a corpus vector
 * could be changed and land fully "verified" having executed nothing.
 * @param {string} f Repo-relative path.
 * @returns {boolean} Whether the path is a cross-driver contract.
 */
function isCrossDriverContract(f) {
	return (
		f.startsWith('static/ergopti_plus/_shared/core/') ||
		f.startsWith('static/ergopti_plus/_shared/tests/')
	);
}

/**
 * Every rule states WHY the gate is required, because the non-obvious pairings
 * are the whole point of this file.
 */
const RULES = [
	{
		gate: 'ahk-encoding',
		why: 'every .ahk must stay UTF-8 BOM + LF; a stray CRLF or a lost BOM breaks the parser in ways that are hard to read',
		match: (f) => f.endsWith('.ahk'),
	},
	{
		gate: 'ahk-suite',
		why: 'the AHK unit + meta suite covers the Windows driver — and replays the shared corpora and port contracts',
		match: (f) =>
			(f.startsWith('static/ergopti_plus/windows/') && f.endsWith('.ahk')) || isCrossDriverContract(f),
	},
	{
		gate: 'ahk-parse',
		// run_all.ahk deliberately excludes the production files that register
		// hotkeys or build menus at top level, so a syntax error in one of them
		// was caught only by the CI compile job. The AHK suite's brace-balance
		// meta test catches the subset that happens to unbalance a brace, and
		// nothing at all catches the rest.
		why: 'a compile parses the WHOLE #Include graph, including the files run_all.ahk cannot include',
		match: (f) =>
			f.startsWith('static/ergopti_plus/windows/') && f.endsWith('.ahk') && !f.includes('/tests/'),
	},
	{
		gate: 'ahk-e2e',
		why: 'driver behaviour changed, and the e2e runner exercises the expansion pipeline end to end',
		match: (f) =>
			f.startsWith('static/ergopti_plus/windows/') &&
			f.endsWith('.ahk') &&
			!f.includes('/tests/'),
	},
	{
		gate: 'js',
		why: 'port compliance, single-source and parity checks live ONLY here — and doc-paths, which validates every link a .md file carries',
		match: (f) =>
			f.includes('/adapters/') ||
			f.includes('_shared/') ||
			f.startsWith('static/ergopti_plus/macos/launcher/') ||
			f.startsWith('tools/') ||
			f.includes('/locales/') ||
			f.endsWith('.json') ||
			f.endsWith('.toml') ||
			f.endsWith('.js') ||
			f.endsWith('.cjs') ||
			f.endsWith('.svelte') ||
			f.endsWith('.md'),
	},
	{
		gate: 'swift-launcher',
		why: 'native launcher code must compile and its process-level XCTest must run on macOS; other hosts report the CI deferral explicitly',
		match: (f) => f.startsWith('static/ergopti_plus/macos/launcher/'),
	},
	{
		gate: 'hs-e2e',
		// Exact sibling of the ahk-e2e rule above. Its absence is how a keymap
		// change shipped that left the macOS e2e harness red while the unit suite
		// stayed fully green: the two tiers are disjoint, and only CI ran the
		// second one. Excluding tests/ mirrors ahk-e2e — editing the harness
		// itself does not need a behaviour re-run.
		why: 'driver behaviour changed, and the e2e runner exercises the expansion pipeline end to end',
		match: (f) =>
			f.startsWith('static/ergopti_plus/macos/') &&
			f.endsWith('.lua') &&
			!f.includes('/tests/'),
	},
	{
		gate: 'hs',
		why: 'the macOS driver changed — or a shared corpus/port contract it replays did',
		// Markdown under a driver tree is documentation, not driver code: it cannot
		// break a Lua suite, and running one for a README edit trains people to
		// ignore the tool's answer.
		match: (f) =>
			(f.startsWith('static/ergopti_plus/macos/') && !f.endsWith('.md')) || isCrossDriverContract(f),
	},
	{
		gate: 'linux-e2e',
		// Found by tools/test/test-e2e-gate-symmetry.cjs, not by a bug report: the
		// Linux driver ships tests/e2e/run_e2e.lua and a CI job for it, and had the
		// same missing rule macOS did. Widening the guard to the whole class is
		// what surfaced it.
		why: 'driver behaviour changed, and the e2e runner exercises the expansion pipeline end to end',
		match: (f) =>
			f.startsWith('static/ergopti_plus/linux/') &&
			f.endsWith('.lua') &&
			!f.includes('/tests/'),
	},
	{
		gate: 'linux',
		why: 'the Linux driver changed — or a shared corpus/port contract it replays did',
		match: (f) =>
			(f.startsWith('static/ergopti_plus/linux/') && !f.endsWith('.md')) || isCrossDriverContract(f),
	},
];

function selectGates(files) {
	const selected = new Map();
	for (const rule of RULES) {
		const hits = files.filter(rule.match);
		if (hits.length > 0) selected.set(rule.gate, { why: rule.why, sample: hits.slice(0, 3) });
	}
	return selected;
}

// ==================================================
// ==================================================
// ======= 4/ Running the selected gates ============
// ==================================================
// ==================================================

function findAhk() {
	return AHK_CANDIDATES.find((p) => fs.existsSync(p)) || null;
}

/**
 * npm is a .cmd shim on Windows, and Node 20+ refuses to spawn one without a
 * shell (the CVE-2024-27980 hardening). Without shell:true the call fails to
 * start and reports a null status, which reads as "the gate failed" even though
 * the gate never ran — a false red is as damaging here as a false green.
 */
function runNpm(script) {
	return spawnSync('npm', ['run', script], { cwd: REPO_ROOT, stdio: 'inherit', shell: true });
}

// How each gate is actually executed. A TABLE rather than a switch so a test can
// assert that every rule above resolves to a real command without spawning any of
// them: a rule whose gate has no entry here selects silently and runs nothing,
// which is indistinguishable from "the gate passed".
const GATE_COMMANDS = {
	'ahk-encoding': { npm: 'test:ahk-encoding' },
	js: { npm: 'test:js' },
	'swift-launcher': { npm: 'test:macos-swift-launcher' },
	hs: { npm: 'test:hs' },
	'hs-e2e': { npm: 'test:hs:e2e' },
	linux: { npm: 'test:linux' },
	'linux-e2e': { npm: 'test:linux:e2e' },
	'ahk-parse': { npm: 'test:ahk-parse' },
	'ahk-suite': { ahk: 'run_all.ahk' },
	'ahk-e2e': { ahk: 'e2e/run_e2e.ahk' },
};

function runGate(gate) {
	const spec = GATE_COMMANDS[gate];
	// Fail loudly instead of reporting a pass for a gate nobody wired up.
	if (!spec) {
		return { error: new Error(`gate "${gate}" has no command in GATE_COMMANDS`) };
	}
	if (spec.npm) return runNpm(spec.npm);
	const ahk = findAhk();
	if (!ahk) return { skipped: 'AutoHotkey v2 not installed on this machine' };
	return spawnSync(ahk, [spec.ahk], { cwd: WINDOWS_TESTS, stdio: 'inherit' });
}

/**
 * Classifies a gate outcome without pretending a red proves causality. A gate
 * selected by the current diff is a candidate regression; an extra full-audit
 * gate is baseline/history until separately reproduced against the baseline.
 * Failure to start is environmental, not a test assertion.
 * @param {string} gate Gate name.
 * @param {object} result spawnSync-like result.
 * @param {boolean} selectedByChange Whether the current diff requires the gate.
 * @returns {{kind: string, blockingInDiagnosis: boolean, detail: string}}
 */
function classifyGateResult(gate, result, selectedByChange) {
	if (result.skipped) {
		return { kind: 'environment-deferral', blockingInDiagnosis: false, detail: result.skipped };
	}
	if (result.error || result.status === null) {
		return {
			kind: 'environment-failure',
			blockingInDiagnosis: selectedByChange,
			detail: result.error ? result.error.message : `${gate} process did not start`,
		};
	}
	if (result.status === 0) return { kind: 'pass', blockingInDiagnosis: false, detail: '' };
	if (selectedByChange) {
		return {
			kind: 'candidate-regression',
			blockingInDiagnosis: true,
			detail: 'this gate covers the current diff; inspect the exact assertion before attributing causality',
		};
	}
	return {
		kind: 'baseline-or-history',
		blockingInDiagnosis: false,
		detail: 'this full-audit gate is not selected by the current diff; reproduce it against the baseline before blocking a scoped change',
	};
}

// ==================================================
// ==================================================
// ======= 5/ Entry point ===========================
// ==================================================
// ==================================================

function main() {
	const args = process.argv.slice(2);
	const planOnly = args.includes('--plan');
	const all = args.includes('--all');
	const diagnose = args.includes('--diagnose');
	const range = (args.find((a) => a.startsWith('--range=')) || '').replace('--range=', '') || null;
	if (diagnose && !all) {
		console.error('verify-change: --diagnose is a full-audit classifier and requires --all.');
		return 2;
	}

	const files = changedFiles(range);
	if (!all && files.length === 0) {
		console.log('verify-change: nothing changed — nothing to verify.');
		return 0;
	}

	if (files.length > 0) {
		console.log(`verify-change: ${files.length} changed file(s).`);
		const problems = [...checkTestsAreRegistered(files), ...checkScannedSymbolsExist(files)];
		if (problems.length > 0) {
			console.error('\n  SILENT-FAILURE PRE-CHECKS FAILED — these would not have shown up as a red suite:\n');
			for (const p of problems) console.error(`   - ${p}`);
			console.error('');
			return 1;
		}
		console.log('verify-change: silent-failure pre-checks passed.');
	}

	const changeGates = selectGates(files);
	const gates = all
		? new Map([['ahk-encoding', {}], ['ahk-suite', {}], ['ahk-e2e', {}], ['js', {}]])
		: changeGates;

	if (gates.size === 0) {
		console.log('verify-change: no gate matches these files. Run with --all if in doubt.');
		return 0;
	}

	console.log('\n  Gates required by this change:');
	for (const [gate, info] of gates) {
		console.log(`   - ${gate}${info.why ? `  (${info.why})` : ''}`);
		if (info.sample) console.log(`       e.g. ${info.sample.join(', ')}`);
	}
	console.log('');
	if (planOnly) return 0;

	let failed = 0;
	let diagnosticBlockers = 0;
	const classifications = [];
	for (const [gate] of gates) {
		console.log(`\n=== ${gate} ===`);
		const res = runGate(gate);
		const classification = classifyGateResult(gate, res, changeGates.has(gate));
		classifications.push({ gate, ...classification });
		if (classification.kind === 'environment-deferral') console.log(`  skipped: ${classification.detail}`);
		else if (classification.kind !== 'pass') {
			failed += 1;
			if (classification.blockingInDiagnosis) diagnosticBlockers += 1;
			console.error(`  ${gate} ${classification.kind.toUpperCase()}: ${classification.detail}`);
		}
	}

	console.log('');
	if (diagnose) {
		const nonPassing = classifications.filter((item) => item.kind !== 'pass');
		console.log('verify-change diagnosis:');
		if (nonPassing.length === 0) console.log('  every full-audit gate passed.');
		for (const item of nonPassing) {
			console.log(`  - ${item.gate}: ${item.kind}${item.blockingInDiagnosis ? ' (blocks this scoped change)' : ' (reported, non-blocking for this scoped change)'}`);
		}
		if (diagnosticBlockers === 0) {
			console.log('verify-change: gates required by the current diff passed or were explicitly deferred; unrelated historical reds were not promoted to regressions.');
			return 0;
		}
		console.error(`verify-change: ${diagnosticBlockers} current-diff gate(s) still require diagnosis.`);
		return 1;
	}
	if (failed > 0) {
		console.error(`verify-change: ${failed} gate(s) failed.`);
		return 1;
	}
	console.log('verify-change: every required gate passed.');
	return 0;
}

// Exported so a regression test can assert which gates a change SELECTS, and that
// every selectable gate resolves to a real command, without spawning any suite.
// The auto-run stays guarded on require.main so `node verify-change.cjs` behaves
// exactly as before.
module.exports = { RULES, GATE_COMMANDS, classifyGateResult, selectGates, hasAhkFunctionDefinition };

if (require.main === module) {
	process.exit(main());
}
