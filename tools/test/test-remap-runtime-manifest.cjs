// tools/test/test-remap-runtime-manifest.cjs

/**
 * ==============================================================================
 * MODULE: Owned Runtime Artifact Manifest Gate
 * DESCRIPTION:
 * Guards static/ergopti_plus/macos/vendor/remap-runtime/manifest.json, the pin
 * of the owned Karabiner runtime (ADR 011, WP5), and refuses an unpinned
 * artifact when asked to (`--require-pinned`, for the hosted signed build and
 * any release that would ship the runtime).
 *
 * WHY THIS EXISTS: the digest of the runtime tarball and the designated
 * requirement can only be written after a hosted macOS run has built and signed
 * the artifact. Until then those fields are null, honestly. What must never
 * happen is a half-pinned manifest (a digest without its address, or a
 * VirtualHIDDevice digest quietly nulled) or a release that ships while any
 * field is still null.
 *
 * FEATURES & RATIONALE:
 * 1. One Field List: the paths a complete pin needs are read from
 *    platform/remap/runtime_manifest.lua (M.FIELDS), the module the driver
 *    itself uses to refuse an unpinned artifact, so the gate cannot drift from
 *    the runtime's meaning of "pinned".
 * 2. All Or Nothing: the runtime fields are either all null (not built yet) or
 *    all present. Nothing else may be null.
 * 3. Cross-Pinned Driver: the VirtualHIDDevice pin must equal the digest the
 *    runtime build tooling (tools/build/remap_runtime_source.py) verifies.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const MANIFEST = path.join(ROOT, 'static/ergopti_plus/macos/vendor/remap-runtime/manifest.json');
const VALIDATOR = path.join(ROOT, 'static/ergopti_plus/macos/platform/remap/runtime_manifest.lua');
const BUILD_SOURCE = path.join(ROOT, 'tools/build/remap_runtime_source.py');

// The fields that exist only after the hosted build has produced and signed the artifact.
const UNBUILT_RUNTIME = [
	'runtime.version',
	'runtime.file_name',
	'runtime.source_url',
	'runtime.sha256',
	'runtime.size'
];
const UNBUILT = new Set([...UNBUILT_RUNTIME, 'capture.requirement']);

/**
 * Reads the dotted field paths from the Lua validator.
 * @param {string} source Lua source of runtime_manifest.lua.
 * @returns {string[]} Dotted paths, in declaration order.
 */
function fieldPaths(source) {
	const block = /M\.FIELDS = \{([\s\S]*?)\n\}/.exec(source);
	if (!block)
		throw new Error('runtime_manifest.lua no longer declares M.FIELDS the way this gate reads it');
	return [...block[1].matchAll(/\{\s*"([a-z0-9_.]+)"\s*,\s*"[a-z_0-9]+"\s*\}/g)].map(
		(match) => match[1]
	);
}

/**
 * Reads one dotted path.
 * @param {object} manifest Parsed manifest.
 * @param {string} dotted Dotted path.
 * @returns {*} The value, or undefined.
 */
function lookup(manifest, dotted) {
	return dotted
		.split('.')
		.reduce(
			(value, key) => (value === null || value === undefined ? undefined : value[key]),
			manifest
		);
}

/**
 * Judges a manifest.
 * @param {object} manifest Parsed manifest.
 * @param {string[]} paths Every field a complete pin carries.
 * @param {boolean} requirePinned Whether any null field is an error.
 * @returns {string[]} Error sentences; empty when acceptable.
 */
function judge(manifest, paths, requirePinned) {
	const errors = [];
	const nulls = paths.filter(
		(dotted) => lookup(manifest, dotted) === null || lookup(manifest, dotted) === undefined
	);
	if (requirePinned) {
		if (nulls.length > 0) {
			errors.push(`the runtime artifact is not pinned; null: ${nulls.join(', ')}`);
		}
		return errors;
	}
	for (const dotted of nulls) {
		if (!UNBUILT.has(dotted))
			errors.push(
				`${dotted} may not be null: only the unbuilt runtime fields wait for the hosted build`
			);
	}
	const unbuiltRuntimeNulls = UNBUILT_RUNTIME.filter((dotted) => nulls.includes(dotted));
	if (unbuiltRuntimeNulls.length !== 0 && unbuiltRuntimeNulls.length !== UNBUILT_RUNTIME.length) {
		errors.push(
			`the runtime pin is half written (null: ${unbuiltRuntimeNulls.join(', ')}); pin all of it or none`
		);
	}
	return errors;
}

/**
 * Extracts the VirtualHIDDevice package row the build tooling verifies.
 * @param {string} source Python source of remap_runtime_source.py.
 * @returns {{ name: string, sha256: string, size: number }|null} The row.
 */
