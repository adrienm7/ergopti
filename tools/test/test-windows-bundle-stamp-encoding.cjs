// tools/test/test-windows-bundle-stamp-encoding.cjs

/**
 * ==============================================================================
 * MODULE: Windows Bundle Stamp Encoding
 * DESCRIPTION:
 * Runs the actual packaging stamp under native PowerShell and requires exact
 * UTF8 BOM and LF bytes after replacing every CI version and identity token.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const pipeline = require('./ci-pipeline.cjs');

const recipe = pipeline
	.runOf(
		pipeline.step(
			pipeline.job('package-windows'),
			'Stamp BUNDLE_VERSION, BUNDLE_RELEASE_URL, BUNDLE_CHANNEL'
		)
	)
	.join('\n');
if (process.platform !== 'win32') {
	assert.match(
		recipe,
		/UTF8Encoding\]\s*::\s*new\(\$true\)/,
		'the packaging writer must explicitly preserve the AHK UTF8 BOM'
	);
	console.log(
		'[SKIP] Native PowerShell stamp bytes require the Windows lane; the BOM writer contract passed.'
	);
} else {
	const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-bundle-stamp-'));
	try {
		const file = path.join(root, 'static/ergopti_plus/windows/infra/bundle.ahk');
		fs.mkdirSync(path.dirname(file), { recursive: true });
		const source =
			'\uFEFF; Unicode: café / 𐐀 / 中文\n' +
			'global BUNDLE_VERSION := "__BUNDLE_VERSION__"\n' +
			'global BUNDLE_RELEASE_URL := "__BUNDLE_RELEASE_URL__"\n' +
			'global BUNDLE_CHANNEL := "__BUNDLE_CHANNEL__"\n' +
			'global BUNDLE_COMMIT := "__BUNDLE_COMMIT__"\n';
		fs.writeFileSync(file, source);
		const sha = 'a'.repeat(40);
		const values = {
			"inputs.version || '0.0.0-dev'": '0.0.0-dev',
			'inputs.tag': '0.0.0-dev',
			'inputs.channel': 'dev',
			'github.repository_owner': 'audit',
			'github.event.repository.name': 'ergopti',
			'github.workspace': root,
			'github.sha': sha
		};
		const script = path.join(root, 'stamp.ps1');
		fs.writeFileSync(
			script,
			"$ErrorActionPreference = 'Stop'\n" +
				recipe.replace(/\$\{\{\s*([^}]+?)\s*\}\}/g, (_, key) => {
					assert.ok(Object.hasOwn(values, key), 'every CI input has an explicit native fixture');
					return values[key].replaceAll('`', '``').replaceAll('$', '`$').replaceAll('"', '`"');
				}) +
				'\n'
		);
		const child = spawnSync('pwsh.exe', ['-NoProfile', '-NonInteractive', '-File', script], {
			cwd: root,
			encoding: 'utf8',
			windowsHide: true,
			timeout: 30000
		});
		assert.ifError(child.error);
		assert.equal(child.status, 0, child.stdout + child.stderr);
		const expected = source
			.replace('__BUNDLE_VERSION__', '0.0.0-dev')
			.replace('__BUNDLE_RELEASE_URL__', 'https://github.com/audit/ergopti/releases/tag/0.0.0-dev')
			.replace('__BUNDLE_CHANNEL__', 'dev')
			.replace('__BUNDLE_COMMIT__', sha);
		assert.deepEqual(
			fs.readFileSync(file),
			Buffer.from(expected, 'utf8'),
			'the real stamp must preserve BOM, LF and every Unicode byte with exact replacements'
		);
		console.log(
			'[OK] Native Windows packaging stamp preserves exact AHK BOM, LF and Unicode bytes.'
		);
	} finally {
		assert.equal(
			path.dirname(path.resolve(root)),
			path.resolve(os.tmpdir()),
			'cleanup stays inside the owned temporary parent'
		);
		assert.ok(path.basename(root).startsWith('ergopti-bundle-stamp-'));
		fs.rmSync(root, { recursive: true, force: true });
	}
}
