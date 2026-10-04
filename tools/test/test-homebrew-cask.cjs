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
		const run = spawnSync('ruby', ['-c'], { input: cask.text, encoding: 'utf8' });
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

if (failures > 0) {
	console.error(`\n${failures} Homebrew cask check(s) failed.`);
	process.exit(1);
}
console.log('\nAll Homebrew cask checks passed.');
