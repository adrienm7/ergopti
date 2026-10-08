// tools/test/test-macos-stable-signing-identity.cjs

/**
 * ==============================================================================
 * MODULE: macOS Stable Signing Identity Guard
 * DESCRIPTION:
 * Replays the signing section of build_macos_app.sh with codesign and security
 * doubles, and runs create_macos_signing_identity.sh for real with openssl.
 *
 * ROOT CAUSE ENCODED:
 * ErgoptiPlus.app was signed ad hoc (`codesign --sign -`). An ad hoc
 * designated requirement is the code hash, which every build changes, so
 * macOS dropped the Accessibility, Screen Recording, Automation and Login
 * Items grants at every update and users re-granted each one by hand. Signing
 * every nested code object with one stable self-signed certificate turns the
 * requirement into identifier + certificate hash, which later builds satisfy.
 *
 * FEATURES & RATIONALE:
 * 1. With both certificate variables set, the real main() and
 *    build_native_helper() must import the .p12 into a temporary keychain
 *    (partition list open to codesign), sign every object with the
 *    certificate's SHA-1 and none ad hoc, inside-out with the outer app last,
 *    and delete the keychain at exit, also after a failed signature.
 * 2. A requirement that does not name the certificate fails the build, so
 *    the CI log cannot show a silently ad hoc release.
 * 3. Without the variables the build still signs ad hoc, and says loudly what
 *    it costs; one variable without the other fails before any download.
 * 4. A self-check replays a build that ignores the imported identity: the
 *    guard must reject it, or it could not fail for the original bug.
 * 5. The creation script packs a codeSigning, CA:false, digitalSignature
 *    certificate into a .p12 its printed password opens, never prints a
 *    private key, refuses to overwrite its output, and refuses to run in CI.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { spawnSync } = require('child_process');
const { bashExecutable } = require('../lib/git-bash.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const BUILD = fs.readFileSync(path.join(ROOT, 'tools/build/build_macos_app.sh'), 'utf8');
const CREATE = path.join(ROOT, 'tools/build/create_macos_signing_identity.sh');
const HASH = '0123456789ABCDEF0123456789ABCDEF01234567';
const P12_BYTES = Buffer.from('not a real pkcs12, only bytes to round-trip');
const P12_PASSWORD = 'p12-password-under-test';
const errors = [];
const check = (condition, message) => {
	if (!condition) errors.push(message);
};

// ==========================================
// ==========================================
// ======= 1/ Build script replay ===========
// ==========================================
// ==========================================

/**
 * Returns the source between two section banners of the build script.
 * @param {string} source Build script text.
 * @param {string} from Banner title that opens the slice.
 * @param {string} to Banner title that closes it.
 * @returns {string} The slice, or an empty string when a banner is missing.
 */
function sliceBetween(source, from, to) {
	const banner = source.indexOf(from);
	const start = source.indexOf('\n', banner) + 1;
	const end = source.lastIndexOf('\n', source.indexOf(to, start)) + 1;
	return banner < 0 || end <= start ? '' : source.slice(start, end);
}

/**
 * Returns one top-level shell function, from its header to its closing brace.
 * @param {string} source Build script text.
 * @param {string} name Function name.
 * @returns {string} Function source, or an empty string when absent.
 */
function shellFunction(source, name) {
	const start = source.indexOf(`\n${name}() {\n`);
	if (start < 0) return '';
	const end = source.indexOf('\n}\n', start + 1);
	return end < 0 ? '' : source.slice(start + 1, end + 2);
}

/**
 * Runs the real main() or build_native_helper() with every step but signing
 * replaced by a double. codesign and security record their arguments, one
 * call per line, fields separated by a unit separator.
 * @param {string} source Build script text (possibly mutated).
 * @param {{entry: string, base64: string, password: string, dr?: string, failOn?: string}} options
 * @returns {{status: number|null, stderr: string, calls: string[][], leftovers: string[], imported: Buffer|null}}
 */
