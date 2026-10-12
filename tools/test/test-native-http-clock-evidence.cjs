'use strict';
if (process.platform === 'win32') {
	process.stdout.write(
		'CLOCK_RECEIVER controls=32 SKIPPED reason=POSIX_file_modes_and_process_owners_unavailable native=false official=false\n'
	);
	process.exit(0);
}
// Independently authored protocol values. No compiler, codesign, Darwin or
// authenticated GitHub API operation is executed by these portable controls.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const { bashExecutable } = require('../lib/git-bash.cjs');
const evidence = require('../ci/native_http_clock_evidence.cjs');
const hash = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex');
const SWIFT = [
	'static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/ManagedHTTPWorker.swift',
	'static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/ManagedPACSource.swift',
	'static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/ManagedCertificateAuthorities.swift',
	'static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/ManagedBootstrapPolicy.generated.swift',
	'static/ergopti_plus/macos/tests/support/native_http_fixture_main.swift'
];
const HEADERS = [
	'static/ergopti_plus/macos/launcher/Sources/CPOSIXCompatibility/include/CPOSIXCompatibility.h',
	'static/ergopti_plus/macos/launcher/Sources/CPOSIXCompatibility/include/OwnedProgramCompatibility.h',
	'static/ergopti_plus/macos/launcher/Sources/CPOSIXCompatibility/include/LoopbackListenerCompatibility.h',
	'static/ergopti_plus/macos/launcher/Sources/CPOSIXCompatibility/include/OwnedImageAliasCompatibility.h',
	'static/ergopti_plus/macos/launcher/Sources/CPOSIXCompatibility/include/OwnedSuspendedImageCompatibility.h',
	'static/ergopti_plus/macos/launcher/Sources/CPOSIXCompatibility/include/OwnedListenerEventCompatibility.h'
];
const RUNTIME = [
	'static/ergopti_plus/macos/platform/network/native_http.py',
	'static/ergopti_plus/macos/platform/network/managed_http.py',
	'static/ergopti_plus/_shared/python/network_proxy_policy.py',
	'static/ergopti_plus/_shared/modules/network/proxy_policy.json'
];
const OWNERS = [
	'static/ergopti_plus/macos/tests/support/native_http_fixture_builder.py',
	'static/ergopti_plus/macos/tests/support/native_http_wire_fixture.py',
	'tools/diagnostics/macos_owned_process.py'
];
const RECEIVER = 'static/ergopti_plus/macos/tests/support/native_http_wire_client_receiving.py';
const INPUTS = [...SWIFT, ...HEADERS, ...RUNTIME, ...OWNERS, RECEIVER];
const temporary = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), 'ergopti-clock-receive-'));
let received = 0;
function control(name, body) {
	body();
	received++;
	process.stdout.write('PASS ' + name + '\n');
}
function modeledPayload() {
	const root = fs.mkdtempSync(path.join(temporary, 'payload-'));
	const sources = Object.fromEntries(
		INPUTS.map((relative, index) => [
			relative,
			hash(Buffer.from('independent source vector ' + index))
		])
	);
	const source = {
		candidate: 'a'.repeat(40),
		run_id: '123',
		run_attempt: '2',
		architecture: 'arm64',
		sources,
		private_cache: { device: 7, inode: 29, empty: true }
	};
	const sourceHashes = Object.fromEntries(
		INPUTS.slice(0, 18).map((relative) => [relative, sources[relative]])
	);
	const staged = Object.fromEntries([
		...SWIFT.map((relative) => [path.posix.basename(relative), sources[relative]]),
		...HEADERS.map((relative) => [
			'CPOSIXCompatibility/' + path.posix.basename(relative),
			sources[relative]
		]),
		...RUNTIME.map((relative) => [
			'OwnedNativeHTTPFixture.app/Contents/Resources/' + relative,
			sources[relative]
		]),
		[
			'CPOSIXCompatibility/module.modulemap',
			hash(
				Buffer.from(
					'module CPOSIXCompatibility {\n  umbrella header "CPOSIXCompatibility.h"\n  export *\n}\n'
				)
			)
		]
	]);
	const image = Buffer.alloc(32);
	image.writeUInt32LE(0xfeedfacf, 0);
	image.writeUInt32LE(0x0100000c, 4);
	const original = {
		version: 1,
		source_hashes: sourceHashes,
		staged_hashes: staged,
		binary_sha256: hash(image),
		device: 7,
		inode: 23
	};
	const originalBytes = Buffer.from(JSON.stringify(original));
	const samples = Array.from({ length: 16 }, (_, i) => 50.125 + i / 128);
	const raw = Buffer.from(JSON.stringify({ version: 1, system_uptime: samples }) + '\n');
	const clock = {
		version: 1,
		state: 'observed',
		native_acceptance: 'UNQUALIFIED_GIT_HEAD_CLEANLINESS_NOT_RECEIVED',
		git_head: null,
		tracked_clean_sources: null,
		epoch: {
			candidate: source.candidate,
			run_id: '123',
			run_attempt: '2',
			architecture: 'arm64',
			provenance: 'github_environment'
		},
		context_bound: true,
		python_before: 50,
		python_after: 51,
		system_uptime: samples,
		source_receipt_sha256: hash(originalBytes),
		source_hashes: sourceHashes,
		staged_hashes: staged,
		receiver_sha256: sources[RECEIVER],
		binary_sha256: hash(image),
		device: 7,
		inode: 23,
		architecture: 'arm64',
		signature: 'existing_build_codesign_strict_verified_same_image'
	};
	const fact = {
		version: 1,
		command: { phase: 'complete', status: 0 },
		exit_status: 0,
		original_failed: false,
		literal_true_settlement: true,
		stdin_closed: true,
		stderr_closed: true,
		stdout_closed: true,
		command_group_debt: false,
		command_file_debt: false,
		owner: {
			worker_pid: 321,
			group_id: 321,
			closed: true,
			reservation_lost: false,
			signals: [],
			live_group_members: [],
			escaped_sessions_managed: false
		}
	};
	const write = (name, value) =>
		fs.writeFileSync(
			path.join(root, name),
			Buffer.isBuffer(value) ? value : JSON.stringify(value),
			{ mode: 0o600 }
		);
	for (const role of ['compile', 'sign', 'strict_verify', 'clock']) write(role + '.json', fact);
	write('clock-frame.bin', raw);
	write('image.bin', image);
	write('source-receipt.json', originalBytes);
	write('clock-receipt.json', clock);
	write('python-loader.json', {
		version: 1,
		isolated: 1,
		ignore_environment: 1,
		no_user_site: 1,
		dont_write_bytecode: true,
		safe_path: true,
		cache_empty: true,
		cache_device: 7,
		cache_inode: 29
	});
	return { root, source, original, clock, fact, write };
}
const { execFileSync } = require('node:child_process');
const repository = path.resolve(__dirname, '../..');
function git(root, args) {
	return execFileSync('git', ['-c', 'core.hooksPath=/dev/null', ...args], {
		cwd: root,
		stdio: 'pipe'
	});
}
function sourceFixture(change = () => {}) {
	const root = fs.mkdtempSync(path.join(temporary, 'source-'));
	const roots = [
		'static/ergopti_plus/macos/launcher',
		'static/ergopti_plus/macos/adapters/release_stage.sh',
		'static/ergopti_plus/_shared/modules/updater/defaults.json',
		'tools/build',
		'tools/diagnostics'
	];
	const original = execFileSync('git', ['ls-files', '-z', '--', ...roots], {
		cwd: repository,
		stdio: 'pipe'
	})
		.toString()
		.split('\0')
		.filter(Boolean);
	const files = new Set([
		...original,
		...INPUTS,
		...evidence.LOADERS,
		'static/ergopti_plus/macos/tests/support/native_pac_source_fixture.py'
	]);
	for (const relative of files) {
		const destination = path.join(root, relative);
		fs.mkdirSync(path.dirname(destination), { recursive: true });
		fs.copyFileSync(path.join(repository, relative), destination);
	}
	fs.writeFileSync(
		path.join(root, 'outside-source.txt'),
		'independent tracked cleanliness sentinel'
	);
	change(root);
	git(root, ['init', '-q']);
	git(root, ['config', 'user.name', 'Portable receiving']);
	git(root, ['config', 'user.email', 'portable@example.invalid']);
	git(root, ['add', '--all']);
	git(root, ['commit', '-qm', 'Independent clock source control']);
	const candidate = git(root, ['rev-parse', 'HEAD']).toString().trim();
	return {
		root,
		epoch: {
			candidate,
			run_id: '123',
			run_attempt: '2',
			architecture: 'arm64'
		}
	};
}
function mutation(name, body) {
	control(name, () => {
		const vector = modeledPayload();
		body(vector);
		assert.throws(() => evidence.payloadReceipt(vector.root, vector.source));
	});
}
function selectorShape(node) {
	if (Array.isArray(node)) return node.map(selectorShape);
	if (node !== null && typeof node === 'object')
		return Object.fromEntries(
			Object.entries(node)
				.filter(([key]) => !['start', 'end', 'raw'].includes(key))
				.map(([key, value]) => [key, selectorShape(value)])
		);
	return node;
}
function assertSelectors(text) {
	const acorn = require('acorn'),
		ast = acorn.parse(text, { ecmaVersion: 'latest' });
	const expected = acorn.parse("process.platform !== 'win32'", { ecmaVersion: 'latest' }).body[0]
		.expression;
	const blocks = ast.body.filter(
		(node) =>
			node.type === 'IfStatement' &&
			JSON.stringify(selectorShape(node.test)) === JSON.stringify(selectorShape(expected))
	);
	assert.equal(blocks.length, 1, 'Fixed POSIX owning selector must exist exactly once.');
	const statements = blocks[0].consequent.body;
	for (const template of [
		"cases.push(['tools/test/macos_native_http_receiving_facts_test.py',165]);",
		"cases.push(['tools/test/macos_native_http_clock_passive_receiving_controls.py',21]);"
	]) {
		const expectedStatement = selectorShape(
			acorn.parse(template, { ecmaVersion: 'latest' }).body[0]
		);
		assert.equal(
			statements.filter(
				(node) => JSON.stringify(selectorShape(node)) === JSON.stringify(expectedStatement)
			).length,
			1,
			'Fixed owning Python selector/census must be retained.'
		);
	}
	const declarations = statements
		.filter((node) => node.type === 'VariableDeclaration')
		.flatMap((node) => node.declarations)
		.filter((node) => node.id.name === 'clockResult');
	assert.equal(declarations.length, 1);
	const call = declarations[0].init;
	assert.equal(call.type, 'CallExpression');
	assert.equal(call.callee.name, 'spawnSync');
	const expectedCall = acorn.parse(
		"spawnSync(process.execPath,[path.join(__dirname,'test-native-http-clock-evidence.cjs')])",
		{ ecmaVersion: 'latest' }
	).body[0].expression;
	assert.deepEqual(
		selectorShape(call.arguments.slice(0, 2)),
		selectorShape(expectedCall.arguments)
	);
	const expectedAssert = acorn.parse('assert.equal(clockResult.status,0)', {
		ecmaVersion: 'latest'
	}).body[0].expression;
	assert.equal(
		statements.filter(
			(node) =>
				node.type === 'ExpressionStatement' &&
				node.expression.type === 'CallExpression' &&
				JSON.stringify(selectorShape(node.expression.callee)) ===
					JSON.stringify(selectorShape(expectedAssert.callee)) &&
				JSON.stringify(selectorShape(node.expression.arguments.slice(0, 2))) ===
					JSON.stringify(selectorShape(expectedAssert.arguments))
		).length,
		1
	);
	const matches = statements.filter(
		(node) =>
			node.type === 'ExpressionStatement' &&
			node.expression.type === 'CallExpression' &&
			node.expression.callee.object?.name === 'assert' &&
			node.expression.callee.property?.name === 'match' &&
			node.expression.arguments[0]?.object?.name === 'clockResult'
	);
	assert.equal(matches.length, 1);
	assert.equal(
		matches[0].expression.arguments[1].regex.pattern,
		'^CLOCK_RECEIVER controls=32 native=false official=false$'
	);
}
function fixedClockStatusProgram(argument) {
	let result = '',
		cursor = 0;
	while (cursor < argument.length) {
		const newline = "$'\\n'",
			apostrophe = '"\'"';
		if (argument.startsWith(newline, cursor)) {
			result += '\n';
			cursor += newline.length;
		} else if (argument.startsWith(apostrophe, cursor)) {
			result += "'";
			cursor += apostrophe.length;
		} else {
			assert.equal(argument[cursor], "'", 'Only fixed literal clock-program segments are allowed.');
			const end = argument.indexOf("'", cursor + 1);
			assert.ok(end > cursor, 'Fixed program literal must terminate.');
			result += argument.slice(cursor + 1, end);
			cursor = end + 1;
		}
	}
	return result;
}
const ORIGINAL_CLOCK_STATUS_PROGRAM =
	"    const fs = require('node:fs');\n    const args = process.argv.slice(2);\n    if (args.length !== 7 || args.slice(1).some(value => !/^(?:0|[1-9][0-9]{0,2})$/.test(value) || Number(value) > 255)) process.exit(1);\n    fs.writeFileSync(args[0], JSON.stringify({schema:1, owned_process:{command:Number(args[1]),capture:Number(args[2])},public_native:{command:Number(args[3]),capture:Number(args[4])},independent_client:{command:Number(args[5]),capture:Number(args[6])}}) + '\\n', {flag:'wx',mode:0o600});\n";
