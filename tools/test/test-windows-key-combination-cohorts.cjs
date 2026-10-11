// Explicit private modeled receiver controls; no AHK/native child or hosted identity is fabricated.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const vm = require('node:vm');
const digest = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex');
const pins = JSON.parse(
	fs.readFileSync(path.join(__dirname, 'portable-control-inputs.json'), 'utf8')
);
const helperBytes = fs.readFileSync(path.join(__dirname, pins.helper.path));
const validatorBytes = fs.readFileSync(path.join(__dirname, pins.validator.path));
const inputBytes = fs.readFileSync(path.join(__dirname, pins.inputs.path));
assert.equal(digest(helperBytes), pins.helper.sha256, 'exact proposed helper source');
assert.equal(
	digest(validatorBytes),
	pins.validator.sha256,
	'exact original manifest receiver source'
);
assert.equal(
	digest(inputBytes),
	pins.inputs.sha256,
	'exact frozen V1 cohort/source-provenance frame'
);
const validatorModule = { exports: {} };
vm.runInNewContext(
	validatorBytes.toString('utf8'),
	{
		require: (name) => {
			assert.equal(name, 'node:fs');
			return fs;
		},
		module: validatorModule,
		exports: validatorModule.exports,
		process: { env: {} },
		console
	},
	{ filename: pins.validator.path }
);
const terminator = 'main().catch((error) => {\n\tconsole.error(error);\n\tprocess.exit(1);\n});\n';
const helperSource = helperBytes.toString('utf8');
assert.ok(helperSource.endsWith(terminator), 'exact launch suffix; never execute helper main');
assert.equal(helperSource.split(terminator).length, 2, 'unique launch suffix');
const fixtureModule = { exports: {} };
const forbidChild = () => {
	throw new Error('portable receiver controls must never allocate a child or inspect Git');
};
vm.runInNewContext(
	helperSource.slice(0, -terminator.length) +
		'\nmodule.exports = { receiveCanonical, receiveDrySelection, receiveExecution, receiveRetirement, receiveSourcePins, receiveHead, receivePublishedPac };\n',
	{
		require: (name) => {
			if (name === 'node:child_process') return { spawn: forbidChild, execFileSync: forbidChild };
			if (name === '../test/validate-ahk-suite-manifest.cjs') return validatorModule.exports;
			if (name === './windows-key-combination-cohort-inputs.json') return JSON.parse(inputBytes);
			assert.ok(
				['node:fs', 'node:path', 'node:crypto'].includes(name),
				'closed helper dependencies'
			);
			return require(name);
		},
		module: fixtureModule,
		exports: fixtureModule.exports,
		__dirname,
		Buffer,
		console,
		setTimeout: forbidChild,
		clearTimeout: forbidChild,
		process: { env: {} }
	},
	{ filename: pins.helper.path }
);
const R = fixtureModule.exports;
// Literal two-case observations exercise acceptance. They are not the 28 native test results.
const cohort = { id: 'modeled-two', planned: 2, expected_names: ['alpha', 'beta'] };
const dry =
	'\uFEFF# [boot] fixture\r\n1..2\r\n# --only modeled - 2 of 99 test(s) selected.\r\n# dry-run - skipping execution.\r\n';
const first = 'RUNNING 1/2 - alpha\r\nok 1 - alpha\r\n# duration_ms 1 1.000\r\n';
const second = 'RUNNING 2/2 - beta\r\nok 2 - beta\r\n# duration_ms 2 2.000\r\n';
const prefix = '\uFEFF# [boot] fixture\r\n1..2\r\n';
const footer = '# 2 passed, 0 failed.\r\n';
const actual = prefix + first + second + footer;
const goodExit = () => ({
	started: true,
	disposed: true,
	timeout: false,
	native_exit_code: 0,
	signal: null
});
const native = (text, exit = goodExit(), selected = cohort) => {
	const manifest = validatorModule.exports.validateAhkSuiteManifest(text);
	R.receiveExecution(text, exit, selected, manifest);
	return manifest;
};
let passed = 0;
function test(name, callback) {
	try {
		callback();
		passed++;
		console.log(`ok ${passed} - ${name}`);
	} catch (error) {
		console.error(`not ok - ${name}`);
		throw error;
	}
}
function refused(callback, reason) {
	assert.throws(callback, new RegExp(reason));
}
test('original modeled dry and timed owners accept complete literal observations', () => {
	R.receiveDrySelection(dry, goodExit(), cohort);
	const manifest = native(actual);
	assert.equal(manifest.executed_count, 2);
	assert.equal(manifest.timed_count, 2);
});
test('dry owner refuses missing plan', () =>
	refused(
		() => R.receiveDrySelection(dry.replace('1..2\r\n', ''), goodExit(), cohort),
		'count differs'
	));
