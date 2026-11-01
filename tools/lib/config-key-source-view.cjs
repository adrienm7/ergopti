// tools/lib/config-key-source-view.cjs

/**
 * ==============================================================================
 * MODULE: Config-Key Source View For Source-Shape Gates
 * DESCRIPTION:
 * A gate that matches driver source with regular expressions or byte-exact morphology
 * reads the literal a call passes. Once the call names its generated constant, the
 * same gate must still see that literal. `install()` makes every UTF-8 read of a
 * Lua or AutoHotkey source under static/ergopti_plus return text in which each
 * resolvable constant reference (`ConfigKeys.KEY.LLM_ENABLED`, `ConfigLeaf.MAX_WORDS`)
 * reads as the quoted string it stands for (tools/lib/config-key-tokens.cjs). A name
 * the generated tables do not hold, or one that stands for another key, is left or
 * yields a different string, so the gate still refuses it.
 *
 * It changes only reads made after the call, in the calling process, and only for
 * those files: JSON and tool sources are returned untouched. The generated AutoHotkey
 * tables stay as they are: they declare the constants, they do not read them.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const { expandConfigKeys, expandAhkConfigKeys } = require('./config-key-tokens.cjs');

const DRIVER_LUA = /[\\/]static[\\/]ergopti_plus[\\/].*\.lua$/;
const DRIVER_AHK = /[\\/]static[\\/]ergopti_plus[\\/].*\.ahk$/;
let installed = false;

/** Reports whether a read asks for text. */
function asksForText(options) {
	const encoding = typeof options === 'string' ? options : options && options.encoding;
	return typeof encoding === 'string' && /^utf-?8$/i.test(encoding);
}

/** Installs the view once per process. */
function install() {
	if (installed) return;
	installed = true;
	const read = fs.readFileSync;
	fs.readFileSync = function readFileSync(file, options) {
		const text = read.apply(this, arguments);
		if (typeof file !== 'string' || typeof text !== 'string' || !asksForText(options)) return text;
		if (DRIVER_LUA.test(file)) return expandConfigKeys(text);
		if (DRIVER_AHK.test(file)) return expandAhkConfigKeys(text);
		return text;
	};
}

module.exports = { install };
