// tools/test/test-homebrew-cask.cjs

/**
 * ==============================================================================
 * MODULE: Homebrew Cask Guard
 * DESCRIPTION:
 * Renders the cask of a dev and of a stable release through the generator the
 * release workflow runs, and pins every name it repeats to its owner.
 *
 * FEATURES & RATIONALE:
 * 1. Channel from the registry: a dev tag renders ergoptiplus@dev, a semver
 *    tag ergoptiplus, each conflicting with the other, so installing one
 *    channel's cask replaces the other's app instead of adding a second one.
 * 2. brew upgrade updates the app with the user's other casks: no cask
 *    declares auto_updates, brew quits both bundle identifiers before replacing
 *    the bundle and relaunches the app only when it was running. livecheck
 *    reads the same appcast the app follows.
 * 3. Names repeated from the build (bundle id, app, asset, minimum macOS) and
 *    from the release workflow (appcast branch, generator call, tap
 *    repository) must match their owners, or the cask downloads or installs
 *    something the release never published.
 * 4. Invalid input (tag without v, tag owned by no channel, malformed
 *    checksum) fails instead of publishing a cask that cannot install.
 * 5. Ruby parses both casks when a Ruby interpreter is on PATH (the Linux CI
 *    runners have one).
 * ==============================================================================
 */

'use strict';

