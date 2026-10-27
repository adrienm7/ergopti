// tools/test/test-macos-field-run-contract.cjs

/**
 * ==============================================================================
 * MODULE: macOS Field Run Contract Tests
 * DESCRIPTION:
 * Pins the contract between tools/dev/collect-macos-field-report.sh and the
 * developer app's field run (static/ergopti_plus/macos/infra/field_run.lua),
 * both of which read static/ergopti_plus/macos/data/field_run.json:
 * 1. the declaration: a step for every Debug field check, the person verdicts,
 *    progress-aware AI downloads, and a request deadline that covers every
 *    step at its bound and ends before the collector stops waiting;
 * 2. the collector reads every name it uses from the declaration;
 * 3. the real collector, in a fixture clone with a recording driver, writes a
 *    request of the declared shape, waits for done, copies the results and
 *    records the step, and reports a refusal without losing the other steps.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const { bashExecutable } = require('../lib/git-bash.cjs');

const ROOT = path.resolve(__dirname, '../..');
const SCRIPT = 'tools/dev/collect-macos-field-report.sh';
const SPEC_PATH = 'static/ergopti_plus/macos/data/field_run.json';
const CHECKS_PATH = 'static/ergopti_plus/macos/infra/field_check_checks.lua';
const IDENTIFIERS = 'static/ergopti_plus/_shared/data/identifiers.sh';

if (process.platform === 'win32') {
	console.log('[SKIP] The macOS field report collector is a macOS shell tool; not run on Windows.');
	process.exit(0);
}

const spec = JSON.parse(fs.readFileSync(path.join(ROOT, SPEC_PATH), 'utf8'));
const collector = fs.readFileSync(path.join(ROOT, SCRIPT), 'utf8');
let checks = 0;

/** Runs one named check. */
async function check(name, body) {
	await body();
	checks++;
	console.log(`PASS ${name}`);
}

/** Reads a dotted key of the declaration, as plutil -extract does. */
function specValue(keyPath, document = spec) {
	return keyPath
		.split('.')
		.reduce((value, key) => (value == null ? undefined : value[key]), document);
}

const scratch = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-field-run-')));

/** Writes one executable shim. */
function shim(bin, name, body) {
	fs.writeFileSync(path.join(bin, name), `#!/bin/sh\n${body}\n`, { mode: 0o755 });
}

/** Runs git in a folder and fails on error. */
function git(cwd, ...args) {
	const result = spawnSync('git', args, { cwd, encoding: 'utf8' });
	assert.equal(result.status, 0, `git ${args.join(' ')}: ${result.stderr}`);
	return result.stdout.trim();
}

const GIT_IDENTITY = {
	GIT_AUTHOR_NAME: 'Fixture',
	GIT_AUTHOR_EMAIL: 'fixture@example.invalid',
	GIT_COMMITTER_NAME: 'Fixture',
	GIT_COMMITTER_EMAIL: 'fixture@example.invalid',
	GIT_CONFIG_GLOBAL: '/dev/null',
	GIT_CONFIG_NOSYSTEM: '1'
};

