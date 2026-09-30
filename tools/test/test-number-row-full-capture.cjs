// tools/test/test-number-row-full-capture.cjs

/**
 * ==============================================================================
 * MODULE: Number-Row Full-Capture Recommendation Gate (number-row-full-capture)
 * DESCRIPTION:
 * The number-row key left of 1 exists to catch something that is only on
 * screen for a moment. It was recommended to open the system's capture tool,
 * whose selection the user has to draw first. This gate holds, for every
 * driver, that the manifest recommends the immediate whole-screen capture, that
 * the driver's generated manifest carries it, and that the driver's capture of
 * that action asks for no selection and covers every screen. In-memory
 * mutations prove each check can fail.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const toml = require('smol-toml');
const { stripComments } = require('../lib/script-source.cjs');

const SP = path.resolve(__dirname, '../../static/ergopti_plus');
const PATH = 'shortcuts.tap_keys.number_row_left';
const ACTION = 'screenshot_fullscreen_save';
const PLATFORMS = ['ahk', 'hs', 'linux'];
const read = (file) => fs.readFileSync(path.join(SP, file), 'utf8').replace(/^﻿/, '');

/**
 * Checks the recommendation and every driver's capture of it.
 * @param {object} input Parsed entry and driver source snapshots.
 * @returns {{errors: string[], checks: number}} Violations and check count.
 */
function validate(input) {
	const errors = [];
	let checks = 0;
	const check = (ok, message) => {
		checks += 1;
		if (!ok) errors.push(message);
	};
	const entry = input.entry;
	check(entry !== undefined, `inventory: ${PATH} is missing from the manifest`);
	if (!entry) return { errors, checks };
	check(entry.default === 'none', 'neutral: the key keeps its character until the user opts in');
	for (const platform of PLATFORMS) {
		check(entry.platforms.includes(platform), `platform: ${platform} must offer the key`);
		const recommended = (entry.recommended_per_platform || {})[platform] ?? entry.recommended;
		check(recommended === ACTION, `recommendation: ${platform} must recommend ${ACTION}`);
	}
	check(input.actionPlatform === 'all', `catalogue: ${ACTION} must be offered by every driver`);
	const generated = {
		hs: /path = "shortcuts\.tap_keys\.number_row_left"[^\n]*recommended = "([^"]+)"/,
		linux: /path = "shortcuts\.tap_keys\.number_row_left"[^\n]*recommended = "([^"]+)"/,
		ahk: /"path", "shortcuts\.tap_keys\.number_row_left"[^\n]*?"recommended", "([^"]+)"/
	};
	for (const platform of PLATFORMS) {
		const match = input.generated[platform].match(generated[platform]);
		check(
			match !== null && match[1] === ACTION,
			`generated: ${platform}'s manifest must carry ${ACTION} (run npm run gen)`
		);
	}

	// macOS: no area flag, so screenshot_save names a file for every display.
	const hs = stripComments(input.hs, '.lua');
	const hsCall = hs.match(
		/sg\("screenshot_fullscreen_save",\s*function\(\)\s*return ScreenshotSave\.save\(\{([^}]*)\}/
	);
	check(
		hsCall !== null && hsCall[1].trim() === '',
		'macos: the full capture must pass no area flag'
	);
	const save = stripComments(input.hsSave, '.lua');
	check(
		/if #flags == 0 then[\s\S]*?getMonitorCount\(\)/.test(save),
		'macos: a whole-screen save must name a file for every display'
	);

	// Windows: the whole virtual screen, never the interactive region selector.
	const ahk = stripComments(input.ahk, '.ahk');
	const body =
		(ahk.match(/^GestureScreenshotFullscreen\(Mode\)\s*\{([\s\S]*?)^\}/m) || [])[1] || '';
	check(
		/GESTURE_SM_CXVIRTUALSCREEN/.test(body) &&
			/GESTURE_SM_CYVIRTUALSCREEN/.test(body) &&
			!/GestureScreenshotRegion/.test(body),
		'windows: the full capture must cover the virtual screen with no selection'
	);
	const route = stripComments(input.ahkActions, '.ahk');
	check(
		/"screenshot_fullscreen_save",\s*\{\s*Fn:\s*\(\*\)\s*=>\s*GestureScreenshotFullscreen\("save"\)/.test(
			route
		),
		'windows: the action must save the full capture'
	);

	// Linux: every tool of the cascade captures the whole desktop at once.
	const linux = stripComments(input.linux, '.lua');
	const command =
		(linux.match(/\["screenshot_fullscreen_save"\]\s*=\s*"((?:[^"\\]|\\.)*)"/) || [])[1] || '';
	check(command.includes('%s'), 'linux: the full capture must save to a file');
	// Area (-a, -g, -r, -s, slurp), window (-i, -w) and single-monitor (-m)
	// options of grim, gnome-screenshot, spectacle and maim.
	const flags = [...command.matchAll(/(?:^|\s)-([A-Za-z]+)/g)].map((match) => match[1]).join('');
	check(
		command !== '' && !/slurp/.test(command) && !/[agimrsw]/.test(flags),
		'linux: the full capture must not ask for an area, a window or a selection'
	);
	return { errors, checks };
}

