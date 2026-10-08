// tools/test/test-opensuse-first-install-tooling.cjs

/** Exercise actual first-install prep wiring and closed native capability refusal receipts. */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawnSync } = require('node:child_process');
const { bashExecutable } = require('../lib/git-bash.cjs');
const pipeline = require('./ci-pipeline.cjs');
const root = path.resolve(__dirname, '../..');
const args = process.argv.slice(2);
assert.ok(
	args.length === 0 || (args.length === 2 && ['--workflow', '--producer'].includes(args[0])),
	'closed causal source selector'
);
const workflowPath =
	args[0] === '--workflow' ? args[1] : path.join(root, '.github/workflows/ci-linux.yml');
const producerPath =
	args[0] === '--producer'
		? args[1]
		: path.join(root, 'static/ergopti_plus/linux/tests/distro/e2e_install.sh');
const workflow = fs.readFileSync(workflowPath, 'utf8');
const originPrep =
	"sed -i 's|http://download.opensuse.org|https://downloadcontent.opensuse.org|g' /etc/zypp/repos.d/*.repo";
function wiring(source) {
	const jobs = pipeline
		.jobsOfText(source, '.github/workflows/ci-linux.yml')
		.filter((job) => job.id === 'install-linux');
	assert.equal(jobs.length, 1);
	const job = jobs[0].body;
	const rows = [
		...job.matchAll(
			/          - id: first-install-opensuse-tumbleweed\n((?:            [^\n]*\n)+)/g
		)
	];
	assert.equal(rows.length, 1);
	assert.ok(
		rows[0][1].includes('            prep: ' + originPrep + '\n'),
		'actual openSUSE first-install row must own coherent-origin preparation'
	);
	const step = pipeline.step(job, 'Install on ${{ matrix.image }} and verify the first run');
	assert.match(step, /        env:\n          ERGOPTI_E2E_PREP: \$\{\{ matrix\.prep \|\| '' \}\}/);
	const script = pipeline.runOf(step).join('\n');
	assert.ok(
		script.includes('-e ERGOPTI_E2E_PREP '),
		'Docker must inherit the exact prep environment by name'
	);
	return script;
}
const hostedScript = wiring(workflow);
for (const [label, from, to] of [
	['missing first-row prep', '            prep: ' + originPrep + '\n', ''],
	['missing prep environment', "          ERGOPTI_E2E_PREP: ${{ matrix.prep || '' }}\n", ''],
	['missing Docker environment transfer', '-e ERGOPTI_E2E_PREP ', ''],
	[
		'wrong prep environment',
		"          ERGOPTI_E2E_PREP: ${{ matrix.prep || '' }}",
		"          WRONG_PREP: ${{ matrix.prep || '' }}"
	]
]) {
	assert.equal(workflow.split(from).length, 2, label + ': unique real owner');
	assert.throws(() => wiring(workflow.replace(from, to)), assert.AssertionError, label);
}
const posix = (value) =>
	value.replaceAll('\\', '/').replace(/^([A-Za-z]):/, (_, drive) => '/' + drive.toLowerCase());
