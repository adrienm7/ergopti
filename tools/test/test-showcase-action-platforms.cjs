// tools/test/test-showcase-action-platforms.cjs

/**
 * ==============================================================================
 * MODULE: Showcase Action Platform Filter Gate
 * DESCRIPTION:
 * The Ergopti+ page lists the catalogue actions available on the OS its
 * toggle selects. Its filter compared the whole `platform` field with one
 * driver key, so every action declared for several drivers ("ahk,hs",
 * "hs,linux", …) vanished from every OS view: moving minimize_all from "ahk"
 * to "ahk,hs" removed it from the Windows view.
 *
 * FEATURES & RATIONALE:
 * 1. Replays the shared actions.toml: each row is listed for exactly the
 *    drivers its platform field names, as the codegen reads it.
 * 2. Pins that KeyboardPower.svelte filters through isActionOnPlatform, so an
 *    inline whole-string comparison cannot return.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { pathToFileURL } = require('url');
const { parse: parseToml } = require('smol-toml');

const ROOT = path.resolve(__dirname, '..', '..');
const HELPER = path.join(ROOT, 'src/routes/ergopti-plus/action-platforms.js');
const PAGE = path.join(ROOT, 'src/routes/ergopti-plus/KeyboardPower.svelte');
const CATALOGUE = path.join(ROOT, 'static/ergopti_plus/_shared/modules/actions/actions.toml');
const DRIVERS = ['ahk', 'hs', 'linux'];

(async () => {
	const { isActionOnPlatform } = await import(pathToFileURL(HELPER).href);
	const failures = [];

	// The catalogue carries a leading BOM that smol-toml rejects.
	const doc = parseToml(fs.readFileSync(CATALOGUE, 'utf8').replace(/^﻿+/, ''));
	const rows = Object.entries(doc.sg_actions ?? {}).filter(
		([, row]) => row && typeof row === 'object' && typeof row.platform === 'string'
	);
	if (rows.length === 0) failures.push('actions.toml has no [sg_actions.*] row with a platform');
	for (const [id, row] of rows) {
		const claimed =
			row.platform === 'all' ? DRIVERS : row.platform.split(',').map((key) => key.trim());
		for (const driver of DRIVERS) {
			const expected = claimed.includes(driver);
			if (isActionOnPlatform(row.platform, driver) !== expected) {
				failures.push(`${id} (platform "${row.platform}") listed=${!expected} on ${driver}`);
			}
		}
	}
	for (const [platform, expected] of [
		['all', true],
		['ahk', false]
	]) {
		if (isActionOnPlatform(platform, null) !== expected) {
			failures.push(`platform "${platform}" with no OS selected should be listed=${expected}`);
		}
	}
	const minimizeAll = doc.sg_actions?.minimize_all?.platform;
	if (!isActionOnPlatform(String(minimizeAll), 'ahk')) {
		failures.push(`minimize_all (platform "${minimizeAll}") is missing from the Windows view`);
	}

	const page = fs.readFileSync(PAGE, 'utf8');
	if (!/isActionOnPlatform\(a\.platform, platformTag\)/.test(page)) {
		failures.push('KeyboardPower.svelte does not filter through isActionOnPlatform');
	}
	if (/a\.platform === platformTag/.test(page)) {
		failures.push('KeyboardPower.svelte compares the whole platform field with one driver key');
	}

	if (failures.length > 0) {
		console.error('\x1b[31m[ERROR] The showcase action filter drops catalogue actions:\x1b[0m');
		for (const f of failures) console.error('  - ' + f);
		process.exit(1);
	}
	console.log(
		`\x1b[32m[OK] The showcase lists all ${rows.length} catalogue actions on exactly their drivers.\x1b[0m`
	);
})().catch((err) => {
	console.error(err);
	process.exit(1);
});
