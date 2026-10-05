// tools/test/run-windows-inline-causal.cjs

/** CI-only exact-case native controls; never changes the committed feature sources. */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const { validateAhkSuiteManifest } = require('./validate-ahk-suite-manifest.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const DOC = 'static/ergopti_plus/windows/infra/toml/toml_document.ahk';
const FIXTURE = 'static/ergopti_plus/windows/tests/unit/test_toml_build_updated_content.ahk';
const DOC_HASH = '90739f44e7a91cac5303c023f8b020fe8443d892466da4a44a58f45b1a35d20d';
const FIXTURE_HASH = 'd71c336a63369e60801e8c89d51250e84f310fb97e672cfc66be85639f918743';
const CASES = [
	{
		id: 'span',
		name: 'toml config inline source spans: actual names timing order',
		patchHash: 'd237126759945f6b6b427c50b0c83ba4275c2b7bec215f6691cb66e139e6c613',
		inverseHash: '249c4d8f331af2a1d15d5a69da36d8642c8fd7c2e8daca728158f55637afc68b',
		cause: 'only explicit owned source spans change - expected: <'
	},
	{
		id: 'reader',
		name: 'toml config inline source spans: semantic reader reuses the actual canonical multiline lexer',
		patchHash: '72da0dfbfc13d3b001880867569a8fa0d42fc67bbda7679006a275c881426cc2',
		inverseHash: '1a851b830e3c89ddd816e3af9d138a112c825a90043770a2b1b69da492a0fd22',
		cause: 'Unbalanced TOML inline table member'
	}
];

const digest = (value) => crypto.createHash('sha256').update(value).digest('hex');

/** Requires a retired native child and exactly the requested nonvacuous case. */
function validateReceipt(transcript, native, control, inverse) {
	assert.ok(!native.error, `native launch/timeout/buffer error: ${native.error || ''}`);
	assert.equal(native.signal, null, 'native signal is not a terminal exit receipt');
	assert.equal(native.status, inverse ? 1 : 0, 'exact native exit code is required');
	assert.equal(
		String(native.stderr || ''),
		'',
		'native load/parse errors are not causal test failures'
	);
	const manifest = validateAhkSuiteManifest(transcript);
	assert.equal(manifest.complete, true, JSON.stringify(manifest.errors));
	assert.equal(manifest.planned, 1, 'the exact selected case must be planned once');
	assert.equal(manifest.executed_count, 1, 'the exact selected case must execute once');
	assert.equal(manifest.executed[0].name, control.name, 'a substring neighbor cannot substitute');
	assert.equal(manifest.passed, inverse ? 0 : 1);
	assert.equal(manifest.failed, inverse ? 1 : 0);
	if (inverse) {
		const prefix = `not ok 1 - ${control.name} — `;
		const failure = String(transcript)
			.split(/\r?\n/)
			.find((line) => line.startsWith(prefix));
		assert.ok(
			failure && failure.slice(prefix.length).startsWith(control.cause),
			`unexpected native failure; not accepted as original-route causality: ${failure || ''}`
		);
		assert.doesNotMatch(
			failure,
			/UnsetError|nonexistent|missing.*(?:function|include|symbol)|unassigned/i
		);
		if (control.id === 'span') {
			assert.ok(
				transcript.includes('time_activation_seconds = 0.75, future = "retain"'),
				'retain expected physical order evidence'
			);
			assert.ok(
				transcript.includes('future = "retain", time_activation_seconds = 0.75'),
				'retain observed original-route reorder evidence'
			);
		}
	}
	return manifest;
}

function snapshot(file) {
	return { file, bytes: fs.existsSync(file) ? fs.readFileSync(file) : null };
}
function same(saved) {
	return saved.bytes === null
		? !fs.existsSync(saved.file)
		: fs.existsSync(saved.file) && saved.bytes.equals(fs.readFileSync(saved.file));
}
function restore(saved) {
	if (!same(saved)) {
		if (saved.bytes === null) fs.rmSync(saved.file, { force: true });
		else fs.writeFileSync(saved.file, saved.bytes);
	}
	assert.ok(same(saved), `exact restoration refused: ${saved.file}`);
}
function git(args) {
	const result = spawnSync('git', args, {
		cwd: ROOT,
		encoding: 'utf8',
		timeout: 30000,
		windowsHide: true
	});
	assert.ok(
		!result.error && result.signal === null && result.status === 0,
		`inverse patch admission refused: ${result.error || result.stderr || result.stdout}`
	);
}

function selfTest() {
	const control = CASES[1];
	const tap = (failed, name = control.name, cause = control.cause) =>
		`1..1\nRUNNING 1/1 - ${name}\n${failed ? 'not ok' : 'ok'} 1 - ${name}${failed ? ` — ${cause} [toml_helpers.ahk:369]` : ''}\n# ${failed ? '0 passed, 1 failed' : '1 passed, 0 failed'}.\n`;
	const exited = (status) => ({ status, signal: null, stderr: '' });
	validateReceipt(tap(false), exited(0), control, false);
	validateReceipt(tap(true), exited(1), control, true);
	for (const [transcript, native, inverse] of [
		[tap(true), exited(0), true],
		[tap(false), exited(1), false],
		[tap(false, control.name + ' neighbor'), exited(0), false],
		['1..0\n# 0 passed, 0 failed.\n', exited(0), false],
		[tap(false).replace('RUNNING 1/1', 'RUNNING 2/1'), exited(0), false],
		[tap(true, control.name, 'UnsetError: this variable has not been assigned'), exited(1), true],
		[tap(true, control.name, 'Call to nonexistent function'), exited(1), true],
		[tap(true, control.name, 'unrelated assertion failed'), exited(1), true],
		[tap(true), { ...exited(1), stderr: 'load error' }, true],
		[tap(true), { ...exited(1), error: new Error('ETIMEDOUT') }, true],
		[tap(true), { ...exited(1), signal: 'SIGTERM' }, true],
		[tap(true).replace('# 0 passed, 1 failed.', '# 1 passed, 0 failed.'), exited(1), true]
	])
		assert.throws(() => validateReceipt(transcript, native, control, inverse));
	console.log('CI-only receipt controls: 2 admitted + 12 refused; no native execution');
}

function main() {
	assert.equal(process.platform, 'win32', 'actual Windows native controls are required');
	const argument = (name) => {
		const i = process.argv.indexOf(name);
		assert.ok(i >= 0 && process.argv[i + 1], `missing ${name}`);
		return process.argv[i + 1];
	};
	const ahk = argument('--ahk');
	assert.ok(fs.existsSync(ahk), 'actual AutoHotkey executable is required');
	const source = snapshot(path.join(ROOT, DOC));
	const fixture = snapshot(path.join(ROOT, FIXTURE));
	assert.equal(
		digest(source.bytes),
		DOC_HASH,
		'source generation is not the reviewed native owner'
	);
	assert.equal(
		digest(fixture.bytes),
		FIXTURE_HASH,
		'fixture generation is not the reviewed exact-case owner'
	);
	const mainReceipt = snapshot(argument('--main-receipt'));
	const evidence = fs.mkdtempSync(
		path.join(process.env.RUNNER_TEMP || os.tmpdir(), 'windows-inline-causal-')
	);
	const outcomes = [];
	try {
		for (const control of CASES) {
			for (const inverse of [false, true]) {
				const label = `${control.id}-${inverse ? 'original-route' : 'source'}`;
				const tapFile = path.join(evidence, `${label}-${crypto.randomUUID()}.txt`);
				const outcome = { label, name: control.name, inverse, tapFile, accepted: false };
				try {
					assert.ok(
						same(source) && same(fixture) && same(mainReceipt),
						'initial source or main transcript changed'
					);
					if (inverse) {
						const patch = path.join(
							__dirname,
							'fixtures',
							`windows-inline-${control.id}-original-route-inverse.patch`
						);
						assert.equal(
							digest(fs.readFileSync(patch)),
							control.patchHash,
							'inverse payload is not admitted'
						);
						git(['apply', '--check', patch]);
						git(['apply', patch]);
						assert.equal(
							digest(fs.readFileSync(source.file)),
							control.inverseHash,
							'inverse must change only its reviewed route'
						);
					}
					// spawnSync joins its owned native process before returning; never read live TAP.
					const native = spawnSync(
						ahk,
						[
							'/ErrorStdOut',
							path.join(ROOT, 'static/ergopti_plus/windows/tests/run_all.ahk'),
							'--only',
							control.name
						],
						{
							cwd: ROOT,
							env: { ...process.env, ERGOPTI_AHK_RESULTS_FILE: tapFile },
							encoding: 'utf8',
							shell: false,
							windowsHide: true,
							timeout: 120000,
							maxBuffer: 8 * 1024 * 1024
						}
					);
					outcome.native = {
						status: native.status,
						signal: native.signal,
						error: native.error ? String(native.error) : null
					};
					fs.writeFileSync(path.join(evidence, `${label}-stdout.txt`), String(native.stdout || ''));
					fs.writeFileSync(path.join(evidence, `${label}-stderr.txt`), String(native.stderr || ''));
					const transcript = fs.existsSync(tapFile) ? fs.readFileSync(tapFile, 'utf8') : '';
					outcome.transcript = transcript;
					outcome.stdout = String(native.stdout || '');
					outcome.stderr = String(native.stderr || '');
					console.log(`--- ${label}: ${control.name} ---\n${transcript}`);
					outcome.manifest = validateReceipt(transcript, native, control, inverse);
					assert.ok(same(mainReceipt), 'isolated child changed the main all-suite TAP');
					assert.ok(same(fixture), 'isolated child changed the fixture source');
					assert.equal(
						digest(fs.readFileSync(source.file)),
						inverse ? control.inverseHash : DOC_HASH,
						'native child changed the admitted source'
					);
					outcome.accepted = true;
				} catch (error) {
					outcome.error = String(error.stack || error);
				} finally {
					outcomes.push(outcome);
					restore(source);
					restore(fixture);
					restore(mainReceipt);
				}
			}
		}
	} finally {
		const restorationErrors = [];
		for (const saved of [source, fixture, mainReceipt]) {
			try {
				restore(saved);
			} catch (error) {
				restorationErrors.push(String(error));
			}
		}
		fs.writeFileSync(
			path.join(evidence, 'summary.json'),
			JSON.stringify(
				{
					outcomes,
					restorationErrors,
					sourceRestored: same(source),
					fixtureRestored: same(fixture),
					mainTapRestored: same(mainReceipt)
				},
				null,
				2
			) + '\n'
		);
		const summary = fs.readFileSync(path.join(evidence, 'summary.json'));
		fs.writeFileSync(
			path.join(
				process.env.RUNNER_TEMP || os.tmpdir(),
				`windows-ahk-isolated-inline-causal-${path.basename(evidence)}.json`
			),
			summary
		);
		for (const outcome of outcomes) {
			const status = outcome.accepted ? 'notice' : 'error';
			const detail = `${outcome.label}: accepted=${outcome.accepted}; native exit=${outcome.native?.status}; ${outcome.error || 'exact named manifest and causal receipt admitted'}`;
			if (process.env.GITHUB_ACTIONS === 'true')
				console.log(
					`::${status}::${detail.replaceAll('%', '%25').replaceAll('\r', '%0D').replaceAll('\n', '%0A')}`
				);
		}
		console.log(`Native causal evidence: ${evidence}`);
		assert.deepEqual(restorationErrors, [], 'source/main transcript cleanup is incomplete');
	}
	assert.equal(outcomes.length, 4, 'all four native children must be qualified');
	for (const outcome of outcomes) assert.ok(outcome.accepted, `${outcome.label}: ${outcome.error}`);
	console.log(
		'Native inline source and original-route controls: 4/4 qualified; exact source/main TAP restored'
	);
}

module.exports = { validateReceipt, CASES };
if (require.main === module) {
	try {
		if (process.argv.includes('--self-test')) selfTest();
		else main();
	} catch (error) {
		const message = String(error.stack || error);
		if (process.env.GITHUB_ACTIONS === 'true')
			console.log(
				`::error::${message.replaceAll('%', '%25').replaceAll('\r', '%0D').replaceAll('\n', '%0A')}`
			);
		console.error(message);
		process.exitCode = 1;
	}
}