test('dry owner refuses a wrong selection count', () =>
	refused(
		() => R.receiveDrySelection(dry.replace('1..2', '1..3'), goodExit(), cohort),
		'count differs'
	));
test('dry owner refuses duplicate matching plans', () =>
	refused(() => R.receiveDrySelection(dry + '1..2\r\n', goodExit(), cohort), 'count differs'));
test('dry owner refuses additional different plan', () =>
	refused(
		() => R.receiveDrySelection(dry + '1..999\r\n', goodExit(), cohort),
		'additional or malformed plans'
	));
test('dry owner refuses additional malformed plan', () =>
	refused(
		() => R.receiveDrySelection(dry + '1..oops\r\n', goodExit(), cohort),
		'additional or malformed plans'
	));
test('dry owner refuses absent marker', () =>
	refused(
		() =>
			R.receiveDrySelection(
				dry.replace('# dry-run - skipping execution.\r\n', ''),
				goodExit(),
				cohort
			),
		'marker'
	));
test('dry owner refuses duplicate marker', () =>
	refused(
		() => R.receiveDrySelection(dry + '# dry-run - skipping execution.\r\n', goodExit(), cohort),
		'marker'
	));
test('dry owner refuses executed subject', () =>
	refused(() => R.receiveDrySelection(dry + first, goodExit(), cohort), 'executed subjects'));
test('dry owner refuses zero selection instead of accepting a dry exit', () =>
	refused(
		() => R.receiveDrySelection(dry.replace('1..2', '1..0'), goodExit(), cohort),
		'count differs'
	));
for (const [name, change] of [
	['nonzero exit', { native_exit_code: 1 }],
	['unknown exit', { native_exit_code: null }],
	['signal', { signal: 'SIGKILL' }],
	['timeout despite exit zero', { timeout: true }]
])
	test(`dry owner refuses ${name}`, () =>
		refused(
			() => R.receiveDrySelection(dry, { ...goodExit(), ...change }, cohort),
			'native dry selection failed'
		));
test('timed owner refuses missing terminal result', () =>
	refused(() => native(actual.replace('ok 2 - beta\r\n', '')), 'manifest incomplete'));
test('timed owner refuses missing duration', () =>
	refused(() => native(actual.replace('# duration_ms 2 2.000\r\n', '')), 'manifest incomplete'));
test('timed owner refuses duplicate result', () =>
	refused(() => native(actual.replace(footer, 'ok 2 - beta\r\n' + footer)), 'manifest incomplete'));
test('timed owner refuses failed native assertion and matching failed footer', () =>
	refused(
		() =>
			native(
				actual
					.replace('ok 2 - beta', 'not ok 2 - beta — independent refusal')
					.replace(footer, '# 1 passed, 1 failed.\r\n')
			),
		'native assertions failed'
	));
test('timed owner refuses missing footer', () =>
	refused(() => native(actual.replace(footer, '')), 'manifest incomplete'));
test('timed owner refuses wrong running total', () =>
	refused(() => native(actual.replace('RUNNING 2/2', 'RUNNING 2/3')), 'manifest incomplete'));
test('timed owner refuses renamed genuine ordinal', () =>
	refused(() => native(actual.replaceAll('beta', 'gamma')), 'names/order differ'));
test('timed owner refuses out-of-plan ordinal', () =>
	refused(
		() =>
			native(
				actual
					.replaceAll('2/2', '3/2')
					.replace('ok 2 ', 'ok 3 ')
					.replace('duration_ms 2 ', 'duration_ms 3 ')
			),
		'manifest incomplete'
	));
