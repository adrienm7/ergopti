// tools/test/test-linux-layout-bom-gate.cjs

/**
 * The « Encoding hygiene » job of linux-layout.yml refuses a UTF-8 BOM in any
 * tracked file but AutoHotkey sources and a few declared exceptions. The
 * tap-hold shared-file corpus pins the bytes the Windows writers produce, BOM
 * included, so the job stayed red on dev from the structure move on. The job's
 * own script runs here in a scratch repository: the Windows-written corpus file
 * passes, while a BOM in a Lua module or in a sibling corpus file still fails.
 */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const pipeline = require('./ci-pipeline.cjs');

const REL = '.github/workflows/linux-layout.yml';
const CORPUS = 'static/ergopti_plus/_shared/tests/corpus/tap_hold_shared_file';
const BOM = Buffer.from([0xef, 0xbb, 0xbf]);

const job = pipeline
	.jobsOfText(fs.readFileSync(path.join(pipeline.ROOT, REL), 'utf8'), REL)
	.find((candidate) => candidate.id === 'hygiene');
assert.ok(job, `${REL} has no hygiene job`);
const script = pipeline.runOf(
	pipeline.step(job.body, 'Reject UTF-8 BOM in tracked non-AHK text files')
);
assert.ok(script && script.length > 0, 'the BOM gate has a script');

const real = fs.readFileSync(path.join(pipeline.ROOT, CORPUS, 'windows_written.toml'));
assert.ok(real.subarray(0, 3).equals(BOM), 'the Windows-written corpus file keeps its BOM');

/**
 * Runs the gate over a scratch repository holding the given files.
 * @param {Object<string, Buffer>} files Repository path to content.
 * @returns {{status: number, stdout: string}}
 */
function gate(files) {
	const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-bom-gate-'));
	try {
		const git = (...args) => {
			const run = spawnSync('git', args, { cwd: scratch, encoding: 'utf8' });
			assert.equal(run.status, 0, run.stderr);
		};
		git('init', '-q');
		for (const [rel, content] of Object.entries(files)) {
			fs.mkdirSync(path.dirname(path.join(scratch, rel)), { recursive: true });
			fs.writeFileSync(path.join(scratch, rel), content);
		}
		git('add', '--', ...Object.keys(files));
		const run = spawnSync('/bin/bash', ['-c', script.join('\n')], {
			cwd: scratch,
			encoding: 'utf8'
		});
		return { status: run.status, stdout: run.stdout };
	} finally {
		fs.rmSync(scratch, { recursive: true, force: true });
	}
}

const clean = { 'README.md': Buffer.from('# fixture\n') };
const corpus = { [`${CORPUS}/windows_written.toml`]: real };

assert.equal(gate({ ...clean, ...corpus }).status, 0, 'the Windows-written corpus file passes');

const lua = gate({
	...clean,
	...corpus,
	'mod.lua': Buffer.concat([BOM, Buffer.from('return 1\n')])
});
assert.equal(lua.status, 1, 'a BOM in a Lua module still fails');
assert.match(lua.stdout, /mod\.lua/);

const sibling = gate({
	...corpus,
	[`${CORPUS}/linux_written.toml`]: Buffer.concat([BOM, Buffer.from('[_meta]\n')])
});
assert.equal(sibling.status, 1, 'the exception names one file, not its folder');
assert.match(sibling.stdout, /linux_written\.toml/);

console.log('[OK] Linux layout BOM gate: 3 checks passed.');
