// tools/test/test-linux-managed-http-ci-registration.cjs

/**
 * ==============================================================================
 * MODULE: Mandatory Managed HTTP Native CI Registration
 * DESCRIPTION:
 * Keeps authentic validation tools, exact native receipts and Linux selection
 * mandatory. Pure receiving controls grant no native execution credit.
 * ==============================================================================
 */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const Pipeline = require('./ci-full-default.cjs');
const Evidence = require('./linux-managed-http-evidence.cjs');
const Planner = require('./verify-change.cjs');
const ROOT = path.resolve(__dirname, '../..');
const read = (name) => fs.readFileSync(path.join(ROOT, name), 'utf8');
const sha256 = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex');
const SETUP = 'Prepare authenticated managed HTTP validation tools';
const NATIVE = 'Qualify native managed HTTP public and retained output';
const NOT_CANCELLED = '${{ !cancelled() }}';
const sources = [
	'tools/test/run-linux-managed-http-native.cjs',
	'tools/test/linux-managed-http-evidence.cjs',
	'tools/test/test-linux-managed-http-ci-registration.cjs',
	'tools/test/fixtures/validation-curl/setup_validation_curl.py',
	'tools/test/fixtures/validation-curl/prepare_validation_keyring.py',
	'tools/test/test_validation_keyring_preparation.py',
	'tools/test/fixtures/validation-curl/PINS.json'
];
let passed = 0;
function validateRegistration(aliases, inventory, planner, coverage) {
	assert.equal(
		aliases['test:linux:managed-http-native'],
		'node ./tools/test/run-linux-managed-http-native.cjs'
	);
	assert.equal(
		aliases['test:linux-managed-http-ci-registration'],
		'node ./tools/test/test-linux-managed-http-ci-registration.cjs'
	);
	assert.ok(inventory.includes("args: ['tools/test/test-linux-managed-http-ci-registration.cjs']"));
	assert.ok(!inventory.includes("args: ['tools/test/run-linux-managed-http-native.cjs']"));
	assert.equal(
		planner.GATE_COMMANDS['linux-managed-http-native']?.npm,
		'test:linux:managed-http-native'
	);
	assert.equal(planner.GATE_COMMANDS['linux-managed-http-native']?.platform, 'linux');
	for (const source of sources)
		assert.ok(planner.selectGates([source]).has('linux-managed-http-native'), source);
	assert.equal(coverage.jobs['e2e-linux'].classification, 'mandatory');
	assert.equal(coverage.jobs['e2e-linux'].subjects['managed-http-output'], 18);
	assert.equal(coverage.jobs['e2e-linux'].subjects['managed-http-public'], 30);
}
const aliases = JSON.parse(read('package.json')).scripts;
const inventory = read('tools/test/run-js-suite.cjs');
const coverage = JSON.parse(read('.github/linux-ci-coverage.json'));
validateRegistration(aliases, inventory, Planner, coverage);
passed++;
for (const mutation of [
	() =>
		validateRegistration(
			{ ...aliases, 'test:linux:managed-http-native': 'true' },
			inventory,
			Planner,
			coverage
		),
	() =>
		validateRegistration(
			aliases,
			inventory.replace(
				"args: ['tools/test/test-linux-managed-http-ci-registration.cjs']",
				"args: ['missing']"
			),
			Planner,
			coverage
		),
	() =>
		validateRegistration(
			aliases,
			inventory + "args: ['tools/test/run-linux-managed-http-native.cjs']",
			Planner,
			coverage
		),
	() => validateRegistration(aliases, inventory, { ...Planner, GATE_COMMANDS: {} }, coverage),
	() =>
		validateRegistration(
			aliases,
			inventory,
			{ ...Planner, selectGates: () => new Map() },
			coverage
		),
	() =>
		validateRegistration(aliases, inventory, Planner, {
			...coverage,
			jobs: {
				...coverage.jobs,
				'e2e-linux': {
					classification: 'informational',
					subjects: coverage.jobs['e2e-linux'].subjects
				}
			}
		}),
	() =>
		validateRegistration(aliases, inventory, Planner, {
			...coverage,
			jobs: {
				...coverage.jobs,
				'e2e-linux': {
					...coverage.jobs['e2e-linux'],
					subjects: { ...coverage.jobs['e2e-linux'].subjects, 'managed-http-output': 0 }
				}
			}
		})
]) {
	assert.throws(mutation);
	passed++;
}