function replay(source, options) {
	const signing = sliceBetween(source, '======= 8/ Codesign + zip', '======= 9/ Entrypoint');
	const entry = shellFunction(source, options.entry === 'main' ? 'main' : 'build_native_helper');
	const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-signing-'));
	const posix = tmp.replaceAll('\\', '/');
	try {
		const script = `
set -euo pipefail
T="$1"
LOG="$T/calls.log"
: > "$LOG"
record() { local IFS=$'\\x1f'; printf '%s\\n' "$*" >> "$LOG"; }
log()  { printf '[macos-build] %s\\n' "$*" >&2; }
fail() { printf '[macos-build] ERROR: %s\\n' "$*" >&2; exit 1; }
require_cmd() { :; }
codesign() {
	record codesign "$@"
	local arg target=""
	for arg in "$@"; do target="$arg"; done
	if [ -n "\${FAIL_ON:-}" ] && [[ "$target" == *"$FAIL_ON" ]]; then return 1; fi
	if [ "$1" = "--force" ]; then
		case "$target" in
			"$APP_PATH/Contents/MacOS/ErgoptiAutomationQuery") : > "$T/query-signed" ;;
			"$APP_PATH/Contents/MacOS/SystemSwitcherState") : > "$T/switcher-signed" ;;
			"$APP_PATH/Contents/MacOS/ErgoptiPlus"|"$APP_PATH")
				[ -f "$T/query-signed" ] && [ -f "$T/switcher-signed" ] \\
					|| { printf 'CONTROL_UNSIGNED_NESTED_HELPER\\n' >&2; return 1; } ;;
		esac
	fi
	if [ "$1" = "-d" ]; then
		printf 'Executable=%s\\n' "$target" >&2
		printf '%s\\n' "$DR"
	fi
}
security() {
	record security "$@"
	case "$1" in
		create-keychain) : > "$4" ;;
		delete-keychain) rm -f "$2" ;;
		list-keychains) [ "$#" -eq 3 ] && printf '    "/Library/Keychains/ci.keychain-db"\\n' ;;
		import) cp "$2" "$T/imported.p12" ;;
		find-identity)
			printf '\\nPolicy: Code Signing\\n  Matching identities\\n  1) ${HASH} "ErgoptiPlus Self-Signed" (CSSMERR_TP_NOT_TRUSTED)\\n     1 identities found\\n\\n  Valid identities only\\n     0 valid identities found\\n' ;;
	esac
	return 0
}
REPO_ROOT="$T/repo"
LAUNCHER_DIR="$T/launcher"
BUNDLE_ID="com.ergoptiplus.app"
ERGOPTI_VERSION=0.0.0-dev ERGOPTI_BUILD=1 ERGOPTI_CHANNEL=main
HAMMERSPOON_VERSION=1.1.1
BUILD_DIR="$T/build"
APP_PATH="$BUILD_DIR/ErgoptiPlus.app"
ZIP_PATH="$BUILD_DIR/ErgoptiPlus.app.zip"
mkdir -p "$LAUNCHER_DIR" "$T/tmp"
: > "$LAUNCHER_DIR/ErgoptiPlus.entitlements"
: > "$T/launcher.bin"
export TMPDIR="$T/tmp"
MACOS_SIGNING_CERTIFICATE_BASE64="$2"
MACOS_SIGNING_CERTIFICATE_PASSWORD="$3"
DR="$4"
FAIL_ON="$5"
${signing}
${entry}
clean_build_dir() { :; }
download_hammerspoon() { record download; }
build_launcher() { printf '%s\\n' "$T/launcher.bin"; }
assemble_native_runtime() {
	mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Frameworks/Sparkle.framework"
	: > "$APP_PATH/Contents/MacOS/ErgoptiPlus"
	: > "$APP_PATH/Contents/MacOS/SystemSwitcherState"
	: > "$APP_PATH/Contents/MacOS/ErgoptiAutomationQuery"
}
assemble_app() {
	assemble_native_runtime
	mkdir -p "$APP_PATH/Contents/Frameworks/Hammerspoon.app" \\
		"$APP_PATH/Contents/Resources/static/ergopti_plus/macos/socket"
	: > "$APP_PATH/Contents/Resources/static/ergopti_plus/macos/socket/core.so"
}
bash() { :; }
build_icon() { :; }
generate_info_plist() { mkdir -p "$APP_PATH/Contents"; : > "$APP_PATH/Contents/Info.plist"; }
plutil() { :; }
disarm_bundle_sparkle() { :; }
zip_app() { record zip; }
# The full app now delegates both archives to one producer. This isolated
# signing replay accepts only that exact boundary; it does not create archives.
node() {
	[ "$#" -eq 3 ] && [ "$1" = "$REPO_ROOT/tools/build/macos-release-archives.cjs" ] && \
		[ "$2" = "$APP_PATH" ] && [ "$3" = "$BUILD_DIR" ] || fail "Unexpected archive producer invocation."
	record archive-producer "$@"
	# ZIP is one output of this admitted producer, preserving the signing-order check.
	record zip
}
${options.entry === 'main' ? 'main' : 'build_native_helper'}
`;
		const result = spawnSync(
			bashExecutable(),
			['-s', '--', posix, options.base64, options.password, options.dr ?? '', options.failOn ?? ''],
			{ input: script, encoding: 'utf8', timeout: 20000 }
		);
		const logPath = path.join(tmp, 'calls.log');
		const calls = fs.existsSync(logPath)
			? fs
					.readFileSync(logPath, 'utf8')
					.split('\n')
					.filter(Boolean)
					.map((line) => line.split('\x1f'))
			: [];
		const importedPath = path.join(tmp, 'imported.p12');
		return {
			status: result.error ? null : result.status,
			stderr: `${result.stderr ?? ''}${result.error ? String(result.error) : ''}`,
			calls,
			leftovers: fs.existsSync(path.join(tmp, 'tmp'))
				? fs.readdirSync(path.join(tmp, 'tmp'))
				: ['<no TMPDIR>'],
			imported: fs.existsSync(importedPath) ? fs.readFileSync(importedPath) : null
		};
	} finally {
		fs.rmSync(tmp, { recursive: true, force: true });
	}
}

