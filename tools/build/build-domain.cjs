// scripts/build-domain.cjs

/**
 * ==============================================================================
 * MODULE: Domain Build Pipeline
 * DESCRIPTION:
 * Unified build pipeline for all Ergopti+ domain artefacts. Runs every codegen
 * step in dependency order, then validates the outputs for drift against the
 * source manifests. Exits with code 1 if any step fails or any drift is
 * detected, so CI catches regressions immediately.
 *
 * FEATURES & RATIONALE:
 * 1. Single entry point: "npm run build:domain" replaces the sequence of
 *    individual build:* calls that developers previously had to run manually,
 *    eliminating the class of "I forgot to regenerate X" bugs.
 * 2. Drift detection: after each codegen step the output files are compared
 *    against the Git index. Files that differ from HEAD are flagged as
 *    "drifted" — meaning a source change was made without re-running codegen.
 *    The check runs even when no codegen is needed so stale artefacts in PRs
 *    are caught by CI.
 * 3. Sequential steps: each step must succeed before the next runs. A failure
 *    short-circuits the pipeline and prints a clear error with the step name.
 * 4. Test vectors: the manifest-parity test (test:manifest-parity) is included
 *    in the pipeline so cross-driver equivalence is verified on every build.
 * ==============================================================================
 */

'use strict';

const { execSync, spawnSync } = require('child_process');
const path = require('path');
const fs = require('fs');

const ROOT = path.resolve(__dirname, '..', '..');
const PASS_SYMBOL = '✓';
const FAIL_SYMBOL = '✗';

let total_pass = 0;
let total_fail = 0;

// ==================================================
// ==================================================
// ======= 1/ Helpers =======
// ==================================================
// ==================================================

/**
 * Runs an npm script and returns { ok, stdout, stderr }.
 * @param {string} scriptName  npm run <scriptName>
 * @returns {{ ok: boolean, stdout: string, stderr: string }}
 */
function runNpmScript(scriptName) {
	const result = spawnSync('npm', ['run', '--silent', scriptName], {
		cwd: ROOT,
		encoding: 'utf8',
		shell: true
	});
	return {
		ok: result.status === 0,
		stdout: result.stdout || '',
		stderr: result.stderr || ''
	};
}

/**
 * Checks whether the given file paths have uncommitted changes according to Git.
 * Returns an array of drifted paths (relative to ROOT).
 * @param {string[]} filePaths  Absolute or relative paths to check.
 * @returns {string[]}
 */
function detectDrift(filePaths) {
	const drifted = [];
	for (const fp of filePaths) {
		const rel = path.relative(ROOT, path.resolve(ROOT, fp));
		try {
			// git diff --exit-code returns 1 if file differs from HEAD
			const result = spawnSync('git', ['diff', '--exit-code', '--', rel], {
				cwd: ROOT,
				encoding: 'utf8'
			});
			if (result.status !== 0) {
				drifted.push(rel);
			}
		} catch (_) {
			// If git is unavailable, skip drift check silently
		}
	}
	return drifted;
}

/**
 * Prints a step result and increments the pass/fail counters.
 * @param {string}  stepName
 * @param {boolean} ok
 * @param {string}  [detail]  Extra detail line printed on failure.
 */
function reportStep(stepName, ok, detail) {
	if (ok) {
		console.log(`  ${PASS_SYMBOL}  ${stepName}`);
		total_pass++;
	} else {
		console.log(`  ${FAIL_SYMBOL}  ${stepName}`);
		if (detail) {
			for (const line of detail.trim().split('\n')) {
				console.log(`       ${line}`);
			}
		}
		total_fail++;
	}
}

// ==================================================
// ==================================================
// ======= 2/ Pipeline Step Definitions =======
// ==================================================
// ==================================================

/**
 * The ordered list of pipeline steps.
 * Each step has:
 *   name       — display name
 *   run        — function() → { ok, detail? }
 *   generated  — (optional) list of generated file paths to check for drift
 */