test('timed owner refuses reversed complete raw triples even when sorted manifest is complete', () => {
	const reversed = prefix + second + first + footer;
	assert.equal(validatorModule.exports.validateAhkSuiteManifest(reversed).complete, true);
	refused(() => native(reversed), 'raw native.*order differs');
});
test('timed owner refuses interleaved start boundaries', () => {
	const interleaved =
		prefix +
		'RUNNING 1/2 - alpha\r\nRUNNING 2/2 - beta\r\nok 1 - alpha\r\n# duration_ms 1 1.000\r\nok 2 - beta\r\n# duration_ms 2 2.000\r\n' +
		footer;
	assert.equal(validatorModule.exports.validateAhkSuiteManifest(interleaved).complete, true);
	refused(() => native(interleaved), 'raw native.*order differs');
});
test('timed owner refuses late first duration after next subject', () => {
	const late =
		prefix +
		first.replace('# duration_ms 1 1.000\r\n', '') +
		second +
		'# duration_ms 1 1.000\r\n' +
		footer;
	assert.equal(validatorModule.exports.validateAhkSuiteManifest(late).complete, true);
	refused(() => native(late), 'raw native.*order differs');
});
test('timed owner refuses footer before last duration', () =>
	refused(
		() =>
			native(
				actual.replace(
					second + footer,
					second.replace('# duration_ms 2 2.000\r\n', '') + footer + '# duration_ms 2 2.000\r\n'
				)
			),
		'raw native.*order differs'
	));
for (const [name, change] of [
	['nonzero exit', { native_exit_code: 1 }],
	['unknown exit', { native_exit_code: null }],
	['signal', { signal: 'SIGTERM' }],
	['timeout despite complete transcript', { timeout: true }]
])
	test(`timed owner refuses ${name}`, () =>
		refused(() => native(actual, { ...goodExit(), ...change }), 'native process failed'));
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'windows91-receiver-controls-'));
let files = 0;
function captured(tap, stdout, stderr) {
	const name = path.join(temporary, String(++files));
	const entry = { mode: 'modeled-capture' };
	for (const [key, bytes] of Object.entries({ tap, stdout, stderr })) {
		entry[key] = `${name}.${key}`;
		fs.writeFileSync(entry[key], bytes, { flag: 'wx' });
		entry[`${key}_present`] = true;
		entry[`${key}_sha256`] = digest(bytes);
	}
	return entry;
}
const tapBytes = Buffer.from(actual);
const stdoutBytes = Buffer.from(actual.slice(1));
const empty = Buffer.alloc(0);
try {
	test('capture accepts required canonical framing and exact complete payload without normalization', () => {
		const entry = captured(tapBytes, stdoutBytes, empty);
		R.receiveCanonical(entry, actual);
		assert.equal(entry.stdout_equals_canonical, true);
		assert.equal(entry.stderr_empty, true);
		assert.equal(entry.canonical_framing, 'required-EF-BB-BF');
	});
	test('capture refuses missing file receipt', () =>
		refused(
			() =>
				R.receiveCanonical(
					{ ...captured(tapBytes, stdoutBytes, empty), stdout_present: false },
					actual
				),
			'missing complete output'
		));
	test('capture refuses post-exit canonical drift', () => {
		const entry = captured(tapBytes, stdoutBytes, empty);
		fs.appendFileSync(entry.tap, 'changed');
		refused(() => R.receiveCanonical(entry, actual), 'images changed');
	});
	test('capture refuses retained-string divergence', () =>
		refused(
			() => R.receiveCanonical(captured(tapBytes, stdoutBytes, empty), actual + 'changed'),
			'retained child result'
		));
	test('capture refuses invalid UTF-8 instead of replacement-normalizing', () => {
		const invalid = Buffer.from([239, 187, 191, 255]);
		refused(
			() =>
				R.receiveCanonical(captured(invalid, Buffer.from([255]), empty), invalid.toString('utf8')),
			'retained child result'
		);
	});
	test('capture refuses absent mandatory canonical framing', () =>
		refused(
			() => R.receiveCanonical(captured(stdoutBytes, stdoutBytes, empty), actual.slice(1)),
			'framing prefix is missing'
		));
	test('capture refuses duplicate canonical framing', () =>
		refused(
			() =>
				R.receiveCanonical(
					captured(Buffer.concat([tapBytes.subarray(0, 3), tapBytes]), stdoutBytes, empty),
					'\uFEFF' + actual
				),
			'complete stdout differs'
		));
	test('capture refuses unexpected stdout framing instead of optional BOM stripping', () =>
		refused(
			() => R.receiveCanonical(captured(tapBytes, tapBytes, empty), actual),
			'complete stdout differs'
		));
	test('capture refuses stdout suffix', () =>
		refused(
			() =>
				R.receiveCanonical(
					captured(tapBytes, Buffer.concat([stdoutBytes, Buffer.from('noise')]), empty),
					actual
				),
			'complete stdout differs'
		));
	test('capture refuses partial stdout', () =>
		refused(
			() => R.receiveCanonical(captured(tapBytes, stdoutBytes.subarray(0, -1), empty), actual),
			'complete stdout differs'
		));
	test('capture refuses newline normalization', () =>
		refused(
			() =>
				R.receiveCanonical(
					captured(tapBytes, Buffer.from(actual.slice(1).replaceAll('\r\n', '\n')), empty),
					actual
				),
			'complete stdout differs'
		));
	test('capture refuses any stderr despite complete TAP', () =>
		refused(
			() => R.receiveCanonical(captured(tapBytes, stdoutBytes, Buffer.from('warning')), actual),
			'stderr is not empty'
		));
} finally {
	// Only this explicitly owned receiver-test directory; no native or source path cleanup.
	fs.rmSync(temporary, { recursive: true, force: false });
}
const cohorts = () => [
	{ status: 'PASS', manifest: { executed_count: 1 } },
	{ status: 'PASS', manifest: { executed_count: 1 } }
];
const children = () => [goodExit(), goodExit(), goodExit(), goodExit()];
test('retirement accepts four acknowledged children and exact aggregate', () =>
	R.receiveRetirement(children(), cohorts(), 4, 2));