/** Builds a fixture clone on a field branch whose origin holds dev. */
function fixture(name) {
	const base = path.join(scratch, name);
	const clone = path.join(base, 'clone');
	const origin = path.join(base, 'origin.git');
	const bin = path.join(base, 'bin');
	const home = path.join(base, 'home');
	for (const relative of [SCRIPT, SPEC_PATH, IDENTIFIERS]) {
		fs.mkdirSync(path.dirname(path.join(clone, relative)), { recursive: true });
		fs.copyFileSync(path.join(ROOT, relative), path.join(clone, relative));
	}
	// The logs are ignored in the real clone too: the collector adds them with -f
	fs.writeFileSync(path.join(clone, '.gitignore'), '/build/\n*.log\n');
	fs.mkdirSync(bin, { recursive: true });
	fs.mkdirSync(home, { recursive: true });
	const env = { ...process.env, ...GIT_IDENTITY, HOME: home };
	const run = (...args) => {
		const result = spawnSync('git', args, { cwd: clone, encoding: 'utf8', env });
		assert.equal(result.status, 0, `git ${args.join(' ')}: ${result.stderr}`);
	};
	run('init', '-q', '-b', 'dev');
	run('add', '-A');
	run('commit', '-q', '-m', 'fixture');
	spawnSync('git', ['init', '-q', '--bare', origin], { encoding: 'utf8', env });
	run('remote', 'add', 'origin', `file://${origin}`);
	run('push', '-q', 'origin', 'dev');
	run('switch', '-q', '-c', 'field/mac-fixture');
	shim(bin, 'uname', 'echo Darwin');
	// The app is running: the collector must not try to start it
	shim(bin, 'pgrep', 'exit 0');
	const plutil = path.join(bin, 'plutil.cjs');
	fs.writeFileSync(
		plutil,
		`const fs = require('fs');
const [keyPath, file] = [process.argv[2], process.argv[3]];
let value = JSON.parse(fs.readFileSync(file, 'utf8'));
for (const key of keyPath.split('.')) { if (value == null || !(key in Object(value))) process.exit(1); value = value[key]; }
process.stdout.write(typeof value === 'object' ? JSON.stringify(value) : String(value));\n`
	);
	shim(
		bin,
		'plutil',
		`[ "$1" = -extract ] && [ "$3" = raw ] && [ "$4" = -o ] && [ "$5" = - ] || exit 9\nexec "${process.execPath}" "${plutil}" "$2" "$6"`
	);
	return { clone, bin, home, env };
}

/**
 * Starts a recording driver: it publishes readiness with its own live pid,
 * then answers the first request the collector writes.
 */
function startDriver(paths, mode) {
	const folder = path.join(paths.clone, spec.folder);
	fs.mkdirSync(path.join(folder, spec.files.results), { recursive: true });
	const record = path.join(paths.clone, '..', 'request-seen.json');
	const program = `
const fs = require('fs');
const path = require('path');
const [folder, mode, record] = process.argv.slice(1);
const spec = JSON.parse(process.env.FIELD_RUN_SPEC);
fs.writeFileSync(path.join(folder, spec.files.ready), JSON.stringify({ schema: 1, driver: 'macos', pid: process.pid }));
const requestPath = path.join(folder, spec.files.request);
const timer = setInterval(() => {
	if (!fs.existsSync(requestPath)) return;
	const text = fs.readFileSync(requestPath, 'utf8');
	fs.rmSync(requestPath);
	fs.writeFileSync(record, text);
	const request = JSON.parse(text);
	if (mode === 'hang') {
		const dir = path.join(folder, spec.files.results, request.request_id);
		fs.mkdirSync(dir, { recursive: true });
		fs.writeFileSync(path.join(dir, spec.files.accepted), JSON.stringify({ schema: 1, request_id: request.request_id }));
		fs.writeFileSync(path.join(dir, '01_field_lease.json'), JSON.stringify({ schema: 1, step: 'field_lease', verdict: 'pass', codes: [] }));
	} else if (mode === 'refuse') {
		fs.writeFileSync(path.join(folder, spec.files.refused), JSON.stringify({ schema: 1, request_id: request.request_id, reason: 'busy' }));
	} else {
		const dir = path.join(folder, spec.files.results, request.request_id);
		fs.mkdirSync(dir, { recursive: true });
		fs.writeFileSync(path.join(dir, spec.files.accepted), JSON.stringify({ schema: 1, request_id: request.request_id }));
		fs.writeFileSync(path.join(dir, '01_field_lease.json'), JSON.stringify({ schema: 1, step: 'field_lease', verdict: 'pass', codes: [] }));
		fs.writeFileSync(path.join(dir, spec.files.done), JSON.stringify({ schema: 1, request_id: request.request_id, interrupted: false, verdicts: { field_lease: 'pass' } }));
	}
	clearInterval(timer);
	setTimeout(() => process.exit(0), 60000);
}, 100);
`;
	const child = spawn(process.execPath, ['-e', program, folder, mode, record], {
		env: { ...process.env, FIELD_RUN_SPEC: JSON.stringify(spec) },
		stdio: 'ignore'
	});
	const readyPath = path.join(folder, spec.files.ready);
	return { child, record, readyPath };
}

