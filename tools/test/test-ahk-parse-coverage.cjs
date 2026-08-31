// tools/test/test-ahk-parse-coverage.cjs

/**
 * ==============================================================================
 * MODULE: AHK Parse Coverage (local mirror of the CI compile)
 * DESCRIPTION:
 * Compiles ErgoptiPlus.ahk with Ahk2Exe and fails on a syntax error anywhere in
 * its #Include graph. A compile parses every included file transitively, so this
 * is the only check that covers the production files run_all.ahk deliberately
 * does not include — the ones that register hotkeys or build menus at top level
 * and would block a clean exit in the headless runner.
 *
 * WHY IT MUST NOT RUN THE SCRIPT:
 * Every "parse-only" trick that goes through AutoHotkey.exe RUNS the driver when
 * the parse succeeds. `/validate` is silently ignored (measured, PROJECT_MEMORY
 * `feedback_ahk_ui_syntax_validation`), and an `ExitApp` probe still fires the
 * driver's OnExit handlers. With `#SingleInstance Force` in the entry point,
 * that is not a theoretical concern: it can take down the maintainer's running
 * driver. Ahk2Exe never executes the script — it writes an .exe — which is why
 * it is the only safe local tool for this.
 *
 * SELF-VALIDATION, AND WHY IT IS NOT OPTIONAL:
 * The Ahk2Exe shipped with the AutoHotkey installer on the maintainer's machine
 * exits 52 on EVERY input, valid or not. A gate wired straight to that is a
 * permanent false red; a gate that treated 52 as "not a syntax error" would be a
 * permanent false green. So the compiler is measured against a known-good and a
 * known-bad fixture first, and is used only if it separates them. Otherwise the
 * check reports SKIPPED — never OK — and says which half of the probe failed.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const DRIVER = path.join(ROOT, 'static', 'ergopti_plus', 'windows');
const ENTRY = path.join(DRIVER, 'ErgoptiPlus.ahk');
const BUNDLE = path.join(DRIVER, 'build', 'static_bundle.zip');
const BUNDLE_BUILDER = path.join(ROOT, 'tools', 'build', 'build_static_bundle.py');

// Ahk2Exe is a GUI-subsystem app: `/silent` stops it opening a dialog that would
// block forever on a headless runner and then report a meaningless exit code.
const SILENT = '/silent';

const AHK2EXE_CANDIDATES = [
	'C:\\Program Files\\AutoHotkey\\Compiler\\Ahk2Exe.exe',
	'C:\\Program Files (x86)\\AutoHotkey\\Compiler\\Ahk2Exe.exe',
];

const BASE_CANDIDATES = [
	'C:\\Program Files\\AutoHotkey\\v2\\AutoHotkey64.exe',
	'C:\\Program Files\\AutoHotkey\\v2\\AutoHotkey32.exe',
];

// ==================================================
// ==================================================
// ======= 1/ Locating the toolchain ================
// ==================================================
// ==================================================

/**
 * @param {string[]} candidates Absolute paths to try in order.
 * @returns {string|null} The first that exists.
 */
function firstExisting(candidates) {
	return candidates.find((p) => fs.existsSync(p)) || null;
}

/**
 * Runs Ahk2Exe once.
 * @param {string} ahk2exe Compiler path.
 * @param {string} base Runtime .exe used as the compile base.
 * @param {string} input Script to compile.
 * @param {string} output Where to write the .exe.
 * @returns {{status: number|null, produced: boolean, text: string}} Outcome.
 */
function compile(ahk2exe, base, input, output) {
	if (fs.existsSync(output)) fs.rmSync(output, { force: true });
	const res = spawnSync(ahk2exe, ['/in', input, '/out', output, '/base', base, SILENT], {
		encoding: 'utf8',
	});
	return {
		status: res.status,
		produced: fs.existsSync(output),
		text: `${res.stdout || ''}${res.stderr || ''}`.trim(),
	};
}

/**
 * Builds the ignored FileInstall input when a local checkout does not already
 * have one. Ahk2Exe validates FileInstall sources while compiling, so the parse
 * gate otherwise reports a packaging precondition as an AHK syntax failure.
 * @returns {string|null} An actionable failure message, or null on success.
 */
function ensureStaticBundle() {
	if (fs.existsSync(BUNDLE)) return null;
	const candidates = [
		{ command: 'py', prefix: ['-3'] },
		{ command: 'python', prefix: [] },
	];
	for (const candidate of candidates) {
		const run = spawnSync(candidate.command, [...candidate.prefix, BUNDLE_BUILDER], {
			cwd: ROOT,
			encoding: 'utf8',
		});
		if (run.error?.code === 'ENOENT') continue;
		if (run.status === 0 && fs.existsSync(BUNDLE)) return null;
		const details = `${run.stdout || ''}${run.stderr || ''}`.trim();
		return `static bundle generation failed with ${candidate.command} (exit ${run.status})${details ? `: ${details}` : ''}`;
	}
	return 'static bundle is absent and neither py nor python is available to build it';
}