test('retirement refuses missing child', () =>
	refused(() => R.receiveRetirement(children().slice(1), cohorts(), 4, 2), 'four-child'));
test('retirement refuses started child without exit acknowledgment', () =>
	refused(
		() =>
			R.receiveRetirement(
				[{ ...goodExit(), disposed: false }, ...children().slice(1)],
				cohorts(),
				4,
				2
			),
		'four-child'
	));
test('retirement refuses unstarted allocation even if marked disposed', () =>
	refused(
		() =>
			R.receiveRetirement(
				[{ ...goodExit(), started: false }, ...children().slice(1)],
				cohorts(),
				4,
				2
			),
		'four-child'
	));
test('retirement refuses timeout before continued allocation', () =>
	refused(
		() =>
			R.receiveRetirement(
				[{ ...goodExit(), timeout: true }, ...children().slice(1)],
				cohorts(),
				4,
				2
			),
		'four-child'
	));
test('retirement refuses failed cohort', () =>
	refused(
		() => R.receiveRetirement(children(), [{ status: 'FAIL' }, cohorts()[1]], 4, 2),
		'not every|Not every'
	));
test('retirement refuses incorrect aggregate', () =>
	refused(() => R.receiveRetirement(children(), cohorts(), 4, 3), 'aggregate differs'));
const sourceFrame = { 'a.ahk': 'source-a', 'b.ahk': 'source-b' };
test('source receiving retains unchanged ordered frame', () =>
	R.receiveSourcePins({ ...sourceFrame }, sourceFrame, 'source refusal'));
test('source receiving refuses changed image', () =>
	refused(
		() =>
			R.receiveSourcePins({ ...sourceFrame, 'b.ahk': 'changed' }, sourceFrame, 'source refusal'),
		'source refusal'
	));
test('source receiving refuses missing source', () =>
	refused(
		() => R.receiveSourcePins({ 'a.ahk': 'source-a' }, sourceFrame, 'source refusal'),
		'source refusal'
	));
test('source receiving refuses added unknown source', () =>
	refused(
		() =>
			R.receiveSourcePins({ ...sourceFrame, 'c.ahk': 'source-c' }, sourceFrame, 'source refusal'),
		'source refusal'
	));