/** Waits until a file exists. */
async function waitFor(file, ms = 10000) {
	const until = Date.now() + ms;
	while (!fs.existsSync(file)) {
		if (Date.now() > until) throw new Error(`${file} never appeared`);
		await new Promise((resolve) => setTimeout(resolve, 50));
	}
}

/**
 * Runs the real collector, without pushing, inside a fixture.
 * @param {object} paths Fixture paths.
 * @param {(child: object) => void} [onStart] Receives the child, in its own process group.
 */
function runCollector(paths, onStart) {
	return new Promise((resolve) => {
		const child = spawn(bashExecutable(), [path.join(paths.clone, SCRIPT), '--no-push'], {
			cwd: paths.clone,
			env: { ...paths.env, PATH: `${paths.bin}${path.delimiter}${process.env.PATH}` },
			detached: Boolean(onStart)
		});
		if (onStart) onStart(child);
		let stdout = '';
		let stderr = '';
		child.stdout.on('data', (chunk) => (stdout += chunk));
		child.stderr.on('data', (chunk) => (stderr += chunk));
		const timer = setTimeout(() => child.kill('SIGKILL'), 90000);
		child.on('close', (status) => {
			clearTimeout(timer);
			resolve({ status, stdout, stderr });
		});
	});
}

/** The single report folder a collector run committed. */
function reportFolder(paths) {
	const reports = path.join(paths.clone, 'docs/field-reports');
	const folders = fs.readdirSync(reports);
	assert.equal(folders.length, 1, `expected one report folder, found ${folders.join(', ')}`);
	return path.join(reports, folders[0]);
}

