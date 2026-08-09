// tools/test/test-macos-remap-launchagent.cjs

/**
 * ==============================================================================
 * MODULE: macOS Remap LaunchAgent Crash Guard
 * DESCRIPTION:
 * Proves that ErgoptiPlus ships and registers an independent user LaunchAgent
 * before embedded Hammerspoon starts, and that the native lease worker cannot
 * activate a Karabiner generation before the guardian durably arms that exact
 * token.
 *
 * ROOT CAUSE ENCODED:
 * The in-process outer/inner pair can fence Hammerspoon loss, but SIGKILL of all
 * three private processes leaves no survivor to revoke the generation. Looking
 * up or killing a process named "Karabiner" is not a valid repair: Karabiner's
 * UI, Core Service, session agents, watchers, and VirtualHID components are
 * shared with the user's personal configuration. The independent survivor must
 * therefore derive and revoke only one exact ErgoptiPlus token.
 *
 * FEATURES & RATIONALE:
 * 1. Packaging: the signed app contains one own-label LaunchAgent and the build
 *    copies it into Contents/Library/LaunchAgents.
 * 2. Causal ordering: durable record + kernel liveness proof + ARMED precede
 *    inner spawn and ACTIVATE; source presence alone is not sufficient.
 * 3. Isolation: the guardian accepts only a token and derives the canonical CLI
 *    plus mode/tombstone names; no stock Karabiner process family is targeted.
 * 4. Native behavior: XCTest must include abandonment and pre-ARM failure cases,
 *    because a source grep cannot prove flock/fsync/process-loss semantics.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { selectGates } = require('./verify-change.cjs');
const {
	commandPlan: swiftLauncherCommandPlan,
	run: runSwiftLauncherGate,
} = require('./run-macos-swift-launcher.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const LAUNCHER_ROOT = path.join(ROOT, 'static', 'ergopti_plus', 'macos', 'launcher');
const SOURCE_ROOT = path.join(LAUNCHER_ROOT, 'Sources', 'ErgoptiPlus');
const TEST_ROOT = path.join(LAUNCHER_ROOT, 'Tests', 'ErgoptiPlusTests');
const BUILD_SCRIPT = fs.readFileSync(path.join(ROOT, 'tools', 'build', 'build_macos_app.sh'), 'utf8');
const PACKAGE = fs.readFileSync(path.join(LAUNCHER_ROOT, 'Package.swift'), 'utf8');

/** Reads every matching source file under one fixed tree. */
function readTree(directory, extension) {
	return fs.readdirSync(directory, { withFileTypes: true })
		.flatMap((entry) => {
			const entryPath = path.join(directory, entry.name);
			if (entry.isDirectory()) return readTree(entryPath, extension);
			return entry.isFile() && entry.name.endsWith(extension)
				? [fs.readFileSync(entryPath, 'utf8')]
				: [];
		})
		.join('\n');
}

const SWIFT = readTree(SOURCE_ROOT, '.swift');
const XCTEST = readTree(TEST_ROOT, '.swift');
const PLIST_PATH = path.join(
	LAUNCHER_ROOT,
	'com.ergoptiplus.remap-guardian.plist'
);
const PLIST = fs.existsSync(PLIST_PATH) ? fs.readFileSync(PLIST_PATH, 'utf8') : '';
const failures = [];

const PLIST_WITHOUT_COMMENTS = PLIST.replace(/<!--[\s\S]*?-->/g, '');

