// Supplemental personal-CI probe; it never changes the mandatory AHK suite.
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn, execFileSync } = require('node:child_process');
const { validateAhkSuiteManifest } = require('../test/validate-ahk-suite-manifest.cjs');
const inputs = require('./windows-key-combination-cohort-inputs.json');
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
const budgetMs = 300000; // Supplemental selection + execution only; below the original 1320000 ms maximum.
let directory, primary, receiptError;
const receipt = {
	scope: 'supplemental-controlled-key-combination-two-cohorts',
	status: 'UNRUN',
	full_suite_qualified: false,
	started_at: new Date().toISOString(),
	budget_ms: budgetMs,
	children: [],
	errors: [],
	cleanup_errors: []
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

// The actual canonical receipt owns acceptance; both output channels are retained.
function receiveCanonical(entry, canonicalText) {
	demand(
		entry.tap_present && entry.stdout_present && entry.stderr_present,
		`${entry.mode}: missing complete output receipts`
	);
	const canonical = fs.readFileSync(entry.tap);
	const stdout = fs.readFileSync(entry.stdout);
	const stderr = fs.readFileSync(entry.stderr);
	demand(
		sha(canonical) === entry.tap_sha256 &&
			sha(stdout) === entry.stdout_sha256 &&
			sha(stderr) === entry.stderr_sha256,
		`${entry.mode}: child output images changed after exit receiving`
	);
	demand(
		canonical.toString('utf8') === canonicalText &&
			Buffer.from(canonicalText, 'utf8').equals(canonical),
		`${entry.mode}: canonical UTF-8 image differs from the retained child result`
	);
	// The genuine framework writes this framing prefix to the disk receipt only.
	demand(
		canonical.length >= 3 && canonical[0] === 239 && canonical[1] === 187 && canonical[2] === 191,
		`${entry.mode}: canonical native UTF-8 framing prefix is missing`
	);
	entry.canonical_framing = 'required-EF-BB-BF';
	entry.stdout_equals_canonical = stdout.equals(canonical.subarray(3));
	entry.stderr_empty = stderr.length === 0;
	demand(
		entry.stdout_equals_canonical,
		`${entry.mode}: complete stdout differs from canonical TAP`
	);
	demand(entry.stderr_empty, `${entry.mode}: stderr is not empty`);
}

// These receivers are also exercised by modeled portable controls; no child is fabricated.
function receiveDrySelection(dry, selection, cohort) {
	demand(
		!selection.timeout && selection.native_exit_code === 0 && selection.signal === null,
		`${cohort.id}: native dry selection failed`
	);
	demand(
		(dry.match(new RegExp(`^1\\.\\.${cohort.planned}\\r?$`, 'gm')) || []).length === 1,
		`${cohort.id}: genuine dry selection count differs`
	);
	demand(
		(dry.match(/^# dry-run - skipping execution\.\r?$/gm) || []).length === 1,
		`${cohort.id}: missing genuine dry-run marker`
	);
	demand(
		!/^(RUNNING |ok |not ok |# duration_ms |# \d+ passed)/m.test(dry),
		`${cohort.id}: dry selection executed subjects`
	);

	// The native dry owner emits one plan, not merely one matching plan among extras.
	demand(
		(dry.match(/^1\.\..*\r?$/gm) || []).length === 1,
		`${cohort.id}: dry selection has additional or malformed plans`
	);
}

function receiveExecution(actual, execution, cohort, manifest) {
	demand(
		!execution.timeout && execution.native_exit_code === 0 && execution.signal === null,
		`${cohort.id}: native process failed; actual partial manifest retained`
	);
	demand(
		manifest.complete &&
			manifest.planned === cohort.planned &&
			manifest.executed_count === cohort.planned &&
			manifest.timed_count === cohort.planned,
		`${cohort.id}: native execution manifest incomplete`
	);
	demand(
		manifest.passed === cohort.planned && manifest.failed === 0 && manifest.errors.length === 0,
		`${cohort.id}: native assertions failed`
	);
	demand(
		JSON.stringify(manifest.executed.map((row) => row.name)) ===
			JSON.stringify(cohort.expected_names),
		`${cohort.id}: actual original names/order differ`
	);
	demand(
		manifest.executed.every(
			(row, index) =>
				row.index === index + 1 && row.status === 'ok' && Number.isFinite(row.duration_ms)
		),
		`${cohort.id}: missing native terminal/timing receipts`
	);

	// The manifest intentionally sorts ordinals; independently retain the raw execution order.
	const cadence = actual
		.replace(/^\uFEFF/, '')
		.split(/\r?\n/)
		.filter((line) =>
			/^(1\.\.|RUNNING |ok |not ok |# duration_ms(?:\s|$)|# \d+ passed)/.test(line)
		);
	const expected = [`1..${cohort.planned}`];
	for (let index = 0; index < cohort.planned; index += 1) {
		expected.push(`RUNNING ${index + 1}/${cohort.planned} - ${cohort.expected_names[index]}`);
		expected.push(`ok ${index + 1} - ${cohort.expected_names[index]}`);
		expected.push(null); // Actual finite timing remains independently validated above.
	}
	expected.push(`# ${cohort.planned} passed, 0 failed.`);
	demand(
		cadence.length === expected.length &&
			expected.every((line, index) =>
				line === null
					? new RegExp(`^# duration_ms ${Math.floor((index - 1) / 3) + 1} \\d+(?:\\.\\d+)?$`).test(
							cadence[index]
						)
					: cadence[index] === line
			),
		`${cohort.id}: raw native plan/start/result/timing/footer order differs`
	);
}

function receiveRetirement(children, cohorts, expectedChildren, plannedTotal) {
	demand(
		cohorts.length === 2 && cohorts.every((entry) => entry.status === 'PASS'),
		'Not every genuine supplemental cohort passed'
	);
	demand(
		children.length === expectedChildren &&
			children.every(
				(entry) =>
					entry.started &&
					entry.disposed &&
					!entry.timeout &&
					entry.native_exit_code === 0 &&
					entry.signal === null
			),
		'Incomplete four-child controlled selection/execution accounting'
	);
	demand(
		cohorts.reduce((total, entry) => total + entry.manifest.executed_count, 0) === plannedTotal,
		'Actual complete aggregate differs from 28 registered subjects'
	);
}

function receiveSourcePins(actual, expected, message) {
	demand(JSON.stringify(actual) === JSON.stringify(expected), message);
}

function receiveHead(actual, expected, message) {
	demand(actual === expected, message);
}

// Receive only the existing successful publisher's retained images. This does
// not invoke --identity, rebuild, authenticate a new binary, or allocate a child.
function receivePublishedPac(checkout, sourcePins, producerOutcome) {
	demand(producerOutcome === 'success', 'Original native PAC publisher did not succeed.');
	const read = (relative) => {
		let target = checkout;
		for (const piece of relative.split('/')) {
			demand(piece !== '' && piece !== '.' && piece !== '..', 'Unsafe PAC receipt path.');
			target = path.join(target, piece);
			demand(!fs.lstatSync(target).isSymbolicLink(), 'PAC receipt/source symlink refused.');
		}
		demand(fs.lstatSync(target).isFile(), 'PAC receipt/source must be regular.');
		return fs.readFileSync(target);
	};
	const vendor = 'static/ergopti_plus/windows/vendor/ergopti_network_pac';
	const build = 'static/ergopti_plus/windows/build/native/network_pac/';
	const captured = {};
	const image = (relative) => {
		const bytes = read(relative);
		captured[relative] = sha(bytes);
		return bytes;
	};
	const artifactBytes = image(`${build}artifact_receipt.json`);
	const vendorBytes = image(`${vendor}.json`);
	demand(
		vendorBytes.equals(artifactBytes),
		'Published PAC JSON differs from original artifact receipt.'
	);
	const artifact = JSON.parse(artifactBytes.toString('utf8'));
	const prepared = JSON.parse(image(`${build}prepared/source_receipt.json`).toString('utf8'));
	const exe = image(`${vendor}.exe`);
	const license = image(`${vendor}.LICENSE.txt`);
	demand(
		artifact.schema_version === 1 && prepared.schema_version === 1,
		'Original PAC receipt schema refused.'
	);
	demand(
		artifact.exe_sha256 === sha(exe),
		'Published PAC executable differs from original artifact receipt.'
	);
	demand(
		artifact.license_sha256 === sha(license),
		'Published PAC license differs from original artifact receipt.'
	);
	demand(
		/^[0-9a-f]{64}$/.test(artifact.source_fingerprint) &&
			artifact.source_fingerprint === prepared.source_fingerprint,
		'Original PAC source fingerprint differs.'
	);
	const sourceFiles = [
		'static/ergopti_plus/_shared/data/linux_native_runtime.json',
		'static/ergopti_plus/_shared/modules/network/proxy_policy.json',
		'static/ergopti_plus/_shared/modules/updater/defaults.json',
		'static/ergopti_plus/_shared/modules/network/pac_helpers.js',
		'static/ergopti_plus/_shared/native/network/pac_runtime.c',
		'static/ergopti_plus/_shared/native/network/pac_runtime.h',
		'static/ergopti_plus/windows/native/ergopti_network_pac_platform.c',
		'static/ergopti_plus/windows/native/ergopti_network_pac_platform.h',
		'static/ergopti_plus/windows/native/ergopti_network_pac.c',
		'tools/build/build_windows_nav_owner.ps1',
		'tools/build/build_windows_network_pac.ps1',
		'tools/build/prepare_network_pac_sources.py'
	];
	demand(
		JSON.stringify(prepared.inputs) === JSON.stringify(sourceFiles),
		'Original PAC source input roster differs.'
	);
	for (const relative of sourceFiles) {
		demand(
			Object.hasOwn(sourcePins, relative) &&
				/^[0-9a-f]{64}$/.test(sourcePins[relative]) &&
				sha(read(relative)) === sourcePins[relative],
			'PAC source is absent from or differs from received Git closure.'
		);
	}
	const catalog = JSON.parse(read(sourceFiles[0]).toString('utf8'));
	const archive = catalog.network_runtime.portable.flatpak_sources.duktape.sha256;
	demand(
		/^[0-9a-f]{64}$/.test(archive) &&
			artifact.duktape_archive_sha256 === archive &&
			prepared.duktape_archive_sha256 === archive,
		'Original PAC archive differs from canonical Duktape pin.'
	);
	return captured;
}

async function main() {
	// Reserve the inherited 30-second native exit acknowledgement inside five minutes.
	const deadline = Date.now() + budgetMs - 30000;
	try {
		demand(path.isAbsolute(process.env.RUNNER_TEMP || ''), 'RUNNER_TEMP must be absolute.');
		const destination = path.join(process.env.RUNNER_TEMP, 'windows-key-combination-two');
		demand(!fs.existsSync(destination), 'Refusing to reuse prior cohort evidence.');
		fs.mkdirSync(destination);
		directory = destination;
		receipt.output_directory = directory;
		demand(process.platform === 'win32', 'This cohort requires the genuine Windows AHK SDK.');
		demand(
			process.argv.length === 4,
			'Usage: node run-windows-key-combination-cohorts.cjs <ahk.exe> <file-version>'
		);
		const ahk = path.resolve(process.argv[2]);
		demand(process.argv[3].trim() !== '', 'AHK executable FileVersion is unavailable.');
		receipt.ahk = { path: ahk, file_version: process.argv[3], sha256: sha(fs.readFileSync(ahk)) };
		demand(process.env.GITHUB_ACTIONS === 'true', 'Actual hosted CI metadata is required.');
		demand(/^[1-9][0-9]*$/.test(process.env.GITHUB_RUN_ID || ''), 'Actual CI run ID is missing.');
		demand(
			/^[1-9][0-9]*$/.test(process.env.GITHUB_RUN_ATTEMPT || ''),
			'Actual CI attempt is missing.'
		);
		demand(
			Boolean(
				process.env.GITHUB_REPOSITORY && process.env.GITHUB_WORKFLOW && process.env.GITHUB_REF
			),
			'Actual CI source/workflow metadata is missing.'
		);
		receipt.ci_environment = {
			repository: process.env.GITHUB_REPOSITORY,
			run_id: process.env.GITHUB_RUN_ID,
			attempt: process.env.GITHUB_RUN_ATTEMPT,
			workflow: process.env.GITHUB_WORKFLOW,
			ref: process.env.GITHUB_REF,
			head_sha: process.env.GITHUB_SHA,
			authority: 'hosted environment; independent API receiving still required'
		};
		const gitEnv = { ...process.env, GIT_OPTIONAL_LOCKS: '0' };
		receipt.source_commit = execFileSync('git', ['rev-parse', 'HEAD'], {
			cwd: root,
			env: gitEnv,
			encoding: 'utf8'
		}).trim();
		receiveHead(
			receipt.source_commit,
			process.env.GITHUB_SHA,
			'Checkout HEAD differs from the actual CI SHA.'
		);
		receipt.source_before = source();
		receiveSourcePins(receipt.source_before, inputs.source_sha256, 'Original source pins changed.');
		receipt.native_pac_build_outcome = process.env.ERGOPTI_WINDOWS_NATIVE_PAC_BUILD_OUTCOME;
		receipt.pac_before = receivePublishedPac(
			root,
			inputs.source_sha256,
			receipt.native_pac_build_outcome
		);
		receipt.cohorts = inputs.cohorts.map((cohort) => ({
			id: cohort.id,
			planned: cohort.planned,
			expected_names: cohort.expected_names,
			status: 'UNRUN',
			errors: []
		}));
		for (let at = 0; at < inputs.cohorts.length; at += 1) {
			const cohort = inputs.cohorts[at],
				result = receipt.cohorts[at];
			try {
				demand(
					Date.now() < deadline,
					`${cohort.id}: supplemental budget exhausted before allocation`
				);
				demand(
					receipt.children.every((entry) => !entry.started || entry.disposed),
					'Prior native child has no actual exit receipt; refusing overlap'
				);
				const common = ['/ErrorStdOut', path.join(root, cohort.runner)];
				if (cohort.filter !== null) common.push(`--only=${cohort.filter}`);
				if (cohort.dry_selection) {
					const dry = await child(
						ahk,
						[...common, '--dry-run'],
						`${cohort.id}-selection`,
						process.env,
						deadline
					);
					const selection = receipt.children[receipt.children.length - 1];
					receiveCanonical(selection, dry);
					receiveDrySelection(dry, selection, cohort);
				}
				demand(Date.now() < deadline, `${cohort.id}: budget exhausted after dry selection`);
				const actual = await child(ahk, common, `${cohort.id}-actual`, process.env, deadline);
				const execution = receipt.children[receipt.children.length - 1];
				receiveCanonical(execution, actual);
				const manifest = validateAhkSuiteManifest(actual);
				fs.writeFileSync(
					path.join(directory, `${cohort.id}-execution-manifest.json`),
					`${JSON.stringify(manifest, null, 2)}\n`,
					{ flag: 'wx' }
				);
				result.manifest = manifest;
				receiveExecution(actual, execution, cohort, manifest);
				result.status = 'PASS';
			} catch (error) {
				if (!primary) primary = error;
				result.status = 'FAIL';
				result.errors.push(String(error));
				receipt.errors.push(`${cohort.id}: ${String(error)}`);
			}
		}
		receiveRetirement(
			receipt.children,
			receipt.cohorts,
			inputs.expected_children,
			inputs.planned_total
		);
		receipt.status = 'PASS';
	} catch (error) {
		if (!primary) primary = error;
		receipt.status = 'FAIL';
		receipt.errors.push(String(error));
	} finally {
		try {
			receipt.source_after = source();
			receipt.source_commit_after = execFileSync('git', ['rev-parse', 'HEAD'], {
				cwd: root,
				env: { ...process.env, GIT_OPTIONAL_LOCKS: '0' },
				encoding: 'utf8'
			}).trim();
			receiveHead(
				receipt.source_commit_after,
				receipt.source_commit,
				'Final Git source identity changed.'
			);
			receiveSourcePins(receipt.source_after, inputs.source_sha256, 'Final source pins changed.');
			if (receipt.pac_before) {
				receipt.pac_after = receivePublishedPac(
					root,
					inputs.source_sha256,
					process.env.ERGOPTI_WINDOWS_NATIVE_PAC_BUILD_OUTCOME
				);
				receiveSourcePins(
					receipt.pac_after,
					receipt.pac_before,
					'Final published PAC images/receipts changed.'
				);
			}
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
main().catch((error) => {
	console.error(error);
	process.exit(1);
});