test('source receiving refuses changed key order', () =>
	refused(
		() =>
			R.receiveSourcePins(
				{ 'b.ahk': 'source-b', 'a.ahk': 'source-a' },
				sourceFrame,
				'source refusal'
			),
		'source refusal'
	));
test('HEAD receiving accepts exact actual commit', () =>
	R.receiveHead('received-head', 'received-head', 'HEAD refusal'));
test('HEAD receiving refuses changed commit', () =>
	refused(() => R.receiveHead('changed-head', 'received-head', 'HEAD refusal'), 'HEAD refusal'));
test('HEAD receiving refuses missing actual commit', () =>
	refused(() => R.receiveHead(undefined, 'received-head', 'HEAD refusal'), 'HEAD refusal'));
// These recording fixtures prove receipt joins only; no PAC executable, compiler,
// SDK, native child or successful hosted publisher is created by these controls.
const pacFixture = (callback) => {
	const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'windows91-pac-receiving-'));
	try {
		const sourceNames = [
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
		const vendor = 'static/ergopti_plus/windows/vendor/ergopti_network_pac';
		const build = 'static/ergopti_plus/windows/build/native/network_pac/';
		const archive = '2'.repeat(64);
		const write = (relative, bytes) => {
			const destination = path.join(directory, relative);
			fs.mkdirSync(path.dirname(destination), { recursive: true });
			fs.writeFileSync(destination, bytes);
		};
		const catalog = {
			network_runtime: { portable: { flatpak_sources: { duktape: { sha256: archive } } } }
		};
		const sourcePins = {};
		for (const relative of sourceNames) {
			const bytes =
				relative === sourceNames[0] ? JSON.stringify(catalog) : `independent-source:${relative}\n`;
			write(relative, bytes);
			sourcePins[relative] = digest(Buffer.from(bytes));
		}
		const exe = Buffer.from('modeled executable bytes; never launched');
		const license = Buffer.from('independent modeled license');
		const artifact = {
			schema_version: 1,
			source_fingerprint: '1'.repeat(64),
			duktape_archive_sha256: archive,
			exe_sha256: digest(exe),
			license_sha256: digest(license)
		};
		const prepared = {
			schema_version: 1,
			source_fingerprint: '1'.repeat(64),
			duktape_archive_sha256: archive,
			inputs: sourceNames
		};
		write(`${vendor}.exe`, exe);
		write(`${vendor}.LICENSE.txt`, license);
		write(`${vendor}.json`, JSON.stringify(artifact));
		write(`${build}artifact_receipt.json`, JSON.stringify(artifact));
		write(`${build}prepared/source_receipt.json`, JSON.stringify(prepared));
		callback({ directory, vendor, build, sourcePins, sourceNames, artifact, prepared, write });
	} finally {
		fs.rmSync(directory, { recursive: true, force: true });
	}
};
test('PAC receiving accepts the unchanged modeled original-publisher frame', () =>
	pacFixture((f) => {
		const before = R.receivePublishedPac(f.directory, f.sourcePins, 'success');
		assert.equal(Object.keys(before).length, 5);
		assert.equal(before[`${f.vendor}.exe`], f.artifact.exe_sha256);
		assert.equal(before[`${f.vendor}.LICENSE.txt`], f.artifact.license_sha256);
		const after = R.receivePublishedPac(f.directory, f.sourcePins, 'success');
		R.receiveSourcePins(after, before, 'PAC final images changed');
	}));
test('PAC receiving refuses unknown or unsuccessful original publisher', () =>
	pacFixture((f) => {
		for (const outcome of [undefined, 'failure', 'cancelled', true]) {
			refused(
				() => R.receivePublishedPac(f.directory, f.sourcePins, outcome),
				'publisher did not succeed'
			);
		}
	}));
test('PAC receiving refuses vendor JSON differing only in bytes from its original receipt', () =>
	pacFixture((f) => {
		f.write(`${f.vendor}.json`, JSON.stringify(f.artifact) + '\n');
		refused(
			() => R.receivePublishedPac(f.directory, f.sourcePins, 'success'),
			'Published PAC JSON differs'
		);
	}));
