// tools/lib/kbd-dll/layout-ini.cjs

/**
 * ==============================================================================
 * MODULE: Generic Installer Layout File
 * DESCRIPTION:
 * Writes the layout.ini the generic Windows layout installer
 * (installer.cjs emitStubNsis) reads beside it: the layout file name, its
 * language, its text and its publisher. The layout editor writes it in the
 * page through the bundled DLL writer (_generated/kbd_dll_writer.js), so the
 * site and the app build the same package.
 *
 * FEATURES & RATIONALE:
 * 1. One exact shape: a [layout] section with four keys in a fixed order, in
 *    UTF-16LE with a BOM and CRLF line ends; the installer rebuilds that text
 *    from what it read and refuses any other file.
 * 2. Fail fast: a name the installer would refuse (empty, too long, a control
 *    character, a quote, « = » or a bracket, outer spaces) is refused here.
 * 3. Pure: no file or process access.
 * ==============================================================================
 */

'use strict';

const Model = require('./model.cjs');

// The keys of layout.ini, in the order the installer rebuilds them.
const STUB_INI_KEYS = Object.freeze(['dll_name', 'lcid', 'layout_text', 'company']);
// The longest layout text and company name the installer accepts.
const STUB_MAX_TEXT = 64;

/**
 * The layout.ini a generic installer reads beside it, for one model.
 * @param {object} model - A checked kbd tables model.
 * @returns {Uint8Array} UTF-16LE with a BOM and CRLF line ends.
 * @throws {Error} kbd_installer_text: a name the installer would refuse.
 */
function layoutIni(model) {
	Model.check(model);
	const values = {
		dll_name: model.dll_name,
		lcid: model.lcid,
		layout_text: model.layout_text,
		company: model.company || 'Ergopti'
	};
	for (const key of ['layout_text', 'company'])
		if (
			values[key].length === 0 ||
			values[key].length > STUB_MAX_TEXT ||
			/[\u0000-\u001f"=[\]]/.test(values[key]) ||
			values[key] !== values[key].trim()
		)
			throw new Error(`kbd_installer_text: ${key}`);
	const text = ['[layout]', ...STUB_INI_KEYS.map((key) => `${key}=${values[key]}`), ''].join(
		'\r\n'
	);
	const bytes = new Uint8Array(2 + text.length * 2);
	bytes[0] = 0xff;
	bytes[1] = 0xfe;
	for (let i = 0; i < text.length; i++) {
		const unit = text.charCodeAt(i);
		bytes[2 + i * 2] = unit & 0xff;
		bytes[3 + i * 2] = unit >> 8;
	}
	return bytes;
}

module.exports = { layoutIni, STUB_INI_KEYS, STUB_MAX_TEXT };