/** Removes only the ignored bundle this invocation had to create. */
function cleanupGeneratedBundle() {
	fs.rmSync(BUNDLE, { force: true });
	const buildDir = path.dirname(BUNDLE);
	if (fs.existsSync(buildDir) && fs.readdirSync(buildDir).length === 0) fs.rmdirSync(buildDir);
}

// ==================================================
// ==================================================
// ======= 2/ Proving the compiler discriminates ====
// ==================================================
// ==================================================

/**
 * Writes the two probe fixtures and compiles both.
 *
 * A compiler is trusted only when the valid script produces an .exe and the
 * invalid one does not. Any other outcome — including "both failed", which is
 * what a broken installation looks like — means its verdict on the real driver
 * carries no information.
 * @param {string} ahk2exe Compiler path.
 * @param {string} base Runtime base path.
 * @param {string} dir Scratch directory.
 * @returns {{usable: boolean, why: string}} Verdict on the toolchain.
 */
function probeCompiler(ahk2exe, base, dir) {
	const good = path.join(dir, 'probe_good.ahk');
	const bad = path.join(dir, 'probe_bad.ahk');
	// UTF-8 BOM: the driver's own encoding rule, and Ahk2Exe honours it.
	fs.writeFileSync(good, '\uFEFF#Requires AutoHotkey v2.0\nMsgBox("ok")\n', 'utf8');
	fs.writeFileSync(bad, '\uFEFF#Requires AutoHotkey v2.0\nif (1 {\nMsgBox("x")\n', 'utf8');

	const okRun = compile(ahk2exe, base, good, path.join(dir, 'probe_good.exe'));
	if (!okRun.produced) {
		return { usable: false, why: `a VALID script failed to compile (exit ${okRun.status}) — ${okRun.text || 'no output'}` };
	}
	const badRun = compile(ahk2exe, base, bad, path.join(dir, 'probe_bad.exe'));
	if (badRun.produced) {
		return { usable: false, why: 'a script with a deliberate syntax error still produced an .exe' };
	}
	return { usable: true, why: '' };
}

// ==================================
// ==================================
// ======= 3/ Entry point ===========
// ==================================
// ==================================

function skip(reason) {
	console.log(`\x1b[33m[SKIP] AHK parse coverage — ${reason}\x1b[0m`);
	console.log('  CI still covers this: the "Compile ErgoptiPlus.ahk" job compiles the same entry point.');
	return 0;
}

function main() {
	if (process.platform !== 'win32') return skip('Ahk2Exe is Windows-only');

	const ahk2exe = firstExisting(AHK2EXE_CANDIDATES);
	if (!ahk2exe) return skip('Ahk2Exe is not installed on this machine');
	const base = firstExisting(BASE_CANDIDATES);
	if (!base) return skip('no AutoHotkey v2 runtime found to use as the compile base');
	if (!fs.existsSync(ENTRY)) {
		console.error(`\x1b[31m[ERROR] entry point not found at ${ENTRY}\x1b[0m`);
		return 1;
	}

	const bundleExisted = fs.existsSync(BUNDLE);
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-parse-'));
	try {
		const bundleError = ensureStaticBundle();
		if (bundleError) {
			console.error(`\x1b[31m[ERROR] AHK parse coverage cannot prepare FileInstall input: ${bundleError}.\x1b[0m`);
			return 1;
		}
		const probe = probeCompiler(ahk2exe, base, dir);
		if (!probe.usable) return skip(`this Ahk2Exe cannot be trusted: ${probe.why}`);

		const out = path.join(dir, 'ErgoptiPlus.exe');
		const run = compile(ahk2exe, base, ENTRY, out);
		// Both conditions matter: Ahk2Exe can exit 0 on a warning without writing
		// the output, which is the shape CI already guards against.
		if (run.status !== 0 || !run.produced) {
			console.error(`\x1b[31m[ERROR] ErgoptiPlus.ahk failed to compile (exit ${run.status}).\x1b[0m`);
			console.error('  A compile parses the WHOLE #Include graph, so the error is in the entry point or');
			console.error('  in any file it pulls in — including the ones run_all.ahk deliberately skips.');
			if (run.text) console.error(`\n${run.text}`);
			return 1;
		}
		console.log('\x1b[32m[OK] ErgoptiPlus.ahk and its whole #Include graph compile.\x1b[0m');
		return 0;
	} finally {
		fs.rmSync(dir, { recursive: true, force: true });
		if (!bundleExisted) cleanupGeneratedBundle();
	}
}

process.exit(main());