const CERT_DR = `designated => identifier "com.ergoptiplus.app" and certificate leaf = H"${HASH.toLowerCase()}"`;
const ADHOC_DR = 'designated => cdhash H"feedfacefeedfacefeedfacefeedfacefeedface"';
const B64 = P12_BYTES.toString('base64');

/** @returns {string[][]} The codesign calls that write a signature. */
const signatures = (run) =>
	run.calls.filter((call) => call[0] === 'codesign' && call.includes('--sign'));
const signedBy = (call) => call[call.indexOf('--sign') + 1];
const target = (call) => call[call.length - 1];

/**
 * Lists what a certificate build got wrong. Empty means it is sound.
 * @param {ReturnType<typeof replay>} run The replayed build.
 * @param {string[]} expected Path suffixes that must be signed, in order.
 * @returns {string[]}
 */
function certificateProblems(run, expected) {
	const problems = [];
	if (run.status !== 0)
		problems.push(`the build failed: ${run.stderr.trim().split('\n').slice(-3).join(' | ')}`);
	const signed = signatures(run);
	const adHoc = signed.filter((call) => signedBy(call) !== HASH);
	if (adHoc.length > 0) {
		problems.push(
			`signed ${adHoc.map(target).join(', ')} with ${adHoc.map(signedBy).join(', ')} instead of the certificate ${HASH}`
		);
	}
	for (const call of signed) {
		const keychain = call[call.indexOf('--keychain') + 1] ?? '';
		if (!call.includes('--keychain') || !keychain.endsWith('.keychain-db')) {
			problems.push(`${target(call)} was not signed from the temporary keychain`);
		}
	}
	const order = signed.map(target);
	const missing = expected.filter(
		(suffix) => !order.some((signedPath) => signedPath.endsWith(suffix))
	);
	if (missing.length > 0) problems.push(`never signed: ${missing.join(', ')}`);
	const positions = expected.map((suffix) =>
		order.findIndex((signedPath) => signedPath.endsWith(suffix))
	);
	if (positions.some((at, index) => index > 0 && at <= positions[index - 1])) {
		problems.push(`signing order must be ${expected.join(' < ')}, got ${order.join(' < ')}`);
	}
	return problems;
}

/**
 * Checks the keychain life cycle of a certificate build.
 * @param {ReturnType<typeof replay>} run The replayed build.
 * @param {string} label Scenario label.
 */