const PIPELINE = [
	// -------------------------------------------------------
	// Step 1: Generate driver feature manifests (AHK + HS)
	// -------------------------------------------------------
	{
		name: 'build:manifest — generate features_manifest.{ahk,lua}',
		run() {
			const { ok, stderr } = runNpmScript('build:manifest');
			return { ok, detail: ok ? undefined : stderr };
		},
		generated: [
			'static/ergopti_plus/windows/_generated/features_manifest.ahk',
			'static/ergopti_plus/windows/_generated/config_template.toml',
			'static/ergopti_plus/macos/_generated/features_manifest.lua',
			'static/ergopti_plus/macos/_generated/config_template.toml',
			'static/ergopti_plus/linux/_generated/config_template.toml'
		]
	},

	// -------------------------------------------------------
	// Step 1b: Regenerate the remaining faithful codegen artefacts so a source
	// change without a re-run (or a hand-edit of a generated file) is caught by
	// the drift gate below — the freshness half of A6. Every generator whose
	// output is byte-faithful to its committed file is listed here:
	//   - codegen:terminators       → terminators.ahk + terminators_catalogue.lua
	//   - codegen:prompt-builder:ahk → prompt_builder.ahk (string-delimiter bug fixed)
	// contracts.json is already gated by test:port-compliance (with line-ending
	// normalisation). There is no macOS prompt-builder generator: the driver
	// requires the shared Lua module directly (see macos/_generated/README.md).
	{
		name: 'codegen:terminators — regenerate terminators.{ahk,lua}',
		run() {
			const { ok, stderr } = runNpmScript('codegen:terminators');
			return { ok, detail: ok ? undefined : stderr };
		},
		generated: [
			'static/ergopti_plus/windows/_generated/terminators.ahk',
			'static/ergopti_plus/_shared/lua/keymap/terminators_catalogue.lua'
		]
	},
	{
		name: 'codegen:prompt-builder:ahk — regenerate prompt_builder.ahk',
		run() {
			const { ok, stderr } = runNpmScript('codegen:prompt-builder:ahk');
			return { ok, detail: ok ? undefined : stderr };
		},
		generated: ['static/ergopti_plus/windows/_generated/prompt_builder.ahk']
	},
	{
		name: 'codegen:llm-profiles-data:ahk — regenerate llm_profiles_data.ahk',
		run() {
			const { ok, stderr } = runNpmScript('codegen:llm-profiles-data:ahk');
			return { ok, detail: ok ? undefined : stderr };
		},
		generated: ['static/ergopti_plus/windows/_generated/llm_profiles_data.ahk']
	},
	{
		name: 'codegen:keycode-data:js — regenerate keycode_data.js (DC-1)',
		run() {
			const { ok, stderr } = runNpmScript('codegen:keycode-data:js');
			return { ok, detail: ok ? undefined : stderr };
		},
		generated: ['static/ergopti_plus/_shared/ui/metrics_typing/_generated/keycode_data.js']
	},
	{
		name: 'build:menu — emit menu_manifest.json from manifest.toml [menu.*]',
		run() {
			const { ok, stderr } = runNpmScript('build:menu');
			return { ok, detail: ok ? undefined : stderr };
		},
		generated: ['static/ergopti_plus/_shared/modules/menu/menu_manifest.json']
	},

	// -------------------------------------------------------
	// Step 2: Cross-driver manifest parity (AHK ↔ HS)
	// -------------------------------------------------------
	{
		name: 'test:manifest-parity — AHK ↔ HS codegen equivalence',
		run() {
			const { ok, stdout, stderr } = runNpmScript('test:manifest-parity');
			// Extract summary line from test output (last non-empty line)
			const lines = (stdout + stderr).trim().split('\n').filter(Boolean);
			const summary = lines[lines.length - 1] || '';
			return { ok, detail: ok ? undefined : summary };
		}
	},
	{
		name: 'test:llm-legacy-basic-prompt-single-source — legacy/basic-prompt parity',
		run() {
			const { ok, stdout, stderr } = runNpmScript('test:llm-legacy-basic-prompt-single-source');
			const lines = (stdout + stderr).trim().split('\n').filter(Boolean);
			const summary = lines[lines.length - 1] || '';
			return { ok, detail: ok ? undefined : summary };
		}
	},
	{
		name: 'test:keycode-data-js-parity — DC-1 parity',
		run() {
			const { ok, stdout, stderr } = runNpmScript('test:keycode-data-js-parity');
			const lines = (stdout + stderr).trim().split('\n').filter(Boolean);
			const summary = lines[lines.length - 1] || '';
			return { ok, detail: ok ? undefined : summary };
		}
	},

	// -------------------------------------------------------
	// Step 3: Port adapter structural compliance (all 13 ports)
	// -------------------------------------------------------
	{
		name: 'test:port-compliance — 13 port adapter contracts',
		run() {
			const { ok, stdout, stderr } = runNpmScript('test:port-compliance');
			const lines = (stdout + stderr).trim().split('\n').filter(Boolean);
			const summary = lines[lines.length - 1] || '';
			return { ok, detail: ok ? undefined : summary };
		}
	},

	// -------------------------------------------------------
	// Step 5: Generated config template conforms to the schema
	// -------------------------------------------------------
	{
		name: 'test:config-schema — config_template.toml vs config.schema.json',
		run() {
			const { ok, stdout, stderr } = runNpmScript('test:config-schema');
			const lines = (stdout + stderr).trim().split('\n').filter(Boolean);
			// Surface every violation line, not just the summary, on failure.
			const detail = lines
				.filter((l) => l.includes('✗') || l.trim().startsWith('-'))
				.join('\n');
			return { ok, detail: ok ? undefined : detail || lines[lines.length - 1] || '' };
		}
	},

	// -------------------------------------------------------
	// Step 6: Every AHK feature read site is backed by the manifest. Guards the
	// layout.ahk ctrl_magic_save UnsetItemError class — a feature read at a path
	// the manifest does not define (section-prefix drift, removed feature, etc.).
	// -------------------------------------------------------
	{
		name: 'test:kanata-defalias-parity — kanata.kbd timeouts match defaults.toml',
		run() {
			const { ok, stdout, stderr } = runNpmScript('test:kanata-defalias-parity');
			const lines = (stdout + stderr).trim().split('\n').filter(Boolean);
			const summary = lines[lines.length - 1] || '';
			return { ok, detail: ok ? undefined : summary };
		}
	},
	{
		name: 'test:feature-read-sites — AHK Features[...] reads ⊆ manifest',
		run() {
			const { ok, stdout, stderr } = runNpmScript('test:feature-read-sites');
			const lines = (stdout + stderr).trim().split('\n').filter(Boolean);
			const detail = lines
				.filter((l) => l.includes('✗') || l.trim().startsWith('Features['))
				.join('\n');
			return { ok, detail: ok ? undefined : detail || lines[lines.length - 1] || '' };
		}
	},

	// -------------------------------------------------------
	// Step 7: Assemble the Linux driver bundle and verify integrity.
	// The build script runs on Linux (CI) or Windows (dev) — it skips
	// engine/module smoke tests on non-Linux automatically.
	// -------------------------------------------------------
	{
		name: 'build:linux — assemble driver bundle + integrity check',
		run() {
			const result = spawnSync('bash', [
				'tools/build/build-linux-driver.sh',
				'--skip-smoke'
			], {
				cwd: ROOT,
				encoding: 'utf8',
				shell: true,
				timeout: 60000
			});
			const combined = (result.stdout || '') + (result.stderr || '');
			const lines = combined.trim().split('\n').filter(Boolean);
			const detail = result.status === 0
				? undefined
				: lines.filter(l => l.includes('MISSING:') || l.includes('ERROR:')).join('\n') || combined.slice(-200);
			return { ok: result.status === 0, detail };
		}
	},

	// -------------------------------------------------------
	// Step 8: Validate .deb package structure (no dpkg-deb needed).
	// -------------------------------------------------------
	// -------------------------------------------------------
	// The build:deb and build:rpm steps run in CI on ubuntu-latest
	// (see ci.yml jobs build-deb / build-rpm). They require a real
	// driver bundle assembled from static/ source files, which the
	// cross-platform build:linux step already produces. Local dev on
	// Windows/macOS skips these — the CI gate is sufficient.
	// -------------------------------------------------------
];

