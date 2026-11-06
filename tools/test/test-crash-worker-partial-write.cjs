// tools/test/test-crash-worker-partial-write.cjs

/**
 * Both Windows crash workers must never leave a truncated report under a
 * canonical <timestamp>.json name after a refused write (audit WDG-001).
 */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const VENDOR = path.join(__dirname, '../../static/ergopti_plus/windows/vendor');
const SCRIPT = path.join(__dirname, 'test_crash_worker_partial_write.ps1');
const RUNTIME =
	process.platform === 'win32'
		? path.join(process.env.SystemRoot, 'System32/WindowsPowerShell/v1.0/powershell.exe')
		: 'pwsh';

/** Runs one receiving mode in a fresh private directory and returns its stdout. */
function run(worker, mode) {
	const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-crash-partial-'));
	try {
		const args = [
			'-NoProfile',
			'-NonInteractive',
			'-File',
			SCRIPT,
			'-WorkerSourcePath',
			path.join(VENDOR, worker),
			'-Directory',
			directory,
			'-Mode',
			mode
		];
		// Ignored SIGXFSZ survives exec, so the kernel refuses the write with EFBIG
		// instead of killing the runtime; a 1-2 KiB limit is far below the 16 KiB document.
		const result =
			mode === 'FileSizeLimit'
				? spawnSync('sh', ['-c', 'trap "" XFSZ; ulimit -f 2; exec "$0" "$@"', RUNTIME, ...args], {
						encoding: 'utf8'
					})
				: spawnSync(RUNTIME, args, { encoding: 'utf8', windowsHide: true });
		assert.ifError(result.error);
		assert.equal(result.status, 0, `${worker} ${mode}: ${result.stdout}${result.stderr}`);
		return result.stdout.trim();
	} finally {
		fs.rmSync(directory, { recursive: true, force: true });
	}
}

for (const worker of ['ergopti_crash_worker.ps1', 'ergopti_crash_fallback_worker.ps1']) {
	assert.equal(run(worker, 'Publication'), 'PASS: crash writer publishes only complete reports');
	console.log(`PASS: ${worker} publishes only complete reports`);
	if (process.platform === 'win32') {
		console.log(`SKIP: ${worker} kernel file-size refusal needs a POSIX rlimit.`);
		continue;
	}
	assert.equal(
		run(worker, 'FileSizeLimit'),
		'PASS: kernel-refused crash write left no partial file'
	);
	console.log(`PASS: ${worker} leaves no partial file after a kernel write refusal`);
}
