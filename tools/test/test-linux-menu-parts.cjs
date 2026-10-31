// tools/test/test-linux-menu-parts.cjs

/**
 * The Linux tray root is read through one resolver.
 *
 * tools/lib/linux-menu-parts.cjs binds each
 * `local _build_x = require("ui.menu.menu_x").build` of
 * linux/ui/menu/builder.lua to that module's builder and recomposes the
 * root the menu gates analyse. This gate proves the two halves of that
 * contract: a faithful split recomposes token for token into the root it came
 * from, and every other wiring is refused rather than composed.
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
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

// M3.3: the root holds only the imports it reads itself; every other one lives
// in the part that reads it, and the composed root carries it once, ahead of
// its first reader.
const rootTokens = scriptTokens(sources[LINUX_MENU_ROOT], '.lua');
const rootReads = (name) =>
	rootTokens.filter(
		(token, at) =>
			token.kind === 'identifier' &&
			token.value === name &&
			!['.', ':'].includes(rootTokens[at - 1]?.value)
	).length;
const rootImports = [
	...sources[LINUX_MENU_ROOT].matchAll(/^local ([A-Za-z_][A-Za-z_0-9]*) = require\(/gm)
].map((match) => match[1]);
assert.ok(rootImports.includes('Version'), 'the root keeps the imports it reads');
for (const name of rootImports)
	assert.ok(rootReads(name) > 1, 'the root holds ' + name + ' only for a part: move it there');
assert.ok(
	!/require\("ui\.menu\.menu_dialogs"\)/.test(sources[LINUX_MENU_ROOT]),
	'the parts bind the dialogs they use, not the root'
);
for (const statement of [
	'local TextPrompt = require("ui.text_prompt")',
	'local WindowTitles = require("window_titles")',
	'local uninstall_caption_i18n = rawget(separator_modules, "infra.i18n")'
])
	assert.equal(
		whole.split(statement).length - 1,
		1,
		'the composed root declares a part-only import once: ' + statement
	);
assert.ok(
	whole.indexOf('local WindowTitles = require("window_titles")') <
		whole.indexOf('local function zenity_plain('),
	'a part-only import precedes the definitions that read it'
);
const partOnly = (file, before, after) => ({
	...sources,
	[file]: sources[file].replace(before, () => after)
});
const partOnlyCases = [
	[
		'the root reads a name only a part declares',
		partOnly(
			LINUX_MENU_ROOT,
			'local function header_facade_current()',
			'local function _reads_part_import() return TextPrompt end\nlocal function header_facade_current()'
		)
	],
	[
		'two parts declare one name from different modules',
		partOnly(
			'linux/ui/menu/menu_metrics.lua',
			'local TextPrompt = require("ui.text_prompt")',
			'local TextPrompt = require("ui.foreign_prompt")'
		)
	],
	[
		'a part reads a name a later part declares',
		partOnly(
			'linux/ui/menu/menu_layouts.lua',
			'local function _build_layouts(ctx)',
			'local function _layouts_reads_later() return PrivacyPolicy end\nlocal function _build_layouts(ctx)'
		)
	],
	[
		'a part binds a dialog the dialogs module does not export',
		partOnly(
			'linux/ui/menu/menu_quit.lua',
			'local LOG = "ui.menu.menu_quit"',
			'local foreign_dialog = require("ui.menu.menu_dialogs").foreign_dialog\nlocal LOG = "ui.menu.menu_quit"'
		)
	],
	[
		'part modules bind each other in a cycle',
		partOnly(
			'linux/ui/menu/menu_dialogs.lua',
			'local LOG = "ui.menu.menu_dialogs"',
			'local layouts_probe = require("ui.menu.menu_layouts").layouts_probe\nlocal LOG = "ui.menu.menu_dialogs"'
		)
	]
];
for (const [cause, changed] of partOnlyCases) {
	assert.notDeepEqual(changed, sources, cause + ': the case changes a source');
	const refused = composeLinuxMenuRoot(changed);
	assert.equal(refused.ok, false, cause + ': refused');
	assert.equal(typeof refused.reason, 'string', cause + ': refusal reason');
	controls += 1;
}

// M3.3: once every section moved to its own menu_*.lua, the root took the macOS
// root's name, so the `menu_` prefix names parts only and both drivers read
// `ui/menu/builder.lua` as the tray root. Nothing may still load the old name.
assert.equal(
	LINUX_MENU_ROOT,
	'linux/ui/menu/builder.lua',
	'the Linux root has the macOS root name'
);
assert.ok(
	fs.existsSync(path.join(SP, 'macos/ui/menu/builder.lua')),
	'the macOS root it mirrors exists'
);
assert.ok(
	!fs.existsSync(path.join(SP, 'linux/ui/menu/menu_builder.lua')),
	'the pre-split root file is gone'
);
const oldRootReaders = [];
(function walk(dir) {
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) walk(full);
		else if (
			entry.name.endsWith('.lua') &&
			/ui[./]menu[./]menu_builder\b/.test(fs.readFileSync(full, 'utf8'))
		)
			oldRootReaders.push(path.relative(SP, full));
	}
})(path.join(SP, 'linux'));
assert.deepEqual(oldRootReaders, [], 'no Linux source loads the pre-split root name');
controls += 1;

console.log(
	`[OK] Linux menu parts: ${actual.parts.length} split module(s) followed, ` +
		`${controls} wiring and split-module counterexamples refused.`
);
