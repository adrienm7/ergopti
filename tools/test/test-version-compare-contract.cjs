// tools/test/test-version-compare-contract.cjs

/**
 * ==============================================================================
 * MODULE: Cross-Driver Version-Compare Parity Gate (JS side)
 * DESCRIPTION:
 * The semver comparison algorithm is hand-ported into three runtimes — JS
 * (_shared/modules/updater/version.js compareVersions), AHK
 * (windows/modules/updater/core.ahk _Updater_CompareVersions) and macOS
 * (macos/modules/updater/init.lua compare_versions). version.js's header has always
 * mandated they agree, but nothing enforced it and the non-semver fallback had
 * already drifted (AHK/JS lexicographic vs macOS fail-closed) — D-1.
 *
 * This is the JS third of the gate: it drives compareVersions over the SHARED
 * vector table (_shared/modules/updater/version_vectors.json) and asserts each
 * result equals the table's `expect`. The AHK and macOS suites read the SAME
 * file (test_updater.ahk, test_updater_version_compare.lua), so a divergence in
 * any driver — especially a re-introduced lexicographic non-semver fallback —
 * fails its suite. Models the proven tooltip-tint parity gate.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { pathToFileURL } = require('url');

const ROOT = path.resolve(__dirname, '..', '..');
const versionUrl = pathToFileURL(
	path.join(ROOT, 'static/ergopti_plus/_shared/modules/updater/version.js')
).href;
const vectorsPath = path.join(ROOT, 'static/ergopti_plus/_shared/modules/updater/version_vectors.json');

// version.js is an ESM module (the repo is type:module); load it via dynamic
// import so this CommonJS runner can read its compareVersions export.
(async () => {
	const { compareVersions } = await import(versionUrl);
	const data = JSON.parse(fs.readFileSync(vectorsPath, 'utf8'));
	const vectors = Array.isArray(data.vectors) ? data.vectors : [];

	if (vectors.length === 0) {
		console.error('\x1b[31m[ERROR] version_vectors.json has no vectors.\x1b[0m');
		process.exit(1);
	}

	const failures = [];
	for (const v of vectors) {
		const got = compareVersions(v.a, v.b);
		if (got !== v.expect) {
			failures.push(
				`${v.id}: compareVersions(${JSON.stringify(v.a)}, ${JSON.stringify(v.b)}) expected ${v.expect}, got ${got}`
			);
		}
	}

	if (failures.length > 0) {
		console.error('\x1b[31m[ERROR] JS compareVersions disagrees with the shared parity vectors:\x1b[0m');
		for (const f of failures) console.error('  - ' + f);
		console.error('  Non-semver pairs must be fail-closed (expect 0). Fix version.js to match the table.');
		process.exit(1);
	}

	console.log(
		`\x1b[32m[OK] JS compareVersions matches all ${vectors.length} shared version vectors (incl. fail-closed non-semver).\x1b[0m`
	);
})();
