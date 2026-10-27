// tools/test/test-macos-dev-source-build.cjs

/**
 * ==============================================================================
 * MODULE: macOS Developer Source Build Guard Tests
 * DESCRIPTION:
 * A developer ErgoptiPlus.app (ERGOPTI_DEV_SOURCE=1) runs the Lua of one clone.
 * These checks run the real build script's admission, the real archive CLI and
 * the guard module against fixture bundles, so such an app can neither be
 * built as a release nor archived, receipted or installed by CI.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { bashExecutable } = require('../lib/git-bash.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const BUILD = path.join(ROOT, 'tools/build/build_macos_app.sh');
const ARCHIVES = path.join(ROOT, 'tools/build/macos-release-archives.cjs');
const {
	developerSourceKey,
	refuseDeveloperSource
} = require('../build/macos-dev-source-guard.cjs');
const KEY = JSON.parse(
	fs.readFileSync(path.join(ROOT, 'static/ergopti_plus/_shared/data/identifiers.json'), 'utf8')
).dev_source.plist_key;

let checks = 0;
function check(name, body) {
	body();
	checks++;
	console.log(`PASS ${name}`);
}

const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-dev-source-'));
/** Writes a fixture bundle whose launcher plist carries the given dict body. */
function bundle(name, plist) {
	const app = path.join(scratch, name, 'ErgoptiPlus.app');
	fs.mkdirSync(path.join(app, 'Contents'), { recursive: true });
	if (plist !== null) fs.writeFileSync(path.join(app, 'Contents', 'Info.plist'), plist);
	return app;
}
const xml = (dict) =>
	`<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<dict>\n${dict}</dict>\n</plist>\n`;

try {
	const developer = bundle(
		'developer',
		xml(`\t<key>${KEY}</key>\t<string>/Users/me/ergopti</string>\n`)
	);
	const packaged = bundle(
		'packaged',
		xml('\t<key>CFBundleName</key>\t<string>ErgoptiPlus</string>\n')
	);

	check('the guard reads the one declared plist key', () => {
		assert.equal(developerSourceKey(), KEY);
		assert.match(KEY, /^[A-Za-z]+$/);
	});

	check('the guard refuses a developer source bundle and admits a packaged one', () => {
		assert.throws(() => refuseDeveloperSource(developer), /developer source build/);
		refuseDeveloperSource(packaged);
	});

	check('the guard refuses a plist it cannot prove free of the key', () => {
		assert.throws(() => refuseDeveloperSource(bundle('binary', 'bplist00\u0000')), /not an XML/);
		assert.throws(() => refuseDeveloperSource(bundle('missing', null)), /ENOENT/);
		assert.throws(() => refuseDeveloperSource('relative.app'), /absolute/);
	});

	check('every archive CLI entry refuses a developer bundle before any native step', () => {
		const output = path.join(scratch, 'archives');
		fs.mkdirSync(output);
		for (const args of [
			[developer, output],
			['--ci-receipt', developer, path.dirname(developer)]
		]) {
			const result = spawnSync(process.execPath, [ARCHIVES, ...args], { encoding: 'utf8' });
			assert.notEqual(result.status, 0);
			assert.match(result.stderr, /developer source build/);
		}
		assert.deepEqual(fs.readdirSync(output), [], 'a refused developer bundle produced an archive');
	});

	check('the build orders the plist key before signing and skips the archive producer', () => {
		const source = fs.readFileSync(BUILD, 'utf8');
		const main = source.slice(source.indexOf('\nmain() {\n'));
		const recorded = main.indexOf('record_dev_source_root');
		const signed = main.indexOf('\tcodesign_app\n');
		const skipped = main.indexOf('if [ "$ERGOPTI_DEV_SOURCE" = 1 ]; then');
		const archived = main.indexOf('tools/build/macos-release-archives.cjs');
		assert(main.indexOf('\tcheck_dev_source_configuration\n') > 0, 'main must admit the switch');
		assert(recorded > 0 && recorded < signed, 'the key must be written before codesign');
		assert(skipped > signed && skipped < archived, 'a developer app must return before archiving');
		assert.match(main.slice(skipped, archived), /\n\t\treturn\n/);
	});

	if (process.platform === 'win32') {
		console.log('SKIP build script admission: the macOS build script is not run on Windows.');
	} else {
		const run = (environment) =>
			spawnSync(bashExecutable(), [BUILD], {
				encoding: 'utf8',
				env: { ...process.env, ERGOPTI_RELEASE: 'false', ...environment },
				timeout: 60000
			});
		check('the real build refuses a developer source release before building', () => {
			const result = run({ ERGOPTI_DEV_SOURCE: '1', ERGOPTI_RELEASE: 'true' });
			assert.notEqual(result.status, 0);
			assert.match(result.stderr, /ERGOPTI_DEV_SOURCE=1 is refused for a release build/);
			assert.doesNotMatch(result.stderr, /Downloading|Building launcher/);
		});
		check('the real build refuses an unknown developer switch value', () => {
			const result = run({ ERGOPTI_DEV_SOURCE: 'yes' });
			assert.notEqual(result.status, 0);
			assert.match(result.stderr, /ERGOPTI_DEV_SOURCE must be 0 or 1, not 'yes'/);
		});
	}
} finally {
	fs.rmSync(scratch, { recursive: true, force: true });
}
console.log(
	`[OK] macOS developer source builds are refused as releases and archives (${checks} checks).`
);