function buildToolingPackage(source) {
	const row =
		/"vendor\/Karabiner-DriverKit-VirtualHIDDevice\/dist\/([^"]+\.pkg)",\s*"([^"]+\.pkg)",\s*"([0-9a-f]{64})",\s*(\d+),/.exec(
			source
		);
	return row ? { name: row[2], sha256: row[3], size: Number(row[4]) } : null;
}

const failures = [];
let passes = 0;

/**
 * Records one check.
 * @param {boolean} condition Whether it holds.
 * @param {string} message What it asserts.
 */
function check(condition, message) {
	if (condition) {
		passes += 1;
		console.log(`  ✓ ${message}`);
	} else {
		failures.push(message);
		console.log(`  ✗ ${message}`);
	}
}

const paths = fieldPaths(fs.readFileSync(VALIDATOR, 'utf8'));
check(
	paths.length >= 15 && new Set(paths).size === paths.length,
	`the validator declares ${paths.length} distinct pin fields`
);

// 1. The gate itself, on fixtures: it must be able to fail.
const complete = {
	runtime: {
		upstream_repository: 'a',
		upstream_revision: 'b',
		version: '1.0.0',
		file_name: 'f',
		source_url: 'u',
		sha256: 's',
		size: 1
	},
	virtual_hid_device: {
		version: '8.5.0',
		team_identifier: 't',
		file_name: 'f',
		source_url: 'u',
		sha256: 's',
		size: 1
	},
	capture: { requirement: 'r', batch_limit: 1, frame_limit: 1, history_capacity: 1 }
};
check(judge(complete, paths, true).length === 0, 'a complete pin passes --require-pinned');
check(judge(complete, paths, false).length === 0, 'a complete pin passes the default check');
const unbuilt = JSON.parse(JSON.stringify(complete));
for (const dotted of UNBUILT) {
	const [group, key] = dotted.split('.');
	unbuilt[group][key] = null;
}
check(
	judge(unbuilt, paths, false).length === 0,
	'an unbuilt runtime is acceptable until a release asks for a pin'
);
check(judge(unbuilt, paths, true).length === 1, '--require-pinned refuses an unbuilt runtime');
const half = JSON.parse(JSON.stringify(unbuilt));
half.runtime.sha256 = 'abc';
check(
	judge(half, paths, false).some((message) => message.includes('half written')),
	'a half-pinned runtime is refused'
);
const driverNulled = JSON.parse(JSON.stringify(unbuilt));
driverNulled.virtual_hid_device.sha256 = null;
check(
	judge(driverNulled, paths, false).some((message) =>
		message.includes('virtual_hid_device.sha256 may not be null')
	),
	'a nulled VirtualHIDDevice digest is refused'
);

// 2. The shipped manifest.
const manifest = JSON.parse(fs.readFileSync(MANIFEST, 'utf8'));
const requirePinned = process.argv.includes('--require-pinned');
check(manifest.schema === 1, 'the manifest declares schema 1');
const known = new Set(paths.map((dotted) => dotted.split('.')[0]).concat(['schema']));
check(
	Object.keys(manifest).every((key) => known.has(key)),
	'the manifest holds no group the validator does not know'
);
check(
	paths.every((dotted) => lookup(manifest, dotted) !== undefined),
	'every pin field is written in the manifest, as null while it waits for the hosted build'
);
for (const message of judge(manifest, paths, requirePinned)) check(false, message);

// 3. The driver pin equals what the build tooling verifies.
const verified = buildToolingPackage(fs.readFileSync(BUILD_SOURCE, 'utf8'));
check(verified !== null, 'remap_runtime_source.py still verifies a VirtualHIDDevice package row');
if (verified) {
	const pinned = manifest.virtual_hid_device;
	check(
		pinned.file_name === verified.name,
		'the VirtualHIDDevice file name equals the build tooling row'
	);
	check(
		pinned.sha256 === verified.sha256,
		'the VirtualHIDDevice digest equals the build tooling row'
	);
	check(pinned.size === verified.size, 'the VirtualHIDDevice size equals the build tooling row');
	check(
		pinned.source_url.endsWith(`/v${pinned.version}/${pinned.file_name}`),
		'the VirtualHIDDevice address names the pinned version and file'
	);
}

if (failures.length > 0) {
	console.error(`\n[FAIL] owned runtime manifest: ${failures.length} problem(s)`);
	process.exit(1);
}
console.log(
	`\n[OK] owned runtime manifest: ${passes} check(s) passed${requirePinned ? ' (pinned)' : ''}.`
);