function job(text, id, rel) {
	const found = Pipeline.jobsOfText(text, rel).filter((value) => value.id === id);
	assert.equal(found.length, 1);
	return found[0].body;
}
function validateWorkflow(text, entry) {
	const body = job(text, 'e2e-linux', '.github/workflows/ci-linux.yml');
	for (const name of [SETUP, NATIVE]) {
		const step = Pipeline.step(body, name);
		assert.equal(Pipeline.stepField(step, 'if'), NOT_CANCELLED);
		assert.equal(Pipeline.stepField(step, 'continue-on-error'), null);
		assert.equal(Pipeline.stepField(step, 'timeout-minutes'), '35');
		assert.ok(Pipeline.runOf(step).includes('set -euo pipefail'));
	}
	const setup = Pipeline.runOf(Pipeline.step(body, SETUP)).join('\n');
	for (const dependency of [
		'build-essential',
		'pkg-config',
		'libssl-dev',
		'zlib1g-dev',
		'gpgv',
		'debian-archive-keyring',
		'luajit',
		'lua-luv',
		'libglib2.0-dev',
		'glib-networking',
		'gsettings-desktop-schemas',
		'dconf-gsettings-backend'
	]) {
		assert.ok(setup.split(/\s+/).includes(dependency), dependency);
	}
	assert.ok(setup.includes('umask 077'));
	assert.ok(setup.includes('mkdir -m 700 "$validation_parent"'));
	assert.ok(
		setup.includes(
			'if ! python3 -B tools/test/test_validation_keyring_preparation.py > "$validation_parent/keyring.models.stdout.private" 2> "$validation_parent/keyring.models.stderr.private"; then'
		)
	);
	assert.ok(
		setup.includes(
			'if ! python3 -B tools/test/fixtures/validation-curl/prepare_validation_keyring.py --repo "$GITHUB_WORKSPACE" --destination "$validation_parent/keyring" > "$validation_parent/keyring.stdout.private" 2> "$validation_parent/keyring.stderr.private"; then'
		)
	);
	assert.ok(
		setup.includes(
			'echo "::error::Authenticated private validation keyring preparation failed; private inputs retained."\n  exit 1\nfi'
		)
	);
	assert.ok(
		setup.indexOf('prepare_validation_keyring.py --repo') <
			setup.indexOf('setup_validation_curl.py --repo')
	);
	assert.ok(
		setup.includes(
			'if python3 -B tools/test/fixtures/validation-curl/setup_validation_curl.py --repo "$GITHUB_WORKSPACE" --destination "$validation_parent/tools" --openssl-prefix /usr --keyring "$validation_parent/keyring/trusted.gpg" --jobs 2 > "$validation_parent/setup.stdout.private" 2> "$validation_parent/setup.stderr.private"; then'
		)
	);
	assert.ok(
		setup.includes(
			'node tools/test/linux-managed-http-evidence.cjs --tools-env "$validation_parent/tools/TOOLS-ADMISSION.json" "$validation_parent/tools" tools/test/fixtures/validation-curl/PINS.json >> "$GITHUB_ENV"'
		)
	);
	assert.ok(/else\n[^\n]+\n\s*exit 1\n\s*fi/.test(setup));
	assert.doesNotMatch(setup, /GITHUB_PATH|LD_LIBRARY_PATH=|--insecure|--skip|\|\| true/);
	const nativeStep = Pipeline.step(body, NATIVE);
	const native = Pipeline.runOf(nativeStep).join('\n');
	assert.ok(nativeStep.includes('ERGOPTI_MANAGED_NATIVE_EXPECTED_HEAD: ${{ github.sha }}'));
	assert.ok(native.includes('unset PKG_CONFIG_SYSROOT_DIR ERGOPTI_MANAGED_NATIVE_GIO_SYSROOT'));
	assert.ok(
		native.includes(
			'npm run --silent test:linux:managed-http-native | tee "$RUNNER_TEMP/linux-managed-http-native.log"'
		)
	);
	assert.doesNotMatch(native, /run_native_subreaper|timeout [0-9]|\|\| true|continue-on-error/);
	assert.ok(body.indexOf('- name: ' + SETUP) < body.indexOf('- name: ' + NATIVE));
	const record = Pipeline.runOf(Pipeline.step(body, 'Record mandatory E2E evidence')).join('\n');
	for (const [kind, subject] of [
		['output', 'managed-http-output'],
		['public', 'managed-http-public']
	]) {
		assert.ok(
			record.includes(
				'managed_http_' +
					kind +
					'_assertions=$(node tools/test/linux-managed-http-evidence.cjs --count ' +
					kind +
					' "$RUNNER_TEMP/linux-managed-http-native.log" "$GITHUB_SHA")'
			)
		);
		assert.ok(record.includes('--subject "' + subject + '=$managed_http_' + kind + '_assertions"'));
	}
	const linux = job(entry, 'linux', '.github/workflows/ci.yml');
	assert.equal(Pipeline.field(linux, 'if'), "needs.validate.outputs.lane_linux == 'true'");
	assert.equal(Pipeline.field(linux, 'uses'), './.github/workflows/ci-linux.yml');
	assert.equal(
		Pipeline.field(job(entry, 'release', '.github/workflows/ci.yml'), 'if'),
		"github.event_name == 'push' && needs.validate.outputs.release == 'true'"
	);
}
const workflow = Pipeline.file('.github/workflows/ci-linux.yml');
const entry = Pipeline.file('.github/workflows/ci.yml');
validateWorkflow(workflow, entry);
passed++;
function uniqueReplace(text, needle, replacement) {
	assert.equal(text.split(needle).length - 1, 1, 'Mutation must target one exact managed step');
	return text.replace(needle, replacement);
}
for (const [needle, replacement] of [
	['- name: ' + SETUP, '- name: Removed managed setup'],
	['- name: ' + NATIVE, '- name: Removed managed native'],
	[
		'- name: ' + NATIVE + '\n        if: ' + NOT_CANCELLED,
		'- name: ' + NATIVE + '\n        if: false'
	],
	[
		'- name: ' + SETUP + '\n        if: ' + NOT_CANCELLED,
		'- name: ' + SETUP + '\n        if: ' + NOT_CANCELLED + '\n        continue-on-error: true'
	],
	[
		'--jobs 2 > "$validation_parent/setup.stdout.private"',
		'--jobs 2 > "$validation_parent/changed.stdout"'
	],
	[
		'--keyring "$validation_parent/keyring/trusted.gpg" --jobs',
		'--keyring /untrusted/keyring --jobs'
	],
	[
		'--tools-env "$validation_parent/tools/TOOLS-ADMISSION.json"',
		'--tools-env "$validation_parent/tools/FAILED.json"'
	],
	[
		'unset PKG_CONFIG_SYSROOT_DIR ERGOPTI_MANAGED_NATIVE_GIO_SYSROOT',
		'export PKG_CONFIG_SYSROOT_DIR=/changed'
	],
	[
		'npm run --silent test:linux:managed-http-native | tee',
		'npm run --silent test:linux:managed-http-native || true | tee'
	],
	[
		'ERGOPTI_MANAGED_NATIVE_EXPECTED_HEAD: ${{ github.sha }}',
		'ERGOPTI_MANAGED_NATIVE_EXPECTED_HEAD: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
	],
	[
		'--count public "$RUNNER_TEMP/linux-managed-http-native.log"',
		'--count public "$RUNNER_TEMP/missing.log"'
	],
	[
		'--subject "managed-http-public=$managed_http_public_assertions"',
		'--subject "managed-http-public=30"'
	]
]) {
	const mutated = uniqueReplace(workflow, needle, replacement);
	assert.throws(() => validateWorkflow(mutated, entry));
	passed++;
}
for (const [needle, replacement] of [
	["if: needs.validate.outputs.lane_linux == 'true'", 'if: true'],
	["if: github.event_name == 'push' && needs.validate.outputs.release == 'true'", 'if: true']
]) {
	const mutated = uniqueReplace(entry, needle, replacement);
	assert.throws(() => validateWorkflow(workflow, mutated));
	passed++;
}

