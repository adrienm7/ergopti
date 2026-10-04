// tools/test/test-hs274-baseline-contract.cjs

/**
 * ==============================================================================
 * MODULE: HS-274 Baseline Contract Refusal
 * DESCRIPTION:
 * The live Lua consumer admits one physical baseline version; the diagnostic
 * producer, CLI transfer and Python fixture reader declare their own. This gate proves
 * that the native workflow refuses a Hammerspoon-consumer run on a cheap Linux
 * job, with a named reason, while they disagree, and lets it through once they
 * agree.
 *
 * ROOT CAUSE ENCODED:
 * physical_baseline.lua moved to baseline version 2 (keyboard type per device,
 * usage page per key) before the producer did: hs274-stream-source.hpp still
 * emits version 1 and hs274_baseline_frames.py still reads only version 1. A
 * dispatch of hs274-native.yml with hammerspoon_consumer=true therefore built
 * and installed everything on a macOS runner and only then failed at admission.
 * The CLI transfer also rejects baseline descriptors other than version 1;
 * aligning the producer and Python reader alone must not admit that CLI.
 *
 * WHAT IS CHECKED:
 * 1. tools/diagnostics/hs274_baseline_contract.py refuses a mismatched tree
 *    with exit 3 and the reason consumer_baseline_version_mismatch, and accepts
 *    an aligned one.
 * 2. It reads the real tree without error and reports a verdict.
 * 3. hs274-native.yml runs it in its own Linux job whenever the Hammerspoon
 *    consumer is selected, and the macOS job needs that job.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const SCRIPT = path.join(ROOT, 'tools', 'diagnostics', 'hs274_baseline_contract.py');
const WORKFLOW = path.join(ROOT, '.github', 'workflows', 'hs274-native.yml');
const REASON = 'consumer_baseline_version_mismatch';
const REFUSED = 3;

const errors = [];
const fail = (msg) => errors.push(msg);

/** Runs the contract check against one repository root. */
function check(root) {
	const python = process.platform === 'win32' ? 'python' : 'python3';
	return spawnSync(python, [SCRIPT, '--root', root], { encoding: 'utf8' });
}

/** Writes independently chosen declarations for all four baseline boundaries. */
function fixture(dir, consumer, producer, reader, cli) {
	const files = {
		'static/ergopti_plus/macos/modules/keylogger/physical_baseline.lua': `local M = {}\nM.VERSION = ${consumer}\nreturn M\n`,
		'tools/diagnostics/hs274-stream-source.hpp': `opened["baseline"] = {{"version", ${producer}u}, {"rows", 1}};\n`,
		'tools/diagnostics/hs274_baseline_frames.py': `integer(descriptor["version"], "baseline version", ${reader}, ${reader})\n`,
		'tools/diagnostics/hs274-stream-baseline-client.hpp': `if (descriptor.at("version") != ${cli}u) throw std::invalid_argument("Invalid capture baseline descriptor");\n`
	};
	for (const [rel, text] of Object.entries(files)) {
		fs.mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true });
		fs.writeFileSync(path.join(dir, rel), text);
	}
}

// =====================================
// =====================================
// ======= 1/ Verdicts =================
// =====================================
// =====================================

