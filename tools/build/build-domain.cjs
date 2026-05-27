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

"use strict";

const { execSync, spawnSync } = require("child_process");
const path   = require("path");
const fs     = require("fs");

const ROOT        = path.resolve(__dirname, "..", "..");
const PASS_SYMBOL = "✓";
const FAIL_SYMBOL = "✗";
const WARN_SYMBOL = "⚠";

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
	const result = spawnSync(
		"npm",
		["run", "--silent", scriptName],
		{ cwd: ROOT, encoding: "utf8", shell: true }
	);
	return {
		ok:     result.status === 0,
		stdout: result.stdout || "",
		stderr: result.stderr || "",
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
			const result = spawnSync(
				"git",
				["diff", "--exit-code", "--", rel],
				{ cwd: ROOT, encoding: "utf8" }
			);
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
			for (const line of detail.trim().split("\n")) {
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
		name: "build:manifest — generate features_manifest.{ahk,lua}",
		run() {
			const { ok, stderr } = runNpmScript("build:manifest");
			return { ok, detail: ok ? undefined : stderr };
		},
		generated: [
			"static/ergopti_plus/windows/_generated/features_manifest.ahk",
			"static/ergopti_plus/windows/_generated/config_template.toml",
			"static/ergopti_plus/windows/_generated/tap_hold_template.toml",
			"static/ergopti_plus/macos/_generated/features_manifest.lua",
			"static/ergopti_plus/macos/_generated/config_template.toml",
			"static/ergopti_plus/macos/_generated/tap_hold_template.toml",
		],
	},

	// -------------------------------------------------------
	// Step 2: Cross-driver manifest parity (AHK ↔ HS)
	// -------------------------------------------------------
	{
		name: "test:manifest-parity — AHK ↔ HS codegen equivalence",
		run() {
			const { ok, stdout, stderr } = runNpmScript("test:manifest-parity");
			// Extract summary line from test output (last non-empty line)
			const lines   = (stdout + stderr).trim().split("\n").filter(Boolean);
			const summary = lines[lines.length - 1] || "";
			return { ok, detail: ok ? undefined : summary };
		},
	},

	// -------------------------------------------------------
	// Step 3: Port adapter structural compliance (all 13 ports)
	// -------------------------------------------------------
	{
		name: "test:port-compliance — 13 port adapter contracts",
		run() {
			const { ok, stdout, stderr } = runNpmScript("test:port-compliance");
			const lines   = (stdout + stderr).trim().split("\n").filter(Boolean);
			const summary = lines[lines.length - 1] || "";
			return { ok, detail: ok ? undefined : summary };
		},
	},

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
	const allGenerated = PIPELINE
		.flatMap(step => step.generated || [])
		.map(p => path.resolve(ROOT, p));

	// Only check files that actually exist
	const existing = allGenerated.filter(p => fs.existsSync(p));

	if (existing.length === 0) {
		console.log(`  ${WARN_SYMBOL}  drift-check — no generated files found, skipping`);
		return;
	}

	const drifted = detectDrift(existing);
	if (drifted.length === 0) {
		console.log(`  ${PASS_SYMBOL}  drift-check — all generated files match HEAD (${existing.length} file(s))`);
		total_pass++;
	} else {
		console.log(`  ${FAIL_SYMBOL}  drift-check — ${drifted.length} generated file(s) differ from HEAD:`);
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

console.log("\nErgopti+ Domain Build Pipeline");
console.log("=".repeat(50));

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
	console.log("");
	console.log("Drift detection");
	console.log("-".repeat(50));
	runDriftCheck();
}

console.log("");
console.log(`Total: ${total_pass + total_fail} step(s) — ${total_pass} passed, ${total_fail} failed`);
console.log("");

process.exit(total_fail > 0 ? 1 : 0);