function workflowDisposition(body, mode, commandStatus = 0, captureStatus = 0) {
	const root = fs.mkdtempSync(path.join(temporary, 'workflow-')),
		bin = path.join(root, 'bin');
	fs.mkdirSync(bin);
	const node = path.join(bin, 'node'),
		python = path.join(bin, 'modeled-python'),
		tee = path.join(bin, 'tee');
	function shellQuote(value) {
		return "'" + value.replaceAll("'", "'\\''") + "'";
	}
	fs.writeFileSync(
		node,
		`#!/bin/sh
if [ "$1" = tools/ci/dev-release-qualification.cjs ]; then
 if [ "$4" = --validate-scope-receipt ]; then printf '%s\\n' "$CLOCK_MODEL_MODE"; fi
 exit 0
fi
if [ "$1" = tools/ci/native_http_clock_evidence.cjs ]; then exit 0; fi
exec ${shellQuote(process.execPath)} "$@"
`,
		{ mode: 0o700 }
	);
	fs.writeFileSync(
		python,
		`#!/bin/sh
printf '%s\\n' "$*" >> "$CLOCK_MODEL_TRACE"
printf '%s\\n' 'EXPLICIT modeled native stdout'
case "$*" in *native_http_wire_client_receiving.py*) exit "$CLOCK_MODEL_COMMAND_STATUS";; esac
exit 0
`,
		{ mode: 0o700 }
	);
	const realTee = execFileSync('which', ['tee'], { encoding: 'utf8' }).trim();
	fs.writeFileSync(
		tee,
		`#!/bin/sh
${shellQuote(realTee)} "$@"
exit "$CLOCK_MODEL_CAPTURE_STATUS"
`,
		{ mode: 0o700 }
	);
	const output = path.join(root, 'outputs'),
		trace = path.join(root, 'trace');
	fs.writeFileSync(output, '');
	const expanded = body
		.replaceAll('${{ matrix.architecture }}', 'arm64')
		.replaceAll('${{ github.run_id }}', '123')
		.replaceAll('${{ github.run_attempt }}', '2')
		.replaceAll('${{ github.sha }}', 'a'.repeat(40));
	const result = require('node:child_process').spawnSync(bashExecutable(), ['-c', expanded], {
		cwd: repository,
		encoding: 'utf8',
		timeout: 15000,
		env: {
			...process.env,
			PATH: bin + path.delimiter + process.env.PATH,
			RUNNER_TEMP: root,
			GITHUB_OUTPUT: output,
			ERGOPTI_NATIVE_HTTP_PYTHON: python,
			CLOCK_MODEL_MODE: mode,
			CLOCK_MODEL_TRACE: trace,
			CLOCK_MODEL_COMMAND_STATUS: String(commandStatus),
			CLOCK_MODEL_CAPTURE_STATUS: String(captureStatus)
		}
	});
	assert.equal(result.error, undefined);
	assert.equal(result.signal, null);
	return {
		root,
		result,
		output: fs.readFileSync(output, 'utf8'),
		calls: fs.existsSync(trace) ? fs.readFileSync(trace, 'utf8').trim().split('\n') : []
	};
}
try {
	control('complete fixed independently modeled closure preserves explicit limits', () => {
		assert.deepEqual(evidence.INPUTS, INPUTS);
		const vector = modeledPayload(),
			verdict = evidence.payloadReceipt(vector.root, vector.source);
		assert.equal(verdict.calibration_samples_observed, 16);
		assert.equal(verdict.source_consistent, true);
		assert.equal(
			verdict.native_acceptance,
			'PENDING_AUTHENTICATED_OFFICIAL_RUN_ARTIFACT_RECEIVING'
		);
		assert.equal(
			verdict.kernel_executable_identity,
			'UNKNOWN_NOT_ESTABLISHED_BY_PATH_HASH_OR_PROCESS_RECEIPT'
		);
		assert.equal(verdict.swift_factory_activation, 'HELD');
		assert.equal(Object.keys(verdict.payload_sha256).length, 9);
		assert.throws(() =>
			evidence.commandFact(
				evidence.uniqueJSON(
					Buffer.from(JSON.stringify(vector.fact).replace('\"version\":1', '\"version\":1.0'))
				)
			)
		);
		const statuses = {
			schema: 1,
			owned_process: { command: 0, capture: 0 },
			public_native: { command: 0, capture: 0 },
			independent_client: { command: 1, capture: 0 }
		};
		assert.equal(
			evidence.nativeStatuses(Buffer.from(JSON.stringify(statuses))).independent_client.command,
			1
		);
		assert.throws(() =>
			evidence.nativeStatuses(
				Buffer.from(JSON.stringify(statuses).replace('\"capture\":0', '\"capture\":1'))
			)
		);
	});
	control('duplicate escaped and nested JSON keys refuse', () => {
		for (const raw of [
			'{"version":1,"version":1}',
			'{"a":1,"\\u0061":2}',
			'{"nested":{"x":1,"x":1}}'
		])
			assert.throws(() => evidence.uniqueJSON(Buffer.from(raw)));
	});
	control('JSON malformed nonfinite and excessive depth refuse', () => {
		const v = modeledPayload();
		v.write('python-loader.json', {
			version: 1,
			isolated: 0,
			ignore_environment: 1,
			no_user_site: 1,
			dont_write_bytecode: true,
			safe_path: true,
			cache_empty: true,
			cache_device: 7,
			cache_inode: 29
		});
		assert.throws(() => evidence.payloadReceipt(v.root, v.source));
		for (const raw of [
			'{"x":1e999}',
			'true false',
			'[1,]',
			'"unterminated',
			'['.repeat(34) + '0' + ']'.repeat(34)
		])
			assert.throws(() => evidence.uniqueJSON(Buffer.from(raw)));
	});
	control('all interior samples are checked independently', () => {
		for (let index = 1; index < 15; index++)
			for (const sample of [49, 52, null, true, '50.5']) {
				const samples = Array(16).fill(50.5);
				samples[index] = sample;
				assert.throws(() =>
					evidence.frame(
						Buffer.from(JSON.stringify({ version: 1, system_uptime: samples }) + '\n'),
						50,
						51
					)
				);
			}
	});
	control('exact sixteen original cap and frame boundary refuse', () => {
		for (const count of [0, 1, 15, 17])
			assert.throws(() =>
				evidence.frame(
					Buffer.from(
						JSON.stringify({
							version: 1,
							system_uptime: Array(count).fill(50.5)
						}) + '\n'
					),
					50,
					51
				)
			);
		const raw = Buffer.from(
			JSON.stringify({ version: 1, system_uptime: Array(16).fill(50.5) }) + '\n'
		);
		for (const version of ['1.0', '1e0', 'true'])
			assert.throws(() =>
				evidence.frame(
					Buffer.from(
						'{\"version\":' +
							version +
							',\"system_uptime\":' +
							JSON.stringify(Array(16).fill(50.5)) +
							'}\n'
					),
					50,
					51
				)
			);
		for (const [before, after] of [
			[50, 65.00001],
			[51, 50],
			[0, 1],
			[true, 51]
		])
			assert.throws(() => evidence.frame(raw, before, after));
		for (const changed of [
			raw.subarray(0, raw.length - 1),
			Buffer.concat([raw, raw]),
			Buffer.alloc(4097, 32)
		])
			assert.throws(() => evidence.frame(changed, 50, 51));
	});
	mutation('missing one original source denies closure', (v) => {
		delete v.original.source_hashes[OWNERS[0]];
		v.write('source-receipt.json', v.original);
	});
	mutation('changed staged runtime is not regenerated into acceptance', (v) => {
		v.original.staged_hashes['OwnedNativeHTTPFixture.app/Contents/Resources/' + RUNTIME[0]] =
			'b'.repeat(64);
		v.write('source-receipt.json', v.original);
	});
	mutation('forged original receipt with equivalent object changes byte binding', (v) => {
		v.write('source-receipt.json', Buffer.from(JSON.stringify(v.original, null, 2)));
	});
	mutation('different actual receiver source refuses', (v) => {
		v.clock.receiver_sha256 = 'b'.repeat(64);
		v.write('clock-receipt.json', v.clock);
	});
	mutation('changed signed image bytes refuses', (v) => {
		v.write('image.bin', Buffer.alloc(32));
	});
	mutation('foreign architecture refuses', (v) => {
		v.source.architecture = 'amd64';
	});
	mutation('foreign attempt refuses', (v) => {
		v.clock.epoch.run_attempt = '3';
		v.write('clock-receipt.json', v.clock);
	});
	mutation('absent official context stays unbound', (v) => {
		v.clock.context_bound = false;
		v.clock.epoch = null;
		v.write('clock-receipt.json', v.clock);
	});
	mutation('failed strict signature command refuses', (v) => {
		v.fact.command = { phase: 'exit', status: 1 };
		v.fact.exit_status = 1;
		v.write('strict_verify.json', v.fact);
	});
	mutation('false settlement cannot be inferred from closed handles', (v) => {
		v.fact.literal_true_settlement = 1;
		v.write('clock.json', v.fact);
	});
	mutation('remaining group debt denies observation', (v) => {
		v.fact.command_group_debt = true;
		v.write('compile.json', v.fact);
	});
	mutation('uncertain capture closure denies observation', (v) => {
		v.fact.stderr_closed = false;
		v.write('sign.json', v.fact);
	});
	mutation('missing observed command denies complete payload', (v) => {
		fs.unlinkSync(path.join(v.root, 'clock.json'));
	});
	mutation('same-name aliases are never read', (v) => {
		fs.renameSync(path.join(v.root, 'clock.json'), path.join(v.root, 'outside.json'));
		fs.symlinkSync('outside.json', path.join(v.root, 'clock.json'));
	});
	control('official metadata consistency never authenticates caller JSON', () => {
		const v = modeledPayload(),
			verdict = evidence.payloadReceipt(v.root, v.source),
			archive = Buffer.from('independent artifact bytes');
		const run = {
			id: 123,
			run_attempt: 2,
			head_sha: v.source.candidate,
			event: 'workflow_dispatch',
			path: '.github/workflows/ci.yml',
			head_branch: 'codex/ci-validation',
			repository: { full_name: 'adrienm7/ergopti' },
			status: 'completed'
		};
		const artifact = {
			name: 'native-http-clock-arm64-123-2',
			expired: false,
			digest: 'sha256:' + hash(archive),
			workflow_run: { id: 123, head_sha: v.source.candidate }
		};
		const job = {
			run_id: 123,
			run_attempt: 2,
			head_sha: v.source.candidate,
			status: 'completed',
			name: 'macOS / Managed Ollama native · arm64',
			conclusion: 'failure'
		};
		const receiving = {
			job_api_path: '/repos/adrienm7/ergopti/actions/runs/123/attempts/2/jobs'
		};
		const result = evidence.officialConsistency(verdict, run, artifact, job, archive, receiving);
		assert.equal(result.authentication, 'NOT_ESTABLISHED_BY_CALLER_SUPPLIED_JSON');
		assert.equal(result.swift_factory_activation, 'HELD');
		for (const change of [
			{ run_attempt: 3 },
			{ head_sha: 'b'.repeat(40) },
			{ event: 'push' },
			{ head_branch: 'dev' }
		])
			assert.throws(() =>
				evidence.officialConsistency(
					verdict,
					{ ...run, ...change },
					artifact,
					job,
					archive,
					receiving
				)
			);
		assert.throws(() =>
			evidence.officialConsistency(
				verdict,
				run,
				{ ...artifact, digest: 'sha256:' + 'b'.repeat(64) },
				job,
				archive,
				receiving
			)
		);

		// Literal parent-prefixed names come from actual ci.yml/API receiving,
		// independent of the comparison implementation. Caller JSON stays modeled.
		const amdVerdict = { ...verdict, source: { ...verdict.source, architecture: 'amd64' } };
		const amdArtifact = { ...artifact, name: 'native-http-clock-amd64-123-2' };
		const amdJob = { ...job, name: 'macOS / Managed Ollama native · amd64' };
		const amdResult = evidence.officialConsistency(
			amdVerdict,
			run,
			amdArtifact,
			amdJob,
			archive,
			receiving
		);
		assert.equal(amdResult.authentication, 'NOT_ESTABLISHED_BY_CALLER_SUPPLIED_JSON');
		assert.equal(amdResult.swift_factory_activation, 'HELD');
		for (const name of [
			'Managed Ollama native · arm64',
			'Managed Ollama native · amd64',
			'Windows / Managed Ollama native · arm64',
			'macOS / macOS / Managed Ollama native · arm64',
			'macOS/Managed Ollama native · arm64',
			'macOS / Managed Ollama native · amd64',
			'macOS / Managed Ollama native · arm64 extra',
			null,
			true,
			123,
			['macOS / Managed Ollama native · arm64'],
			{ name: 'macOS / Managed Ollama native · arm64' }
		])
			assert.throws(
				() =>
					evidence.officialConsistency(
						verdict,
						run,
						artifact,
						{ ...job, name },
						archive,
						receiving
					),
				/Official job consistency refused/
			);
		assert.throws(
			() => evidence.officialConsistency(amdVerdict, run, amdArtifact, job, archive, receiving),
			/Official job consistency refused/
		);
		assert.throws(
			() => evidence.officialConsistency(verdict, run, artifact, [job, job], archive, receiving),
			/Official job consistency refused/
		);
		assert.throws(
			() => evidence.officialConsistency(verdict, run, artifact, {}, archive, receiving),
			/Official job consistency refused/
		);
		assert.throws(
			() => evidence.officialConsistency(verdict, run, artifact, job, archive, {}),
			/Attempt-scoped job receiving path refused/
		);
		assert.throws(
			() =>
				evidence.officialConsistency(verdict, run, artifact, job, archive, {
					job_api_path: '/repos/adrienm7/ergopti/actions/runs/123/jobs'
				}),
			/Attempt-scoped job receiving path refused/
		);
	});
	control('actual fresh Git HEAD clean closure receives fixed nineteen inputs', () => {
		const fixture = sourceFixture(),
			receipt = evidence.sourceReceipt(fixture.root, fixture.epoch);
		assert.deepEqual(Object.keys(receipt.sources).sort(), [...INPUTS].sort());
		assert.equal(receipt.original_source.candidate, fixture.epoch.candidate);
		assert.equal(receipt.original_source.scope, 'native-pac-source-only');
		const output = path.join(temporary, 'begin.json');
		const privateDirectory = path.join(temporary, 'private-cache');
		fs.mkdirSync(privateDirectory, { mode: 0o700 });
		receipt.private_cache = evidence.privateCache(privateDirectory);
		assert.equal(
			evidence.main(['begin', fixture.epoch.candidate, '123', '2', 'arm64', output], fixture.root),
			0
		);
		assert.deepEqual(JSON.parse(fs.readFileSync(output)), receipt);
	});
	control('missing tracked builder cannot enroll new role', () => {
		const fixture = sourceFixture((root) =>
			fs.unlinkSync(
				path.join(root, 'static/ergopti_plus/macos/tests/support/native_http_fixture_builder.py')
			)
		);
		assert.throws(() => evidence.sourceReceipt(fixture.root, fixture.epoch));
	});
	control('foreign HEAD refuses clean identical source inputs', () => {
		const fixture = sourceFixture();
		assert.throws(() =>
			evidence.sourceReceipt(fixture.root, {
				...fixture.epoch,
				candidate: 'b'.repeat(40)
			})
		);
	});
	control('whole tracked cleanliness includes files outside native roots', () => {
		const fixture = sourceFixture();
		fs.writeFileSync(path.join(fixture.root, 'outside-source.txt'), 'changed');
		assert.throws(() => evidence.sourceReceipt(fixture.root, fixture.epoch));
	});
	control('unchanged-content hardlinked owner is refused independently of Git diff', () => {
		const fixture = sourceFixture(),
			owner = path.join(
				fixture.root,
				'static/ergopti_plus/macos/tests/support/native_http_wire_fixture.py'
			);
		fs.linkSync(owner, path.join(temporary, 'owner-alias.py'));
		assert.throws(() => evidence.sourceReceipt(fixture.root, fixture.epoch));
	});
	control('untracked support Python shadow loader refuses', () => {
		const fixture = sourceFixture();
		const cache = path.join(fixture.root, 'static/ergopti_plus/macos/tests/support/__pycache__');
		fs.mkdirSync(cache);
		const name = 'native_http_fixture_builder.cpython-313.pyc';
		fs.writeFileSync(path.join(cache, name), 'independent bytecode bytes');
		const received = evidence.sourceReceipt(fixture.root, fixture.epoch);
		assert.equal(
			received.identified_unused_default_cache[
				'static/ergopti_plus/macos/tests/support/__pycache__/' + name
			],
			hash(Buffer.from('independent bytecode bytes'))
		);
		fs.writeFileSync(
			path.join(fixture.root, 'static/ergopti_plus/macos/tests/support/httpx.py'),
			'# independent unbound loader'
		);
		assert.throws(() => evidence.sourceReceipt(fixture.root, fixture.epoch));
	});
	control('original exact-ten source inventory is still mandatory', () => {
		const fixture = sourceFixture((root) =>
			fs.appendFileSync(
				path.join(
					root,
					'static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/ManagedPACSourceTests.swift'
				),
				'\nfunc testUnapprovedClockEnrollment() {}\n'
			)
		);
		assert.throws(() => evidence.sourceReceipt(fixture.root, fixture.epoch));
	});
	control('new-role context refuses overlong run attempt and unknown CLI selector', () => {
		const fixture = sourceFixture();
		for (const changed of [
			{ run_id: '123456789012345678901' },
			{ run_attempt: '1000000' },
			{ architecture: 'x86_64' }
		])
			assert.throws(() =>
				evidence.sourceReceipt(fixture.root, {
					...fixture.epoch,
					...changed
				})
			);
		assert.equal(evidence.main(['unregistered-role'], fixture.root), 1);
	});
	control('actual owning selectors refuse omission wrong count and no-op child', () => {
		const original = fs.readFileSync(
			path.join(repository, 'tools/test/test-managed-ollama-protocol.cjs'),
			'utf8'
		);
		assertSelectors(original);
		for (const [from, to] of [
			[
				"cases.push(['tools/test/macos_native_http_receiving_facts_test.py', 165]);",
				"cases.push(['tools/test/macos_native_http_receiving_facts_test.py', 156]);"
			],
			["cases.push(['tools/test/macos_native_http_clock_passive_receiving_controls.py', 21]);", ''],
			[
				"cases.push(['tools/test/macos_native_http_clock_passive_receiving_controls.py', 21]);",
				"cases.push(['tools/test/macos_native_http_clock_passive_receiving_controls.py', 20]);"
			],
			["'test-native-http-clock-evidence.cjs'", "'unregistered-clock.cjs'"],
			['assert.equal(clockResult.status, 0,', 'assert.equal(0, 0,']
		]) {
			assert.ok(original.includes(from));
			assert.throws(() => assertSelectors(original.replace(from, to)));
		}
	});
	control(
		'frozen proposed disposition keeps deferred skip full missing evidence and capture statuses',
		() => {
			const workflow = require('yaml').parse(
				fs.readFileSync(
					path.join(repository, 'tools/test/fixtures/native_http_clock_workflow.yml'),
					'utf8'
				)
			);
			const steps = workflow.jobs['managed-ollama-native'].steps;
			const selected = steps.filter(
				(step) => step.name === 'Receive actual independent managed HTTP native clients'
			);
			assert.equal(selected.length, 1);
			const step = selected[0];
			assert.equal(step.id, 'native_http_clock');
			assert.equal(step.if, '${{ !cancelled() }}');
			assert.equal(step['timeout-minutes'], 5);
			assert.equal(step.shell, 'bash');
			const statusBodies = [
				...step.run.matchAll(
					/^    node -e (.+) - "\$clock_root\/native-statuses\.json" "\$\{owned_status\[@\]\}" "\$\{public_status\[@\]\}" "\$\{client_status\[@\]\}" \|\| clock_status=1$/gm
				)
			];
			assert.equal(statusBodies.length, 1);
			const syntaxRoot = fs.mkdtempSync(path.join(temporary, 'workflow-syntax-'));
			const statusScript = path.join(syntaxRoot, 'clock-status.cjs');
			const actualStatusProgram = fixedClockStatusProgram(statusBodies[0][1]);
			assert.equal(
				actualStatusProgram,
				ORIGINAL_CLOCK_STATUS_PROGRAM,
				'Actual literal status program must preserve every frozen original statement and LF.'
			);
			fs.writeFileSync(statusScript, actualStatusProgram);
			const statusSyntax = require('node:child_process').spawnSync(
				process.execPath,
				['--check', statusScript],
				{ encoding: 'utf8' }
			);
			assert.equal(statusSyntax.status, 0, statusSyntax.stderr);
			const statusOutput = path.join(syntaxRoot, 'actual-statuses.json');
			const actualWriter = require('node:child_process').spawnSync(
				process.execPath,
				['-e', actualStatusProgram, '-', statusOutput, '7', '9', '11', '13', '15', '255'],
				{ encoding: 'utf8' }
			);
			assert.equal(actualWriter.error, undefined);
			assert.equal(actualWriter.signal, null);
			assert.equal(actualWriter.status, 0, actualWriter.stderr);
			assert.deepEqual(JSON.parse(fs.readFileSync(statusOutput, 'utf8')), {
				schema: 1,
				owned_process: { command: 7, capture: 9 },
				public_native: { command: 11, capture: 13 },
				independent_client: { command: 15, capture: 255 }
			});
			assert.equal(fs.statSync(statusOutput).mode & 0o777, 0o600);
			const retainedStatusBytes = fs.readFileSync(statusOutput);
			const duplicateWriter = require('node:child_process').spawnSync(
				process.execPath,
				['-e', actualStatusProgram, '-', statusOutput, '0', '0', '0', '0', '0', '0'],
				{ encoding: 'utf8' }
			);
			assert.notEqual(
				duplicateWriter.status,
				0,
				'The actual wx writer must refuse a replaced output authority.'
			);
			assert.deepEqual(fs.readFileSync(statusOutput), retainedStatusBytes);
			for (const [name, values] of [
				['missing capture', ['0', '0', '0', '0', '0']],
				['extra capture', ['0', '0', '0', '0', '0', '0', '0']],
				['float status', ['0', '0', '0', '0', '0', '1.0']],
				['exponent status', ['0', '0', '0', '0', '0', '1e0']],
				['negative status', ['0', '0', '0', '0', '0', '-1']],
				['status above uint255', ['0', '0', '0', '0', '0', '256']]
			]) {
				const refusedOutput = path.join(syntaxRoot, name + '.json');
				const refused = require('node:child_process').spawnSync(
					process.execPath,
					['-e', actualStatusProgram, '-', refusedOutput, ...values],
					{ encoding: 'utf8' }
				);
				assert.equal(refused.error, undefined);
				assert.equal(refused.signal, null);
				assert.equal(refused.status, 1, name + ': actual unchanged validator must refuse.');
				assert.equal(fs.existsSync(refusedOutput), false);
			}
			for (const invalidLiteral of ['$variable', '$(printf guessed)', '`printf guessed`'])
				assert.throws(() => fixedClockStatusProgram(invalidLiteral), /fixed literal/);
			const shellSyntax = require('node:child_process').spawnSync(bashExecutable(), ['-n'], {
				input: step.run.replace(/\$\{\{[^}]+\}\}/g, 'SYNTAX_ONLY'),
				encoding: 'utf8'
			});
			assert.equal(shellSyntax.status, 0, shellSyntax.stderr);
			assert.ok(
				step.run.indexOf('native_http_receiving_test.py --client-only') <
					step.run.indexOf('native_http_clock_evidence.cjs begin')
			);
			assert.ok(
				step.run.indexOf('native_http_clock_evidence.cjs begin') <
					step.run.indexOf('ERGOPTI_NATIVE_CLOCK_EVIDENCE=')
			);
			const uploads = steps.filter(
				(step) => step.name === 'Retain independent native HTTP clock receiving'
			);
			assert.equal(uploads.length, 1);
			assert.equal(
				uploads[0].if,
				"${{ always() && steps.native_http_clock.outputs.clock_expected == 'true' }}"
			);
			assert.equal(uploads[0].with['if-no-files-found'], 'error');
			assert.equal(
				uploads[0].with.name,
				'native-http-clock-${{ matrix.architecture }}-${{ github.run_id }}-${{ github.run_attempt }}'
			);
			const deferred = workflowDisposition(step.run, 'deferred');
			assert.equal(deferred.result.status, 0);
			assert.equal(deferred.output, '');
			assert.deepEqual(deferred.calls, []);
			assert.equal(fs.existsSync(path.join(deferred.root, 'native-http-clock-arm64-123-2')), false);
			const full = workflowDisposition(step.run, 'full');
			assert.equal(full.result.status, 0);
			assert.equal(full.output, 'clock_expected=true\n');
			assert.equal(full.calls.length, 3);
			assert.equal(full.calls[0], 'tools/diagnostics/macos_owned_process_native_test.py');
			assert.equal(
				full.calls[1],
				'static/ergopti_plus/macos/tests/support/native_http_receiving_test.py --client-only'
			);
			assert.equal(
				full.calls[2],
				'-I -B -X pycache_prefix=' +
					path.join(full.root, 'native-http-clock-arm64-123-2/private-cache') +
					' static/ergopti_plus/macos/tests/support/native_http_wire_client_receiving.py'
			);
			const failed = workflowDisposition(step.run, 'full', 7, 0);
			assert.equal(failed.result.status, 1);
			const failedStatuses = JSON.parse(
				fs.readFileSync(
					path.join(failed.root, 'native-http-clock-arm64-123-2/native-statuses.json')
				)
			);
			assert.deepEqual(failedStatuses.independent_client, { command: 7, capture: 0 });
			const capture = workflowDisposition(step.run, 'full', 0, 3);
			assert.equal(capture.result.status, 1);
			const captureStatuses = JSON.parse(
				fs.readFileSync(
					path.join(capture.root, 'native-http-clock-arm64-123-2/native-statuses.json')
				)
			);
			assert.deepEqual(captureStatuses.independent_client, { command: 0, capture: 3 });
			const invalid = workflowDisposition(step.run, 'invalid');
			assert.equal(invalid.result.status, 1);
			assert.equal(invalid.output, '');
			assert.deepEqual(invalid.calls, []);
		}
	);
	control('genuine preceding CPython cache creation is bracketed before clock source begin', () => {
		const fixture = sourceFixture();
		const before = evidence.sourceReceipt(fixture.root, fixture.epoch);
		assert.deepEqual(before.identified_unused_default_cache, {});
		const source = path.join(
			fixture.root,
			'static/ergopti_plus/macos/tests/support/native_http_fixture_builder.py'
		);
		execFileSync(
			require('../lib/python.cjs').pythonExecutable(),
			['-I', '-c', 'import py_compile,sys; py_compile.compile(sys.argv[1],doraise=True)', source],
			{ stdio: 'pipe' }
		);
		const after = evidence.sourceReceipt(fixture.root, fixture.epoch);
		assert.equal(Object.keys(after.identified_unused_default_cache).length, 1);
		assert.notDeepEqual(
			before.identified_unused_default_cache,
			after.identified_unused_default_cache
		);
		const clockRoot = fs.mkdtempSync(path.join(temporary, 'bracket-'));
		fs.mkdirSync(path.join(clockRoot, 'private-cache'), { mode: 0o700 });
		const output = path.join(clockRoot, 'source-before.json');
		assert.equal(
			evidence.main(['begin', fixture.epoch.candidate, '123', '2', 'arm64', output], fixture.root),
			0
		);
		const observed = JSON.parse(fs.readFileSync(output));
		assert.deepEqual(
			observed.identified_unused_default_cache,
			after.identified_unused_default_cache
		);
	});
	control('actual after and final snapshots remain when later payload is refused', () => {
		const fixture = sourceFixture(),
			root = fs.mkdtempSync(path.join(temporary, 'refusal-'));
		fs.mkdirSync(path.join(root, 'private-cache'), { mode: 0o700 });
		const before = path.join(root, 'source-before.json'),
			verdict = path.join(root, 'clock-verdict.json');
		assert.equal(
			evidence.main(['begin', fixture.epoch.candidate, '123', '2', 'arm64', before], fixture.root),
			0
		);
		assert.equal(
			evidence.main(
				[
					'judge',
					before,
					path.join(root, 'missing-payload'),
					path.join(root, 'missing-statuses'),
					fixture.epoch.candidate,
					'123',
					'2',
					'arm64',
					verdict
				],
				fixture.root
			),
			1
		);
		const after = JSON.parse(fs.readFileSync(path.join(root, 'source-after.json'))),
			final = JSON.parse(fs.readFileSync(path.join(root, 'source-final.json')));
		assert.deepEqual(after, JSON.parse(fs.readFileSync(before)));
		assert.deepEqual(final, after);
		assert.equal(fs.existsSync(verdict), false);
	});
	assert.equal(received, 32, 'Every fixed independently authored control must execute.');
	process.stdout.write('CLOCK_RECEIVER controls=32 native=false official=false\n');
} finally {
	if (received === 32) fs.rmSync(temporary, { recursive: true, force: true });
	else process.stderr.write('Retained failed clock controls: ' + temporary + '\n');
}