function checkKeychain(run, label) {
	const security = run.calls.filter((call) => call[0] === 'security').map((call) => call.slice(1));
	const created = security.find((call) => call[0] === 'create-keychain');
	const keychain = created ? created[created.length - 1] : '';
	check(
		created !== undefined && keychain.endsWith('.keychain-db'),
		`${label}: a temporary keychain must be created`
	);
	const verbs = security.map((call) => call[0]);
	for (const verb of [
		'unlock-keychain',
		'import',
		'set-key-partition-list',
		'find-identity',
		'delete-keychain'
	]) {
		check(verbs.includes(verb), `${label}: security ${verb} is missing`);
	}
	check(
		verbs.indexOf('import') < verbs.indexOf('set-key-partition-list'),
		`${label}: the partition list must be set after the import`
	);
	const partition = security.find((call) => call[0] === 'set-key-partition-list') ?? [];
	check(
		partition.join(' ') ===
			`set-key-partition-list -S apple-tool:,apple:,codesign: -s -k ${partition[5]} ${keychain}` &&
			/^[0-9a-f]{48}$/.test(partition[5] ?? ''),
		`${label}: the partition list must open the key to codesign with the random keychain password, got ${partition.join(' ')}`
	);
	const search = security.find((call) => call[0] === 'list-keychains' && call.includes('-s')) ?? [];
	check(
		search[3] === '-s' &&
			search[4] === keychain &&
			search[5] === '/Library/Keychains/ci.keychain-db',
		`${label}: the keychain must be added in front of the existing search list, got ${search.join(' ')}`
	);
	const imported = security.find((call) => call[0] === 'import') ?? [];
	check(
		imported.includes('-P') &&
			imported[imported.indexOf('-P') + 1] === P12_PASSWORD &&
			imported.includes('-T') &&
			imported[imported.indexOf('-T') + 1] === '/usr/bin/codesign',
		`${label}: the .p12 must be imported with its password and codesign allowed, got ${imported.join(' ')}`
	);
	check(
		run.imported !== null && run.imported.equals(P12_BYTES),
		`${label}: the imported .p12 must be the decoded secret`
	);
	const deleted = security.findIndex(
		(call) => call[0] === 'delete-keychain' && call[1] === keychain
	);
	check(deleted === security.length - 1, `${label}: the keychain must be deleted last, at exit`);
	check(
		run.leftovers.length === 0,
		`${label}: the signing work directory must be removed, left ${run.leftovers.join(', ')}`
	);
	check(
		!run.stderr.includes(P12_PASSWORD) && !run.stderr.includes(B64),
		`${label}: the build log must not print the .p12 or its password`
	);
}

const FULL_ORDER = [
	'/socket/core.so',
	'/Contents/Frameworks/Hammerspoon.app',
	'/Contents/Frameworks/Sparkle.framework',
	'/Contents/MacOS/ErgoptiAutomationQuery',
	'/Contents/MacOS/SystemSwitcherState',
	'/Contents/MacOS/ErgoptiPlus',
	'/ErgoptiPlus.app'
];
const HELPER_ORDER = FULL_ORDER.slice(2);

const full = replay(BUILD, { entry: 'main', base64: B64, password: P12_PASSWORD, dr: CERT_DR });
errors.push(
	...certificateProblems(full, FULL_ORDER).map((problem) => `certificate build: ${problem}`)
);
checkKeychain(full, 'certificate build');
const verified = full.calls.filter((call) => call[0] === 'codesign' && call.includes('--verify'));
check(
	verified.some(
		(call) =>
			['--strict', '--deep'].every((flag) => call.includes(flag)) &&
			target(call).endsWith('/ErgoptiPlus.app')
	),
	'certificate build: the app must pass codesign --verify --strict --deep'
);
check(
	full.calls.some((call) => call[0] === 'codesign' && call.join(' ').includes('-d -r-')),
	'certificate build: the designated requirement must be printed to the log'
);
check(
	full.stderr.includes(`certificate leaf = H"${HASH.toLowerCase()}"`),
	'certificate build: the log must show the certificate requirement'
);
const lastSignature = full.calls.lastIndexOf(signatures(full).at(-1));
check(
	full.calls.findIndex((call) => call[0] === 'zip') > lastSignature,
	'certificate build: the zip must be made after the last signature'
);

