// tools/test/test-app-cloner-run-isolation.cjs

/**
 * ============================================================================
 * MODULE: App Cloner Run Isolation - Source Contract Guard
 * DESCRIPTION:
 * Verifies that each App Cloner run owns a private temporary directory and
 * that result, status, and completion files never use shared /tmp names.
 * ============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SOURCE_PATH = path.join(
	ROOT,
	'static',
	'ergopti_plus',
	'macos',
	'apps',
	'App Cloner.app',
	'Contents',
	'Resources',
	'ShortcutBuilder.applescript'
);
const source = fs.readFileSync(SOURCE_PATH, 'utf8');
const results = [];

function test(name, ok, detail = '') {
	results.push({ name, ok, detail });
}

function count(haystack, needle) {
	return haystack.split(needle).length - 1;
}

function contract(candidate) {
	return {
		privateRoot: candidate.includes('mktemp -d \\"${TMPDIR:-/tmp}/ergopti-appcloner.XXXXXXXX\\"'),
		derivedFiles:
			candidate.includes('set resultPath to runDir & "/result"') &&
			candidate.includes('set statusPath to runDir & "/status"') &&
			candidate.includes('set donePath to runDir & "/done"'),
		quotedBoundaries:
			count(candidate, 'quoted form of resultPath') >= 3 &&
			count(candidate, 'quoted form of statusPath') >= 2 &&
			count(candidate, 'quoted form of donePath') >= 2,
		noSharedSentinels:
			!candidate.includes('/tmp/appcloner_done') && !candidate.includes('/tmp/appcloner_result')
	};
}

const actual = contract(source);
test(
	'each run allocates a private temporary directory under TMPDIR',
	actual.privateRoot,
	JSON.stringify(actual)
);
test(
	'result, status, and completion paths derive from the private directory',
	actual.derivedFiles && actual.quotedBoundaries,
	JSON.stringify(actual)
);
test(
	'shared predictable App Cloner sentinel names are absent',
	actual.noSharedSentinels,
	JSON.stringify(actual)
);

const fixedSentinelMutant = source
	.replace(/quoted form of donePath/g, '"/tmp/appcloner_done"')
	.replace(/quoted form of resultPath/g, '"/tmp/appcloner_result"');
const mutant = contract(fixedSentinelMutant);
test(
	'the guard rejects a regression to fixed cross-run sentinel paths',
	!mutant.noSharedSentinels && !mutant.quotedBoundaries,
	JSON.stringify(mutant)
);

// Execute the actual worker command under a zero file-size limit with the
// default SIGXFSZ disposition. The status write must fail without killing the
// worker, so the completion file still appears and the wizard stops waiting.
function shellQuote(value) {
	return "'" + value.replace(/'/g, "'\\''") + "'";
}
function renderWorker(candidate, paths) {
	const match = /^\tset bgCmd to (.+?)\n\tdo shell script bgCmd$/ms.exec(candidate);
	if (!match) return null;
	return match[1]
		.replace(/¬\s*/g, ' ')
		.split(/\s&\s/)
		.map((piece) => {
			const part = piece.trim();
			const literal = /^"((?:[^"\\]|\\.)*)"$/.exec(part);
			if (literal) return literal[1].replace(/\\(.)/g, '$1');
			if (part === 'cmd') return paths.command;
			const quoted = /^quoted form of (resultPath|statusPath|donePath)$/.exec(part);
			if (quoted) return shellQuote(paths[quoted[1]]);
			throw new Error('unexpected worker command piece: ' + part);
		})
		.join('');
}
function workerCompletes(candidate) {
	const { spawnSync } = require('child_process');
	const os = require('os');
	const runDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-appcloner-worker-'));
	try {
		const paths = {
			command: 'true',
			resultPath: path.join(runDir, 'result'),
			statusPath: path.join(runDir, 'status'),
			donePath: path.join(runDir, 'done')
		};
		const worker = renderWorker(candidate, paths);
		if (!worker) return { completed: false, detail: 'worker command not found' };
		// trap - restores the default disposition the wizard's shell inherits.
		const run = spawnSync('/bin/sh', ['-c', 'trap - XFSZ; ulimit -f 0; ' + worker], {
			encoding: 'utf8',
			timeout: 5000
		});
		const deadline = Date.now() + 5000;
		while (!fs.existsSync(paths.donePath) && Date.now() < deadline)
			spawnSync('/bin/sleep', ['0.05']);
		return {
			completed: fs.existsSync(paths.donePath),
			status: fs.existsSync(paths.statusPath) ? fs.readFileSync(paths.statusPath, 'utf8') : null,
			shell: run.status
		};
	} finally {
		fs.rmSync(runDir, { recursive: true, force: true });
	}
}
if (process.platform !== 'win32') {
	const limited = workerCompletes(source);
	test(
		'the worker publishes completion when a file-size limit refuses its status write',
		limited.completed === true && limited.status === '',
		JSON.stringify(limited)
	);
	const killedMutant = workerCompletes(source.replace('"(trap \'\' XFSZ; " & cmd', '"(" & cmd'));
	test(
		'the guard rejects a worker that SIGXFSZ can kill before completion',
		killedMutant.completed === false,
		JSON.stringify(killedMutant)
	);
}

console.log('TAP version 14');
console.log(`1..${results.length}`);
results.forEach((result, index) => {
	console.log(`${result.ok ? 'ok' : 'not ok'} ${index + 1} - ${result.name}`);
	if (!result.ok && result.detail) console.log(`  # ${result.detail}`);
});
console.log(`# passed: ${results.filter((result) => result.ok).length}/${results.length}`);
if (results.some((result) => !result.ok)) process.exitCode = 1;
