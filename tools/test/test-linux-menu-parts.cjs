// tools/test/test-linux-menu-parts.cjs

/**
 * The Linux tray root is read through one resolver.
 *
 * tools/lib/linux-menu-parts.cjs binds each
 * `local _build_x = require("ui.menu.menu_x").build` of
 * linux/ui/menu/menu_builder.lua to that module's builder and recomposes the
 * root the menu gates analyse. This gate proves the two halves of that
 * contract: a faithful split recomposes token for token into the root it came
 * from, and every other wiring is refused rather than composed.
 */

'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const { scriptTokens } = require('../lib/script-source.cjs');
const {
	LINUX_MENU_ROOT,
	composeLinuxMenuRoot,
	readLinuxMenuSources
} = require('../lib/linux-menu-parts.cjs');
const { splitQuit, quitWiringCases, verifyQuitSplit } = require('./lib/linux-menu-split.cjs');

const SP = path.join(__dirname, '..', '..', 'static', 'ergopti_plus');
const shape = (source) =>
	JSON.stringify(scriptTokens(source, '.lua').map((t) => [t.kind, t.value]));

const sources = readLinuxMenuSources(SP);
const actual = composeLinuxMenuRoot(sources);
assert.equal(actual.ok, true, 'the actual Linux root and its parts compose: ' + actual.reason);

// Undo the actual splits, then split Quit again: the round trip is exact.
const whole = actual.source;
const split = splitQuit({ [LINUX_MENU_ROOT]: whole });
assert.notEqual(split[LINUX_MENU_ROOT], whole, 'the probe really moves Quit out of the root');
const recomposed = composeLinuxMenuRoot(split);
assert.equal(recomposed.ok, true, 'a faithful split composes: ' + recomposed.reason);
assert.equal(shape(recomposed.source), shape(whole), 'a faithful split recomposes token for token');

let controls = verifyQuitSplit(
	{ [LINUX_MENU_ROOT]: whole },
	(root) => shape(root) === shape(whole),
	[
		[
			'ManifestMenu.command_row("top_level", "quit"',
			'ManifestMenu.command_row("top_level", "foreign"',
			'changed producer inside the split module'
		]
	],
	'resolver'
);
// Each refusal names its cause instead of composing something else.
for (const [cause, changed] of quitWiringCases(split)) {
	const refused = composeLinuxMenuRoot(changed);
	assert.equal(refused.ok, false, cause + ': refused');
	assert.equal(typeof refused.reason, 'string', cause + ': refusal reason');
}
assert.equal(
	composeLinuxMenuRoot({ [LINUX_MENU_ROOT]: undefined }).ok,
	false,
	'a missing root is refused'
);
controls += 1;

console.log(
	`[OK] Linux menu parts: ${actual.parts.length} split module(s) followed, ` +
		`${controls} wiring and split-module counterexamples refused.`
);