const archiveCalls = full.calls.filter((call) => call[0] === 'archive-producer');
const fullApp = target(signatures(full).at(-1) ?? []);
const fullBuild = path.posix.dirname(fullApp);
check(
	archiveCalls.length === 1 &&
		JSON.stringify(archiveCalls[0]) ===
			JSON.stringify([
				'archive-producer',
				path.posix.join(
					path.posix.dirname(fullBuild),
					'repo/tools/build/macos-release-archives.cjs'
				),
				fullApp,
				fullBuild
			]),
	'certificate build: exactly the owned archive producer receives the signed app and build directory'
);
/** @param {ReturnType<typeof replay>} run Replay whose archive order is checked. @returns {boolean} */
function archiveOrderIsValid(run) {
	const archiveAt = run.calls.findIndex((call) => call[0] === 'archive-producer');
	const signatureAt = run.calls.lastIndexOf(signatures(run).at(-1));
	const verificationAt = run.calls
		.map((call, index) => (call[0] === 'codesign' && call.includes('--verify') ? index : -1))
		.filter((index) => index >= 0);
	return (
		signatureAt >= 0 &&
		archiveAt > signatureAt &&
		verificationAt.length === 2 &&
		verificationAt.every((index) => index < archiveAt)
	);
}
check(
	archiveOrderIsValid(full),
	'certificate build: archive creation follows both real signature verifications'
);

const helper = replay(BUILD, { entry: 'helper', base64: B64, password: P12_PASSWORD, dr: CERT_DR });
errors.push(
	...certificateProblems(helper, HELPER_ORDER).map((problem) => `native helper: ${problem}`)
);
checkKeychain(helper, 'native helper');
check(
	!helper.calls.some((call) => call[0] === 'archive-producer') &&
		helper.calls.filter((call) => call[0] === 'zip').length === 1,
	'native helper: the original helper ZIP owner remains independent of the full-app producer'
);

// Both headless and full bundles require nested signatures in each identity mode.
const adHocHelper = replay(BUILD, { entry: 'helper', base64: '', password: '', dr: ADHOC_DR });
const adHocHelperSignatures = signatures(adHocHelper);
check(adHocHelper.status === 0, 'native ad hoc helper: nested signing completes');
check(
	adHocHelperSignatures.length === HELPER_ORDER.length &&
		adHocHelperSignatures.every((call) => signedBy(call) === '-') &&
		HELPER_ORDER.every((suffix, index) => target(adHocHelperSignatures[index]).endsWith(suffix)),
	'native ad hoc helper: each fixed nested object is signed inside-out before the app'
);
for (const [label, run] of [
	['full certificate', full],
	['helper certificate', helper],
	['helper ad hoc', adHocHelper]
]) {
	const signed = signatures(run);
	const query = signed.find((call) =>
		target(call).endsWith('/Contents/MacOS/ErgoptiAutomationQuery')
	);
	const main = signed.find((call) => target(call).endsWith('/Contents/MacOS/ErgoptiPlus'));
	const switcher = signed.find((call) =>
		target(call).endsWith('/Contents/MacOS/SystemSwitcherState')
	);
	check(
		query && query[query.indexOf('--identifier') + 1] === 'com.ergoptiplus.app.automation-query',
		`${label}: the automation helper keeps its dedicated identifier`
	);
	check(
		main && main[main.indexOf('--identifier') + 1] === 'com.ergoptiplus.app',
		`${label}: the main executable keeps its app identifier`
	);
	check(
		query &&
			main &&
			query.includes('--entitlements') &&
			main.includes('--entitlements') &&
			query[query.indexOf('--entitlements') + 1] === main[main.indexOf('--entitlements') + 1],
		`${label}: query and main retain the exact same existing entitlement file`
	);
	check(
		switcher &&
			switcher[switcher.indexOf('--identifier') + 1] ===
				'com.ergoptiplus.app.system-switcher-state' &&
			!switcher.includes('--entitlements'),
		`${label}: the read-only switcher identity remains separate without automation entitlements`
	);
}
for (const name of ['ErgoptiAutomationQuery', 'SystemSwitcherState']) {
	const refused = replay(BUILD, {
		entry: 'helper',
		base64: B64,
		password: P12_PASSWORD,
		dr: CERT_DR,
		failOn: name
	});
	check(refused.status !== 0, `${name}: a nested signature refusal stops the helper build`);
	check(
		!signatures(refused).some(
			(call) =>
				target(call).endsWith('/Contents/MacOS/ErgoptiPlus') ||
				target(call).endsWith('/ErgoptiPlus.app')
		),
		`${name}: no main or outer signature follows a failed nested signature`
	);
	check(
		!refused.calls.some((call) => call[0] === 'zip'),
		`${name}: failed nested signing cannot package the helper`
	);
	checkKeychain(refused, `${name} nested signing refusal`);
}

