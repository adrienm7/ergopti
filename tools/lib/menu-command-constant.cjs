// tools/lib/menu-command-constant.cjs

/**
 * ==============================================================================
 * MODULE: Menu Command Constant Reference
 * DESCRIPTION:
 * Tells whether driver source names a menu command id through its generated
 * constant (COMMAND.X in Lua, MenuCommand.X in AutoHotkey). The menu coverage
 * gates first looked for the id spelt as text, while test-config-key-literals.cjs
 * asks new code for the constant, so every row that migration touched read as
 * unhandled. A constant reference names the id as surely as its spelling does.
 * ==============================================================================
 */

'use strict';

const ConfigKeysCodegen = require('../codegen/codegen-config-keys.cjs');

const COMMAND_CONSTANTS = new Map(
	ConfigKeysCodegen.collect().COMMAND.map(([name, id]) => [id, name])
);
const COMMAND_TABLE = { '.lua': 'COMMAND', '.ahk': 'MenuCommand' };

/**
 * True when the source names the menu command id through its generated constant.
 * @param {string} source Driver source.
 * @param {string} id Menu row id.
 * @param {string} extension Driver source extension (".lua" or ".ahk").
 * @returns {boolean}
 */
function namesCommandConstant(source, id, extension) {
	const name = COMMAND_CONSTANTS.get(id);
	if (!name || !COMMAND_TABLE[extension]) return false;
	return new RegExp(`\\b${COMMAND_TABLE[extension]}\\.${name}\\b`).test(source);
}

module.exports = { namesCommandConstant };
