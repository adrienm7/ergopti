// tools/ci/windows-test-replay.cjs

/** Replay a declared native AHK selection in isolated processes and reverse order. */
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const { spawnSync, execFileSync } = require('node:child_process');
const { validateAhkSuiteManifest } = require('../test/validate-ahk-suite-manifest.cjs');
const root = path.resolve(__dirname, '../..');
const runner = path.join(root, 'static/ergopti_plus/windows/tests/run_all.ahk');
const demand = (condition, message) => {
	if (!condition) throw new Error(message);
};
const writeJson = (file, value) => fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
const digest = (file) => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');

function repositoryFile(relative) {
	demand(
		typeof relative === 'string' && !path.isAbsolute(relative) && !path.win32.isAbsolute(relative),
		'selection must be repository-relative'
	);
	const resolved = fs.realpathSync(path.resolve(root, relative));
	demand(
		resolved.startsWith(`${fs.realpathSync(root)}${path.sep}`),
		'selection escapes repository'
	);
	demand(path.extname(resolved) === '.json', 'selection must be JSON');
	return resolved;
}
function parsePlan(source) {
	const rows = source
		.replace(/^\uFEFF/, '')
		.trimEnd()
		.split(/\r?\n/);
	demand(rows.length > 0 && rows[0] !== '', 'native discovery plan is empty');
	return rows.map((line) => {
		const fields = line.split('\t');
		demand(fields.length === 3 && fields.every(Boolean), 'malformed native discovery row');
		const [group, file, name] = fields;
		return { group, file, name };
	});
}
function selectTests(plan, selection) {
	demand(
		Number.isSafeInteger(selection.expected_count) && selection.expected_count > 0,
		'invalid total expected_count'
	);
	demand(
		Array.isArray(selection.filters) && selection.filters.length > 0,
		'selection filters are required'
	);
	const filters = new Set();
	const chosen = new Set();
	for (const entry of selection.filters) {
		demand(typeof entry.contains === 'string' && entry.contains.trim() !== '', 'invalid filter');
		const filter = entry.contains.toLowerCase();
		demand(!filters.has(filter), `duplicate filter: ${filter}`);
		filters.add(filter);
		demand(
			Number.isSafeInteger(entry.expected_count) && entry.expected_count > 0,
			'invalid filter expected_count'
		);
		const matches = plan.filter(({ name }) => name.toLowerCase().includes(filter));
		demand(
			matches.length === entry.expected_count,
			`filter ${filter}: expected ${entry.expected_count}, found ${matches.length}`
		);
		for (const { name } of matches) {
			demand(!chosen.has(name.toLowerCase()), `duplicate or overlapping selection: ${name}`);
			chosen.add(name.toLowerCase());
		}
	}
	const selected = plan.filter(({ name }) => chosen.has(name.toLowerCase()));
	demand(
		selected.length === selection.expected_count,
		'selected total disagrees with expected_count'
	);
	return selected.map(({ name }) => name);
}
function validateExecution(tap, expected) {
	const manifest = validateAhkSuiteManifest(tap);
	demand(
		!/^# dry-run/m.test(tap) && manifest.timed_count === expected.length,
		'execution receipt is dry-run or lacks timings'
	);
	demand(manifest.complete, `incomplete native manifest: ${manifest.errors.join('; ')}`);
	demand(
		manifest.failed === 0 && manifest.passed === expected.length,
		'native test failures or wrong count'
	);
	assert.deepEqual(
		manifest.executed.map(({ name }) => name),
		expected,
		'native manifest names/order differ'
	);
	// The shared validator sorts ordinal slots. Also receive their physical order.
	const sequence = [...tap.matchAll(/^(?:(RUNNING) (\d+)\/\d+ - |(?:ok|not ok) (\d+) - )/gm)].map(
		(match) => `${match[1] ? 'start' : 'end'}:${match[2] || match[3]}`
	);
	assert.deepEqual(
		sequence,
		expected.flatMap((_, index) => [`start:${index + 1}`, `end:${index + 1}`])
	);
	return manifest;
}
async function nativeChild(command, args, context) {
	const descriptors = [];
	try {
		for (const file of [context.stdout, context.stderr]) descriptors.push(fs.openSync(file, 'wx'));
		const result = spawnSync(command, args, {
			cwd: root,
			env: { ...process.env, ERGOPTI_AHK_RESULTS_FILE: context.tap },
			stdio: ['ignore', ...descriptors],
			windowsHide: true,
			shell: false,
			timeout: context.timeout_ms,
			killSignal: 'SIGKILL'
		});
		return {
			native_exit_code: result.status,
			signal: result.signal,
			pid: result.pid,
			timeout: result.error?.code === 'ETIMEDOUT',
			process_error: result.error?.message || null
		};
	} finally {
		for (const descriptor of descriptors) fs.closeSync(descriptor);
	}
}
async function invocation(directory, label, ahk, extra, timeout, children, execute = nativeChild) {
	const entry = { label, started_at: new Date().toISOString(), started_ms: Date.now() };
	demand(!fs.existsSync(path.join(directory, `${label}.receipt.json`)), 'stale invocation receipt');
	children.push(entry);
	const context = Object.fromEntries(
		['tap', 'stdout', 'stderr'].map((kind) => [kind, path.join(directory, `${label}.${kind}.txt`)])
	);
	context.timeout_ms = timeout;
	entry.command = [ahk, '/ErrorStdOut', runner, ...extra];
	const clock = process.hrtime.bigint();
	try {
		for (const file of Object.values(context).filter((value) => typeof value === 'string'))
			demand(!fs.existsSync(file), `stale invocation artifact: ${file}`);
		Object.assign(entry, await execute(ahk, entry.command.slice(1), context));
		demand(
			!entry.process_error && !entry.timeout && entry.native_exit_code === 0 && !entry.signal,
			'native exit receipt failed'
		);
		demand(fs.existsSync(context.tap), 'native TAP receipt missing');
		demand(fs.statSync(context.tap).mtimeMs >= entry.started_ms - 1000, 'stale native TAP receipt');
		entry.status = 'received';
		return { entry, tap: fs.readFileSync(context.tap, 'utf8') };
	} catch (error) {
		entry.status = 'failed';
		entry.error = error.message;
		throw error;
	} finally {
		entry.ended_at = new Date().toISOString();
		entry.duration_ms = Number(process.hrtime.bigint() - clock) / 1e6;
		entry.artifacts = Object.fromEntries(
			Object.entries(context)
				.filter(([, file]) => typeof file === 'string' && fs.existsSync(file))
				.map(([kind, file]) => [
					kind,
					{ path: file, bytes: fs.statSync(file).size, sha256: digest(file) }
				])
		);
		writeJson(path.join(directory, `${label}.receipt.json`), entry);
	}
}
async function replay(options) {
	const selectionPath = repositoryFile(options.selection);
	const selection = JSON.parse(fs.readFileSync(selectionPath, 'utf8'));
	const directory = options.output
		? path.resolve(options.output)
		: fs.mkdtempSync(path.join(os.tmpdir(), 'ahk-replay-'));
	if (options.output) fs.mkdirSync(directory, { recursive: false });
	const sourceSha = execFileSync('git', ['rev-parse', 'HEAD'], {
		cwd: root,
		encoding: 'utf8'
	}).trim();
	const summary = {
		source_sha: sourceSha,
		github_run_id: process.env.GITHUB_RUN_ID || null,
		github_run_attempt: process.env.GITHUB_RUN_ATTEMPT || null,
		selection_path: path.relative(root, selectionPath).split(path.sep).join('/'),
		runner_sha256: digest(runner),
		tool_sha256: digest(__filename),
		started_at: new Date().toISOString(),
		status: 'failed',
		children: [],
		selection_sha256: digest(selectionPath),
		runtime_sha256: digest(options.ahk),
		full_suite_qualified: false
	};
	const deadline = Date.now() + 25 * 60 * 1000;
	const run = async (label, extra, expected) => {
		demand(Date.now() < deadline, 'total replay deadline exceeded');
		const result = await invocation(
			directory,
			label,
			options.ahk,
			extra,
			Math.min(options.timeout, deadline - Date.now()),
			summary.children
		);
		if (expected) {
			try {
				result.entry.manifest = validateAhkSuiteManifest(result.tap);
				validateExecution(result.tap, expected);
				result.entry.status = 'passed';
			} catch (error) {
				result.entry.status = 'failed';
				result.entry.error = error.message;
				throw error;
			} finally {
				writeJson(path.join(directory, `${label}.receipt.json`), result.entry);
			}
		}
		console.log(
			`${label}: native exit 0, ${expected ? `${expected.length} passed` : 'discovery received'}`
		);
		return result;
	};
	try {
		if (process.env.GITHUB_SHA)
			demand(sourceSha === process.env.GITHUB_SHA, 'checkout SHA differs from GITHUB_SHA');
		const planFile = path.join(directory, 'discovery.tsv');
		const discovered = await run('discovery', ['--dry-run', `--dump-plan=${planFile}`]);
		const plan = parsePlan(fs.readFileSync(planFile, 'utf8'));
		const plans = [...discovered.tap.matchAll(/^1\.\.(\d+)\r?$/gm)];
		demand(
			plans.length === 1 &&
				Number(plans[0][1]) === plan.length &&
				discovered.tap.includes('# dry-run - skipping execution.') &&
				!/^RUNNING |^not ok /m.test(discovered.tap),
			'discovery TAP disagrees with native plan'
		);
		const selected = selectTests(plan, selection);
		writeJson(path.join(directory, 'selection.json'), {
			selection,
			selected,
			discovery_sha256: digest(planFile)
		});
		summary.selected_count = selected.length;
		const failures = [];
		for (let index = 0; index < selected.length; index += 1) {
			const list = path.join(directory, `case-${index + 1}.list.txt`);
			fs.writeFileSync(list, `${selected[index]}\n`, { flag: 'wx' });
			try {
				await run(`case-${index + 1}`, [`--list=${list}`], [selected[index]]);
			} catch (error) {
				failures.push(`case-${index + 1}: ${error.message}`);
			}
		}
		const list = path.join(directory, 'reverse.list.txt');
		fs.writeFileSync(list, `${selected.join('\n')}\n`, { flag: 'wx' });
		try {
			await run('reverse', [`--list=${list}`, '--reverse'], [...selected].reverse());
		} catch (error) {
			failures.push(`reverse: ${error.message}`);
		}
		summary.failures = failures;
		demand(failures.length === 0, failures.join('\n'));
		summary.status = 'passed';
	} catch (error) {
		summary.error = error.message;
		throw error;
	} finally {
		summary.ended_at = new Date().toISOString();
		summary.duration_ms = Date.now() - Date.parse(summary.started_at);
		writeJson(path.join(directory, 'summary.json'), summary);
		console.log(`Replay evidence: ${directory}`);
	}
}
async function selfTest() {
	const tap = (names) =>
		`1..${names.length}\n${names.map((name, index) => `RUNNING ${index + 1}/${names.length} - ${name}\nok ${index + 1} - ${name}\n# duration_ms ${index + 1} 0.125\n`).join('')}# ${names.length} passed, 0 failed.\n`;
	const plan = parsePlan('core\tunit/a.ahk\tAlpha (one)\ncore\tunit/b.ahk\tBeta (two)\n');
	const selection = {
		expected_count: 2,
		filters: [
			{ contains: '(one)', expected_count: 1 },
			{ contains: '(two)', expected_count: 1 }
		]
	};
	assert.deepEqual(selectTests(plan, selection), ['Alpha (one)', 'Beta (two)']);
	assert.deepEqual(
		selectTests([...plan, ...parsePlan('core\ta\tUnselected\ncore\tb\tunselected\n')], selection),
		['Alpha (one)', 'Beta (two)']
	);
	for (const filters of [
		[selection.filters[0], selection.filters[0]],
		[{ contains: 'unknown', expected_count: 1 }],
		[
			{ contains: 'Alpha', expected_count: 1 },
			{ contains: '(one)', expected_count: 1 }
		]
	])
		assert.throws(() => selectTests(plan, { ...selection, filters }));
	assert.throws(() =>
		selectTests(parsePlan('core\ta\tAlpha\ncore\tb\talpha\n'), {
			expected_count: 2,
			filters: [{ contains: 'alpha', expected_count: 2 }]
		})
	);
	validateExecution(tap(['Alpha', 'Beta']), ['Alpha', 'Beta']);
	validateExecution(tap(['Beta', 'Alpha']), ['Beta', 'Alpha']);
	const lines = tap(['Alpha', 'Beta']).split('\n');
	const reordered = [lines[0], ...lines.slice(4, 7), ...lines.slice(1, 4), ...lines.slice(7)].join(
		'\n'
	);
	for (const [source, expected] of [
		[tap(['Alpha']), ['Beta']],
		[tap(['Alpha', 'Beta']), ['Beta', 'Alpha']],
		[
			tap(['Alpha'])
				.replace('ok 1', 'not ok 1')
				.replace('# 1 passed, 0 failed.', '# 0 passed, 1 failed.'),
			['Alpha']
		],
		['1..1\nRUNNING 1/1 - Alpha\n', ['Alpha']],
		[tap(['Alpha']).replace('1..1', '1..2'), ['Alpha']],
		[tap(['Alpha']).replace(/^# duration_ms.*\n/gm, ''), ['Alpha']],
		[`# dry-run - skipping execution.\n${tap(['Alpha'])}`, ['Alpha']],
		[reordered, ['Alpha', 'Beta']]
	])
		assert.throws(() => validateExecution(source, expected));
	const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'ahk-replay-selftest-'));
	try {
		const fake = (mode) => async (_, args, context) => {
			fs.writeFileSync(context.stdout, '');
			fs.writeFileSync(context.stderr, '');
			if (mode !== 'missing') fs.writeFileSync(context.tap, tap(['Alpha']));
			if (mode === 'stale') fs.utimesSync(context.tap, 1, 1);
			return {
				native_exit_code: mode === 'exit' ? 1 : 0,
				timeout: mode === 'timeout',
				signal: null
			};
		};
		for (const mode of ['missing', 'stale', 'exit', 'timeout'])
			await assert.rejects(invocation(directory, mode, 'fake-ahk', [], 1000, [], fake(mode)));
		await invocation(directory, 'accepted', 'fake-ahk', [], 1000, [], fake('accepted'));
		await assert.rejects(
			invocation(directory, 'accepted', 'fake-ahk', [], 1000, [], fake('accepted'))
		);
		const context = {
			stdout: path.join(directory, 'node.stdout'),
			stderr: path.join(directory, 'node.stderr'),
			tap: path.join(directory, 'node.tap'),
			timeout_ms: 5000
		};
		const result = await nativeChild(
			process.execPath,
			['-e', 'process.stdout.write("native child receipt")'],
			context
		);
		assert.equal(result.native_exit_code, 0);
		assert.equal(fs.readFileSync(context.stdout, 'utf8'), 'native child receipt');
	} finally {
		fs.rmSync(directory, { recursive: true, force: true });
	}
	console.log('Replay self-tests passed: selection, receipts, ordering, freshness and child exit.');
}
async function main(args) {
	if (args.length === 1 && args[0] === '--self-test') return selfTest();
	const options = { selection: '.github/ci/ahk-replay/windows-fixes.json', timeout: 120000 };
	const seen = new Set();
	for (let index = 0; index < args.length; index += 2) {
		const key = args[index];
		demand(
			['--ahk', '--selection', '--output', '--timeout-ms'].includes(key) &&
				!seen.has(key) &&
				args[index + 1],
			`invalid option: ${key}`
		);
		seen.add(key);
		options[key === '--timeout-ms' ? 'timeout' : key.slice(2)] = args[index + 1];
	}
	options.timeout = Number(options.timeout);
	demand(
		Number.isSafeInteger(options.timeout) && options.timeout > 0 && options.timeout <= 300000,
		'invalid child timeout'
	);
	demand(options.ahk && fs.statSync(options.ahk).isFile(), '--ahk must name an existing runtime');
	await replay(options);
}

module.exports = { parsePlan, validateExecution };

if (require.main === module)
	main(process.argv.slice(2)).catch((error) => {
		console.error(error.stack);
		process.exitCode = 1;
	});
