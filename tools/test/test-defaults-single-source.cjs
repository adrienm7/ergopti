// tools/test/test-defaults-single-source.cjs
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const paths = require('../lib/paths.cjs');

/** Verify explicit neutral and recommended projections before driver boot. */
async function main() {
	const { parse } = await import('smol-toml');
	const source = fs.readFileSync(paths.shared('modules/features/manifest.toml'), 'utf8');
	const manifest = parse(source.replace(/^\[\[features\.([^\]]+)\]\]$/gm,
		(_match, section) => `[[entries]]\nsection = "${section}"`));
	assert(manifest.entries.length > 200, 'the real feature registry must be loaded');
	assert.deepEqual(Object.keys(manifest.scopes || {}), [
		'tap_holds', 'shortcuts', 'gestures', 'keyboard_layout', 'hotstrings', 'llm', 'metrics', 'global'
	], 'one ordered scopes registry must own every configuration action');
	let inputCount = 0;
	for (const entry of manifest.entries) {
		const name = `${entry.section}.${entry.id}`;
		assert.notEqual(entry.recommended !== undefined, entry.recommended_per_platform !== undefined,
			`${name}: exactly one explicit recommended source is required`);
		assert.equal(typeof entry.input_altering, 'boolean', `${name}: classify activation versus parameters`);
		for (const platform of entry.platforms || ['ahk', 'hs', 'linux']) {
			const neutral = entry.default_per_platform?.[platform] ?? entry.default;
			const recommended = entry.recommended_per_platform?.[platform] ?? entry.recommended;
			if (neutral === undefined) continue; // Ancestor platform restrictions are resolved by codegen.
			assert.notEqual(recommended, undefined, `${name}: recommended value missing for ${platform}`);
			if (entry.input_altering) {
				inputCount++;
				const enabled = entry.type === 'feature' ? neutral.enabled : neutral;
				assert(enabled === false || enabled === 'none' || enabled === '',
					`${name}: empty ${platform} configuration must not activate input behavior`);
			} else {
				assert.deepEqual(neutral, recommended, `${name}: pure parameters retain their preset`);
			}
		}
	}
	assert(inputCount > 100, 'activation coverage must include real shortcuts, gestures and hotstrings');
	const linuxGestures = fs.readFileSync(paths.shared('..', 'linux', 'modules', 'gestures', 'manager.lua'), 'utf8');
	const projectedSlots = [...linuxGestures.matchAll(/M\.DEFAULT_GESTURES\[slot\]\s*=\s*Manifest\.default_for\("gestures\."\s*\.\.\s*slot\)/g)];
	assert.equal(projectedSlots.length, 2, 'both single and axis gesture defaults must come from the manifest');
	assert.deepEqual(manifest.scopes.llm.restore_exclude, ['llm.enabled']);
	assert.deepEqual(manifest.scopes.metrics.restore_exclude, ['metrics.enabled', 'metrics.metrics_enabled']);
	assert(manifest.scopes.global.prefixes.includes('script'), 'global scope must include script preferences');
	for (const key of ['autocorrection', 'distances_reduction', 'sfbs_reduction', 'rolls', 'magic_key']) {
		assert(manifest.scopes.hotstrings.prefixes.includes(`category_enabled.${key}`),
			`hotstrings scope must include the ${key} subordinate master`);
	}
	console.log(`Neutral/recommended contract passed for ${manifest.entries.length} entries.`);
}

main().catch((error) => { console.error(error.stack); process.exitCode = 1; });