const expectedHead = '1'.repeat(40);
const expectedNative = '2'.repeat(64);
const nativeReceipt = [
	'[OK] Linux managed HTTP retained output: 18 actual native controls passed; 0 skipped.',
	'[OK] Linux managed HTTP public transport: 30 actual native controls passed; 0 skipped.',
	'Linux managed HTTP source: ' +
		expectedHead +
		'; inventory ' +
		'3'.repeat(64) +
		'; native ' +
		expectedNative +
		'.',
	''
].join('\n');
assert.deepEqual(Evidence.readNativeCounts(nativeReceipt, expectedHead, expectedNative), {
	output: 18,
	public: 30
});
passed++;
for (const invalid of [
	'',
	nativeReceipt.trimEnd(),
	nativeReceipt + nativeReceipt,
	nativeReceipt.replace(/\n/g, '\r\n'),
	nativeReceipt.replace('18 actual', '0 actual'),
	nativeReceipt.replace('30 actual', '29 actual'),
	nativeReceipt.replace('18 actual', '018 actual'),
	nativeReceipt.replace('0 skipped', '1 skipped'),
	nativeReceipt.replace('[OK]', '[FAIL]'),
	nativeReceipt + '[FAIL] native cleanup\n',
	nativeReceipt.replace(expectedHead, '4'.repeat(40)),
	nativeReceipt.replace(expectedNative, '5'.repeat(64)),
	nativeReceipt.replace('3'.repeat(64), 'invalid'),
	nativeReceipt.slice(0, -2),
	'x'.repeat(4097)
]) {
	assert.throws(() => Evidence.readNativeCounts(invalid, expectedHead, expectedNative));
	passed++;
}