// A requirement that still reads as ad hoc means the certificate did not
// take; the build must stop rather than ship it.
const mismatch = replay(BUILD, {
	entry: 'main',
	base64: B64,
	password: P12_PASSWORD,
	dr: ADHOC_DR
});
check(
	mismatch.status !== 0 && /does not name the certificate/.test(mismatch.stderr),
	'a certificate build whose requirement does not name the certificate must fail'
);
check(
	mismatch.calls.some((call) => call[0] === 'security' && call[1] === 'delete-keychain'),
	'a failed certificate build must still delete its keychain'
);

const failed = replay(BUILD, {
	entry: 'main',
	base64: B64,
	password: P12_PASSWORD,
	dr: CERT_DR,
	failOn: 'Hammerspoon.app'
});
check(failed.status !== 0, 'a failed signature must fail the build');
check(
	![failed, mismatch].some((run) => run.calls.some((call) => call[0] === 'archive-producer')),
	'a failed signature or refused certificate requirement must never enter archive creation'
);
check(
	failed.calls.some((call) => call[0] === 'security' && call[1] === 'delete-keychain') &&
		failed.leftovers.length === 0,
	'a build that fails while signing must still delete its keychain and work directory'
);

const adHoc = replay(BUILD, { entry: 'main', base64: '', password: '', dr: ADHOC_DR });
check(
	adHoc.status === 0,
	`the ad hoc build must still succeed: ${adHoc.stderr.trim().split('\n').slice(-2).join(' | ')}`
);
check(
	signatures(adHoc).length >= FULL_ORDER.length &&
		signatures(adHoc).every((call) => signedBy(call) === '-'),
	'without the certificate every object must be signed ad hoc'
);
check(
	!adHoc.calls.some((call) => call[0] === 'security'),
	'the ad hoc build must not touch any keychain'
);
check(
	/WARNING: No MACOS_SIGNING_CERTIFICATE_BASE64[\s\S]*Accessibility, Screen Recording, Automation/.test(
		adHoc.stderr
	),
	'the ad hoc build must say loudly that TCC grants will not survive the update'
);

for (const [label, base64, password] of [
	['password alone', '', P12_PASSWORD],
	['certificate alone', B64, '']
]) {
	const partial = replay(BUILD, { entry: 'main', base64, password, dr: CERT_DR });
	check(
		partial.status !== 0 && /set both or neither/.test(partial.stderr),
		`${label}: half a signing configuration must fail the build`
	);
	check(
		!partial.calls.some((call) => call[0] === 'download' || call[0] === 'codesign'),
		`${label}: half a signing configuration must fail before any download or signature`
	);
}

// Self-check: the original bug, a build that signs ad hoc whatever the
// variables say, must be rejected by the checks above.
const adHocOnly = BUILD.replace(
	'codesign --force --sign "$SIGN_IDENTITY" --keychain "$SIGNING_KEYCHAIN" --timestamp=none "$@"',
	'codesign --force --sign - "$@"'
);
if (adHocOnly === BUILD) {
	errors.push('self-check: the certificate codesign call drifted; re-derive the ad hoc mutation');
} else {
	const mutated = replay(adHocOnly, {
		entry: 'main',
		base64: B64,
		password: P12_PASSWORD,
		dr: CERT_DR
	});
	check(
		certificateProblems(mutated, FULL_ORDER).length > 0,
		'self-check: a build that signs ad hoc with the certificate variables set went unnoticed'
	);
}

// Replay the original native ordering fault against the dependency-aware tool port.
const launcherSignature =
	'\tsign_code \\\n\t\t--identifier "$BUNDLE_ID" \\\n\t\t--entitlements "$entitlements" \\\n\t\t"$APP_PATH/Contents/MacOS/ErgoptiPlus"\n';
