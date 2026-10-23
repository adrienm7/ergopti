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
const vm = require('node:vm');
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

	// Execute the actual server loader against the physical shared catalogue.
	// Picker structure is not dispatchable and must not become a marketed action.
	const loader = fs.readFileSync(
		path.join(ROOT, 'src/routes/ergopti-plus/+page.server.js'),
		'utf8'
	);
	const first = loader.indexOf('function loadActionGroups() {');
	const last = loader.indexOf('\n// ====================================================', first);
	if (first < 0 || last <= first) throw new Error('The actual action loader body is unavailable');
	const groups = vm.runInNewContext(loader.slice(first, last) + '\nloadActionGroups()', {
		readFileSync: fs.readFileSync,
		readJson: (filename) => JSON.parse(fs.readFileSync(filename, 'utf8')),
		resolve: path.resolve,
		parseToml,
		ACTIONS_ROOT: path.dirname(CATALOGUE),
		LOCALES_ROOT: path.join(ROOT, 'static/ergopti_plus/_shared/data/locales')
	});
	const loaded = groups.flatMap((group) => group.sections.flatMap((section) => section.actions));
	const dispatchable = doc.sg_order.items.filter(
		(id) => id !== 'none' && doc.sg_actions[id] && !doc.sg_actions[id].is_header
	);
	const expected = [...dispatchable, ...Object.keys(doc.ax_actions)];
	if (loaded.map((action) => action.id).join('\0') !== expected.join('\0'))
		failures.push('the real loader must list exactly the canonical dispatchable actions in order');
	for (const [id, row] of Object.entries(doc.sg_actions)) {
		if (row.is_header && loaded.some((action) => action.id === id))
			failures.push(`${id}: a picker-only header leaked into the real list and action count`);
	}
	for (const tag of ['ahk', 'hs', null]) {
		const actual = loaded.filter((action) => isActionOnPlatform(action.platform, tag));
		const wanted = expected.filter((id) =>
			isActionOnPlatform((doc.sg_actions[id] || doc.ax_actions[id]).platform, tag)
		);
		if (actual.map((action) => action.id).join('\0') !== wanted.join('\0'))
			failures.push(
				`${tag}: displayed action list/count includes non-actions or loses canonical rows`
			);
	}
	if (!/visibleGroups\.reduce\([\s\S]*s\.actions\.length/.test(page))
		failures.push('the displayed count must derive from the displayed action rows');

	if (failures.length > 0) {
		console.error('\x1b[31m[ERROR] The showcase action filter drops catalogue actions:\x1b[0m');
		for (const f of failures) console.error('  - ' + f);
		process.exit(1);
	}
	console.log(
		`\x1b[32m[OK] The showcase lists ${loaded.length} dispatchable catalogue actions and excludes picker headers.\x1b[0m`
	);
})().catch((err) => {
	console.error(err);
	process.exit(1);
});