const manifest = toml.parse(
	read('_shared/modules/features/manifest.toml').replace(
		/^\[\[features\.([^\]]+)\]\]\r?$/gm,
		(_match, prefix) => `[[entries]]\npath_prefix = "${prefix}"`
	)
);
const catalogue = toml.parse(read('_shared/modules/actions/actions.toml'));
const input = {
	entry: (manifest.entries || []).find(
		(entry) => entry.path_prefix === 'shortcuts.tap_keys' && entry.id === 'number_row_left'
	),
	actionPlatform: (catalogue.sg_actions[ACTION] || {}).platform,
	generated: {
		hs: read('macos/_generated/features_manifest.lua'),
		linux: read('linux/_generated/features_manifest.lua'),
		ahk: read('windows/_generated/features_manifest.ahk')
	},
	hs: read('macos/modules/gestures/actions.lua'),
	hsSave: read('macos/modules/shortcuts/actions/screenshot_save.lua'),
	ahk: read('windows/modules/gestures/screenshots.ahk'),
	ahkActions: read('windows/modules/gestures/actions.ahk'),
	linux: read('linux/modules/gestures/manager.lua')
};

const result = validate(input);
const mutations = [
	[
		'recommendation: ahk',
		(copy) => {
			copy.entry.recommended = 'screen_capture';
		}
	],
	[
		'recommendation: hs',
		(copy) => {
			copy.entry.recommended_per_platform = { hs: 'screen_capture' };
		}
	],
	[
		'catalogue',
		(copy) => {
			copy.actionPlatform = 'ahk,hs';
		}
	],
	[
		'generated: linux',
		(copy) => {
			copy.generated.linux = copy.generated.linux.replace(`"${ACTION}"`, '"screen_capture"');
		}
	],
	[
		'macos: the full capture',
		(copy) => {
			copy.hs = copy.hs.replace(
				'ScreenshotSave.save({}, "full"',
				'ScreenshotSave.save({ "-i" }, "full"'
			);
		}
	],
	[
		'macos: a whole-screen save',
		(copy) => {
			copy.hsSave = copy.hsSave.replace('getMonitorCount()', 'getMonitorCount');
		}
	],
	[
		'windows: the full capture',
		(copy) => {
			copy.ahk = copy.ahk.replace(/GESTURE_SM_CXVIRTUALSCREEN/g, 'GESTURE_SM_CXSCREEN');
		}
	],
	[
		'linux: the full capture must not',
		(copy) => {
			copy.linux = copy.linux.replace('"grim %s ||', '"grim -g \\"$(slurp)\\" %s ||');
		}
	]
];
let mutationFailures = 0;
for (const [expected, mutate] of mutations) {
	const copy = structuredClone(input);
	mutate(copy);
	const mutated = validate(copy);
	if (!mutated.errors.some((error) => error.startsWith(expected))) {
		mutationFailures += 1;
		console.error(
			`  - mutation "${expected}" was not detected: ${mutated.errors.join('; ') || 'no error'}`
		);
	}
}

if (result.errors.length > 0 || mutationFailures > 0) {
	console.error(
		'\x1b[31m[FAIL] the number-row key left of 1 is not an instant full capture:\x1b[0m'
	);
	for (const error of result.errors) console.error(`  - ${error}`);
	process.exit(1);
}
console.log(
	`\x1b[32m[OK] number-row-full-capture: ${result.checks} check(s) and ${mutations.length} ` +
		'mutation(s) hold the instant whole-screen capture on every driver.\x1b[0m'
);