// Literal independent tool receipts exercise receiving admission only. They are
// never installed, executed, or used as production validation tool inputs.
const root = '/private/validation-tools';
const pinsDigest = '6'.repeat(64);
const legacyDigest = '7'.repeat(64);
const toolReceipt = {
	schema_version: 1,
	state: 'tools_admitted',
	native_30_qualification: 'UNEXECUTED',
	pins_sha256: pinsDigest,
	openssl_sdk_prefix: '/usr',
	tools: {
		modern: {
			path: root + '/modern/bin/curl',
			sha256: '8'.repeat(64),
			actual_version: 'curl 8.14.1 native libcurl/8.14.1 OpenSSL/3.0.0',
			actual_loader_closure: 'libssl.so.3 => /usr/lib/libssl.so.3'
		},
		legacy: {
			path: root + '/legacy-root/usr/bin/curl',
			sha256: legacyDigest,
			actual_version: 'curl 7.88.1 native libcurl/7.88.1 OpenSSL/3.0.0',
			actual_loader_closure:
				'libcurl.so.4 => /private/validation-tools/legacy-libraries/libcurl.so.4'
		}
	},
	legacy_library_path: root + '/legacy-libraries',
	inherited_library_suffix_preserved: true
};
const admitted = Evidence.readToolEnvironment(
	JSON.stringify(toolReceipt),
	root,
	pinsDigest,
	legacyDigest
);
assert.equal(admitted.ERGOPTI_MANAGED_NATIVE_MODERN_SHA256, '8'.repeat(64));
assert.equal(admitted.ERGOPTI_MANAGED_NATIVE_LEGACY_CURL, root + '/legacy-root/usr/bin/curl');
assert.equal(Object.keys(admitted).length, 5);
assert.ok(!JSON.stringify(admitted).includes('libssl.so.3'));
passed++;
for (const mutation of [
	(value) => {
		value.state = 'failed';
	},
	(value) => {
		value.native_30_qualification = 'PASSED';
	},
	(value) => {
		value.pins_sha256 = '9'.repeat(64);
	},
	(value) => {
		value.openssl_sdk_prefix = '/invented';
	},
	(value) => {
		value.raw_stderr = 'private';
	},
	(value) => {
		value.tools.modern.path += '\nLD_LIBRARY_PATH=/foreign';
	},
	(value) => {
		value.tools.legacy.sha256 = 'a'.repeat(64);
	},
	(value) => {
		value.tools.modern.actual_version = 'curl 8.14.1 native libcurl/8.14.10 OpenSSL/3.0.0';
	},
	(value) => {
		value.tools.legacy.actual_version = 'curl 7.88.1 native libcurl/7.88.10 OpenSSL/3.0.0';
	},
	(value) => {
		value.tools.modern.actual_loader_closure = 'libssl.so.3 => not found';
	},
	(value) => {
		value.legacy_library_path = '/foreign';
	},
	(value) => {
		value.inherited_library_suffix_preserved = false;
	}
]) {
	const value = JSON.parse(JSON.stringify(toolReceipt));
	mutation(value);
	assert.throws(() =>
		Evidence.readToolEnvironment(JSON.stringify(value), root, pinsDigest, legacyDigest)
	);
	passed++;
}
const setupSource = read('tools/test/fixtures/validation-curl/setup_validation_curl.py');
// Execute the full-file inverse: original source integrity remains independently pinned.
let preservedSetupSource = setupSource;
for (const { inserted, original } of [
	{
		inserted: 'import sys\n',
		original: ''
	},
	{
		inserted:
			'\n\n# Diagnostic protocol only: fixed stage/class, never messages, args or environment.\nSETUP_STAGES = frozenset(\n    (\n        "arguments",\n        "pins-owner-admission",\n        "private-destination",\n        "bootstrap-client",\n        "modern-source-fetch",\n        "modern-source-extract",\n        "openssl-sdk",\n        "modern-configure",\n        "modern-build",\n        "modern-install",\n        "legacy-release-fetch",\n        "legacy-signature",\n        "legacy-release-policy",\n        "legacy-index-fetch",\n        "legacy-index-parse",\n        "legacy-package-identity",\n        "legacy-package-fetch",\n        "legacy-package-extract",\n        "legacy-library-admission",\n        "modern-runtime-admission",\n        "legacy-runtime-admission",\n        "receipt-publication",\n        "completion",\n    )\n)\n_setup_stage = "arguments"\n_native_refusal = None\n_diagnostic_publication_refused = False\n_diagnostic_note_refused = False\n\n\ndef mark_setup_stage(stage):\n    global _setup_stage\n    if stage not in SETUP_STAGES:\n        raise RuntimeError("Fixed setup stage required.")\n    _setup_stage = stage\n\n\ndef emit_setup_failure(error):\n    classes = (\n        (RuntimeError, "RuntimeError"),\n        (FileNotFoundError, "FileNotFoundError"),\n        (PermissionError, "PermissionError"),\n        (ValueError, "ValueError"),\n        (TypeError, "TypeError"),\n        (KeyError, "KeyError"),\n        (OSError, "OSError"),\n        (json.JSONDecodeError, "JSONDecodeError"),\n        (lzma.LZMAError, "LZMAError"),\n        (tarfile.ReadError, "TarReadError"),\n        (SystemExit, "SystemExit"),\n        (KeyboardInterrupt, "KeyboardInterrupt"),\n    )\n    # Identity comparisons never invoke exception messages or custom class hashing.\n    kind = "Other"\n    for candidate, label in classes:\n        if type(error) is candidate:\n            kind = label\n            break\n    if _native_refusal is not None and type(error) is _native_refusal:\n        kind = "NativeRefused"\n    packet = {\n        "schema_version": 1,\n        "state": "setup_failed",\n        "stage": _setup_stage,\n        "error_class": kind,\n    }\n    sys.stdout.write(json.dumps(packet, separators=(",", ":")) + "\\n")\n    sys.stdout.flush()\n',
		original: ''
	},
	{
		inserted: '    global _native_refusal\n    mark_setup_stage("arguments")\n',
		original: ''
	},
	{
		inserted: '    mark_setup_stage("pins-owner-admission")\n',
		original: ''
	},
	{
		inserted: '    _native_refusal = owner.RuntimeRefused\n',
		original: ''
	},
	{
		inserted: '    mark_setup_stage("private-destination")\n',
		original: ''
	},
	{
		inserted: '    mark_setup_stage("bootstrap-client")\n',
		original: ''
	},
	{
		inserted: '    mark_setup_stage("modern-source-fetch")\n',
		original: ''
	},
	{
		inserted: '    mark_setup_stage("modern-source-extract")\n',
		original: ''
	},
	{
		inserted: '    mark_setup_stage("openssl-sdk")\n',
		original: ''
	},
	{
		inserted: '        mark_setup_stage("modern-configure")\n',
		original: ''
	},
	{
		inserted: '        mark_setup_stage("modern-build")\n',
		original: ''
	},
	{
		inserted: '        mark_setup_stage("modern-install")\n',
		original: ''
	},
	{
		inserted: '    mark_setup_stage("legacy-release-fetch")\n',
		original: ''
	},
	{
		inserted: '    mark_setup_stage("legacy-signature")\n',
		original: ''
	},
	{
		inserted: '    mark_setup_stage("legacy-release-policy")\n',
		original: ''
	},
	{
		inserted: '    mark_setup_stage("legacy-index-fetch")\n',
		original: ''
	},
	{
		inserted: '    mark_setup_stage("legacy-index-parse")\n',
		original: ''
	},
	{
		inserted: '        mark_setup_stage("legacy-package-identity")\n',
		original: ''
	},
	{
		inserted: '        mark_setup_stage("legacy-package-fetch")\n',
		original: ''
	},
	{
		inserted: '        mark_setup_stage("legacy-package-extract")\n',
		original: ''
	},
	{
		inserted: '    mark_setup_stage("legacy-library-admission")\n',
		original: ''
	},
	{
		inserted:
			'        mark_setup_stage(\n            "modern-runtime-admission" if name == "modern" else "legacy-runtime-admission"\n        )\n',
		original: ''
	},
	{
		inserted: '    mark_setup_stage("receipt-publication")\n',
		original: ''
	},
	{
		inserted: '    mark_setup_stage("completion")\n',
		original: ''
	},
	{
		inserted:
			'    try:\n        main()\n    except BaseException as error:\n        if type(error) is SystemExit:\n            code = error.code\n            if type(code) is int and code == 0:\n                raise\n        try:\n            emit_setup_failure(error)\n        except BaseException:\n            _diagnostic_publication_refused = True\n            try:\n                BaseException.add_note(error, "Fixed setup diagnostic publication unavailable.")\n            except BaseException:\n                _diagnostic_note_refused = True\n        raise\n',
		original: '    main()\n'
	}
]) {
	assert.equal(preservedSetupSource.split(inserted).length - 1, 1);
	preservedSetupSource = preservedSetupSource.replace(inserted, original);
}
assert.equal(
	sha256(preservedSetupSource),
	'73528753dc1c7f1c8a176a3c391f763b772ec999ed6d3adeb9a14f97e42883fe'
);
assert.equal(
	sha256(setupSource),
	'ebdbdccffab7a17cea7823736f156bb29129e1445aab7bae2d6f33711931f212'
);
const pins = JSON.parse(read('tools/test/fixtures/validation-curl/PINS.json'));
assert.equal(
	pins.command_owner_sha256,
	sha256(fs.readFileSync(path.join(ROOT, 'tools/build/stage-linux-network-runtime.py')))
);
assert.equal(
	pins.modern.sha256,
	'f4619a1e2474c4bbfedc88a7c2191209c8334b48fa1f4e53fd584cc12e9120dd'
);
assert.equal(pins.legacy.required_signer, '4D64FEC119C2029067D6E791F8D2585B8783D481');
assert.equal(
	pins.legacy.curl_file_sha256,
	'27125f0331490b7fbf4da11f2bd913ce1b94e071367b2fa8e535ce8c5526e29c'
);
// These literal receiving vectors grant diagnostic classification, never native credit.
const setupFailure = {
	schema_version: 1,
	state: 'setup_failed',
	stage: 'legacy-signature',
	error_class: 'FileNotFoundError'
};
assert.equal(
	Evidence.readSetupFailure(JSON.stringify(setupFailure) + '\n'),
	'::error::Authenticated managed HTTP validation setup failed: stage=legacy-signature; kind=FileNotFoundError. Private diagnostics retained.\n'
);
passed++;
for (const mutation of [
	(value) => {
		value.stage = 'https://dummy-user:dummy-pass@proxy.invalid';
	},
	(value) => {
		value.error_class = 'secret-token';
	},
	(value) => {
		value.message = 'dummy-secret';
	},
	(value) => {
		value.argv = ['--password', 'dummy-secret'];
	},
	(value) => {
		value.schema_version = 2;
	},
	(value) => {
		value.state = 'tools_admitted';
	},
	(value) => {
		value.stage = null;
	},
	(value) => {
		value.error_class = { name: 'RuntimeError' };
	},
	(value) => {
		delete value.stage;
	}
]) {
	const value = structuredClone(setupFailure);
	mutation(value);
	assert.throws(() => Evidence.readSetupFailure(JSON.stringify(value) + '\n'));
	passed++;
}
for (const text of [
	'',
	'private raw stderr\n',
	JSON.stringify(setupFailure),
	JSON.stringify(setupFailure) + '\n' + JSON.stringify(setupFailure) + '\n',
	JSON.stringify(setupFailure) + '\nwarning\n',
	'{"schema_version":1,"state":"setup_failed","stage":"legacy-signature","stage":"legacy-signature","error_class":"FileNotFoundError"}\n',
	'x'.repeat(513),
	'[]\n'
]) {
	assert.throws(() => Evidence.readSetupFailure(text));
	passed++;
}
// Fixed unknown-class fallback remains safe and does not claim a missing binary.
assert.equal(
	Evidence.readSetupFailure(JSON.stringify({ ...setupFailure, error_class: 'Other' }) + '\n'),
	'::error::Authenticated managed HTTP validation setup failed: stage=legacy-signature; kind=Other. Private diagnostics retained.\n'
);
passed++;
assert.ok(
	read('.github/workflows/ci-linux.yml').includes(
		'--setup-diagnostic "$validation_parent/setup.stdout.private"'
	)
);
passed++;
assert.ok(
	setupSource.includes(
		'BaseException.add_note(error, "Fixed setup diagnostic publication unavailable.")'
	)
);
passed++;
// Independent workflow opponents are constructed before expected rejection.
for (const [needle, replacement] of [
	[
		'python3 -B tools/test/test_validation_keyring_preparation.py >',
		'python3 -B tools/test/removed_keyring_controls.py >'
	],
	[
		'python3 -B tools/test/fixtures/validation-curl/prepare_validation_keyring.py --repo',
		'python3 -B tools/test/fixtures/validation-curl/removed_keyring.py --repo'
	],
	['--destination "$validation_parent/keyring" >', '--destination "/foreign/keyring" >'],
	[
		'> "$validation_parent/keyring.stdout.private" 2>',
		'> "$validation_parent/public-keyring.stdout" 2>'
	],
	[
		'echo "::error::Authenticated private validation keyring preparation failed; private inputs retained."',
		'echo "Ignored private keyring preparation failure"'
	]
]) {
	const opponent = uniqueReplace(workflow, needle, replacement);
	assert.throws(() => validateWorkflow(opponent, entry));
	passed++;
}
console.log(
	'[OK] Managed HTTP native CI registration: ' +
		passed +
		' receiving controls passed; native18/public30 unexecuted.'
);