const assert = require('assert');
const { spawnSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const Cask = require(path.join(ROOT, 'tools', 'build', 'homebrew-cask.cjs'));

const BUILD_SCRIPT = fs.readFileSync(
	path.join(ROOT, 'tools', 'build', 'build_macos_app.sh'),
	'utf8'
);
const WORKFLOW = fs.readFileSync(path.join(ROOT, '.github', 'workflows', 'ci.yml'), 'utf8');
const MACOS_README = fs.readFileSync(
	path.join(ROOT, 'static', 'ergopti_plus', 'macos', 'README.md'),
	'utf8'
);

const SHA = 'a'.repeat(64);

// macOS release names Homebrew accepts in depends_on, by major version
const MACOS_SYMBOLS = {
	11: ':big_sur',
	12: ':monterey',
	13: ':ventura',
	14: ':sonoma',
	15: ':sequoia'
};

let failures = 0;

function check(name, fn) {
	try {
		fn();
		console.log(`  ok  ${name}`);
	} catch (err) {
		failures += 1;
		console.error(`  FAIL ${name}\n       ${err.message}`);
	}
}

console.log('Homebrew cask');

const dev = Cask.renderCask('v0.0.0-dev.142', SHA);
const stable = Cask.renderCask('v1.2.3', SHA);

check('a dev tag renders the dev cask, a semver tag the stable one', () => {
	assert.strictEqual(dev.token, 'ergoptiplus@dev');
	assert.strictEqual(dev.file, path.join('Casks', 'ergoptiplus@dev.rb'));
	assert.match(dev.text, /^cask "ergoptiplus@dev" do$/m);
	assert.match(dev.text, /^  version "0\.0\.0-dev\.142"$/m);
	assert.strictEqual(stable.token, 'ergoptiplus');
	assert.match(stable.text, /^  version "1\.2\.3"$/m);
});

check('each channel cask conflicts with every other channel cask', () => {
	const tokens = Cask.caskChannels().map((entry) => entry.token);
	for (const cask of [dev, stable]) {
		const conflicts = [...cask.text.matchAll(/conflicts_with cask: "([^"]+)"/g)].map((m) => m[1]);
		assert.deepStrictEqual(conflicts.sort(), tokens.filter((token) => token !== cask.token).sort());
	}
});

check('the cask downloads the tagged release asset with its checksum', () => {
	assert.match(dev.text, new RegExp(`^  sha256 "${SHA}"$`, 'm'));
	assert.ok(
		dev.text.includes(
			`url "https://github.com/${Cask.SOURCE_REPOSITORY}/releases/download/v#{version}/${Cask.ASSET_NAME}"`
		)
	);
});

check(
	'brew upgrade quits, replaces and relaunches the app, and livecheck reads the channel appcast',
	() => {
		for (const cask of [dev, stable]) {
			assert.doesNotMatch(
				cask.text,
				/auto_updates/,
				'auto_updates would make brew upgrade skip the app'
			);
			assert.ok(
				cask.text.includes(`uninstall quit: ["${Cask.BUNDLE_ID}.hammerspoon", "${Cask.BUNDLE_ID}"]`)
			);
			const marker = `"${Cask.RELAUNCH_MARKER}"`;
			const preflight = cask.text.slice(
				cask.text.indexOf('uninstall_preflight do'),
				cask.text.indexOf('uninstall quit:')
			);
			assert.ok(
				preflight.includes(`FileUtils.touch(${marker})`) && preflight.includes('if running'),
				'the marker is left only when the app was running'
			);
			const postflight = cask.text.slice(cask.text.indexOf('postflight do'));
			assert.ok(
				postflight.includes(`if File.exist?(${marker})`) &&
					postflight.includes(`FileUtils.rm_f(${marker})`) &&
					postflight.includes(`"/usr/bin/open", args: ["#{appdir}/${Cask.APP_NAME}"]`),
				'postflight relaunches only on the marker, and consumes it'
			);
			assert.ok(
				Cask.RELAUNCH_MARKER.includes(`/Library/Caches/${Cask.BUNDLE_ID}/`),
				'zap must remove the marker'
			);
		}
		const base = `https://raw.githubusercontent.com/${Cask.SOURCE_REPOSITORY}/${Cask.APPCAST_BRANCH}/`;
		assert.ok(dev.text.includes(`url "${base}appcast-dev.xml"`));
		assert.ok(stable.text.includes(`url "${base}appcast-main.xml"`));
		assert.ok(
			WORKFLOW.includes(`branch="${Cask.APPCAST_BRANCH}"`),
			'ci.yml publishes the appcasts on another branch'
		);
	}
);

check('bundle names match build_macos_app.sh', () => {
	assert.ok(BUILD_SCRIPT.includes(`BUNDLE_ID="${Cask.BUNDLE_ID}"`));
	assert.ok(BUILD_SCRIPT.includes(`APP_PATH="$BUILD_DIR/${Cask.APP_NAME}"`));
	assert.ok(BUILD_SCRIPT.includes(`ZIP_PATH="$BUILD_DIR/${Cask.ASSET_NAME}"`));
	const minimum = BUILD_SCRIPT.match(
		/<key>LSMinimumSystemVersion<\/key>\s*<string>(\d+)\.\d+<\/string>/
	);
	assert.ok(minimum, 'LSMinimumSystemVersion not found');
	assert.strictEqual(Cask.MINIMUM_MACOS, MACOS_SYMBOLS[minimum[1]]);
	assert.ok(dev.text.includes(`app "${Cask.APP_NAME}"`));
	assert.ok(
		dev.text.includes(`"#{appdir}/${Cask.APP_NAME}"`),
		'the quarantine flag is cleared on the installed app'
	);
});

check(
	'the release workflow runs the generator on the published asset and the docs name its tap',
	() => {
		assert.ok(WORKFLOW.includes('node tools/build/homebrew-cask.cjs "$TAG" "$sha" "$tap"'));
		assert.ok(WORKFLOW.includes('node tools/build/macos-release-publication.cjs download'));
		assert.ok(WORKFLOW.includes('"$tap" "$archive"'));
		const tap = WORKFLOW.match(
			/TAP_REPOSITORY: \$\{\{ github\.repository_owner \}\}\/(homebrew-[a-z-]+)/
		);
		assert.ok(tap, 'ci.yml names no tap repository');
		const owner = Cask.SOURCE_REPOSITORY.split('/')[0];
		const shortTap = `${owner}/${tap[1].replace(/^homebrew-/, '')}`;
		assert.ok(
			MACOS_README.includes(`brew tap ${shortTap}`),
			`the macOS README does not tap ${shortTap}`
		);
		for (const entry of Cask.caskChannels()) {
			assert.ok(
				MACOS_README.includes(`brew install --cask ${entry.token}`),
				`the macOS README does not install ${entry.token}`
			);
		}
	}
);

check('the release notes name the released channel cask and every channel token', () => {
	assert.ok(WORKFLOW.includes('cask="$(node tools/build/homebrew-cask.cjs --token "$CHANNEL")"'));
	assert.ok(WORKFLOW.includes('brew install --cask ${cask}'));
	assert.ok(WORKFLOW.includes('brew tap ${GITHUB_REPOSITORY_OWNER}/ergopti'));
	for (const entry of Cask.caskChannels()) {
		assert.strictEqual(Cask.tokenForChannel(entry.id), entry.token);
		assert.ok(
			WORKFLOW.includes(`\\\`${entry.token}\\\``),
			`the release notes do not name ${entry.token}`
		);
	}
	assert.throws(() => Cask.tokenForChannel('nightly'), /not a registry channel/);
});

check('invalid input fails instead of rendering', () => {
	assert.throws(() => Cask.renderCask('0.0.0-dev.1', SHA), /starts with "v"/);
	assert.throws(() => Cask.renderCask('vnot-a-version', SHA), /no update channel/);
	assert.throws(() => Cask.renderCask('v1.2.3', 'A'.repeat(64)), /SHA-256/);
});

check('the CLI writes the cask into the tap checkout', () => {
	const tap = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-tap-'));
	try {
		const run = spawnSync(
			process.execPath,
			[path.join(ROOT, 'tools', 'build', 'homebrew-cask.cjs'), 'v0.0.0-dev.142', SHA, tap],
			{ encoding: 'utf8' }
		);
		assert.strictEqual(run.status, 0, run.stderr);
		assert.strictEqual(run.stdout, `${dev.file}\n`);
		assert.strictEqual(fs.readFileSync(path.join(tap, dev.file), 'utf8'), dev.text);
	} finally {
		fs.rmSync(tap, { recursive: true, force: true });
	}
});

check('Ruby parses both casks', () => {
	const probe = spawnSync('ruby', ['--version'], { encoding: 'utf8' });
	if (probe.error) {
		console.log('       (no ruby on PATH: syntax not checked here)');
		return;
	}
	for (const cask of [dev, stable]) {
		const run = spawnSync('ruby', ['-c'], {
			input: cask.text,
			encoding: 'utf8'
		});
		assert.strictEqual(run.status, 0, `${cask.token}: ${run.stderr}`);
	}
});

check('an admitted preferred name remains coupled to its independent hash', () => {
	const publication = require('../build/macos-release-publication.cjs');
	const preferred = publication.bindings()[0];
	const crypto = require('node:crypto');
	const tap = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-preferred-cask-'));
	try {
		const payload = path.join(tap, preferred.name);
		fs.writeFileSync(payload, Buffer.from('independent selected public archive bytes'));
		const actualHash = crypto.createHash('sha256').update(fs.readFileSync(payload)).digest('hex');
		const selected = Cask.renderCask('v0.0.0-dev.142', actualHash, preferred.name);
		assert.ok(selected.text.includes(`/v#{version}/${preferred.name}"`));
		assert.ok(selected.text.includes(`sha256 "${actualHash}"`));
		const result = spawnSync(
			process.execPath,
			[
				path.join(ROOT, 'tools/build/homebrew-cask.cjs'),
				'v0.0.0-dev.142',
				actualHash,
				tap,
				preferred.name
			],
			{ encoding: 'utf8' }
		);
		assert.equal(result.status, 0, result.stderr);
		assert.equal(fs.readFileSync(path.join(tap, selected.file), 'utf8'), selected.text);
		assert.throws(() => Cask.renderCask('v1.2.3', actualHash, 'unknown.tar.xz'), /undeclared/);
	} finally {
		fs.rmSync(tap, { recursive: true });
	}
});

check('portable Brew ownership controls remain registered and mandatory', () => {
	const controls = path.join(ROOT, 'tools/diagnostics/macos_brew_archive_acceptance_test.py');
	const result = spawnSync(process.platform === 'win32' ? 'python' : 'python3', [controls], {
		cwd: ROOT,
		encoding: 'utf8',
		timeout: 30000,
		env: { ...process.env, PYTHONDONTWRITEBYTECODE: '1' }
	});
	assert.ifError(result.error);
	assert.strictEqual(result.signal, null, result.stderr);
	assert.strictEqual(result.status, 0, result.stderr);
	assert.match(result.stderr, /Ran 84 tests in /);
	assert.match(result.stderr, /\nOK\s*$/);
	assert.doesNotMatch(result.stderr, /skipped=/);
});

check(
	'owned AppleEvent compile boundary uses declared 64-bit dispatch and actual selected tools',
	() => {
		const receiver = fs.readFileSync(
			path.join(ROOT, 'tools/diagnostics/native_appleevent_probe_receiver.c'),
			'utf8'
		);
		const helper = fs.readFileSync(
			path.join(ROOT, 'tools/diagnostics/macos_brew_archive_acceptance.py'),
			'utf8'
		);
		assert.match(
			receiver,
			/ReceiveNextEvent\(1, &apple_event, kEventDurationForever, true, &event\)/
		);
		assert.match(receiver, /AEProcessEvent\(event\)/);
		assert.match(receiver, /ReleaseEvent\(event\)/);
		assert.doesNotMatch(receiver, /RunApplicationEventLoop\s*\(/);
		const registration = receiver.slice(
			receiver.indexOf('ProcessSerialNumber serial;'),
			receiver.indexOf('const AEEventHandlerUPP handler')
		);
		assert.ok(registration.length > 0, 'the actual native registration body must be present');
		assert.match(
			registration,
			/GetCurrentProcess\(&serial\);\s*if \(status != noErr\) \{\s*fprintf\(stderr, "Owned AppleEvent recipient registration failed: phase=get-current-process, osstatus=%d\\n", \(int\)status\);\s*return 65;/
		);
		assert.match(
			registration,
			/const enum AppKitAdmission admission = admit_appkit\(application\);\s*if \(admission != AppKitAdmitted\) \{[\s\S]*?return 65;/
		);
		assert.doesNotMatch(receiver, /\bTransformProcessType\s*\(/);
		const appkitStart = receiver.indexOf('static enum AppKitAdmission admit_appkit(');
		const appkitEnd = receiver.indexOf('static int receiver_main(', appkitStart);
		assert.ok(
			appkitStart >= 0 && appkitEnd > appkitStart,
			'the actual AppKit admission body must be nonempty'
		);
		const appkit = receiver.slice(appkitStart, appkitEnd);
		assert.match(appkit, /if \(application == nil\) return AppKitApplicationMissing;/);
		assert.match(
			appkit,
			/if \(!\[application setActivationPolicy:NSApplicationActivationPolicyAccessory\]\) \{\s*return AppKitPolicyRefused;/
		);
		assert.match(
			appkit,
			/if \(\[application activationPolicy\] != NSApplicationActivationPolicyAccessory\) \{\s*return AppKitPolicyUnconfirmed;/
		);
		assert.ok(
			appkit.indexOf('return AppKitPolicyUnconfirmed;') < appkit.indexOf('return AppKitAdmitted;')
		);
		assert.ok(
			receiver.indexOf('if (admission != AppKitAdmitted)') <
				receiver.indexOf('AEInstallEventHandler(')
		);
		assert.ok(
			receiver.indexOf('if (admission != AppKitAdmitted)') <
				receiver.indexOf('write_exclusive(argv[1]')
		);
		assert.match(helper, /xcode-select", "--print-path"\], confined=True/);
		assert.match(helper, /-isysroot/);
		assert.match(helper, /-fmodules-cache-path=/);
		assert.match(helper, /cache\.mkdir\(mode=0o700\)/);
		const boundary = helper.slice(
			helper.indexOf('def _admit_appleevent_boundary'),
			helper.indexOf('def ', helper.indexOf('def _admit_appleevent_boundary') + 5)
		);
		assert.doesNotMatch(boundary, /xcrun/);
		const pairStart = helper.indexOf('def _build_appleevent_pair(');
		const pairEnd = helper.indexOf('def _admit_appleevent_boundary(', pairStart);
		assert.ok(
			pairStart >= 0 && pairEnd > pairStart,
			'the real pair compile recipe must be present'
		);
		const pairRecipe = helper.slice(pairStart, pairEnd);
		assert.match(
			pairRecipe,
			/\*compiler,\s*"-std=c11",\s*"-O2",\s*"-fobjc-arc",\s*"-framework",\s*"ApplicationServices",\s*"-framework",\s*"Carbon",\s*"-framework",\s*"AppKit",\s*"-framework",\s*"Security",\s*str\(repository \/ "tools\/diagnostics\/native_appleevent_probe_pair\.m"\)/
		);
		assert.match(
			boundary,
			/registration_controls\.stdout\s*==\s*"native_appkit_registration_controls=6\\nnative_private_appleevent_controls=1\\nnative_sender_registration_controls=6\\nnative_sender_identity_controls=7\\n"/
		);
		assert.doesNotMatch(boundary, /NSWorkspace|\/usr\/bin\/open/);
	}
);

check('owned AppleEvent liveness refusal preserves its nonreaping numeric observation', () => {
	const helper = fs.readFileSync(
		path.join(ROOT, 'tools/diagnostics/macos_brew_archive_acceptance.py'),
		'utf8'
	);
	const begin = helper.indexOf('    def same_live_receiver(checkpoint):');
	assert.ok(begin >= 0);
	const observation = helper.slice(begin, helper.indexOf('    deadline = ', begin));
	assert.equal((observation.match(/group\.observe_exit\(\)/g) || []).length, 1);
	assert.match(observation, /observation = group\.observe_exit\(\)/);
	assert.match(observation, /if observation is not None:/);
	for (const kind of ['CLD_EXITED', 'CLD_KILLED', 'CLD_DUMPED']) {
		assert.ok(observation.includes(`os.${kind}: "${kind}"`));
	}
	assert.ok(observation.includes('waitid_code={observation.si_code}'));
	assert.ok(observation.includes('waitid_status={observation.si_status}'));
	assert.doesNotMatch(observation, /\.(?:poll|wait|settle|read_bytes|read_text)\(/);
	for (const checkpoint of [
		'readiness',
		'before-unconfined-positive',
		'before-deny-removal-positive',
		'before-full-policy-denial',
		'after-full-policy-denial'
	]) {
		assert.equal(helper.split(`same_live_receiver("${checkpoint}")`).length - 1, 1);
	}
});

check('owned registration diagnosis projects only a closed bounded native failure fact', () => {
	const helper = fs.readFileSync(
		path.join(ROOT, 'tools/diagnostics/macos_brew_archive_acceptance.py'),
		'utf8'
	);
	const receiver = fs.readFileSync(
		path.join(ROOT, 'tools/diagnostics/native_appleevent_probe_receiver.c'),
		'utf8'
	);
	const begin = helper.indexOf('def appleevent_registration_fact(');
	assert.ok(begin >= 0);
	const projection = helper.slice(begin, helper.indexOf('def _admit_appleevent_boundary', begin));
	assert.match(projection, /children\.captures\[receiver\]\[1\]/);
	assert.match(projection, /os\.O_NOFOLLOW/);
	assert.match(projection, /os\.O_NONBLOCK/);
	assert.match(projection, /stat\.S_ISREG\(info\.st_mode\)/);
	assert.match(projection, /info\.st_size <= 128/);
	assert.match(projection, /os\.read\(descriptor, 129\)/);
	assert.match(projection, /len\(value\) != info\.st_size/);
	assert.ok(projection.includes('not -(2**31) <= status < 2**31'));
	assert.doesNotMatch(projection, /observe_exit|\.(?:poll|wait|settle)\(/);
	assert.match(helper, /observation\.si_code == os\.CLD_EXITED and observation\.si_status == 65/);
	for (const phase of ['get-current-process']) {
		assert.ok(receiver.includes(`phase=${phase}, osstatus=%d`));
	}
	assert.match(receiver, /Owned AppleEvent recipient AppKit admission refused \(reason %d\)\./);
	const registration = receiver.slice(
		receiver.indexOf('OSStatus status = GetCurrentProcess'),
		receiver.indexOf('const AEEventHandlerUPP')
	);
	assert.equal((registration.match(/if \(status != noErr\)/g) || []).length, 1);
	assert.equal((registration.match(/if \(admission != AppKitAdmitted\)/g) || []).length, 1);
	assert.equal((registration.match(/return 65;/g) || []).length, 2);
});

check('owned receiver uses guarded AppKit accessory admission without front activation', () => {
	const receiver = fs.readFileSync(
		path.join(ROOT, 'tools/diagnostics/native_appleevent_probe_receiver.c'),
		'utf8'
	);
	assert.match(receiver, /admit_appkit\(application\)/);
	assert.doesNotMatch(receiver, /kProcessTransformToUIElementApplication/);
	assert.doesNotMatch(receiver, /SetFrontProcess\s*\(|ShowHideProcess\s*\(|NSApplicationLoad\s*\(/);
	const registration = receiver.slice(
		receiver.indexOf('OSStatus status = GetCurrentProcess'),
		receiver.indexOf('const AEEventHandlerUPP')
	);
	assert.equal((registration.match(/if \(status != noErr\)/g) || []).length, 1);
	assert.equal((registration.match(/if \(admission != AppKitAdmitted\)/g) || []).length, 1);
	assert.equal((registration.match(/return 65;/g) || []).length, 2);
	assert.match(registration, /phase=get-current-process, osstatus=%d/);
	assert.match(registration, /if \(admission != AppKitAdmitted\) \{[\s\S]*?return 65;/);
	assert.match(registration, /AppKit admission refused \(reason %d\)\./);
	assert.doesNotMatch(
		receiver,
		/activateIgnoringOtherApps|activateWithOptions|makeKeyAndOrderFront/
	);
});

check(
	'owned sender reports closed reply facts without weakening nonce or refusal admission',
	() => {
		const sender = fs.readFileSync(
			path.join(ROOT, 'tools/diagnostics/native_appleevent_probe_sender.c'),
			'utf8'
		);
		const helper = fs.readFileSync(
			path.join(ROOT, 'tools/diagnostics/macos_brew_archive_acceptance.py'),
			'utf8'
		);
		assert.match(
			sender,
			/read == noErr && actual_length == 36 && memcmp\(echoed, argv\[2\], 36\) == 0/
		);
		assert.match(sender, /AEGetParamPtr\(&reply, keyErrorNumber, typeSInt32/);
		assert.match(sender, /sizeof\(SInt32\), &error_length/);
		assert.match(sender, /if \(error_length == sizeof\(SInt32\)\)/);
		assert.match(sender, /nonce_length >= 0 && nonce_length <= 4096/);
		assert.match(sender, /error_length >= 0 && error_length <= 4096/);
		assert.match(sender, /char error_value_detail\[16\] = "unobserved"/);
		assert.match(
			sender,
			/phase=%s, send=%d, read=%s, length=%s, match=%s, error_read=%s, error_length=%s, error_value=%s/
		);
		const begin = helper.indexOf('def run_appleevent_sender(');
		const admission = helper.slice(begin, helper.indexOf('def _admit_appleevent_boundary', begin));
		assert.match(admission, /children\.run\(arguments, check=False, confined=confined\)/);
		assert.match(admission, /result\.returncode != 0/);
		assert.match(admission, /result\.returncode == 66/);
		assert.match(admission, /result\.stdout in expected and not result\.stderr/);
		assert.doesNotMatch(admission, /result\.stderr\[:|\.(?:poll|wait|settle)\(/);
		assert.match(helper, /len\(value\) > 256/);
		for (const control of ['unconfined-positive', 'deny-removal-positive', 'full-policy-denial']) {
			assert.ok(admission.includes(`"${control}"`));
		}
	}
);

// BREW_POST_FAILED_SENDER_TARGET_OBSERVATION_BEGIN
check(
	'failed AppleEvent send observes only its exact retained target and preserves primary refusal',
	() => {
		const helper = fs.readFileSync(
			path.join(ROOT, 'tools/diagnostics/macos_brew_archive_acceptance.py'),
			'utf8'
		);
		const begin = helper.indexOf('def run_appleevent_sender_observed(');
		const end = helper.indexOf('def native_compiler(', begin);
		assert.ok(begin >= 0 && end > begin);
		const observation = helper.slice(begin, end);
		assert.equal((observation.match(/group\.observe_exit\(\)/g) || []).length, 1);
		assert.match(observation, /children\.groups\.get\(receiver\) is group/);
		assert.match(observation, /group\.process is receiver/);
		assert.match(observation, /receiver\.returncode is None/);
		assert.match(
			observation,
			/terminal = _appleevent_terminal_packet\(children, receiver, group, observation\)/
		);
		assert.match(observation, /fact\["state"\] = "no-terminal-observation"/);
		assert.match(observation, /except AdmissionError:/);
		assert.match(observation, /except BaseException:/);
		assert.match(observation, /\n        raise\n/);
		assert.doesNotMatch(
			observation,
			/\.(?:poll|wait|settle|sleep)\(|killpg|signal\(|reservation_lost\s*=/
		);
		assert.doesNotMatch(observation, /repr\(|str\(error|\.path|nonce|stdout|stderr\[/);
		assert.equal((helper.match(/positive = run_appleevent_sender_observed\(/g) || []).length, 2);
		assert.equal((helper.match(/refused = run_appleevent_sender_observed\(/g) || []).length, 1);
	}
);
// BREW_POST_FAILED_SENDER_TARGET_OBSERVATION_END

check('owned AppleEvent probe constructs the shared private SDK event before any delivery', () => {
	const diagnostic = (name) => fs.readFileSync(path.join(ROOT, 'tools/diagnostics', name), 'utf8');
	const protocol = diagnostic('native_appleevent_probe_protocol.h');
	assert.match(protocol, /ERGOPTI_PROBE_EVENT_CLASS \(\(AEEventClass\)0x45675062u\)/);
	assert.match(protocol, /ERGOPTI_PROBE_EVENT_ID \(\(AEEventID\)0x6e6f6e63u\)/);
	for (const role of ['sender', 'receiver']) {
		const source = diagnostic('native_appleevent_probe_' + role + '.c');
		assert.match(source, /#include "native_appleevent_probe_protocol\.h"/);
		assert.match(source, /probe_class = ERGOPTI_PROBE_EVENT_CLASS;/);
		assert.match(source, /probe_event = ERGOPTI_PROBE_EVENT_ID;/);
		assert.doesNotMatch(source, /kCoreEventClass|kAEOpenApplication/);
	}
	const controls = diagnostic('native_appleevent_registration_test.m');
	assert.match(controls, /assert\(probe_class != kCoreEventClass\);/);
	assert.match(controls, /AECreateAppleEvent\(probe_class, probe_event, &address,/);
	assert.match(controls, /AEGetAttributePtr\(&event, keyEventClassAttr, typeType,/);
	assert.match(controls, /AEGetAttributePtr\(&event, keyEventIDAttr, typeType,/);
	assert.match(
		controls,
		/assert_private_probe_event\(\);\s*puts\("native_appkit_registration_controls=6"\);/
	);
	const helper = diagnostic('macos_brew_archive_acceptance.py');
	assert.match(
		helper,
		/registration_controls\.stdout\s*==\s*"native_appkit_registration_controls=6\\nnative_private_appleevent_controls=1\\nnative_sender_registration_controls=6\\nnative_sender_identity_controls=7\\n"/
	);
	assert.match(helper, /"tools\/diagnostics\/native_appleevent_probe_protocol\.h",/);
});

check('owned AppleEvent roles use one image without replacing non-self nonce admission', () => {
	const diagnostic = (name) => fs.readFileSync(path.join(ROOT, 'tools/diagnostics', name), 'utf8');
	const pair = diagnostic('native_appleevent_probe_pair.m');
	for (const role of ['receiver', 'sender']) {
		assert.match(pair, new RegExp('#define main owned_' + role + '_entry'));
		assert.match(pair, new RegExp('#include "native_appleevent_probe_' + role + '\\.c"'));
		assert.match(pair, new RegExp('return owned_' + role + '_entry\\(argc - 1, argv \\+ 1\\);'));
	}
	const sender = diagnostic('native_appleevent_probe_sender.c');
	assert.match(sender, /parsed > INT_MAX \|\| parsed == getpid\(\)/);
	assert.match(
		sender,
		/read == noErr && actual_length == 36 && memcmp\(echoed, argv\[2\], 36\) == 0/
	);
	assert.match(sender, /kAEWaitReply \| kAENeverInteract \| kAEDoNotPromptForUserConsent/);
	assert.doesNotMatch(pair, /TCC|entitlement|AESendMessage|AEPutParamPtr|AEInstallEventHandler/);
	const helper = diagnostic('macos_brew_archive_acceptance.py');
	assert.match(
		helper,
		/executables = _build_appleevent_pair\(children, repository, root, compiler, nonce\)/
	);
	assert.match(
		helper,
		/receiver = children\.start\(\s*\[\*executables\["receiver"\], str\(ready\), str\(marker\), nonce\]\s*\)/
	);
	assert.match(helper, /sender = \[\*executables\["sender"\], str\(receiver\.pid\), nonce\]/);
	assert.match(helper, /"tools\/diagnostics\/native_appleevent_probe_pair\.m",/);
});

check('native XCTest invokes actual Brew acceptance and requires its complete receipt', () => {
	const fixture = fs.readFileSync(
		path.join(
			ROOT,
			'static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/HomebrewArchiveAcceptanceTests.swift'
		),
		'utf8'
	);
	assert.match(
		fixture,
		/func testRealBrewZIPInstallXZUpgradeAndRefusalsPreserveInstalledState\(\) throws/
	);
	assert.match(fixture, /tools\/diagnostics\/macos_brew_archive_acceptance\.py/);
	assert.match(fixture, /process\.run\(\)/);
	assert.match(fixture, /process\.terminationStatus == 0/);
	assert.match(fixture, /attributes: \[\.posixPermissions: 0o700\]/);
	assert.match(fixture, /Set\(ownership\.keys\) == Set\(\["schema", "helper_pid", "closed"\]\)/);
	assert.match(fixture, /ownership\["closed"\] as\? Bool == true/);
	assert.match(fixture, /ownership\["helper_pid"\]/);
	assert.match(fixture, /func retireInvoker\(\) -> Bool/);
	assert.doesNotMatch(fixture, /SIGKILL/);

	assert.match(fixture, /receipt\["complete"\] as\? Bool, true/);
	assert.match(fixture, /receipt\["host_unchanged"\] as\? Bool, true/);
	assert.match(fixture, /receipt\["fixture_retained"\] as\? Bool, false/);
	assert.match(fixture, /receipt\["cleanup_errors"\] as\? \[String\], \[\]/);
	for (const name of [
		'zip_install',
		'xz_upgrade',
		'checksum_refusal_preserved',
		'checksum_retry',
		'artifact_refusal_preserved',
		'artifact_retry'
	]) {
		assert.ok(fixture.includes(`"${name}": true`), `Native receipt must acknowledge ${name}`);
	}
	assert.doesNotMatch(fixture, /XCTSkip|mock|stub/i);
});

check('native macOS CI admits the pinned Python nonreaping prerequisites', () => {
	const pipeline = require('./ci-pipeline.cjs');
	const job = pipeline.job('package-macos');
	const setupName = 'Prepare Python for native nonreaping waits';
	const admissionName = 'Admit native nonreaping Python prerequisites';
	const setup = pipeline.step(job, setupName);
	const admission = pipeline.step(job, admissionName);
	assert.equal(pipeline.stepField(setup, 'uses'), 'actions/setup-python@v5');
	assert.match(setup, /python-version: '3\.13'/);
	for (const step of [setup, admission]) {
		assert.equal(pipeline.stepField(step, 'if'), null);
		assert.equal(pipeline.stepField(step, 'continue-on-error'), null);
	}
	const order = pipeline.steps(job).map((step) => step.name);
	assert.ok(order.indexOf(setupName) < order.indexOf(admissionName));
	assert.ok(order.indexOf(admissionName) < order.indexOf('Run Swift launcher tests'));
	const lines = pipeline.runOf(admission);
	assert.equal(lines[0], "python3 - <<'PY'");
	assert.equal(lines.at(-1), 'PY');
	const script = lines.slice(1, -1).join('\n');
	for (const [version, missing, expected] of [
		[[3, 12, 12], null, 1],
		[[3, 13, 7], 'waitid', 1],
		[[3, 13, 7], 'WNOWAIT', 1],
		[[3, 13, 7], null, 0]
	]) {
		// These portable models exercise the actual admission script; native
		// WNOWAIT behavior remains owned by repeated macOS observations.
		const preparation =
			`import os, sys\nsys.platform = "darwin"\nsys.version_info = tuple(${JSON.stringify(version)})\nfor name in ("waitid", "P_PID", "WEXITED", "WNOHANG", "WNOWAIT", "CLD_EXITED", "CLD_KILLED", "CLD_DUMPED"):\n if not hasattr(os, name): setattr(os, name, None)\n` +
			(missing
				? `if hasattr(os, ${JSON.stringify(missing)}): delattr(os, ${JSON.stringify(missing)})\n`
				: '') +
			`exec(${JSON.stringify(script)})\n`;
		const result = spawnSync(
			process.platform === 'win32' ? 'python' : 'python3',
			['-c', preparation],
			{ encoding: 'utf8', timeout: 30000 }
		);
		assert.ifError(result.error);
		assert.equal(result.signal, null, result.stderr);
		assert.equal(result.status === 0 ? 0 : 1, expected, result.stderr);
		if (expected === 0) {
			assert.deepEqual(JSON.parse(result.stdout).version, version);
			assert.ok(JSON.parse(result.stdout).nonreaping_apis.includes('WNOWAIT'));
		} else {
			assert.match(result.stderr, missing ? /Missing native nonreaping APIs/ : /CPython >= 3.13/);
		}
	}
});

check('archive artifacts bind only this step session independently of TIS', () => {
	const pipeline = require('./ci-pipeline.cjs');
	const job = pipeline.job('package-macos');
	const step = pipeline.step(job, 'Run Swift launcher tests');
	const lines = pipeline.runOf(step).join('\n');
	assert.match(
		lines,
		/ERGOPTI_ARCHIVE_EVIDENCE_DIR="\$\(mktemp -d "\$RUNNER_TEMP\/swift-launcher-evidence\/archive-session\.XXXXXX"\)"/
	);
	assert.ok(
		lines.indexOf('archive_session_dir=') < lines.indexOf('export ERGOPTI_TIS_EVIDENCE_DIR=')
	);
	assert.ok(
		lines.indexOf('"scope": "swift-not-started"') <
			lines.indexOf('export ERGOPTI_TIS_EVIDENCE_DIR=')
	);
	assert.equal(pipeline.stepField(step, 'timeout-minutes'), '25');
	const upload = pipeline.step(job, 'Retain archive diagnostic session');
	assert.equal(
		pipeline.stepField(upload, 'if'),
		"${{ always() && steps.swift-launcher-tests.outputs.archive_session_dir != '' }}"
	);
	assert.equal(pipeline.stepField(upload, 'uses'), 'actions/upload-artifact@v4');
	const pathBlock = /^ {10}path: \|\n((?: {12}.+\n?)+)/m.exec(upload)?.[1];
	assert.ok(pathBlock);
	const paths = pathBlock
		.trim()
		.split('\n')
		.map((line) => line.trim());
	assert.deepEqual(paths, [
		'${{ steps.swift-launcher-tests.outputs.archive_session_dir }}/*/*.json',
		'${{ steps.swift-launcher-tests.outputs.archive_session_dir }}/*/helper/*.json'
	]);
	assert.doesNotMatch(upload, /tis_session_dir|\*\*|cache|fixture|key|\.app/i);
});

check('archive owners publish bounded typed phase evidence before native work', () => {
	const testRoot = 'static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/';
	for (const [file, owner] of [
		['HomebrewArchiveAcceptanceTests.swift', 'brew'],
		['SparkleArchiveUpdateAcceptanceTests.swift', 'sparkle']
	]) {
		const source = fs.readFileSync(path.join(ROOT, testRoot, file), 'utf8');
		assert.ok(source.includes(`ArchiveAcceptanceEvidence(owner: .${owner})`));
		assert.ok(source.includes('checkpoint("candidate.begin")'));
		assert.match(source, /checkpoint\("cleanup\.debt(?:-" \+ label|"), status: "cleanup-debt"/);
		if (owner === 'brew') assert.ok(source.includes('if evidenceRefused { canRetire = false }'));
	}
	const writer = fs.readFileSync(
		path.join(ROOT, testRoot, 'ArchiveAcceptanceEvidence.swift'),
		'utf8'
	);
	assert.match(writer, /swift-launcher-evidence/);
	assert.match(writer, /O_NOFOLLOW/);
	assert.match(writer, /bytes\.count <= 4096/);
	assert.match(writer, /sequence < 256/);
	assert.match(writer, /testRefusedPublicationNeverReplacesAnUnclosedCheckpoint/);
});

check('shared native process ownership controls remain registered and mandatory', () => {
	const result = spawnSync(
		process.platform === 'win32' ? 'python' : 'python3',
		[path.join(ROOT, 'tools/diagnostics/macos_owned_process_test.py')],
		{
			cwd: ROOT,
			encoding: 'utf8',
			timeout: 30000,
			env: { ...process.env, PYTHONDONTWRITEBYTECODE: '1' }
		}
	);
	assert.ifError(result.error);
	assert.strictEqual(result.signal, null, result.stderr);
	assert.strictEqual(result.status, 0, result.stderr);
	assert.match(result.stderr, /Ran 15 tests in /);
	assert.match(result.stderr, /\nOK\s*$/);
	assert.doesNotMatch(result.stderr, /skipped=/);
});

// SENDER_INTERNAL_MARKER_DIAGNOSTIC_BEGIN
check('sender-owned marker snapshots never change nonce admission or parent lifetime', () => {
	const sender = fs.readFileSync(
		path.join(ROOT, 'tools/diagnostics/native_appleevent_probe_sender.c'),
		'utf8'
	);
	const helper = fs.readFileSync(
		path.join(ROOT, 'tools/diagnostics/macos_brew_archive_acceptance.py'),
		'utf8'
	);
	const marker = sender.slice(
		sender.indexOf('static const char *owned_second_marker_snapshot('),
		sender.indexOf('int main(')
	);
	assert.match(marker, /open\("\.", O_RDONLY \| O_DIRECTORY \| O_CLOEXEC \| O_NOFOLLOW\)/);
	assert.match(
		marker,
		/openat\(directory, "appleevent-delivered\.2",[\s\S]*O_NOFOLLOW \| O_NONBLOCK/
	);
	assert.match(marker, /before\.st_nlink != 1 \|\| before\.st_size != 36/);
	assert.match(marker, /char bytes\[37\]/);
	assert.match(marker, /read\(descriptor, bytes, sizeof\(bytes\)\)/);
	assert.match(marker, /close\(descriptor\) != 0\) snapshot = "unavailable"/);
	assert.match(marker, /close\(directory\) != 0\) snapshot = "unavailable"/);
	assert.doesNotMatch(marker, /wait|kill|sleep|Permission|Entitlement|fprintf|printf/);
	assert.match(sender, /strcmp\(argv\[3\], "success"\) == 0 && status == noErr/);
	assert.match(
		sender,
		/if \(read == noErr && actual_length == 36 && memcmp\(echoed, argv\[2\], 36\) == 0\)/
	);
	assert.match(
		sender,
		/if \(marker_attempted\) fprintf\(stderr, ", marker2=%s", marker_snapshot\)/
	);
	assert.match(
		helper,
		/facts\.get\("phase"\) not in \("reply-read", "reply-length", "reply-match"\)/
	);
	assert.match(helper, /result\.returncode == 66/);
});
// SENDER_INTERNAL_MARKER_DIAGNOSTIC_END

check('owned AppKit readiness diagnosis preserves native enum and refusal authority', () => {
	const helper = fs.readFileSync(
		path.join(ROOT, 'tools/diagnostics/macos_brew_archive_acceptance.py'),
		'utf8'
	);
	const receiver = fs.readFileSync(
		path.join(ROOT, 'tools/diagnostics/native_appleevent_probe_receiver.c'),
		'utf8'
	);
	assert.match(
		receiver,
		/enum AppKitAdmission \{\s*AppKitAdmitted = 0,\s*AppKitApplicationMissing,\s*AppKitPolicyRefused,\s*AppKitPolicyUnconfirmed\s*\}/
	);
	assert.match(receiver, /Owned AppleEvent recipient AppKit admission refused \(reason %d\)\.\\n/);
	assert.match(helper, /re\.fullmatch\(\s*rb"Owned AppleEvent recipient AppKit admission refused/);
	assert.match(
		helper,
		/b"1": "application-missing",\s*b"2": "policy-refused",\s*b"3": "policy-unconfirmed"/
	);
	assert.match(helper, /return \{"phase": "appkit-admission", "appkit_reason": reason\}/);
	assert.match(helper, /registration\.get\("phase"\) == "appkit-admission"/);
	assert.match(helper, /registration_appkit_reason=\{registration\['appkit_reason'\]\}/);
	assert.match(helper, /observation\.si_code == os\.CLD_EXITED and observation\.si_status == 65/);
});

check('refused AppKit policy snapshots never grant readiness', () => {
	const receiver = fs.readFileSync(
		path.join(ROOT, 'tools/diagnostics/native_appleevent_probe_receiver.c'),
		'utf8'
	);
	const helper = fs.readFileSync(
		path.join(ROOT, 'tools/diagnostics/macos_brew_archive_acceptance.py'),
		'utf8'
	);
	const registration = receiver.slice(
		receiver.indexOf('ProcessSerialNumber serial;'),
		receiver.indexOf('const AEEventHandlerUPP handler')
	);
	assert.match(registration, /NSApplication \*application = \[NSApplication sharedApplication\];/);
	assert.ok(
		registration.indexOf('appkit_policy_label([application activationPolicy])') <
			registration.indexOf('admit_appkit(application)')
	);
	assert.match(
		registration,
		/if \(admission == AppKitPolicyRefused\) \{[\s\S]*?APPKIT_POLICY\/1 initial=%s after=%s\\n[\s\S]*?appkit_policy_label\(\[application activationPolicy\]\)/
	);
	for (const name of ['Regular', 'Accessory', 'Prohibited'])
		assert.match(
			receiver,
			new RegExp(
				'case NSApplicationActivationPolicy' + name + ': return "' + name.toLowerCase() + '";'
			)
		);
	assert.match(receiver, /default: return "unrecognized";/);
	assert.match(helper, /if appkit\[2\] is not None:\s*if appkit\[1\] != b"2":\s*return \{\}/);
	assert.match(helper, /"appkit_initial_policy": appkit\[2\]\.decode\("ascii"\)/);
	assert.match(helper, /"appkit_after_no_policy": appkit\[3\]\.decode\("ascii"\)/);
	assert.match(helper, /observation\.si_code == os\.CLD_EXITED and observation\.si_status == 65/);
	assert.doesNotMatch(
		registration,
		/finishLaunching|NSApplicationLoad|SetFrontProcess|activateIgnoringOtherApps/
	);
});

check('existing accessory AppKit state is freshly confirmed without a modifying setter', () => {
	const receiver = fs.readFileSync(
		path.join(ROOT, 'tools/diagnostics/native_appleevent_probe_receiver.c'),
		'utf8'
	);
	const controls = fs.readFileSync(
		path.join(ROOT, 'tools/diagnostics/native_appleevent_registration_test.m'),
		'utf8'
	);
	const helper = fs.readFileSync(
		path.join(ROOT, 'tools/diagnostics/macos_brew_archive_acceptance.py'),
		'utf8'
	);
	const portable = fs.readFileSync(
		path.join(ROOT, 'tools/diagnostics/macos_brew_archive_acceptance_test.py'),
		'utf8'
	);
	const begin = receiver.indexOf('static enum AppKitAdmission admit_appkit(');
	const end = receiver.indexOf('static const char *appkit_policy_label(', begin);
	assert.ok(begin >= 0 && end > begin);
	const admission = receiver.slice(begin, end);
	assert.match(admission, /if \(application == nil\) return AppKitApplicationMissing;/);
	assert.match(
		admission,
		/const NSApplicationActivationPolicy initial = \[application activationPolicy\];\s*if \(initial != NSApplicationActivationPolicyAccessory\) \{\s*if \(!\[application setActivationPolicy:NSApplicationActivationPolicyAccessory\]\) \{\s*return AppKitPolicyRefused;\s*\}\s*\}/
	);
	assert.match(
		admission,
		/if \(\[application activationPolicy\] != NSApplicationActivationPolicyAccessory\) \{\s*return AppKitPolicyUnconfirmed;\s*\}\s*return AppKitAdmitted;/
	);
	assert.equal((admission.match(/\[application activationPolicy\]/g) || []).length, 2);
	assert.equal((admission.match(/setActivationPolicy:/g) || []).length, 1);
	assert.doesNotMatch(
		admission,
		/finishLaunching|NSApplicationLoad|SetFrontProcess|activateIgnoringOtherApps|sleep\s*\(/
	);
	assert.match(
		controls,
		/return self\.readCalls == 1 \? self\.initialPolicy : self\.observedPolicy;/
	);
	for (const name of ['refused', 'unconfirmed', 'admitted']) {
		assert.match(
			controls,
			new RegExp(name + '\\.initialPolicy = NSApplicationActivationPolicyRegular;')
		);
	}
	assert.match(controls, /refused\.acceptsPolicy = NO;/);
	assert.match(
		controls,
		/assert\(admit_appkit\(\(NSApplication \*\)refused\) == AppKitPolicyRefused\);/
	);
	assert.match(controls, /refused\.setCalls == 1 && refused\.readCalls == 1/);
	assert.match(controls, /unconfirmed\.setCalls == 1 && unconfirmed\.readCalls == 2/);
	assert.match(controls, /admitted\.setCalls == 1 && admitted\.readCalls == 2/);
	for (const [name, final, outcome] of [
		['alreadyAccessory', 'Accessory', 'Admitted'],
		['changedAccessory', 'Regular', 'PolicyUnconfirmed']
	]) {
		assert.match(
			controls,
			new RegExp(name + '\\.initialPolicy = NSApplicationActivationPolicyAccessory;')
		);
		assert.match(controls, new RegExp(name + '\\.acceptsPolicy = NO;'));
		assert.match(
			controls,
			new RegExp(name + '\\.observedPolicy = NSApplicationActivationPolicy' + final + ';')
		);
		assert.match(
			controls,
			new RegExp(
				'assert\\(admit_appkit\\(\\(NSApplication \\*\\)' +
					name +
					'\\) == AppKit' +
					outcome +
					'\\);'
			)
		);
		assert.match(controls, new RegExp(name + '\\.setCalls == 0 && ' + name + '\\.readCalls == 2'));
	}
	assert.match(controls, /puts\("native_appkit_registration_controls=6"\);/);
	assert.match(
		helper,
		/registration_controls\.stdout\s*==\s*"native_appkit_registration_controls=6\\nnative_private_appleevent_controls=1\\nnative_sender_registration_controls=6\\nnative_sender_identity_controls=7\\n"/
	);
	assert.match(portable, /registration_output=None/);
	assert.match(
		portable,
		/"native_appkit_registration_controls=6\\n"\s*"native_private_appleevent_controls=1\\n"\s*"native_sender_registration_controls=6\\n"\s*"native_sender_identity_controls=7\\n"/
	);
});

// SENDER_NONPROMPT_PERMISSION_DIAGNOSTIC_BEGIN
check(
	'failed native AppleEvent permission observations never alter admission or ask for consent',
	() => {
		const sender = fs.readFileSync(
			path.join(ROOT, 'tools/diagnostics/native_appleevent_probe_sender.c'),
			'utf8'
		);
		const helper = fs.readFileSync(
			path.join(ROOT, 'tools/diagnostics/macos_brew_archive_acceptance.py'),
			'utf8'
		);
		function assertNonpromptObservation(source) {
			const executable = source.replace(
				/"(?:\\.|[^"\\])*"|\/\/[^\n]*|\/\*[\s\S]*?\*\//g,
				(token) => (token.startsWith('/') ? '' : token)
			);
			const begin = executable.indexOf('    if (result != 0) {');
			const end = executable.indexOf(
				'    } else {\n        printf("native_appleevent_status=',
				begin
			);
			assert.ok(begin >= 0 && end > begin, 'The original failed native send branch is present');
			const failure = executable.slice(begin, end);
			assert.equal((executable.match(/AEDeterminePermissionToAutomateTarget\(/g) || []).length, 1);
			const queryAt = failure.indexOf('if (strcmp(argv[3], "success") == 0) {');
			assert.ok(
				queryAt > failure.indexOf('fprintf(stderr, "\\n");'),
				'Only the original failed positive is observed'
			);
			const query = failure.slice(queryAt);
			assert.match(
				query,
				/if \(strcmp\(argv\[3\], "success"\) == 0\) \{\s*const OSStatus permission = AEDeterminePermissionToAutomateTarget\(\s*&address, probe_class, probe_event, false\);\s*printf\("OWNED_APPLEEVENT_PERMISSION\/1 osstatus=%d\\n", \(int\)permission\);/
			);
			assert.doesNotMatch(
				query,
				/\b(?:result|status)\s*=|\breturn\b|\b(?:wait|kill|sleep|open|close|exit|system)\s*\(/
			);
			assert.match(executable, /AEDisposeDesc\(&address\);\s*return result;/);
			assert.match(executable, /kAEWaitReply \| kAENeverInteract \| kAEDoNotPromptForUserConsent/);
		}
		assertNonpromptObservation(sender);
		for (const [from, to] of [
			['&address, probe_class, probe_event, false);', '&address, probe_class, probe_event, true);'],
			['&address, probe_class, probe_event, false);', 'NULL, probe_class, probe_event, false);'],
			[
				'printf("OWNED_APPLEEVENT_PERMISSION/1 osstatus=%d\\n", (int)permission);',
				'printf("OWNED_APPLEEVENT_PERMISSION/1 osstatus=%d\\n", (int)permission); result = 0;'
			]
		]) {
			assert.equal(sender.split(from).length - 1, 1, 'One independent native source mutation');
			assert.throws(() => assertNonpromptObservation(sender.replace(from, to)));
		}
		const projectionAt = helper.indexOf('def appleevent_permission_query_fact(');
		const failureAt = helper.indexOf('def run_appleevent_sender(', projectionAt);
		const projectionEnd = helper.indexOf('def appleevent_sender_identity_frame(', projectionAt);
		assert.ok(projectionAt >= 0 && failureAt > projectionAt);
		const projection = helper.slice(projectionAt, projectionEnd);
		assert.match(projection, /len\(value\) > 96/);
		assert.match(
			projection,
			/re\.fullmatch\(r"OWNED_APPLEEVENT_PERMISSION\/1 osstatus=\(-\?\[0-9\]\{1,11\}\)\\n", value\)/
		);
		assert.match(projection, /not -\(2\*\*31\) <= status < 2\*\*31 or str\(status\) != encoded/);
		assert.match(projection, /return \{"osstatus": status\}/);
		assert.doesNotMatch(projection, /print\(|open\(|read|subprocess|TCC|consent|cause/);
		const failure = helper.slice(
			failureAt,
			helper.indexOf('def _admit_appleevent_boundary', failureAt)
		);
		assert.match(failure, /if result\.returncode == 66 and control != "full-policy-denial"/);
		assert.match(failure, /require\(\s*False,\s*f"Owned AppleEvent sender failed:/);
		assert.match(failure, /result\.stdout in expected and not result\.stderr/);
	}
);
// SENDER_NONPROMPT_PERMISSION_DIAGNOSTIC_END

check(
	'sender AppKit experiment preserves nonce admission and closed signed identity metadata',
	() => {
		const read = (name) => fs.readFileSync(path.join(ROOT, 'tools/diagnostics', name), 'utf8');
		const sender = read('native_appleevent_probe_sender.c');
		const helper = read('macos_brew_archive_acceptance.py');
		const controls = read('native_appleevent_registration_test.m');
		const pair = read('native_appleevent_probe_pair.m');
		const admission = sender.slice(
			sender.indexOf('static int admit_sender_appkit('),
			sender.indexOf('static int observe_sender_policy(')
		);
		assert.ok(admission.length > 100);
		assert.match(admission, /if \(application == nil\) return 1;/);
		assert.match(
			admission,
			/!\[application setActivationPolicy:NSApplicationActivationPolicyAccessory\]\) return 2;/
		);
		assert.match(
			admission,
			/return \[application activationPolicy\] == NSApplicationActivationPolicyAccessory \? 0 : 3;/
		);
		assert.ok(
			sender.indexOf('if (admission != 0)') < sender.indexOf('OSStatus status = AECreateDesc(')
		);
		assert.match(
			sender,
			/SecCodeCopyGuestWithAttributes\(NULL, attributes, kSecCSDefaultFlags, &code\)/
		);
		assert.match(sender, /SecCodeCopyStaticCode\(code, kSecCSDefaultFlags, &static_code\)/);
		assert.match(
			sender,
			/SecCodeCopySigningInformation\(static_code, kSecCSSigningInformation, &information\)/
		);
		assert.match(sender, /CFGetTypeID\(left\) != expected_type/);
		assert.match(sender, /CFRelease\(self\);/);
		assert.match(sender, /CFRelease\(other\);/);
		assert.match(
			sender,
			/read == noErr && actual_length == 36 && memcmp\(echoed, argv\[2\], 36\) == 0/
		);
		assert.match(
			sender,
			/kAEWaitReply \| kAENeverInteract \| kAEDoNotPromptForUserConsent, 5 \* 60/
		);
		assert.doesNotMatch(
			sender,
			/Owned AppleEvent sender diagnostic:|ProbeNonceObservation|NSWorkspace/
		);
		assert.match(
			pair,
			/strcmp\(argv\[1\], "sender"\) == 0\) \{\s*@autoreleasepool \{\s*return owned_sender_entry/
		);
		assert.match(controls, /admit_sender_appkit\(nil\) == 1/);
		assert.match(controls, /const int expected\[\] = \{2, 3, 0, 0, 3\}/);
		assert.match(
			controls,
			/sender_identity_equal\(matching, different, kSecCodeInfoIdentifier, CFStringGetTypeID\(\)\) == 0/
		);
		assert.match(controls, /puts\("native_sender_registration_controls=6"\)/);
		assert.match(controls, /puts\("native_sender_identity_controls=7"\)/);
		const split = helper.slice(
			helper.indexOf('def appleevent_sender_identity_frame('),
			helper.indexOf('def run_appleevent_sender(')
		);
		assert.ok(split.length > 100);
		assert.match(split, /len\(value\) > 512/);
		assert.match(split, /re\.fullmatch\(pattern, lines\[1\]\)/);
		assert.match(split, /bool\(appleevent_sender_marker_fact\(lines\[0\]\)\)/);
		assert.match(
			helper,
			/original_stderr, identity = appleevent_sender_identity_frame\(result.stderr\)/
		);
	}
);

if (failures > 0) {
	console.error(`\n${failures} Homebrew cask check(s) failed.`);
	process.exit(1);
}
console.log('\nAll Homebrew cask checks passed.');
