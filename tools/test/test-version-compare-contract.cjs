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
 *
 * The page port (_shared/ui/version_order.js), which the Versions page loads as
 * a plain script to label its install buttons, replays the same table here.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { pathToFileURL } = require('url');

const ROOT = path.resolve(__dirname, '..', '..');
const versionUrl = pathToFileURL(
	path.join(ROOT, 'static/ergopti_plus/_shared/modules/updater/version.js')
).href;
const vectorsPath = path.join(
	ROOT,
	'static/ergopti_plus/_shared/modules/updater/version_vectors.json'
);
const pagePortPath = path.join(ROOT, 'static/ergopti_plus/_shared/ui/version_order.js');

/**
 * Loads the page port the way a page does: a plain script in one context.
 * @returns {{compare: Function}}
 */
function loadPagePort() {
	const sandbox = {};
	vm.createContext(sandbox);
	vm.runInContext(
		`${fs.readFileSync(pagePortPath, 'utf8')}\nthis.__port = ReleaseVersionOrder;`,
		sandbox,
		{
			filename: 'version_order.js'
		}
	);
	return sandbox.__port;
}

/**
 * Builds the actual download-version owner against private literal binary assets.
 * Vite must resolve them as URLs rather than parse archive bytes as JavaScript.
 * @returns {Promise<void>} Resolves only after build and version assertions pass.
 */
async function assertDownloadAssetGlobs() {
	const assert = require('node:assert/strict');
	const os = require('node:os');
	const { build } = await import('vite');
	const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-version-assets-'));
	try {
		const source = fs.readFileSync(path.join(ROOT, 'src/lib/js/getVersions.js'), 'utf8');
		const entry = path.join(fixture, 'getVersions.js');
		fs.writeFileSync(entry, source);
		const samples = [
			['ergopti/windows/Ergopti_v2.2.0.exe', Buffer.from([0x4d, 0x5a, 0xff])],
			['ergopti/windows/Ergopti_v2.2.0.kbe', Buffer.from([0xff, 0x00])],
			[
				'ergopti/macos/bundles/zipped_bundles/Ergopti_v2.2.0.bundle.zip',
				Buffer.from([0x50, 0x4b, 0xff])
			],
			[
				'ergopti/macos/bundles/zipped_bundles/Ergopti_v2.2.2.bundle.zip',
				Buffer.from([0x50, 0x4b, 0xfe])
			],
			['ergopti_plus/windows/Ergopti_v2.2.0.ahk', Buffer.from('; fixture')],
			['ergopti_plus/windows/compiled/Ergopti_v2.2.0.exe', Buffer.from([0x4d, 0x5a, 0xfe])],
			['ergopti_plus/old/kalamine/standard/Ergopti_v2.2.0.toml', Buffer.from('name="fixture"')],
			[
				'ergopti_plus/old/kalamine/standard/Ergopti_v9.0.0_analyse.toml',
				Buffer.from('name="analysis"')
			]
		];
		for (const [relative, bytes] of samples) {
			const file = path.join(fixture, 'static', relative);
			fs.mkdirSync(path.dirname(file), { recursive: true });
			fs.writeFileSync(file, bytes);
		}
		const outputs = await build({
			root: fixture,
			configFile: false,
			publicDir: false,
			base: '/dev/',
			logLevel: 'silent',
			assetsInclude: ['**/*.toml', '**/*.keylayout', '**/*.kbe', '**/*.exe', '**/*.ahk'],
			build: { write: false, minify: false, assetsInlineLimit: 0, ssr: entry }
		});
		const chunks = (Array.isArray(outputs) ? outputs : [outputs]).flatMap(
			(result) => result.output
		);
		const owner = chunks.find((chunk) => chunk.type === 'chunk' && chunk.isEntry);
		assert(owner && owner.code, 'the real version owner must be built');
		const loaded = await import(
			'data:text/javascript;base64,' + Buffer.from(owner.code).toString('base64')
		);
		assert.deepEqual(loaded.getFilteredFileVersions('macos_keylayout'), ['2.2.0', '2.2.2']);
		assert.equal(loaded.getLatestVersion('macos_keylayout'), '2.2.2');
		assert.equal(loaded.getLatestVersion('macos_keylayout', '2.2.0'), '2.2.0');
		for (const name of [
			'kbdedit_exe',
			'kbdedit_kbe',
			'autohotkey',
			'autohotkey_exe',
			'kalamine_standard'
		]) {
			assert.deepEqual(loaded.getFilteredFileVersions(name), ['2.2.0'], name);
		}
		const urls = chunks.filter((chunk) => chunk.type === 'chunk' && chunk.code.includes('.zip'));
		assert(urls.length > 0, 'archive URL chunks must survive the actual build');
		assert(
			urls.some((chunk) => chunk.code.includes('/dev/')),
			'asset URLs retain the configured base'
		);
		for (const [relative, bytes] of samples) {
			assert.deepEqual(fs.readFileSync(path.join(fixture, 'static', relative)), bytes);
		}
		console.log(
			'[OK] Vite builds binary download assets with URL queries and preserves version selection.'
		);
	} finally {
		assert.equal(path.dirname(fixture), path.resolve(os.tmpdir()));
		assert(path.basename(fixture).startsWith('ergopti-version-assets-'));
		fs.rmSync(fixture, { recursive: true, force: true });
	}
}

// version.js is an ESM module (the repo is type:module); load it via dynamic
// import so this CommonJS runner can read its compareVersions export.
(async () => {
	await assertDownloadAssetGlobs();
	const { compareVersions } = await import(versionUrl);
	const data = JSON.parse(fs.readFileSync(vectorsPath, 'utf8'));
	const vectors = Array.isArray(data.vectors) ? data.vectors : [];

	if (vectors.length === 0) {
		console.error('\x1b[31m[ERROR] version_vectors.json has no vectors.\x1b[0m');
		process.exit(1);
	}

	const failures = [];
	const pagePort = loadPagePort();
	for (const v of vectors) {
		const got = compareVersions(v.a, v.b);
		if (got !== v.expect) {
			failures.push(
				`${v.id}: compareVersions(${JSON.stringify(v.a)}, ${JSON.stringify(v.b)}) expected ${v.expect}, got ${got}`
			);
		}
		const page = pagePort.compare(v.a, v.b);
		if (page !== v.expect) {
			failures.push(
				`${v.id}: page port compare(${JSON.stringify(v.a)}, ${JSON.stringify(v.b)}) expected ${v.expect}, got ${page}`
			);
		}
	}

	if (failures.length > 0) {
		console.error(
			'\x1b[31m[ERROR] JS compareVersions or the page port disagrees with the shared parity vectors:\x1b[0m'
		);
		for (const f of failures) console.error('  - ' + f);
		console.error(
			'  Non-semver pairs must be fail-closed (expect 0). Fix version.js to match the table.'
		);
		process.exit(1);
	}

	console.log(
		`\x1b[32m[OK] JS compareVersions and the page port match all ${vectors.length} shared version vectors (incl. fail-closed non-semver).\x1b[0m`
	);
})();