const parent = fs.realpathSync(os.tmpdir());
const scratch = fs.mkdtempSync(path.join(parent, 'ergopti-opensuse-first-tooling-'));
let childrenTerminal = true;
const run = (file, env, cwd = root) => {
	const result = spawnSync(bashExecutable(), [posix(file)], {
		cwd,
		env,
		encoding: 'utf8',
		timeout: 20000,
		maxBuffer: 8192
	});
	if (result.error || result.status === null || result.signal !== null) childrenTerminal = false;
	assert.ifError(result.error);
	assert.notEqual(result.status, null);
	assert.equal(result.signal, null);
	return result;
};
try {
	const docker = path.join(scratch, 'docker'),
		dockerArgs = path.join(scratch, 'docker-args'),
		prep = path.join(scratch, 'prep');
	fs.writeFileSync(
		docker,
		'#!/usr/bin/env bash\nprintf "%s\\n" "$@" > "$OWNED_DOCKER_ARGS"\nprintf "%s" "$ERGOPTI_E2E_PREP" > "$OWNED_DOCKER_PREP"\n'
	);
	fs.chmodSync(docker, 0o755);
	const launch = path.join(scratch, 'hosted.sh');
	const expanded = hostedScript
		.replaceAll('${{ matrix.image }}', 'opensuse/tumbleweed:latest')
		.replaceAll("${{ matrix.known || '' }}", '');
	assert.ok(
		!expanded.includes('${{'),
		'all hosted script expressions have exact controlled values'
	);
	fs.writeFileSync(launch, expanded + '\n');
	const env = {
		...process.env,
		PATH: posix(scratch) + ':/usr/bin:/bin',
		ERGOPTI_E2E_PREP: originPrep,
		RUNNER_TEMP: posix(scratch),
		OWNED_DOCKER_ARGS: posix(dockerArgs),
		OWNED_DOCKER_PREP: posix(prep)
	};
	const launched = run(launch, env);
	assert.equal(launched.status, 0, 'actual hosted entry reaches the controlled Docker boundary');
	assert.equal(
		fs.readFileSync(prep, 'utf8'),
		originPrep,
		'prep bytes survive actual host script and unchanged Docker wrapper'
	);
	const actualArgs = fs.readFileSync(dockerArgs, 'utf8').trim().split('\n');
	assert.ok(
		actualArgs.some(
			(value, index) => value === '-e' && actualArgs[index + 1] === 'ERGOPTI_E2E_PREP'
		)
	);
	assert.ok(actualArgs.includes('opensuse/tumbleweed:latest'));
	console.log(
		'Actual first-install host/Docker prep transfer and four adversarial wiring controls: passed.'
	);
	const producer = fs.readFileSync(producerPath, 'utf8');
	const userBoundary =
		"# An ordinary user with passwordless sudo: the installer's documented audience.";
	const toolingBoundary = 'section "Test tooling"';
	for (const boundary of [userBoundary, toolingBoundary])
		assert.equal(producer.split(boundary).length, 2);
	const phase = producer.slice(0, producer.indexOf(userBoundary));
	const functions = phase.slice(0, phase.indexOf(toolingBoundary));
	const wanted = [
		'sudo',
		'curl',
		'python3',
		'python3-gobject',
		'typelib-1_0-Gio-2_0',
		'dbus-1',
		'dbus-1-daemon',
		'xorg-x11-server-Xvfb',
		'procps',
		'shadow'
	];
	const privatePayload =
		'PRIVATE_REQUESTED_TOOLING /private/config https://private.example/token ::error::foreign\n';
	const scenarios = [
		[
			'all requested providers',
			104,
			wanted
				.slice()
				.reverse()
				.map((name) => "No provider of '" + name + "' found.\n")
				.join(''),
			wanted.join(',')
		],
		['unknown private provider', 104, "No provider of '/private/config' found.\n", 'unknown'],
		[
			'split requested token',
			104,
			'x'.repeat(4091) + "No provider of 'python3-gobject' found.\n",
			'python3-gobject'
		],
		['newline separated token', 104, "No provider of 'python3-\ngobject' found.\n", 'unknown'],
		['successful private output', 0, "No provider of 'python3-gobject' found.\n", 'python3-gobject']
	];
	for (const [label, exit, text, missing] of scenarios) {
		const owned = path.join(scratch, label.replaceAll(' ', '-'));
		fs.mkdirSync(owned);
		const files = Object.fromEntries(
			['stdout', 'stderr', 'calls', 'arguments', 'environment', 'phase', 'functions'].map(
				(name) => [name, path.join(owned, name)]
			)
		);
		fs.writeFileSync(files.stdout, text + privatePayload);
		fs.writeFileSync(files.stderr, privatePayload);
		fs.writeFileSync(files.phase, phase);
		fs.writeFileSync(files.functions, functions + '\nprepare_test_tooling\nexit "$?"\n');
		fs.writeFileSync(
			files.environment,
			'PATH="$TOOLING_STUBS:/usr/bin:/bin"\nexport PATH\ncommand() { if [ "$1" = -v ]; then case "$2" in apt-get) return 1;; zypper) return 0;; esac; fi; builtin command "$@"; }\n'
		);
		const zypper = path.join(owned, 'zypper');
		fs.writeFileSync(
			zypper,
			'#!/usr/bin/env bash\nprintf "call\\n" >> "$TOOLING_CALLS"\nprintf "%s\\n" "$@" > "$TOOLING_ARGUMENTS"\ncat "$TOOLING_STDOUT"\ncat "$TOOLING_STDERR" >&2\nexit "$TOOLING_EXIT"\n'
		);
		fs.chmodSync(zypper, 0o755);
		const nativeEnv = {
			...process.env,
			BASH_ENV: posix(files.environment),
			TOOLING_STUBS: posix(owned),
			TOOLING_CALLS: posix(files.calls),
			TOOLING_ARGUMENTS: posix(files.arguments),
			TOOLING_STDOUT: posix(files.stdout),
			TOOLING_STDERR: posix(files.stderr),
			TOOLING_EXIT: String(exit),
			ERGOPTI_E2E_PREP: '',
			ERGOPTI_E2E_EXTRA_CA: '',
			LC_ALL: 'C'
		};
		const observed = run(files.phase, nativeEnv),
			output = observed.stdout + observed.stderr;
		assert.equal(
			observed.status,
			exit === 0 ? 0 : 2,
			label + ': original outer refusal remains strict'
		);
		if (exit) {
			assert.ok(
				output.includes('missing_requested=' + missing + ' native_exit=104'),
				label + ': actual producer must expose only observed requested capability tokens'
			);
			assert.ok(output.includes('ENVIRONMENT: could not install the test tooling'));
			assert.ok(!output.includes('are available for the checks'));
		} else {
			assert.ok(output.includes('are available for the checks'));
			assert.ok(!output.includes('TOOLING:'));
		}
		for (const privateText of [
			'PRIVATE_REQUESTED_TOOLING',
			'/private/config',
			'private.example',
			'::error::'
		])
			assert.ok(!output.includes(privateText), label + ': closed receipt omits private text');
		assert.ok(output.length < 1024);
		assert.equal(fs.readFileSync(files.calls, 'utf8'), 'call\n');
		assert.deepEqual(fs.readFileSync(files.arguments, 'utf8').trim().split('\n'), [
			'--non-interactive',
			'install',
			'-y',
			...wanted
		]);
		fs.writeFileSync(files.calls, '');
		const returned = run(files.functions, nativeEnv);
		assert.equal(returned.status, exit, label + ': actual native return is preserved');
		assert.equal(fs.readFileSync(files.calls, 'utf8'), 'call\n', 'no native retry');
	}
	console.log(
		'Actual producer requested-capability controls: 5 passed; all ten argv tokens, native104, privacy and no-retry preserved.'
	);
} finally {
	assert.equal(path.dirname(scratch), parent);
	if (childrenTerminal) fs.rmSync(scratch, { recursive: true, force: true });
	else console.error('Owned tooling namespace retained: child retirement is unobserved.');
}
