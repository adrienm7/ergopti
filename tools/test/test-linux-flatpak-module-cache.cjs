// tools/test/test-linux-flatpak-module-cache.cjs

/**
 * ==============================================================================
 * MODULE: Linux Flatpak Module Cache
 * DESCRIPTION:
 * A cold Flatpak build compiles LuaJIT and every network module from source:
 * Build the Flatpak took 378 s on run 43012051378, over the five-minute budget
 * of TODO 16/38. flatpak-builder reuses an unchanged module from its state
 * directory, but the packager let it default to the current directory and CI
 * never kept it. The packager now names a state directory outside the trees it
 * and the driver build wipe, and the Linux Build job restores that exact
 * directory before the build and saves it after. This test resolves the
 * directory the packager derives and proves the job caches that path around the
 * build step.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const YAML = require('yaml');
const { bashExecutable } = require('../lib/git-bash.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const PACKAGER = fs.readFileSync(path.join(ROOT, 'tools/build/build-linux-flatpak.sh'), 'utf8');
const WORKFLOW = YAML.parse(
	fs.readFileSync(path.join(ROOT, '.github/workflows/ci-linux.yml'), 'utf8')
);

// The packager's own derivation, evaluated for the default build directory.
const derivation = /^FLATPAK_STATE_DIR=.*$/m.exec(PACKAGER);
assert.ok(derivation, 'build-linux-flatpak.sh no longer names a flatpak-builder state directory');
const resolved = spawnSync(
	bashExecutable(),
	[
		'-c',
		`BUILD_DIR="$1"\n${derivation[0]}\nprintf '%s' "$FLATPAK_STATE_DIR"`,
		'probe',
		'/w/build/linux'
	],
	{ encoding: 'utf8' }
);
assert.equal(resolved.status, 0, resolved.stderr);
const stateDir = resolved.stdout;
assert.equal(stateDir, '/w/build/linux-flatpak-builder');
// Outside build/linux (wiped by build-linux-driver.sh) and its flatpak/ child
// (wiped by the packager's step 2), so a restored cache survives both.
assert.ok(
	!stateDir.startsWith('/w/build/linux/'),
	'the state directory must survive the driver build'
);

const invocation = /^flatpak-builder --force-clean(?:[^\n]*\\\n)*[^\n]*$/m.exec(PACKAGER);
assert.ok(invocation, 'the packager no longer runs flatpak-builder');
assert.match(invocation[0], /--state-dir="\$FLATPAK_STATE_DIR"/);

const steps = WORKFLOW.jobs['package-linux'].steps;
const index = (name) => {
	const found = steps.findIndex((step) => step.name === name);
	assert.ok(found >= 0, `package-linux has no step "${name}"`);
	return found;
};
const restore = steps[index('Restore the Flatpak module cache')];
const save = steps[index('Save the Flatpak module cache')];
const build = index('Build the Flatpak');
assert.ok(
	index('Restore the Flatpak module cache') < build,
	'the cache is restored before the build'
);
assert.ok(index('Save the Flatpak module cache') > build, 'the cache is saved after the build');
// The job runs from the checkout root with the default build directory.
assert.equal(restore.with.path, 'build/linux-flatpak-builder');
assert.equal(save.with.path, restore.with.path);
assert.equal(steps[build].env?.ERGOPTI_LINUX_BUILD_DIR, undefined);
assert.match(restore.uses, /^actions\/cache\/restore@/);
assert.match(save.uses, /^actions\/cache\/save@/);
assert.equal(save.with.key, '${{ steps.flatpak-builder-cache.outputs.cache-primary-key }}');
for (const input of [
	'tools/build/build-linux-flatpak.sh',
	'static/ergopti_plus/_shared/data/linux_native_runtime.json',
	'tools/codegen/codegen-linux-native-runtime.cjs'
]) {
	assert.ok(restore.with.key.includes(`'${input}'`), `the module cache key must hash ${input}`);
	assert.ok(fs.existsSync(path.join(ROOT, input)), `${input} is gone`);
}
assert.ok(
	restore.with.key.startsWith(restore.with['restore-keys']),
	'restore-keys must be the key prefix'
);

console.log(`[OK] Flatpak module cache: ${stateDir} restored before and saved after the build.`);