/** Escapes one literal value before interpolation into a regular expression. */
function escapeRegex(value) {
	return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/** Reads one simple string value from the fixed property-list fixture. */
function plistString(key) {
	const match = PLIST_WITHOUT_COMMENTS.match(new RegExp(
		`<key>\\s*${escapeRegex(key)}\\s*</key>\\s*<string>([^<]*)</string>`
	));
	return match?.[1] ?? null;
}

/** Reads one simple boolean value from the fixed property-list fixture. */
function plistBoolean(key) {
	const match = PLIST_WITHOUT_COMMENTS.match(new RegExp(
		`<key>\\s*${escapeRegex(key)}\\s*</key>\\s*<(true|false)\\s*/>`
	));
	return match?.[1] === 'true';
}

/** Reads one string-array value from the fixed property-list fixture. */
function plistArray(key) {
	const match = PLIST_WITHOUT_COMMENTS.match(new RegExp(
		`<key>\\s*${escapeRegex(key)}\\s*</key>\\s*<array>([\\s\\S]*?)</array>`
	));
	return match
		? [...match[1].matchAll(/<string>([^<]*)<\/string>/g)].map((item) => item[1])
		: null;
}

/** Reads one decimal integer value from the fixed property-list fixture. */
function plistInteger(key) {
	const match = PLIST_WITHOUT_COMMENTS.match(new RegExp(
		`<key>\\s*${escapeRegex(key)}\\s*</key>\\s*<integer>(-?[0-9]+)</integer>`
	));
	return match ? Number.parseInt(match[1], 10) : null;
}

/** Accumulates one mutation-sensitive contract failure. */
function check(condition, message) {
	if (!condition) failures.push(message);
}

/** Finds one ordered source boundary and records absence as a failure. */
function indexAfter(source, needle, after, message) {
	const index = source.indexOf(needle, after);
	check(index >= 0, message);
	return index;
}

check(SWIFT.length > 50000, 'native launcher sources are missing or truncated');
check(XCTEST.length > 20000, 'native launcher XCTest sources are missing or truncated');
check(PLIST.length > 200, 'the bundled remap LaunchAgent plist is missing or empty');
const topLevelKeys = [...PLIST_WITHOUT_COMMENTS.matchAll(/<key>\s*([^<]+?)\s*<\/key>/g)]
	.map((match) => match[1].trim());
const expectedPlistKeys = [
	'Label',
	'BundleProgram',
	'ProgramArguments',
	'RunAtLoad',
	'KeepAlive',
	'ProcessType',
	'ThrottleInterval',
];
check(JSON.stringify(topLevelKeys) === JSON.stringify(expectedPlistKeys),
	'the packaged LaunchAgent must contain each exact allowed top-level key once and no others');
check(/^\s*<\?xml[\s\S]*<\/plist>\s*$/.test(PLIST_WITHOUT_COMMENTS),
	'the packaged LaunchAgent must have one complete plist document with no trailing payload');
check(plistString('Label') === 'com.ergoptiplus.remap-guardian',
	'the LaunchAgent must use the exact ErgoptiPlus-owned label');
check(plistString('BundleProgram') === 'Contents/MacOS/ErgoptiPlus',
	'the modern LaunchAgent must resolve the exact signed-bundle executable');
check(JSON.stringify(plistArray('ProgramArguments')) === JSON.stringify([
	'ErgoptiPlus',
	'--karabiner-lease-guardian',
]), 'the LaunchAgent argv must contain only the dedicated headless guardian role');
check(plistBoolean('RunAtLoad'), 'the guardian must start when launchd loads the job');
check(plistBoolean('KeepAlive'), 'launchd must restart the guardian after Force Quit/SIGKILL');
check(plistString('ProcessType') === 'Background',
	'the guardian must remain an independent background process');
check(plistInteger('ThrottleInterval') === 10,
	'the guardian restart throttle must remain exactly 10 seconds');
check(plistString('Label') && SWIFT.includes(
	`let kRemapGuardianLabel = "${plistString('Label')}"`
), 'the Swift service label must equal the packaged plist label');
check(SWIFT.includes('let kRemapGuardianPlistName = "com.ergoptiplus.remap-guardian.plist"'),
	'the Swift service registration must name the exact packaged plist');
const guardianCopy = BUILD_SCRIPT.indexOf('cp "$remap_guardian_plist"');
const guardianDestination = BUILD_SCRIPT.indexOf(
	'"$APP_PATH/Contents/Library/LaunchAgents/com.ergoptiplus.remap-guardian.plist"',
	guardianCopy
);
const guardianLint = BUILD_SCRIPT.indexOf('plutil -lint', guardianDestination);
const mainStart = BUILD_SCRIPT.indexOf('main() {');
const mainEnd = BUILD_SCRIPT.indexOf('\nmain "$@"', mainStart);
const mainBody = mainStart >= 0 && mainEnd > mainStart
	? BUILD_SCRIPT.slice(mainStart, mainEnd)
	: '';
const assembleCall = mainBody.indexOf('assemble_app ');
const codesignCall = mainBody.indexOf('codesign_app');
check(guardianCopy >= 0 && guardianDestination > guardianCopy,
	'the app builder must copy the exact guardian plist to Contents/Library/LaunchAgents');
check(guardianLint > guardianDestination,
	'the copied LaunchAgent must pass plutil before packaging continues');
check(assembleCall >= 0 && codesignCall > assembleCall,
	'the entrypoint must assemble and lint the LaunchAgent before calling codesign_app');
check(PACKAGE.split(
	'.define("ERGOPTI_GUARDIAN_TEST_SUPPORT", .when(configuration: .debug))'
).length - 1 === 2,
	'the executable and XCTest targets must both compile guardian test support in debug builds');
check(selectGates([
	'static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/RemapLeaseGuardian.swift',
]).has('js'), 'a launcher-only change must select the JS structural guardian gate');
check(selectGates([
	'static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/RemapLeaseGuardian.swift',
]).has('swift-launcher'), 'a launcher-only change must select native Swift compilation/XCTest');

const nativePlan = swiftLauncherCommandPlan();
check(nativePlan.length === 3, 'the native launcher gate must have exactly lint, build, and test phases');
check(nativePlan[0][0] === 'plutil' && JSON.stringify(nativePlan[0][1].slice(0, 1)) === '["-lint"]',
	'the first native phase must plutil-lint the bundled LaunchAgent');
check(nativePlan[1][0] === 'swift'
	&& nativePlan[1][1].join(' ').includes('build -c release --product ErgoptiPlus'),
	'the second native phase must compile the shipping release product');
check(nativePlan[2][0] === 'swift' && nativePlan[2][1][0] === 'test',
	'the final native phase must execute XCTest');
const simulatedCalls = [];
const simulatedFailure = runSwiftLauncherGate({
	platform: 'darwin',
	spawn(command, arguments_) {
		simulatedCalls.push([command, arguments_]);
		return { status: simulatedCalls.length === 2 ? 23 : 0 };
	},
	log() {},
	error() {},
});
check(simulatedFailure === 23 && simulatedCalls.length === 2,
	'the native launcher gate must stop immediately and propagate a failing phase status');
let deferredSpawnCalls = 0;
check(runSwiftLauncherGate({
	platform: 'win32',
	spawn() {
		deferredSpawnCalls += 1;
		return { status: 0 };
	},
	log() {},
	error() {},
}) === 0 && deferredSpawnCalls === 0,
	'non-macOS verification must report deferral without pretending to spawn native tools');

for (const required of [
	'LeaseGuardianRecord',
	'LeaseGuardianRegistration',
	'beginLiveTransport()',
	'endLiveTransport()',
	'--karabiner-lease-guardian',
	'dispatchMain()',
	'flock(',
	'fsync(',
	'ARMED',
]) {
	check(SWIFT.includes(required), `native guardian contract is missing ${required}`);
}

const outerRun = SWIFT.indexOf('final class KarabinerLeaseOuterRuntime');
const arm = indexAfter(SWIFT, 'guardianRegistration.arm', outerRun,
	'outer runtime must arm the independent guardian');
const spawn = indexAfter(SWIFT, 'spawner.spawn(identity: identity)', outerRun,
	'outer runtime inner spawn must remain locatable');
check(outerRun >= 0 && arm >= 0 && spawn >= 0 && arm < spawn,
	'the guardian must durably return ARMED before any inner can be spawned or activated');

const singletonStartup = SWIFT.indexOf('private func acquireSingletonLock()');
const sharedProbe = indexAfter(SWIFT, 'probeSingletonWithoutOwnership()', singletonStartup,
	'guardian startup must first perform a non-owning singleton probe');
const activationDrain = indexAfter(
	SWIFT,
	'Darwin.flock(activationGateDescriptor, LOCK_EX)',
	sharedProbe,
	'guardian startup must drain the activation gate'
);
const singletonOwnership = indexAfter(SWIFT, 'acquireSingletonExclusive()', activationDrain,
	'guardian startup must acquire singleton ownership only after activation drain');
const activePublication = indexAfter(SWIFT, 'state: .active', singletonOwnership,
	'guardian startup ACTIVE publication must remain locatable');
check(singletonStartup >= 0 && sharedProbe < activationDrain
	&& activationDrain < singletonOwnership && singletonOwnership < activePublication,
	'replacement startup must drain prior live writes before any exclusive singleton ownership');
const probeDefinition = SWIFT.indexOf('private func probeSingletonWithoutOwnership()');
const probeSharedLock = indexAfter(SWIFT, 'LOCK_SH | LOCK_NB', probeDefinition,
	'singleton preflight must use a compatible shared lock');
const probeEnd = SWIFT.indexOf('\n\t}', probeDefinition);
check(probeDefinition >= 0 && probeSharedLock > probeDefinition && probeSharedLock < probeEnd,
	'the preflight probe must never impersonate an exclusive guardian generation');

const atomicGuardianWrite = SWIFT.indexOf('func writeGuardianFileAtomically(');
const acknowledgementWriterLock = indexAfter(
	SWIFT,
	'Darwin.flock(descriptor, LOCK_EX | LOCK_NB)',
	atomicGuardianWrite,
	'atomic ACK publication must exclusively lock its inode'
);
const acknowledgementReader = SWIFT.indexOf('private func readGuardianAcknowledgement(');
const acknowledgementReaderLock = indexAfter(
	SWIFT,
	'Darwin.flock(descriptor, LOCK_SH | LOCK_NB)',
	acknowledgementReader,
	'ACK readers must reject a publication whose inode is still locked'
);
check(atomicGuardianWrite >= 0 && acknowledgementWriterLock > atomicGuardianWrite
	&& acknowledgementReader >= 0 && acknowledgementReaderLock > acknowledgementReader,
	'a visible ACK must remain unreadable until fsync succeeds or rollback removes it');
const guardianTermination = SWIFT.indexOf('private func beginTermination(reason: String)');
const terminationGate = indexAfter(
	SWIFT,
	'activationGateLocker(activationGateDescriptor)',
	guardianTermination,
	'guardian termination activation drain must remain locatable'
);
const drainingPublication = indexAfter(SWIFT, 'state: .draining', guardianTermination,
	'guardian DRAINING publication must remain locatable');
check(guardianTermination >= 0 && terminationGate < drainingPublication,
	'DRAINING must linearize after every previously authorized shared transport');

const appDelegate = SWIFT.indexOf('final class AppDelegate');
const ensureAgent = indexAfter(SWIFT, 'beginRemapGuardianRegistration(executablePath:', appDelegate,
	'the GUI launcher must begin the independent guardian registration');
const launchHS = indexAfter(SWIFT, 'launchHammerspoon(at:', appDelegate,
	'the embedded Hammerspoon launch must remain locatable');
check(appDelegate >= 0 && ensureAgent >= 0 && launchHS >= 0 && ensureAgent < launchHS,
	'the independent guardian must be registered before embedded Hammerspoon starts');

for (const forbidden of [
	'Karabiner-Core-Service',
	'karabiner_grabber',
	'karabiner_console_user_server',
	'Karabiner-Menu',
	'VirtualHID',
]) {
	check(!PLIST.includes(forbidden),
		`the ErgoptiPlus LaunchAgent must never target shared process family ${forbidden}`);
}

check(/test\w*Guardian\w*Refuses\w*Activation\w*Before\w*Armed/i.test(XCTEST),
	'XCTest must behaviorally prove pre-ARM failure performs no activation');
check(/test\w*Guardian\w*Fences\w*Abandoned\w*Record/i.test(XCTEST),
	'XCTest must behaviorally prove exact abandoned-record fencing');
check(/test\w*Guardian\w*Leaves\w*Personal\w*Karabiner\w*Processes/i.test(XCTEST),
	'XCTest must prove the guardian never signals personal/shared Karabiner processes');
check(/test\w*Guardian\w*Process\w*Remains\w*Alive/i.test(XCTEST),
	'XCTest must prove the real guardian process remains alive after startup');
check(/test\w*Guardian\w*Presence\w*Probes\w*DoNot\w*Impersonate\w*Guardian/i.test(XCTEST),
	'XCTest must prove concurrent outer probes cannot impersonate the guardian lock');
check(/test\w*Modern\w*Guardian\w*Registration\w*Never\w*Bypasses\w*User\w*Denial/i.test(XCTEST),
	'XCTest must prove modern registration errors cannot bypass a disabled background item');
check(/test\w*Managed\w*Hammerspoon\w*Waits\w*For\w*Guardian\w*Registration\w*Result\w*Before\w*Child\w*Start/i.test(XCTEST),
	'XCTest must behaviorally prove composed startup waits for guardian registration');
check(/test\w*Guardian\w*Fences\w*Externally\w*Unlinked\w*Live\w*Record/i.test(XCTEST),
	'XCTest must prove pathname deletion cannot impersonate graceful retirement');
check(/test\w*Guardian\w*Skips\w*Explicitly\w*Retired\w*Record/i.test(XCTEST),
	'XCTest must prove only the durable RETIRED state suppresses duplicate fencing');
check(/test\w*Guardian\w*Fences\w*Retirement\w*From\w*Different\w*Record\w*Nonce/i.test(XCTEST),
	'XCTest must prove a foreign canonical RETIRED payload cannot suppress fencing');
check(/test\w*Guardian\w*Restart\w*Recovers\w*Stale\w*Acknowledgement\w*Temporary/i.test(XCTEST),
	'XCTest must prove a stale ACK temporary cannot block crash recovery');
check(/test\w*Guardian\w*Drains\w*Replaced\w*Records\w*Directory\w*Before\w*Restart/i.test(XCTEST),
	'XCTest must prove namespace replacement fences before the old guardian exits');
check(/test\w*Guardian\w*Loss\w*Does\w*Not\w*Outrank\w*Stop\w*Same\w*Parent\w*Batch/i.test(XCTEST),
	'XCTest must prove STOP remains terminal when guardian loss shares its input batch');
check(/test\w*Guardian\w*Restart\w*Prioritizes\w*Acknowledged\w*Records\w*Beyond\w*Unarmed\w*Cap/i.test(XCTEST),
	'XCTest must prove unarmed records cannot evict active acknowledged leases after restart');
check(/test\w*Guardian\w*Termination\w*Fences\w*Locked\w*Active\w*Record\w*Before\w*Exit/i.test(XCTEST),
	'XCTest must prove disabling the guardian fences active locked records before exit');
check(/test\w*Guardian\w*Termination\w*Cannot\w*Fence\w*Before\w*Armed\w*Activation\w*Completes/i.test(XCTEST),
	'XCTest must prove termination cannot race ahead of an accepted activation');
check(/test\w*Guardian\w*Termination\w*Waits\w*For\w*Post\w*Ready\w*Live\w*Transport\w*Acknowledgement/i.test(XCTEST),
	'XCTest must prove termination cannot overtake a post-READY live transport');
check(/test\w*Guardian\w*Cannot\w*Publish\w*Draining\w*Between\w*Revalidation\w*And\w*Live\w*Acknowledgement/i.test(XCTEST),
	'XCTest must linearize public live ACKs before DRAINING under the shared gate');
check(/test\w*Outer\w*Revalidates\w*Guardian\w*After\w*Live\w*Transport\w*Before\w*Publishing\w*Ready/i.test(XCTEST),
	'XCTest must suppress live ACKs after their authorizing guardian generation is lost');
check(/test\w*Outer\w*Retires\w*Live\w*Writer\w*Before\w*Releasing\w*Guardian\w*Drain\w*Gate/i.test(XCTEST),
	'XCTest must retire the exact writer group before guardian drain can fence and exit');
check(/test\w*Replacement\w*Guardian\w*Waits\w*For\w*Prior\w*Generation\w*Transport\w*Gate/i.test(XCTEST),
	'XCTest must drain prior-generation live writes before replacement ACTIVE publication');
check(/test\w*Guardian\w*Permanent\w*Drain\w*Error\w*Fences\w*Until\w*Exact\w*Gate\w*Can\w*Be\w*Taken/i.test(XCTEST),
	'XCTest must prove a persistent gate error fences without authorizing guardian exit');
check(/test\w*Guardian\w*Acknowledgement\w*Rolls\w*Back\w*After\w*Post\w*Rename\w*Directory\w*Sync\w*Failure/i.test(XCTEST),
	'XCTest must remove a visible ACK after post-rename directory sync failure');
check(/test\w*Registration\w*Cannot\w*Arm\w*From\w*Post\w*Rename\w*Directory\w*Sync\w*Failure/i.test(XCTEST),
	'XCTest must prove ARM rejects an ACK whose durable publication failed');
check(/test\w*Guardian\w*Acknowledgement\w*Durability\w*Lock\w*Is\w*Token\w*Local/i.test(XCTEST),
	'XCTest must prove one ACK fsync cannot block another token live transport');
check(/test\w*Guardian\w*Fences\w*Live\w*Owner\w*After\w*SIGKILL/i.test(XCTEST),
	'XCTest must reproduce a real LIVE-owner SIGKILL and exact repeated fence');
check(/test\w*Guardian\w*Restart\w*Fences\w*Orphaned\w*Acknowledgement\w*After\w*Record\w*Loss/i.test(XCTEST),
	'XCTest must recover a detached token from its durable ACK after guardian restart');
check(/test\w*Guardian\w*Registration\w*Collision\w*Preserves\w*Existing\w*Record\w*And\w*Acknowledgement/i.test(XCTEST),
	'XCTest must preserve an existing owner record and ACK on token collision');
check(/test\w*Legacy\w*Registration\w*Preserves\w*Already\w*Running\w*Guardian/i.test(XCTEST),
	'XCTest must prove legacy registration never bootouts a healthy existing guardian');
check(/test\w*Legacy\w*Registration\w*Replaces\w*Stale\w*Executable\w*Path\w*Before\w*Ready/i.test(XCTEST),
	'XCTest must replace a loaded legacy job whose executable path is stale');

if (failures.length > 0) {
	console.error('[FAIL] macOS independent remap LaunchAgent:');
	for (const failure of failures) console.error(`  - ${failure}`);
	process.exit(1);
}

console.log('[OK] macOS remapping is guarded by an exact-token LaunchAgent before activation.');
