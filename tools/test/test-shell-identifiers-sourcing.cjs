// tools/test/test-shell-identifiers-sourcing.cjs

/**
 * ==============================================================================
 * MODULE: Shell Identifiers Are Sourced Fail-Fast
 * DESCRIPTION:
 * The build scripts read the application names, bundle ids and hosts from
 * _shared/data/identifiers.sh. This gate keeps that dependency honest:
 * 1. every script that sources the file does so after `set -e`, with no `|| true`
 *    or default that would turn a missing file into an empty value;
 * 2. a script run without the file stops instead of building with blanks;
 * 3. the AppImage build and smoke containers mount the whole checkout, so the
 *    file is there in the container (a container that mounted only part of the
 *    tree would stop at (2), never fall back to a literal).
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const assert = require('node:assert/strict');
const { execFileSync, spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const SOURCE_LINE =
	/^\. "\$(?:REPO_ROOT|PROJECT_ROOT)\/static\/ergopti_plus\/_shared\/data\/identifiers\.sh"$/m;

const scripts = execFileSync('git', ['ls-files', '-z', '--', 'tools', 'static'], {
	cwd: ROOT,
	encoding: 'utf8',
	maxBuffer: 64 * 1024 * 1024
})
	.split('\0')
	.filter((file) => file.endsWith('.sh') && !file.endsWith('identifiers.sh'))
	.filter((file) => fs.readFileSync(path.join(ROOT, file), 'utf8').includes('data/identifiers.sh'));

assert.ok(scripts.length >= 4, `only ${scripts.length} script(s) source identifiers.sh`);

for (const file of scripts) {
	const text = fs.readFileSync(path.join(ROOT, file), 'utf8');
	const match = SOURCE_LINE.exec(text);
	assert.ok(match, `${file}: sources identifiers.sh in an unrecognised way`);
	const before = text.slice(0, match.index);
	assert.match(
		before,
		/^set -[a-z]*e[a-z]*\b/m,
		`${file}: must set -e before sourcing identifiers.sh`
	);
	assert.ok(
		!/identifiers\.sh"\s*(\|\||2>)/.test(text),
		`${file}: the identifiers.sh source must not tolerate failure`
	);

	// Run the script's own source line under `set -e`, with the file absent and present.
	const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-identifiers-'));
	try {
		const prologue = `set -euo pipefail\nREPO_ROOT='${scratch}'\nPROJECT_ROOT='${scratch}'\n${match[0]}\necho REACHED\n`;
		fs.mkdirSync(path.join(scratch, 'tools/build'), { recursive: true });
		const probe = path.join(scratch, 'tools/build/probe.sh');
		fs.writeFileSync(probe, prologue);
		// Control: with the file present the same prologue must run to the end.
		const present = path.join(scratch, 'static/ergopti_plus/_shared/data');
		fs.mkdirSync(present, { recursive: true });
		fs.copyFileSync(
			path.join(ROOT, 'static/ergopti_plus/_shared/data/identifiers.sh'),
			path.join(present, 'identifiers.sh')
		);
		const control = spawnSync('bash', [probe], {
			cwd: scratch,
			env: { PATH: process.env.PATH },
			encoding: 'utf8'
		});
		assert.ok(
			control.stdout.includes('REACHED'),
			`${file}: the source line does not work even with the file: ${control.stderr}`
		);
		fs.rmSync(path.join(scratch, 'static'), { recursive: true, force: true });
		const result = spawnSync('bash', [probe], {
			cwd: scratch,
			env: { PATH: process.env.PATH },
			encoding: 'utf8'
		});
		assert.notEqual(result.status, 0, `${file}: continued after identifiers.sh was missing`);
		assert.ok(!result.stdout.includes('REACHED'), `${file}: ran past the missing identifiers.sh`);
	} finally {
		fs.rmSync(scratch, { recursive: true, force: true });
	}
}

const appimage = fs.readFileSync(path.join(ROOT, 'tools/build/appimage-oldest-lts.sh'), 'utf8');
const mounts = [...appimage.matchAll(/-v "\$PROJECT_ROOT:\/src(:ro)?"/g)];
assert.equal(
	mounts.length,
	2,
	'the AppImage build and smoke containers must mount the whole checkout at /src'
);
assert.ok(/-w \/src/.test(appimage), 'the containers must run from the mounted checkout');

console.log(
	`[OK] ${scripts.length} script(s) source identifiers.sh fail-fast; the AppImage containers mount the checkout.`
);
