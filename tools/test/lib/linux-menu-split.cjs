// tools/test/lib/linux-menu-split.cjs

/**
 * Split-module counterexamples for the gates that read the Linux tray root
 * through tools/lib/linux-menu-parts.cjs.
 *
 * A gate that follows the module boundary must still fail when the code it
 * guards is broken INSIDE a split module, or wired to the root any other way.
 * The Quit builder is the probe: it needs no root helper, so it can always be
 * split off. When `ui/menu/menu_quit.lua` exists the real module is used;
 * before that, the same module is synthesized from the root, so every case
 * runs on dev before any split lands.
 */

'use strict';

const assert = require('node:assert/strict');
const { LINUX_MENU_ROOT, composeLinuxMenuRoot } = require('../../lib/linux-menu-parts.cjs');

const QUIT_FILE = 'linux/ui/menu/menu_quit.lua';
const QUIT_BINDING = 'local _build_quit = require("ui.menu.menu_quit").build';

/** Replaces the one occurrence of `before` in `text`; throws when it is not unique. */
function replaceOnce(text, before, after, label) {
	const count = text.split(before).length - 1;
	assert.equal(count, 1, label + ': exactly one physical anchor for ' + JSON.stringify(before));
	return text.replace(before, () => after);
}

/** The Lua text of the root's `local function _build_quit(ctx) ... end`. */
function quitFunction(root) {
	const start = root.indexOf('local function _build_quit(ctx)');
	assert(start >= 0, 'the root defines the Quit builder to split');
	const close = root.indexOf('\nend\n', start);
	assert(close > start, 'the Quit builder closes at the top level');
	return root.slice(start, close + 4);
}

/**
 * Sources with Quit in its own module: the real one, or one synthesized from the root.
 * @param {Record<string,string>} sources
 */
function splitQuit(sources) {
	if (Object.hasOwn(sources, QUIT_FILE)) return sources;
	const root = sources[LINUX_MENU_ROOT];
	const body = quitFunction(root);
	const part = [
		'--- ui/menu/menu_quit.lua',
		'local M = {}',
		'local Logger = require("logger.shim")',
		'local ok_mm, ManifestMenu = pcall(require, "infra.manifest_menu")',
		'if not ok_mm or type(ManifestMenu) ~= "table" then ManifestMenu = nil end',
		'local LOG = "ui.menu.menu_quit"',
		body,
		'M.build = _build_quit',
		'return M',
		''
	].join('\n');
	return {
		...sources,
		[LINUX_MENU_ROOT]: replaceOnce(root, body, QUIT_BINDING, 'synthesized split'),
		[QUIT_FILE]: part
	};
}

/** Wiring that the resolver must refuse, each as [cause, sources]. */
function quitWiringCases(split) {
	const root = split[LINUX_MENU_ROOT],
		part = split[QUIT_FILE];
	const inRoot = (before, after) => ({
		...split,
		[LINUX_MENU_ROOT]: replaceOnce(root, before, after, 'root wiring')
	});
	const inPart = (before, after) => ({
		...split,
		[QUIT_FILE]: replaceOnce(part, before, after, 'part wiring')
	});
	return [
		[
			'binding to a foreign module',
			inRoot(QUIT_BINDING, 'local _build_quit = require("ui.menu.menu_foreign").build')
		],
		[
			'binding a foreign export',
			inRoot(QUIT_BINDING, 'local _build_quit = require("ui.menu.menu_quit").quit')
		],
		[
			'binding through an alias',
			inRoot(
				QUIT_BINDING,
				'local QuitPart = require("ui.menu.menu_quit")\nlocal _build_quit = QuitPart.build'
			)
		],
		[
			'second write of the bound name',
			inRoot(QUIT_BINDING, QUIT_BINDING + '\n_build_quit = function() return nil end')
		],
		[
			'export of a foreign producer',
			inPart(
				'M.build = _build_quit',
				'local function _foreign_quit(ctx) return nil end\nM.build = _foreign_quit'
			)
		],
		[
			'foreign facade import in the split module',
			inPart('pcall(require, "infra.manifest_menu")', 'pcall(require, "foreign.manifest_menu")')
		],
		[
			'extra top-level statement in the split module',
			inPart('\nreturn M', '\nObserve(M)\nreturn M')
		],
		[
			'definition reaching the module table',
			inPart('local function _build_quit(ctx)', 'local function _build_quit(ctx)\n\tM.build = nil')
		],
		['foreign log source', inPart('"ui.menu.menu_quit"', '"ui.menu.menu_foreign"')],
		[
			'header reading a facade the module never declared',
			inPart('local ok_mm, ManifestMenu = pcall(require, "infra.manifest_menu")\n', '')
		]
	];
}

/** Sources with `before` replaced by `after` inside the split Quit module. */
function inQuitPart(split, before, after) {
	return { ...split, [QUIT_FILE]: replaceOnce(split[QUIT_FILE], before, after, 'split module') };
}

/**
 * Runs a gate predicate over the split and its counterexamples.
 * @param {Record<string,string>} sources the real root and parts
 * @param {(root: string) => boolean} credits the gate, applied to the composed root
 * @param {Array<[string, string, string]>} bodyCases [before, after, cause] inside the Quit module
 * @param {string} label
 * @returns {number} controls executed
 */
function verifyQuitSplit(sources, credits, bodyCases, label) {
	const split = splitQuit(sources);
	const admits = (candidate) => {
		const composed = composeLinuxMenuRoot(candidate);
		return composed.ok && credits(composed.source) === true;
	};
	assert.equal(admits(split), true, label + ': the split Quit module is followed');
	let controls = 0;
	for (const [cause, changed] of quitWiringCases(split)) {
		assert.equal(admits(changed), false, label + ': ' + cause);
		controls++;
	}
	for (const [before, after, cause] of bodyCases) {
		assert.equal(admits(inQuitPart(split, before, after)), false, label + ': ' + cause);
		controls++;
	}
	assert.equal(admits(split), true, label + ': the split Quit module is admitted again');
	return controls;
}

module.exports = { QUIT_FILE, splitQuit, quitWiringCases, inQuitPart, verifyQuitSplit };