test('PAC receiving refuses executable-byte replacement', () =>
	pacFixture((f) => {
		f.write(`${f.vendor}.exe`, 'replacement executable');
		refused(
			() => R.receivePublishedPac(f.directory, f.sourcePins, 'success'),
			'executable differs'
		);
	}));
test('PAC receiving refuses license-byte replacement', () =>
	pacFixture((f) => {
		f.write(`${f.vendor}.LICENSE.txt`, 'replacement license');
		refused(() => R.receivePublishedPac(f.directory, f.sourcePins, 'success'), 'license differs');
	}));
test('PAC receiving refuses the original source fingerprint mismatch', () =>
	pacFixture((f) => {
		f.write(
			`${f.build}prepared/source_receipt.json`,
			JSON.stringify({ ...f.prepared, source_fingerprint: '3'.repeat(64) })
		);
		refused(
			() => R.receivePublishedPac(f.directory, f.sourcePins, 'success'),
			'fingerprint differs'
		);
	}));
test('PAC receiving refuses archive receipts inconsistent with the admitted canonical catalog', () =>
	pacFixture((f) => {
		const changed = {
			network_runtime: { portable: { flatpak_sources: { duktape: { sha256: '4'.repeat(64) } } } }
		};
		const bytes = JSON.stringify(changed);
		f.write(f.sourceNames[0], bytes);
		f.sourcePins[f.sourceNames[0]] = digest(Buffer.from(bytes));
		refused(
			() => R.receivePublishedPac(f.directory, f.sourcePins, 'success'),
			'canonical Duktape pin'
		);
	}));
test('PAC receiving refuses a publisher source missing from the received Git closure', () =>
	pacFixture((f) => {
		delete f.sourcePins[f.sourceNames[3]];
		refused(
			() => R.receivePublishedPac(f.directory, f.sourcePins, 'success'),
			'received Git closure'
		);
	}));
test('PAC receiving refuses changed source bytes with the original receipt and pins', () =>
	pacFixture((f) => {
		f.write(f.sourceNames[4], 'changed production source');
		refused(
			() => R.receivePublishedPac(f.directory, f.sourcePins, 'success'),
			'received Git closure'
		);
	}));
test('PAC receiving refuses a missing or extra original publisher source path', () =>
	pacFixture((f) => {
		f.write(
			`${f.build}prepared/source_receipt.json`,
			JSON.stringify({ ...f.prepared, inputs: f.sourceNames.slice(1) })
		);
		refused(
			() => R.receivePublishedPac(f.directory, f.sourcePins, 'success'),
			'source input roster'
		);
		f.write(
			`${f.build}prepared/source_receipt.json`,
			JSON.stringify({ ...f.prepared, inputs: [...f.sourceNames, '../foreign'] })
		);
		refused(
			() => R.receivePublishedPac(f.directory, f.sourcePins, 'success'),
			'source input roster'
		);
	}));
test('PAC terminal receiving refuses even internally consistent produced-image replacement', () =>
	pacFixture((f) => {
		const before = R.receivePublishedPac(f.directory, f.sourcePins, 'success');
		const changed = Buffer.from('different modeled executable');
		const artifact = { ...f.artifact, exe_sha256: digest(changed) };
		f.write(`${f.vendor}.exe`, changed);
		f.write(`${f.vendor}.json`, JSON.stringify(artifact));
		f.write(`${f.build}artifact_receipt.json`, JSON.stringify(artifact));
		const after = R.receivePublishedPac(f.directory, f.sourcePins, 'success');
		refused(
			() => R.receiveSourcePins(after, before, 'PAC final images changed'),
			'PAC final images changed'
		);
	}));
test('PAC receiving refuses a same-byte source symlink', () =>
	pacFixture((f) => {
		const original = path.join(f.directory, f.sourceNames[4]);
		const copied = `${original}.owned-copy`;
		fs.renameSync(original, copied);
		fs.symlinkSync(copied, original);
		refused(() => R.receivePublishedPac(f.directory, f.sourcePins, 'success'), 'symlink refused');
	}));
console.log(
	`# ${passed} modeled portable receiver controls passed; native selection/execution UNRUN.`
);