check(
	BUILD.split(launcherSignature).length === 2,
	'nested signing self-check: exact main signature is present'
);
const prematureLauncher = BUILD.replace(launcherSignature, '').replace(
	'\tlocal automation_query="$APP_PATH/Contents/MacOS/ErgoptiAutomationQuery"\n',
	launcherSignature + '\tlocal automation_query="$APP_PATH/Contents/MacOS/ErgoptiAutomationQuery"\n'
);
check(prematureLauncher !== BUILD, 'nested signing self-check: actual producer order must change');
for (const entry of ['main', 'helper']) {
	for (const [label, base64, password, dr] of [
		['certificate', B64, P12_PASSWORD, CERT_DR],
		['ad hoc', '', '', ADHOC_DR]
	]) {
		const refused = replay(prematureLauncher, { entry, base64, password, dr });
		check(
			refused.status !== 0 && /CONTROL_UNSIGNED_NESTED_HELPER/.test(refused.stderr),
			`${entry} ${label}: unsigned nested code must refuse the main signature`
		);
		check(
			!refused.calls.some((call) => call[0] === 'archive-producer' || call[0] === 'zip'),
			`${entry} ${label}: unsigned nested code cannot reach archive creation`
		);
		if (base64) checkKeychain(refused, `${entry} ${label} unsigned nested helper`);
	}
}

// Self-check the narrowly admitted producer boundary, not a generic node double.
const archiveInvocation =
	'node "$REPO_ROOT/tools/build/macos-release-archives.cjs" "$APP_PATH" "$BUILD_DIR"';
for (const [label, invocation] of [
	['wrong producer', 'node "$REPO_ROOT/tools/build/foreign-archives.cjs" "$APP_PATH" "$BUILD_DIR"'],
	[
		'wrong app',
		'node "$REPO_ROOT/tools/build/macos-release-archives.cjs" "$BUILD_DIR" "$BUILD_DIR"'
	],
	[
		'wrong output',
		'node "$REPO_ROOT/tools/build/macos-release-archives.cjs" "$APP_PATH" "$APP_PATH"'
	]
]) {
	const source = BUILD.replace(archiveInvocation, invocation);
	check(source !== BUILD, `self-check: archive invocation drifted for ${label}`);
	const refused = replay(source, {
		entry: 'main',
		base64: B64,
		password: P12_PASSWORD,
		dr: CERT_DR
	});
	check(
		refused.status !== 0 &&
			/Unexpected archive producer invocation/.test(refused.stderr) &&
			!refused.calls.some((call) => call[0] === 'archive-producer'),
		`self-check: ${label} must be rejected by the owned producer port`
	);
	checkKeychain(refused, label);
}
const earlyArchiveSource = BUILD.replace(`\t${archiveInvocation}\n`, '').replace(
	'\tcodesign_app\n',
	`\t${archiveInvocation}\n\tcodesign_app\n`
);
check(
	earlyArchiveSource !== BUILD,
	'self-check: archive/signing order mutation must alter the real main'
);
const earlyArchive = replay(earlyArchiveSource, {
	entry: 'main',
	base64: B64,
	password: P12_PASSWORD,
	dr: CERT_DR
});
check(
	earlyArchive.status === 0 &&
		earlyArchive.calls.filter((call) => call[0] === 'archive-producer').length === 1 &&
		!archiveOrderIsValid(earlyArchive),
	'self-check: an admitted archive producer before signing must fail the order guard'
);

// ==========================================
// ==========================================
// ======= 2/ Workflow wiring ===============
// ==========================================
// ==========================================

// macos-release-launch.yml re-signs a downloaded release ad hoc for a launch
// diagnostic that is never distributed; that is the only other ad hoc site.
for (const rel of ['.github/workflows/ci-macos.yml', '.github/workflows/ci.yml']) {
	const text = fs.readFileSync(path.join(ROOT, rel), 'utf8');
	check(
		!/codesign[^\n]*--sign -/.test(text),
		`${rel} must not sign ad hoc; build_macos_app.sh owns the signature`
	);
}

// ==========================================
// ==========================================
// ======= 3/ Creation script ===============
// ==========================================
// ==========================================

