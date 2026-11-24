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

console.log(`[OK] application metadata: ${checks} check(s).`);
