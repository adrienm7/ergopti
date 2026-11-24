// tools/test/test-app-metadata.cjs

/**
 * ==============================================================================
 * MODULE: Application Metadata Contract
 * DESCRIPTION:
 * Finder's Get Info and Quick Look showed ErgoptiPlus.app with its name,
 * version, size and date only, where Apple's own apps show their copyright;
 * the Linux packages named no website, issue tracker or developer and the
 * Debian package an invented maintainer address. Every package now writes its
 * copyright, licence, website and description from tools/lib/app-metadata.cjs.
 *
 * ROOT CAUSE ENCODED:
 * 1. the notice is derived from LICENSE (holder, first year, MIT) and ends at
 *    the year of the commit built, never a typed year;
 * 2. the website, repository and issue tracker come from CNAME and
 *    _shared/updater/data/defaults.json;
 * 3. each OS build writes the fields its file manager or software centre shows
 *    and spells none of them itself.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const metadata = require('../lib/app-metadata.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const read = (relative) => fs.readFileSync(path.join(ROOT, relative), 'utf8');
const meta = metadata.readMetadata();
let checks = 0;
const check = (fn) => {
	fn();
	checks += 1;
};

// 1. The notice is the LICENSE holder under MIT, ending at the build year
check(() => {
	const license = /^Copyright \(c\) (\d{4}) (.+)$/m.exec(read('LICENSE'));
	assert.equal(meta.holder, license[2]);
	assert.equal(meta.firstYear, Number(license[1]));
	assert.equal(meta.license, 'MIT');
	assert.equal(
		metadata.copyrightNotice(2026, meta),
		`Copyright © ${license[1]}–2026 ${license[2]}. MIT License.`
	);
	assert.equal(
		metadata.copyrightNotice(meta.firstYear, meta),
		`Copyright © ${license[1]} ${license[2]}. MIT License.`
	);
	assert.throws(() => metadata.copyrightNotice(meta.firstYear - 1, meta), /precedes/);
});

// 2. The build year is the commit's, so a rebuild of one commit is identical
check(() => {
	const seconds = Number(
		spawnSync('git', ['-C', ROOT, 'show', '-s', '--format=%ct', 'HEAD'], {
			encoding: 'utf8'
		}).stdout.trim()
	);
	const expected = Number(
		new Intl.DateTimeFormat('en', { year: 'numeric', timeZone: 'Europe/Paris' }).format(
			seconds * 1000
		)
	);
	assert.equal(metadata.buildYear(ROOT, {}), expected);
	// 2025-12-31T23:00Z is already 2026 in Paris.
	assert.equal(metadata.buildYear(ROOT, { SOURCE_DATE_EPOCH: '1767222000' }), 2026);
	assert.throws(() => metadata.buildYear(ROOT, { SOURCE_DATE_EPOCH: '' }), /positive epoch/);
	assert.throws(() => metadata.buildYear(ROOT, { ERGOPTI_BUILD_COMMIT: '0'.repeat(40) }));
});

// 3. The links come from CNAME and the updater's repository
check(() => {
	const { github } = JSON.parse(read('static/ergopti_plus/_shared/updater/data/defaults.json'));
	assert.equal(meta.homepage, `https://${read('CNAME').trim()}`);
	assert.equal(meta.repository, `https://github.com/${github.owner}/${github.repo}`);
	assert.equal(meta.issues, `${meta.repository}/issues`);
});

// 4. The command line serves the shell builds the same values
check(() => {
	const run = spawnSync(
		'node',
		['tools/lib/app-metadata.cjs', 'field', 'copyright', '--year', '2030'],
		{ cwd: ROOT, encoding: 'utf8' }
	);
	assert.equal(run.status, 0, run.stderr);
	assert.equal(run.stdout, `${metadata.copyrightNotice(2030, meta)}\n`);
	const bad = spawnSync('node', ['tools/lib/app-metadata.cjs', 'field', 'nope'], {
		cwd: ROOT,
		encoding: 'utf8'
	});
	assert.notEqual(bad.status, 0, 'an unknown field must fail, not print an empty value');
});

// 5. macOS: Finder and Quick Look read the launcher's copyright and category
check(() => {
	const script = read('tools/build/build_macos_app.sh');
	const start = script.indexOf('generate_info_plist() {');
	const generator = script.slice(start, script.indexOf('\n}\n', start));
	assert.ok(start > 0, 'build_macos_app.sh has no generate_info_plist');
	assert.match(
		generator,
		/plutil -replace NSHumanReadableCopyright -string "\$APP_COPYRIGHT" "\$plist"/,
		'the launcher Info.plist must carry the copyright Finder shows'
	);
	assert.match(
		generator,
		/plutil -replace LSApplicationCategoryType -string "\$APP_CATEGORY" "\$plist"/
	);
	assert.ok(
		generator.indexOf('NSHumanReadableCopyright') < generator.indexOf('plutil -lint'),
		'the keys are written before the plist is linted, and so before codesign seals it'
	);
	assert.match(meta.macosCategory, /^public\.app-category\.[a-z-]+$/);
	// The assignments the build runs yield the library's values.
	const assignments = script.split('\n').filter((line) => /^APP_(COPYRIGHT|CATEGORY)=/.test(line));
	assert.equal(assignments.length, 2, 'the build resolves the copyright and the category once');
	const shell = `set -eu; REPO_ROOT="$1"; ${assignments.join('; ')}; printf '%s|%s' "$APP_COPYRIGHT" "$APP_CATEGORY"`;
	const run = spawnSync('bash', ['-c', shell, '_', ROOT], { encoding: 'utf8' });
	assert.equal(run.status, 0, run.stderr);
	assert.equal(
		run.stdout,
		`${metadata.copyrightNotice(metadata.buildYear(), meta)}|${meta.macosCategory}`
	);
	assert.ok(
		script.indexOf('APP_COPYRIGHT=') < start,
		'the copyright is resolved before the plist is generated'
	);
	// The embedded engine shows under the application's name: it carries the
	// application's copyright and keeps Hammerspoon's own.
	const assemble = script.slice(script.indexOf('assemble_app() {'));
	assert.match(
		assemble,
		/plutil -replace NSHumanReadableCopyright -string "\$APP_COPYRIGHT Includes Hammerspoon: \$hs_copyright" "\$hs_plist"/
	);
	assert.ok(!/Copyright ©|Copyright \(c\)/.test(script), 'the build must not type a notice');
});

console.log(`[OK] application metadata: ${checks} check(s).`);