const createTmp = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-signing-create-'));
try {
	const out = path.join(createTmp, 'identity');
	const env = { ...process.env };
	delete env.CI;
	delete env.GITHUB_ACTIONS;
	const run = (target, extraEnv = {}) =>
		spawnSync(bashExecutable(), [CREATE.replaceAll('\\', '/'), target.replaceAll('\\', '/')], {
			encoding: 'utf8',
			timeout: 60000,
			env: { ...env, ...extraEnv }
		});
	const first = run(out);
	check(
		!first.error && first.status === 0,
		`create_macos_signing_identity.sh failed: ${first.stderr || first.error}`
	);
	const printed = `${first.stdout}${first.stderr}`;
	check(!/PRIVATE KEY/.test(printed), 'the creation script must never print a private key');
	const password =
		/==== MACOS_SIGNING_CERTIFICATE_PASSWORD ====\n([^\n]+)\n/.exec(first.stdout)?.[1] ?? '';
	const base64 =
		/==== MACOS_SIGNING_CERTIFICATE_BASE64[^\n]*\n([^\n]+)\n==== end ====/.exec(
			first.stdout
		)?.[1] ?? '';
	check(
		/^[0-9a-f]{32}$/.test(password),
		'the creation script must print a random password for MACOS_SIGNING_CERTIFICATE_PASSWORD'
	);
	const p12Path = path.join(out, 'ErgoptiPlus-signing.p12');
	const certPath = path.join(out, 'ErgoptiPlus-signing.cer.pem');
	check(
		fs.existsSync(p12Path) && Buffer.from(base64, 'base64').equals(fs.readFileSync(p12Path)),
		'the printed MACOS_SIGNING_CERTIFICATE_BASE64 must be the written .p12'
	);
	for (const file of fs.existsSync(out) ? fs.readdirSync(out) : []) {
		check(
			!/PRIVATE KEY/.test(fs.readFileSync(path.join(out, file), 'latin1')),
			`${file} must not hold a key in clear`
		);
	}
	if (fs.existsSync(certPath)) {
		const cert = new crypto.X509Certificate(fs.readFileSync(certPath));
		check(
			cert.subject === 'CN=ErgoptiPlus Self-Signed',
			`unexpected certificate subject ${cert.subject}`
		);
		check(cert.ca === false, 'the certificate must be CA:false');
		check(
			(cert.keyUsage ?? []).includes('1.3.6.1.5.5.7.3.3'),
			'the certificate must carry extendedKeyUsage codeSigning'
		);
		const years =
			(Date.parse(cert.validTo) - Date.parse(cert.validFrom)) / (365 * 24 * 3600 * 1000);
		check(years >= 9.9, `the certificate must be valid about ten years, got ${years.toFixed(1)}`);
		const text = spawnSync('openssl', ['x509', '-in', certPath, '-noout', '-text'], {
			encoding: 'utf8'
		});
		check(
			text.status === 0 && /Key Usage: critical\s+Digital Signature\s*\n/.test(text.stdout),
			'the certificate key usage must be digitalSignature alone'
		);
		const info = spawnSync(
			'openssl',
			['pkcs12', '-in', p12Path, '-info', '-noout', '-passin', `pass:${password}`],
			{ encoding: 'utf8' }
		);
		const pkcs12 = `${info.stdout}${info.stderr}`;
		check(
			info.status === 0 &&
				/MAC: sha1/.test(pkcs12) &&
				/Shrouded Keybag: pbeWithSHA1And3-KeyTripleDES-CBC/.test(pkcs12),
			`the .p12 must open with the printed password and use 3DES + SHA-1 for security import: ${pkcs12.trim()}`
		);
	}
	const before = fs.existsSync(p12Path) ? fs.readFileSync(p12Path) : Buffer.alloc(0);
	const second = run(out);
	check(
		second.status !== 0 && /Refusing to overwrite/.test(second.stderr),
		'a second run must refuse to overwrite the identity'
	);
	check(
		fs.existsSync(p12Path) && fs.readFileSync(p12Path).equals(before),
		'a refused run must leave the .p12 untouched'
	);
	const inCi = run(path.join(createTmp, 'ci'), { GITHUB_ACTIONS: 'true' });
	check(
		inCi.status !== 0 &&
			/Refusing to run in CI/.test(inCi.stderr) &&
			!fs.existsSync(path.join(createTmp, 'ci')),
		'the creation script must refuse to run in CI'
	);
} finally {
	fs.rmSync(createTmp, { recursive: true, force: true });
}

if (errors.length > 0) {
	console.error('[FAIL] macOS stable signing identity:');
	for (const error of errors) console.error(`  - ${error}`);
	process.exit(1);
}

console.log(
	'[OK] macOS builds sign every object with the imported certificate when it is set, ad hoc (loudly) otherwise, and the identity is created once, never overwritten.'
);