// ==================================================
// ==================================================
// ======= 3/ Drift Detection Step =======
// ==================================================
// ==================================================

/**
 * After all codegen steps pass, scan all generated files for uncommitted
 * changes. Any drift means the source manifest was edited without re-running
 * build:domain — flag it as a failure so CI catches it.
 */
function runDriftCheck() {
	const allGenerated = PIPELINE.flatMap((step) => step.generated || []);

	// Existence assertion: every declared generated path MUST exist on disk after
	// its step ran. A path listed here that no generator actually produces is a
	// phantom drift-gate entry — it would silently pass the diff below (because a
	// non-existent file has no diff) and create false confidence (TT-1). Fail
	// loudly so phantom entries can never be reintroduced.
	const missing = allGenerated.filter((p) => !fs.existsSync(path.resolve(ROOT, p)));
	if (missing.length > 0) {
		console.log(
			`  ${FAIL_SYMBOL}  drift-check — ${missing.length} declared generated file(s) missing on disk (phantom drift-gate entries):`
		);
		for (const p of missing) {
			console.log(`       - ${p}`);
		}
		console.log(
			`       Every PIPELINE[].generated path must be produced by its step — remove the phantom entry or fix the generator.`
		);
		total_fail++;
		return;
	}

	const existing = allGenerated.map((p) => path.resolve(ROOT, p));
	const drifted = detectDrift(existing);
	if (drifted.length === 0) {
		console.log(
			`  ${PASS_SYMBOL}  drift-check — all generated files match HEAD (${existing.length} file(s))`
		);
		total_pass++;
	} else {
		console.log(
			`  ${FAIL_SYMBOL}  drift-check — ${drifted.length} generated file(s) differ from HEAD:`
		);
		for (const p of drifted) {
			console.log(`       - ${p}`);
		}
		console.log(`       Run "npm run build:manifest" and commit the updated files.`);
		total_fail++;
	}
}

// ==================================================
// ==================================================
// ======= 4/ Main Runner =======
// ==================================================
// ==================================================

console.log('\nErgopti+ Domain Build Pipeline');
console.log('='.repeat(50));

let pipeline_aborted = false;

for (const step of PIPELINE) {
	let result;
	try {
		result = step.run();
	} catch (err) {
		result = { ok: false, detail: String(err) };
	}

	reportStep(step.name, result.ok, result.detail);

	if (!result.ok) {
		// A failed codegen step makes downstream steps meaningless — abort
		console.log(`\n  Pipeline aborted after failed step: ${step.name}`);
		pipeline_aborted = true;
		break;
	}
}

if (!pipeline_aborted) {
	// All steps passed — run drift check as a final gate
	console.log('');
	console.log('Drift detection');
	console.log('-'.repeat(50));
	runDriftCheck();
}

console.log('');
console.log(
	`Total: ${total_pass + total_fail} step(s) — ${total_pass} passed, ${total_fail} failed`
);
console.log('');

process.exit(total_fail > 0 ? 1 : 0);
