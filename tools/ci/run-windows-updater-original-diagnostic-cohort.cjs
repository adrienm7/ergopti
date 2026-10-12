// tools/ci/run-windows-updater-original-diagnostic-cohort.cjs

// Supplemental candidate receiving; the mandatory native suite remains byte-preserved.
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn, execFileSync } = require('node:child_process');
const { validateAhkSuiteManifest } = require('../test/validate-ahk-suite-manifest.cjs');
const inputs = require('./windows-updater-original-diagnostic-cohort-inputs.json');
const { receiveSdk, requireSameSdk } = require('./windows-updater-sdk-auth.cjs');
const {
	readSourceFile,
	candidateSourceReceipt,
	localInvocation
} = require('./windows-updater-original-source.cjs');
const root = path.resolve(__dirname, '../..');
const sha = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex');
const source = () =>
	Object.fromEntries(
		Object.keys(inputs.source_sha256).map((rel) => [
			rel,
			sha(fs.readFileSync(path.join(root, rel)))
		])
	);
const demand = (ok, message) => {
	if (!ok) throw new Error(message);
};

// This collector records source facts; independent Git/API/artifact receiving
// authenticates them. Neither input JSON nor a digest is a native assertion.
function admittedContext() {
	const value = {
		candidate: process.env.GITHUB_SHA,
		run_id: process.env.GITHUB_RUN_ID,
		run_attempt: process.env.GITHUB_RUN_ATTEMPT,
		architecture: process.arch,
		role: 'candidate'
	};
	demand(/^[0-9a-f]{40}$/.test(value.candidate || ''), 'Candidate SHA refused.');
	demand(/^[1-9][0-9]{0,19}$/.test(value.run_id || ''), 'Run ID refused.');
	demand(/^[1-9][0-9]{0,5}$/.test(value.run_attempt || ''), 'Attempt refused.');
	demand(value.architecture === 'x64', 'Original Windows SDK architecture refused.');
	demand(
		process.env.GITHUB_EVENT_NAME === 'workflow_dispatch' &&
			process.env.ERGOPTI_DEV_RELEASE_RELEASE === 'false',
		'Manual nonrelease receiving required.'
	);
	return value;
}

function invocation() {
	const args = process.argv.slice(2);
	if (args[0] === '--local') return localInvocation(args);
	demand(
		args.length === 2 &&
			args.every((value) => typeof value === 'string' && !value.startsWith('--')),
		'Unknown or mixed original updater invocation mode.'
	);
	return { local: false, arguments: args, context: { ...admittedContext(), context_bound: true } };
}

const budgetMs = 300000; // Supplemental selection + execution only; below the original 1320000 ms maximum.
let directory, primary, receiptError;
const receipt = {
	scope: 'supplemental-original-updater-diagnostics',
	role: 'candidate',
	status: 'UNRUN',
	full_suite_qualified: false,
	feature_qualified: false,
	diagnostic_only: true,
	started_at: new Date().toISOString(),
	budget_ms: budgetMs,
	children: [],
	errors: [],
	cleanup_errors: [],
	cohorts: inputs.cohorts.map((cohort) => ({
		id: cohort.id,
		status: 'UNRUN',
		expected_names: cohort.expected_names
	}))
};

async function child(ahk, args, mode, environment, deadline) {
	const tap = path.join(directory, `${mode}.tap.txt`);
	const stdout = path.join(directory, `${mode}.stdout.txt`);
	const stderr = path.join(directory, `${mode}.stderr.txt`);
	const entry = {
		mode,
		command: [ahk, ...args],
		tap,
		stdout,
		stderr,
		attempted: false,
		started: false,
		disposed: false,
		timeout: false,
		native_exit_code: null,
		signal: null
	};
	receipt.children.push(entry);
	let outFd, errFd, proc, pending, alarm, disposalAlarm;
	try {
		outFd = fs.openSync(stdout, 'wx');
		errFd = fs.openSync(stderr, 'wx');
		entry.attempted = true;
		await new Promise((resolve, reject) => {
			proc = spawn(ahk, args, {
				cwd: root,
				env: { ...environment, ERGOPTI_AHK_RESULTS_FILE: tap },
				stdio: ['ignore', outFd, errFd],
				windowsHide: true,
				shell: false
			});
			proc.once('spawn', () => {
				entry.started = true;
				entry.pid = proc.pid;
			});
			proc.once('error', reject);
			proc.once('close', (code, signal) => {
				entry.disposed = true;
				entry.native_exit_code = code;
				entry.signal = signal;
				entry.ended_at = new Date().toISOString();
				resolve();
			});
			alarm = setTimeout(
				() => {
					entry.timeout = true;
					try {
						entry.kill_acknowledged = proc.kill('SIGKILL');
					} catch (error) {
						entry.kill_error = String(error);
					}
					disposalAlarm = setTimeout(
						() => reject(new Error(`${mode}: native exit not acknowledged after timeout`)),
						30000
					);
				},
				Math.max(1, deadline - Date.now())
			);
		});
	} catch (error) {
		pending = error;
	} finally {
		clearTimeout(alarm);
		clearTimeout(disposalAlarm);
		for (const fd of [outFd, errFd])
			if (fd !== undefined) {
				try {
					fs.closeSync(fd);
				} catch (error) {
					receipt.cleanup_errors.push(String(error));
				}
			}
	}
	if (pending) throw pending;
	demand(entry.disposed, `${mode}: missing native exit receipt`);
	// FileAppend owns an exclusive handle. Never read the canonical TAP before exit.
	for (const name of ['tap', 'stdout', 'stderr']) {
		entry[`${name}_present`] = fs.existsSync(entry[name]);
		if (entry[`${name}_present`]) entry[`${name}_sha256`] = sha(fs.readFileSync(entry[name]));
	}
	return entry.tap_present ? fs.readFileSync(tap, 'utf8') : '';
}

