// tools/lib/menu-source.cjs

/**
 * ==============================================================================
 * MODULE: Tray Menu Source Reader
 * DESCRIPTION:
 * The one place a tool reads the hand-edited tray-menu source,
 * _shared/modules/menu/menu.toml, whose [menu] tables build-menu-manifest.js
 * compiles into menu_manifest.json. The tables lived in the feature manifest
 * until 2026-10-31; a tool that still needs both reads the feature manifest for
 * features and this module for the menu.
 *
 * FEATURES & RATIONALE:
 * 1. One path: the location comes from paths.cjs, never from a literal.
 * 2. The caller's parser: tests wrap the TOML parser differently (own-data
 *    records, rewritten headers), so the parser is a parameter.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const { shared, MENU_SOURCE_REL } = require('./paths.cjs');

// Absolute path of the tray-menu source.
const MENU_SOURCE_PATH = shared(MENU_SOURCE_REL);

/**
 * Reads the menu source text.
 * @returns {string} The TOML source of menu.toml.
 */
function readMenuSource() {
	return fs.readFileSync(MENU_SOURCE_PATH, 'utf8');
}

/**
 * Parses the menu source and returns its [menu] tables.
 * @param {(source: string) => object} parse The caller's TOML parser.
 * @returns {object} The parsed [menu] tables.
 */
function readMenuTables(parse) {
	const parsed = parse(readMenuSource());
	if (!parsed || typeof parsed.menu !== 'object' || parsed.menu === null)
		throw new Error(`${MENU_SOURCE_REL} declares no [menu] tables`);
	return parsed.menu;
}

module.exports = { MENU_SOURCE_PATH, readMenuSource, readMenuTables };