if (!fs.existsSync(SCRIPT)) {
	fail(
		'tools/diagnostics/hs274_baseline_contract.py is missing — nothing refuses a mismatched run'
	);
} else {
	const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'hs274-contract-'));
	try {
		const mismatched = path.join(temp, 'mismatched');
		fixture(mismatched, 2, 1, 1, 1);
		const refused = check(mismatched);
		if (refused.status !== REFUSED || !refused.stdout.includes(REASON))
			fail(
				`a mismatched tree must be refused with exit ${REFUSED} and ${REASON}, got ${refused.status}: ${refused.stdout}${refused.stderr}`
			);
		const reader = path.join(temp, 'reader');
		fixture(reader, 2, 2, 1, 2);
		if (check(reader).status !== REFUSED)
			fail('a reader that cannot read the version must be refused');
		const aligned = path.join(temp, 'aligned');
		fixture(aligned, 2, 2, 2, 2);
		const accepted = check(aligned);
		if (accepted.status !== 0)
			fail(`an aligned tree must pass, got ${accepted.status}: ${accepted.stdout}`);
		const cliMismatch = path.join(temp, 'cli-mismatch');
		fixture(cliMismatch, 2, 2, 2, 1);
		const cliRefused = check(cliMismatch);
		if (cliRefused.status !== REFUSED || !cliRefused.stdout.includes(REASON))
			fail(
				`CLI version 1 alone must refuse a version-2 baseline with exit ${REFUSED} and ${REASON}, got ${cliRefused.status}: ${cliRefused.stdout}${cliRefused.stderr}`
			);
		const declarations = {
			consumer: [
				'static/ergopti_plus/macos/modules/keylogger/physical_baseline.lua',
				'M.VERSION = 1\n'
			],
			producer: [
				'tools/diagnostics/hs274-stream-source.hpp',
				'opened["baseline"] = {{"version", 1u}, {"rows", 1}};\n'
			],
			reader: [
				'tools/diagnostics/hs274_baseline_frames.py',
				'integer(descriptor["version"], "baseline version", 1, 1)\n'
			],
			cli: [
				'tools/diagnostics/hs274-stream-baseline-client.hpp',
				'if (descriptor.at("version") != 1u) throw std::invalid_argument("ambiguous");\n'
			]
		};
		for (const [boundary, [relative, contradictory]] of Object.entries(declarations)) {
			const ambiguous = path.join(temp, `ambiguous-${boundary}`);
			fixture(ambiguous, 2, 2, 2, 2);
			fs.appendFileSync(path.join(ambiguous, relative), contradictory);
			const rejected = check(ambiguous);
			if (
				rejected.status === 0 ||
				!rejected.stderr.includes('Expected one baseline version declaration')
			)
				fail(
					`ambiguous ${boundary} declarations must fail closed, got ${rejected.status}: ${rejected.stdout}${rejected.stderr}`
				);
		}
		const missingCli = path.join(temp, 'missing-cli-declaration');
		fixture(missingCli, 2, 2, 2, 2);
		fs.writeFileSync(
			path.join(missingCli, 'tools/diagnostics/hs274-stream-baseline-client.hpp'),
			'// No baseline admission declaration.\n'
		);
		const missingRefused = check(missingCli);
		if (
			missingRefused.status === 0 ||
			!missingRefused.stderr.includes('Expected one baseline version declaration')
		)
			fail(
				`a missing CLI declaration must fail closed, got ${missingRefused.status}: ${missingRefused.stdout}${missingRefused.stderr}`
			);
	} finally {
		fs.rmSync(temp, { recursive: true, force: true });
	}
	const real = check(ROOT);
	if (real.status !== 0 && !(real.status === REFUSED && real.stdout.includes(REASON)))
		fail(`the real tree must yield a verdict, got ${real.status}: ${real.stdout}${real.stderr}`);
}

// =====================================
// =====================================
// ======= 2/ Workflow wiring ==========
// =====================================
// =====================================

{
	const yml = fs.readFileSync(WORKFLOW, 'utf8');
	const contract = (yml.match(/\n {2}contract:\n([\s\S]*?)\n {2}observe:\n/) || [])[1];
	if (!contract) fail('hs274-native.yml has no contract job before observe');
	else {
		if (!/runs-on: ubuntu-/.test(contract))
			fail('the contract job must run on Linux, before any macOS runner is spent');
		if (
			!/if: inputs\.hammerspoon_consumer\n\s+run: python3 tools\/diagnostics\/hs274_baseline_contract\.py/.test(
				contract
			)
		)
			fail(
				'the contract job must run hs274_baseline_contract.py whenever the Hammerspoon consumer is selected'
			);
	}
	const observe = (yml.match(/\n {2}observe:\n([\s\S]*)$/) || [])[1] || '';
	if (!/^ {4}needs: contract$/m.test(observe)) fail('the observe job must need the contract job');
}

if (errors.length > 0) {
	console.error(
		'\x1b[31m[FAIL] the HS-274 native run is not refused while the baseline versions disagree:\x1b[0m'
	);
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}
console.log(
	'\x1b[32m[OK] hs274-native.yml refuses a Hammerspoon consumer on Linux, with a named reason, until the producer serves the consumer baseline version.\x1b[0m'
);