(async () => {
	try {
		await check('declares a step for every Debug field check and the person verdicts', () => {
			const source = fs.readFileSync(path.join(ROOT, CHECKS_PATH), 'utf8');
			const table = source.match(/M\.checks = \{([^}]*)\}/);
			assert(table, 'field_check_checks.lua has no M.checks table');
			const names = [...table[1].matchAll(/(\w+)\s*=/g)].map((match) => match[1]);
			assert(names.length >= 7, `too few checks parsed: ${names.join(', ')}`);
			const declared = new Set(
				spec.steps.filter((step) => step.kind === 'field_check').map((step) => step.check)
			);
			for (const name of names)
				assert(declared.has(name), `no field run step runs the check ${name}`);
			for (const verdict of ['pass', 'fail', 'skip', 'timeout', 'needs_person', 'needs_typing'])
				assert(spec.verdicts.includes(verdict), `verdict ${verdict} is not declared`);
			for (const step of spec.steps.filter((item) => item.person))
				assert(spec.verdicts.includes(step.person), `${step.id} names an undeclared verdict`);
			for (const id of [
				'diagnostics',
				'ollama_runtime',
				'ollama_model',
				'mlx_runtime',
				'mlx_model'
			])
				assert(
					spec.steps.some((step) => step.id === id),
					`the AI and diagnostics step ${id} is not declared`
				);
		});

		await check(
			'the request deadline covers every step and ends before the collector stops waiting',
			() => {
				const grace = Number(collector.match(/^FIELD_RUN_GRACE_SECONDS=(\d+)$/m)?.[1]);
				assert(grace >= 60 && grace <= 300, `the collector grace is ${grace} s`);
				assert.match(
					collector,
					/\$\(\(now - sent_at\)\) -ge \$\(\(deadline_seconds \+ FIELD_RUN_GRACE_SECONDS\)\)/,
					'the collector must wait for the request deadline it sent plus its grace'
				);
				assert.doesNotMatch(
					collector,
					/FIELD_RUN_DEADLINE_SECONDS/,
					'no second, fixed run deadline'
				);
				const { min, default: fallback, max } = spec.deadline_seconds;
				assert(min <= fallback && fallback <= max, 'deadline_seconds needs min <= default <= max');
				const bounds = spec.steps.reduce(
					(sum, step) => sum + (step.progress_max_seconds ?? step.deadline_seconds),
					0
				);
				assert(
					fallback >= bounds,
					`the default request (${fallback} s) is below the step bounds (${bounds} s)`
				);
				for (const id of ['ollama_runtime', 'ollama_model', 'mlx_runtime', 'mlx_model']) {
					const step = spec.steps.find((item) => item.id === id);
					assert(
						step.progress_max_seconds >= step.deadline_seconds,
						`${id} must be judged by its progress, with a bound`
					);
				}
			}
		);

		await check('the collector reads every name it uses from the declaration', () => {
			const used = [...collector.matchAll(/spec_value ([\w.]+)/g)].map((match) => match[1]);
			for (const key of [
				'folder',
				'files.ready',
				'files.request',
				'files.refused',
				'files.accepted',
				'files.done',
				'files.results',
				'deadline_seconds.default'
			]) {
				assert(used.includes(key), `the collector does not read ${key} from the declaration`);
			}
			for (const key of used) assert(specValue(key) !== undefined, `${key} is not declared`);
			assert.doesNotMatch(
				collector,
				/build\/field-run/,
				'the folder must come from the declaration'
			);
		});

		await check(
			'the collector requests every step, waits for done and copies the results',
			async () => {
				const paths = fixture('done');
				const driver = startDriver(paths, 'done');
				try {
					await waitFor(driver.readyPath);
					const result = await runCollector(paths);
					assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
					const request = JSON.parse(fs.readFileSync(driver.record, 'utf8'));
					assert.deepEqual(Object.keys(request).sort(), [
						'deadline_seconds',
						'request_id',
						'schema',
						'steps'
					]);
					assert.equal(request.schema, spec.schema);
					assert.deepEqual(request.steps, ['all']);
					assert.equal(request.deadline_seconds, spec.deadline_seconds.default);
					assert.match(request.request_id, new RegExp(spec.request_id_pattern));
					const folder = reportFolder(paths);
					const done = JSON.parse(
						fs.readFileSync(path.join(folder, 'field_run', spec.files.done), 'utf8')
					);
					assert.equal(done.request_id, request.request_id);
					assert(fs.existsSync(path.join(folder, 'field_run', '01_field_lease.json')));
					assert.match(
						fs.readFileSync(path.join(folder, 'steps.txt'), 'utf8'),
						/^field_run\s+exit=0$/m
					);
					assert.match(result.stdout, /field run 01_field_lease: pass/);
					const committed = git(paths.clone, 'show', '--name-only', '--format=', 'HEAD');
					assert.match(committed, /field_run\/done\.json/);
				} finally {
					driver.child.kill();
				}
			}
		);

		await check('a refusal is reported and the other steps still run and commit', async () => {
			const paths = fixture('refused');
			const driver = startDriver(paths, 'refuse');
			try {
				await waitFor(driver.readyPath);
				const result = await runCollector(paths);
				assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
				const folder = reportFolder(paths);
				assert.match(
					fs.readFileSync(path.join(folder, 'steps.txt'), 'utf8'),
					/^field_run\s+exit=1$/m
				);
				assert.match(
					fs.readFileSync(path.join(folder, 'field_run_refused.json'), 'utf8'),
					/"reason":"busy"/
				);
				assert.match(fs.readFileSync(path.join(folder, 'steps.txt'), 'utf8'), /^versions\s+exit=/m);
			} finally {
				driver.child.kill();
			}
		});
	} finally {
		fs.rmSync(scratch, { recursive: true, force: true });
	}
	console.log(`[OK] macOS field run contract (${checks} checks).`);
})().catch((error) => {
	console.error(error);
	process.exit(1);
});
