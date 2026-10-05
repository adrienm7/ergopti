// tools/test/test-linux-http-stream-registration.cjs

/**
 * ==============================================================================
 * MODULE: Native Linux HTTP Streaming Gate Registration
 * DESCRIPTION:
 * Reads actual npm/planner/CI owners and mutation-tests missing declarations.
 * Native output counts must be recorded rather than manufactured; unavailable
 * Linux prerequisites fail, and foreign hosts explicitly defer this proof.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const Pipeline = require('./ci-pipeline.cjs');
const { run } = require('./run-linux-http-stream-receipts.cjs');

const ROOT = path.resolve(__dirname, '../..');
const NATIVE = 'tools/test/run-linux-http-stream-receipts.cjs';
const CONTRACT = 'tools/test/test-linux-http-stream-registration.cjs';
const SOURCES = [
	'static/ergopti_plus/_shared/lua/network/proxy_policy.lua',
	'static/ergopti_plus/_shared/modules/network/proxy_policy.json',
	'static/ergopti_plus/linux/adapters/curl_http_client.lua',
	'static/ergopti_plus/linux/adapters/system_proxy.lua',
	'static/ergopti_plus/linux/infra/curl_identity.lua',
	'static/ergopti_plus/linux/infra/http_body_pipe.lua',
	'static/ergopti_plus/linux/infra/managed_http.lua',
	'static/ergopti_plus/linux/infra/managed_http_deadline.lua',
	'static/ergopti_plus/linux/infra/native_timer.lua',
	'static/ergopti_plus/linux/infra/proxy_policy.lua',
	'static/ergopti_plus/linux/platform/network/system_proxy_probe.lua',
	'static/ergopti_plus/linux/platform/network/native_proxy_runtime.lua',
	'static/ergopti_plus/linux/_generated/native_runtime.lua',
	'static/ergopti_plus/linux/adapters/http_client.lua',
	'static/ergopti_plus/linux/modules/llm/api_ollama.lua',
	'static/ergopti_plus/linux/modules/llm/local_model_probe.lua',
	'static/ergopti_plus/linux/modules/llm/local_model_offer.lua',
	'static/ergopti_plus/linux/tests/unit/meta/test_http_client_curl.lua',
	'static/ergopti_plus/linux/tests/hardware/run_http_stream_receipts.lua',
	'static/ergopti_plus/linux/tests/hardware/run_local_api_auth.lua',
	'static/ergopti_plus/linux/modules/llm/api_remote.lua',
	'static/ergopti_plus/linux/modules/llm/api_entries.lua',
	'static/ergopti_plus/linux/modules/llm/local_server_catalogue.lua',
	'static/ergopti_plus/_shared/lua/llm/local_server_auth.lua',
	'static/ergopti_plus/_shared/modules/llm/local_servers.json',
	'static/ergopti_plus/_shared/lua/llm/local_model_policy.lua'
];

/** Verifies the actual declarations of one checkout without running its suites. */
function validate(root) {
	const read = (relative) => fs.readFileSync(path.join(root, relative), 'utf8');
	const scripts = JSON.parse(read('package.json')).scripts;
	assert.equal(scripts['test:linux:http-stream'], `node ./${NATIVE}`, 'native npm declaration');
	assert.equal(
		scripts['test:linux-http-stream-registration'],
		`node ./${CONTRACT}`,
		'static npm declaration'
	);
	const plannerPath = path.join(root, 'tools/test/verify-change.cjs');
	delete require.cache[require.resolve(plannerPath)];
	const planner = require(plannerPath);
	assert.equal(
		planner.GATE_COMMANDS['linux-http-stream']?.npm,
		'test:linux:http-stream',
		'native planner command'
	);
	for (const source of SOURCES)
		assert(
			planner.selectGates([source]).has('linux-http-stream'),
			`${source}: native planner selection`
		);

	const pipeline = Pipeline.open(root);
	const job = pipeline.job('e2e-linux');
	const step = Pipeline.step(job, 'Qualify native HTTP streaming receipts');
	assert.equal(Pipeline.stepField(step, 'if'), '${{ !cancelled() }}');
	assert.equal(
		Pipeline.stepField(step, 'continue-on-error'),
		null,
		'native CI errors cannot be forgiven'
	);
	const command = Pipeline.stepField(step, 'run');
	assert.match(command, /set -euo pipefail/);
	assert.match(command, /apt-get install[^\n]*curl lua-luv/);
	assert.match(
		command,
		/npm run test:linux:http-stream \| tee "\$RUNNER_TEMP\/linux-http-stream\.log"/
	);
	assert.doesNotMatch(command, /\|\| true|continue-on-error|exit 0/);
	const record = Pipeline.stepField(Pipeline.step(job, 'Record mandatory E2E evidence'), 'run');
	assert.match(
		record,
		/http_stream_assertions=\$\(sed -n 's\/\^PASS native HTTP streaming receipts:/
	);
	assert.match(record, /\$RUNNER_TEMP\/linux-http-stream\.log/);
	assert.match(record, /--subject "http-stream-receipts=\$http_stream_assertions"/);
	const manifest = JSON.parse(read('.github/linux-ci-coverage.json'));
	assert.equal(manifest.jobs['e2e-linux'].classification, 'mandatory');
	assert.equal(
		manifest.jobs['e2e-linux'].subjects['http-stream-receipts'],
		55,
		'native executed assertion floor'
	);
	assert(
		read('tools/test/run-js-suite.cjs').includes(`args: ['${CONTRACT}']`),
		'static gate must join the actual JS suite'
	);
	assert(
		read('tools/test/test-npm-aliases-match-the-suite.cjs').includes(`'${NATIVE}',`),
		'native execution has an explicit separate owner'
	);
}

/** Runs the registration and failure-contract tests with private file mutations. */
function main() {
	validate(ROOT);
	for (const platform of ['darwin', 'win32']) {
		const lines = [];
		assert.equal(
			run({
				platform,
				spawn: () => assert.fail('foreign host cannot run Linux proof'),
				log: (line) => lines.push(line)
			}),
			0
		);
		assert(
			lines.some((line) => line.includes('[DEFERRED]')),
			'foreign host must identify deferred proof'
		);
		assert(
			!lines.some((line) => line.includes('[OK]')),
			'deferred proof cannot claim native success'
		);
	}
	for (const result of [
		{ status: 2 },
		{ status: null, signal: 'SIGTERM' },
		{ error: new Error('missing native prerequisites') }
	])
		assert.notEqual(
			run({ platform: 'linux', spawn: () => result, error: () => {}, log: () => {} }),
			0,
			'Linux native refusal cannot skip'
		);
	const invocations = [];
	let invocation;
	assert.equal(
		run({
			platform: 'linux',
			spawn: (...args) => {
				invocations.push(args);
				invocation = args;
				return { status: 0 };
			},
			log: () => {}
		}),
		0
	);
	assert.equal(invocation[0], 'luajit');
	assert.deepEqual(
		invocations.map((args) => args[1]),
		[['tests/hardware/run_http_stream_receipts.lua'], ['tests/hardware/run_local_api_auth.lua']],
		'both actual owners are mandatory and ordered'
	);
	for (const failedIndex of [0, 1]) {
		let calls = 0;
		assert.equal(
			run({
				platform: 'linux',
				spawn: () => ({ status: calls++ === failedIndex ? 17 : 0 }),
				log: () => {},
				error: () => {}
			}),
			17,
			'either child failure retains its real exit'
		);
		assert.equal(
			calls,
			2,
			'a first child refusal cannot silently skip the second mandatory fixture'
		);
	}
	assert.equal(invocation[2].cwd, path.join(ROOT, 'static/ergopti_plus/linux'));
	assert.equal(invocation[2].stdio, 'inherit');
	assert(invocation[2].env.LUA_PATH.includes('../_shared/lua/?.lua'));
	if (process.env.ERGOPTI_NATIVE_LUA_CPATH)
		assert.equal(
			invocation[2].env.LUA_CPATH,
			process.env.ERGOPTI_NATIVE_LUA_CPATH,
			'native fixture uses its provisioned Lua ABI'
		);

	const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-http-registration-'));
	try {
		for (const relative of [
			'package.json',
			'.github/linux-ci-coverage.json',
			'tools/test/verify-change.cjs',
			'tools/test/validate-ahk-suite-manifest.cjs',
			'tools/test/validate-ahk-e2e-manifest.cjs',
			'static/ergopti_plus/_shared/tests/corpus/hotstrings/vectors.json',
			'tools/test/test-ahk-test-coverage.cjs',
			'tools/lint/format.cjs',
			'tools/test/run-js-suite.cjs',
			'tools/test/test-npm-aliases-match-the-suite.cjs'
		]) {
			const target = path.join(fixture, relative);
			fs.mkdirSync(path.dirname(target), { recursive: true });
			fs.copyFileSync(path.join(ROOT, relative), target);
		}
		fs.cpSync(path.join(ROOT, '.github/workflows'), path.join(fixture, '.github/workflows'), {
			recursive: true
		});
		validate(fixture);
		const mutations = [
			[
				'package.json',
				(source) => {
					const data = JSON.parse(source);
					delete data.scripts['test:linux:http-stream'];
					return JSON.stringify(data);
				},
				/native npm declaration/
			],
			[
				'tools/test/verify-change.cjs',
				(source) =>
					source.replace(/\s*'linux-http-stream': \{ npm: 'test:linux:http-stream' \},/, ''),
				/native planner command/
			],
			[
				'tools/test/verify-change.cjs',
				(source) => source.replace("gate: 'linux-http-stream'", "gate: 'removed-native-proof'"),
				/native planner selection/
			],
			[
				'.github/workflows/ci-linux.yml',
				(source) =>
					source.replace('Qualify native HTTP streaming receipts', 'Removed native HTTP proof'),
				/Qualify native HTTP streaming receipts/
			],
			[
				'.github/workflows/ci-linux.yml',
				(source) =>
					source.replace('npm run test:linux:http-stream | tee', 'echo omitted-native-proof | tee'),
				/test:linux:http-stream/
			],
			[
				'.github/workflows/ci-linux.yml',
				(source) =>
					source.replace(
						'--subject "http-stream-receipts=$http_stream_assertions"',
						'--subject "http-stream-receipts=55"'
					),
				/http-stream-receipts/
			],
			[
				'.github/linux-ci-coverage.json',
				(source) => {
					const data = JSON.parse(source);
					delete data.jobs['e2e-linux'].subjects['http-stream-receipts'];
					return JSON.stringify(data);
				},
				/native executed assertion floor/
			],
			[
				'tools/test/run-js-suite.cjs',
				(source) =>
					source.replace(`args: ['${CONTRACT}']`, "args: ['removed-registration-contract']"),
				/actual JS suite/
			]
		];
		for (const [relative, mutate, reason] of mutations) {
			const target = path.join(fixture, relative);
			const before = fs.readFileSync(target, 'utf8');
			const after = mutate(before);
			assert.notEqual(after, before, `${relative}: mutation must reach the actual declaration`);
			try {
				fs.writeFileSync(target, after);
				assert.throws(() => validate(fixture), reason);
			} finally {
				fs.writeFileSync(target, before);
			}
		}
	} finally {
		fs.rmSync(fixture, { recursive: true, force: true });
	}
	console.log(
		'[OK] Native Linux HTTP receipts retain npm/planner/CI owners and reject eight missing or fabricated declarations.'
	);
}

if (require.main === module) main();
module.exports = { validate };