async function main() {
	try {
		const selected = invocation();
		receipt.context = selected.context;
		let destination;
		if (selected.local) {
			receipt.role = 'local';
			receipt.context_bound = false;
			receipt.official_qualified = false;
			receipt.file_version_source = 'caller_provided_local_argument';
			const owner = fs.lstatSync(selected.evidence_root, { bigint: true });
			demand(
				owner.isDirectory() && !owner.isSymbolicLink(),
				'Local evidence requires an existing unaliased directory.'
			);
			destination = fs.mkdtempSync(
				path.join(
					selected.evidence_root,
					`windows-updater-original-diagnostic-local-${receipt.context.candidate}-`
				)
			);
			receipt.evidence_root = {
				path: selected.evidence_root,
				device: String(owner.dev),
				inode: String(owner.ino)
			};
		} else {
			demand(path.isAbsolute(process.env.RUNNER_TEMP || ''), 'RUNNER_TEMP must be absolute.');
			const suffix = `${receipt.context.candidate}-${receipt.context.run_id}-${receipt.context.run_attempt}`;
			destination = path.join(
				process.env.RUNNER_TEMP,
				`windows-updater-original-diagnostic-candidate-${suffix}`
			);
			demand(!fs.existsSync(destination), 'Refusing to reuse prior cohort evidence.');
			fs.mkdirSync(destination);
		}
		directory = destination;
		receipt.output_directory = directory;
		demand(
			inputs.status === 'SEALED_CANDIDATE_SOURCE_PINS',
			'Candidate source pins are not sealed.'
		);
		demand(process.platform === 'win32', 'This cohort requires the genuine Windows AHK SDK.');
		demand(
			selected.local ? process.argv.length === 6 : process.argv.length === 4,
			'Usage: node run-windows-updater-original-diagnostic-cohort.cjs <ahk.exe> <file-version>'
		);
		const ahk = path.resolve(selected.arguments[0]);
		demand(selected.arguments[1].trim() !== '', 'AHK executable FileVersion is unavailable.');
		receipt.ahk = {
			path: ahk,
			file_version: selected.arguments[1],
			file_version_qualified: false,
			file_version_source: 'caller_provided_metadata',
			sha256: readSourceFile(ahk, 134217728).sha256
		};
		receipt.node = {
			path: process.execPath,
			version: process.version,
			sha256: readSourceFile(process.execPath, 134217728).sha256
		};
		receipt.source_receipt_before = candidateSourceReceipt(receipt.context);
		const gitEnv = { ...process.env, GIT_OPTIONAL_LOCKS: '0' };
		receipt.source_commit = execFileSync('git', ['rev-parse', 'HEAD'], {
			cwd: root,
			env: gitEnv,
			encoding: 'utf8'
		}).trim();
		demand(
			receipt.source_commit ===
				(selected.local ? receipt.context.candidate : process.env.GITHUB_SHA),
			'Checkout HEAD differs from the actual CI SHA.'
		);
		receipt.source_before = source();
		demand(
			JSON.stringify(receipt.source_before) === JSON.stringify(inputs.source_sha256),
			'Original source pins changed.'
		);
		receipt.sdk_before = receiveSdk(ahk, selected.arguments[1]);
		const runner = path.join(root, 'static/ergopti_plus/windows/tests/run_all.ahk');
		const deadline = Date.now() + budgetMs;
		requireSameSdk(receipt.sdk_before, receiveSdk(ahk, selected.arguments[1]));
		for (const [cohortIndex, cohort] of inputs.cohorts.entries()) {
			const current = receipt.cohorts[cohortIndex];
			current.status = 'ATTEMPTED';
			const childBase = receipt.children.length;
			const common = ['/ErrorStdOut', runner, `--only=${cohort.filter}`];
			try {
				demand(Date.now() < deadline, 'Shared supplemental budget exhausted before selection.');
				const dry = await child(
					ahk,
					[...common, '--dry-run'],
					`${cohort.id}-selection`,
					process.env,
					deadline
				);
				const selection = receipt.children[childBase];
				demand(
					!selection.timeout && selection.native_exit_code === 0 && selection.signal === null,
					'Native dry selection failed.'
				);
				const plans = [...dry.matchAll(/^1\.\.(\d+)\r?$/gm)];
				demand(
					plans.length === 1 && Number(plans[0][1]) === cohort.expected_names.length,
					'Dry selection differs from frozen prospective plan.'
				);
				demand(
					(dry.match(/^# dry-run - skipping execution\.\r?$/gm) || []).length === 1,
					'Missing genuine dry-run marker.'
				);
				demand(
					!/^(RUNNING |ok |not ok |# duration_ms |# \d+ passed)/m.test(dry),
					'Dry selection unexpectedly executed tests.'
				);
				demand(Date.now() < deadline, 'Shared supplemental budget exhausted before execution.');
				const actual = await child(ahk, common, `${cohort.id}-actual`, process.env, deadline);
				const manifest = validateAhkSuiteManifest(actual);
				fs.writeFileSync(
					path.join(directory, `${cohort.id}-execution-manifest.json`),
					`${JSON.stringify(manifest, null, 2)}\n`,
					{ flag: 'wx' }
				);
				current.manifest = manifest;
				const execution = receipt.children[childBase + 1];
				demand(
					!execution.timeout && execution.native_exit_code === 0 && execution.signal === null,
					'Native cohort refused; partial manifest retained.'
				);
				demand(
					manifest.complete &&
						manifest.planned === cohort.expected_names.length &&
						manifest.executed_count === cohort.expected_names.length &&
						manifest.timed_count === cohort.expected_names.length,
					'Incomplete supplemental execution manifest.'
				);
				demand(
					manifest.passed === cohort.expected_names.length &&
						manifest.failed === 0 &&
						manifest.errors.length === 0,
					'Supplemental native assertions failed.'
				);
				demand(
					JSON.stringify(manifest.executed.map((row) => row.name)) ===
						JSON.stringify(cohort.expected_names),
					'Original labels/order differ from frozen source oracle.'
				);
				demand(
					manifest.executed.every(
						(row, i) =>
							row.index === i + 1 && row.status === 'ok' && Number.isFinite(row.duration_ms)
					),
					'Missing native terminal/timing receipts.'
				);
				current.status = 'PASS';
			} catch (error) {
				current.status = 'FAIL';
				current.error = String(error);
				demand(
					receipt.children.every((entry) => !entry.started || entry.disposed),
					'Native retirement unacknowledged; refusing subsequent cohort overlap.'
				);
			}
		}
		demand(
			receipt.cohorts.every((cohort) => cohort.status === 'PASS'),
			'One or more supplemental cohorts failed; original raw evidence retained.'
		);
		receipt.status = 'PASS';
	} catch (error) {
		primary = error;
		receipt.status = 'FAIL';
		receipt.errors.push(String(error));
	} finally {
		try {
			receipt.source_commit_after = execFileSync('git', ['rev-parse', 'HEAD'], {
				cwd: root,
				env: { ...process.env, GIT_OPTIONAL_LOCKS: '0' },
				encoding: 'utf8'
			}).trim();
			demand(
				receipt.source_commit_after === receipt.context.candidate,
				'Final source HEAD changed.'
			);
			receipt.source_after = source();
			receipt.source_receipt_after = candidateSourceReceipt(receipt.context);
			demand(
				JSON.stringify(receipt.source_receipt_before) ===
					JSON.stringify(receipt.source_receipt_after),
				'Final tracked source receipt changed.'
			);
			demand(
				readSourceFile(receipt.ahk.path, 134217728).sha256 === receipt.ahk.sha256 &&
					readSourceFile(receipt.node.path, 134217728).sha256 === receipt.node.sha256,
				'Native SDK/runtime image changed.'
			);
			demand(
				JSON.stringify(receipt.source_after) === JSON.stringify(inputs.source_sha256),
				'Final source pins changed.'
			);
			receipt.sdk_after = receiveSdk(receipt.ahk.path, receipt.ahk.file_version);
			requireSameSdk(receipt.sdk_before, receipt.sdk_after);
		} catch (error) {
			receipt.cleanup_errors.push(String(error));
		}
		if (receipt.cleanup_errors.length) receipt.status = 'FAIL';
		receipt.native_children_retired = receipt.children.every(
			(entry) => entry.started === false || entry.disposed === true
		);
		if (!receipt.native_children_retired) receipt.status = 'FAIL';
		receipt.ended_at = new Date().toISOString();
		if (directory)
			try {
				fs.writeFileSync(
					path.join(directory, 'RESULT.json'),
					`${JSON.stringify(receipt, null, 2)}\n`,
					{ flag: 'wx' }
				);
			} catch (error) {
				receiptError = error;
			}
	}
	if (primary) {
		console.error(primary);
		if (receiptError) console.error('Receipt failure:', receiptError);
	} else if (receiptError) console.error(receiptError);
	console.log(JSON.stringify(receipt));
	// A failed supplemental probe has its own late workflow verdict. All evidence
	// remains; no process/source/data paths are recursively removed by this helper.
	process.exit(receipt.status === 'PASS' && !receiptError ? 0 : 1);
}
module.exports = { admittedContext, invocation };

if (require.main === module) {
	main().catch((error) => {
		console.error(error);
		process.exit(1);
	});
}
