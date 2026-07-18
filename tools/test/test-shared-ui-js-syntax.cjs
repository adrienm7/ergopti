// tools/test/test-shared-ui-js-syntax.cjs

/**
 * ==============================================================================
 * MODULE: Shared UI JavaScript Syntax Regression Test
 * DESCRIPTION:
 * Parses every JavaScript asset served by the shared Ergopti+ user interface.
 * A syntax error in one ordinary browser script aborts the rest of the WebView
 * script chain, leaving native hosts to wait for globals such as
 * `window.process_manifest` that can never be exported.
 *
 * FEATURES & RATIONALE:
 * 1. Browser-asset coverage: Recursively checks every committed shared UI script,
 *    including assets not imported by Node's module resolver.
 * 2. Real parser: Delegates to the repository Node runtime's `--check` mode, so
 *    malformed template literals and other parser failures are exercised exactly.
 * 3. Actionable TAP output: Identifies each invalid asset and preserves the parser
 *    diagnostic needed to repair a blocked WebView initialization.
 * ==============================================================================
 */

"use strict";

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const ROOT = path.resolve(__dirname, "..", "..");
const SHARED_UI_ROOT = path.join(ROOT, "static", "ergopti_plus", "_shared", "ui");

let passCount = 0;
let failCount = 0;
const results = [];





// =====================================================
// =====================================================
// ======= 1/ Shared UI Syntax Assertions ==============
// =====================================================
// =====================================================

/**
 * Recursively collects JavaScript browser assets below a directory.
 * @param {string} directory - Absolute directory to walk.
 * @returns {string[]} Sorted absolute JavaScript asset paths.
 */
function collectJavascriptFiles(directory) {
	const files = [];
	for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
		const entryPath = path.join(directory, entry.name);
		if (entry.isDirectory()) {
			files.push(...collectJavascriptFiles(entryPath));
		} else if (entry.isFile() && entry.name.endsWith(".js")) {
			files.push(entryPath);
		}
	}
	return files.sort();
}

/**
 * Records a TAP assertion result.
 * @param {string} name - Human-readable assertion name.
 * @param {boolean} ok - Whether the assertion passed.
 * @param {string} [detail] - Failure detail shown beneath a failing assertion.
 */
function record(name, ok, detail) {
	if (ok) {
		passCount += 1;
	} else {
		failCount += 1;
	}
	results.push({ name, ok, detail });
}

/**
 * Checks one browser asset with Node's syntax-only parser.
 * @param {string} filePath - Absolute JavaScript asset path.
 */
function checkSyntax(filePath) {
	const result = spawnSync(process.execPath, ["--check", filePath], {
		cwd: ROOT,
		encoding: "utf8"
	});
	const relativePath = path.relative(ROOT, filePath).replaceAll(path.sep, "/");
	const parserOutput = `${result.stdout || ""}${result.stderr || ""}`.trim();
	record(
		`${relativePath} parses as JavaScript`,
		result.status === 0,
		parserOutput || `node --check exited with status ${String(result.status)}`
	);
}

/**
 * Prints TAP output and exits non-zero if any syntax assertion failed.
 */
function report() {
	const total = passCount + failCount;
	console.log("TAP version 14");
	console.log(`1..${total}`);
	results.forEach((result, index) => {
		console.log(`${result.ok ? "ok" : "not ok"} ${index + 1} - ${result.name}`);
		if (!result.ok && result.detail) {
			console.log(`  # ${result.detail.replaceAll("\n", "\n  # ")}`);
		}
	});
	console.log(`# passed: ${passCount}/${total}`);
	if (failCount > 0) {
		console.log(`# FAILED: ${failCount} shared UI JavaScript asset(s) do not parse`);
		process.exit(1);
	}
}

const javascriptFiles = collectJavascriptFiles(SHARED_UI_ROOT);
record("shared UI contains JavaScript browser assets", javascriptFiles.length > 0);
javascriptFiles.forEach(checkSyntax);
report();
