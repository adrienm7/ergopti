// tools/lib/key-names.cjs

/**
 * ==============================================================================
 * MODULE: Key Names (build and test side)
 * DESCRIPTION:
 * Reads `_shared/layouts/data/keycodes/key_names.json`, the one table naming a key or
 * modifier in visible text, for the generators and gates written in Node. The
 * drivers read its projections (_shared/platform/input/keycodes/key_names.lua and
 * windows/platform/input/key_names.ahk); this is the same rule.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const { shared } = require('./paths.cjs');

const TABLE = JSON.parse(
	fs.readFileSync(shared('layouts', 'data', 'keycodes', 'key_names.json'), 'utf8')
);

// The tap-hold catalogue and the manifests name a driver ahk/hs/linux.
const PLATFORM_OF = {
	windows: 'windows',
	macos: 'macos',
	linux: 'linux',
	ahk: 'windows',
	hs: 'macos'
};

/**
 * The key id a spelling names, or null.
 * @param {string} spelling Any id or alias, in any case.
 * @returns {string|null}
 */
function canonical(spelling) {
	if (typeof spelling !== 'string') return null;
	const lower = spelling.toLowerCase();
	if (Object.hasOwn(TABLE.keys, lower)) return lower;
	return Object.hasOwn(TABLE.aliases, lower) ? TABLE.aliases[lower] : null;
}

/**
 * The locale key naming one key on one platform.
 * @param {string} spelling Any id or alias.
 * @param {string} platform windows, macos, linux, or the catalogue's ahk/hs.
 * @returns {string}
 */
function i18n(spelling, platform) {
	const os = PLATFORM_OF[platform];
	if (!os) throw new Error(`key names: unknown platform ${platform}`);
	const id = canonical(spelling);
	if (id === null) throw new Error(`key names: unknown key ${spelling}`);
	const entry = TABLE.keys[id];
	return (entry.platforms && entry.platforms[os]) || entry.i18n;
}

/**
 * Every spelling a row must never show: each id and alias, plus the
 * abbreviations rows used to print (LCtrl, RShift, LAlt, LCmd, ROption…).
 * @returns {Set<string>}
 */
function rawSpellings() {
	const out = new Set([...Object.keys(TABLE.keys), ...Object.keys(TABLE.aliases)]);
	for (const side of ['L', 'R'])
		for (const name of ['Ctrl', 'Shift', 'Alt', 'Win', 'Cmd', 'Option']) out.add(side + name);
	return out;
}

/**
 * The key ids a sticky action holds, read from its id as
 * _shared/shortcuts/engine/actions/sticky_label.lua reads them (Option is the Alt key);
 * null for an action that is no sticky combination (sticky_hyper is named by
 * its own word, with no {1}).
 * @param {string} action Action id.
 * @returns {string[]|null}
 */
function stickyModifiers(action) {
	const match = /^sticky_(.+)$/.exec(action);
	if (match === null || match[1] === 'hyper') return null;
	const ids = { cmd: 'cmd', ctrl: 'ctrl', option: 'alt', shift: 'shift' };
	return match[1].split('_').map((token) => {
		if (!Object.hasOwn(ids, token)) throw new Error(`sticky action ${action} names ${token}`);
		return ids[token];
	});
}

module.exports = { TABLE, canonical, i18n, rawSpellings, stickyModifiers };
