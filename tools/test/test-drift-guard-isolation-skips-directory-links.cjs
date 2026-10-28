// tools/test/test-drift-guard-isolation-skips-directory-links.cjs

/**
 * ==============================================================================
 * MODULE: Drift Guard Isolation Ignores Directory Links
 * DESCRIPTION:
 * `runIsolatedCoverage` copies `git ls-files --cached --others` into a private
 * tree. An untracked symlink to a directory (a worktree's `node_modules`) is
 * listed as a file and used to abort the copy with EISDIR.
 *
 * FEATURES & RATIONALE:
 * 1. A symlink to a directory is skipped, never followed or copied.
 * 2. A symlink to a file is recreated as a link.
 * 3. Regular files still arrive byte for byte.
 * ==============================================================================
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { runIsolatedCoverage } = require('./test-drift-guard-covers-every-output.cjs');

const ROOT = path.resolve(__dirname, '..', '..');

const scratch = fs.mkdtempSync(path.join(ROOT, 'tmp-drift-link-'));
const rel = (name) => path.relative(ROOT, path.join(scratch, name)).split(path.sep).join('/');

try {
	const outside = fs.mkdtempSync(path.join(os.tmpdir(), 'drift-link-target-'));
	fs.writeFileSync(path.join(outside, 'inside.txt'), 'must not be copied\n');
	fs.symlinkSync(
		outside,
		path.join(scratch, 'dir_link'),
		process.platform === 'win32' ? 'junction' : 'dir'
	);
	fs.writeFileSync(path.join(scratch, 'real.txt'), 'real bytes\n');
	fs.symlinkSync('real.txt', path.join(scratch, 'file_link'));

	let seen;
	runIsolatedCoverage({
		files: [rel('dir_link'), rel('real.txt'), rel('file_link')],
		probe: ({ root }) => {
			const base = path.join(root, rel('x')).replace(/x$/, '');
			seen = {
				dirLink: fs.existsSync(path.join(base, 'dir_link')),
				real: fs.readFileSync(path.join(base, 'real.txt'), 'utf8'),
				fileLink: fs.lstatSync(path.join(base, 'file_link')).isSymbolicLink()
			};
			return [];
		}
	});
	fs.rmSync(outside, { recursive: true, force: true });
	assert.strictEqual(seen.dirLink, false, 'a directory link must not be copied or followed');
	assert.strictEqual(seen.real, 'real bytes\n');
	assert.strictEqual(seen.fileLink, true, 'a file link stays a link');
	console.log('[OK] drift-guard isolation skips directory links and keeps file links.');
} finally {
	fs.rmSync(scratch, { recursive: true, force: true });
}
