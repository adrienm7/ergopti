// tools/test/test-menu-font-faces.cjs

/**
 * ==============================================================================
 * MODULE: Menu Font Faces
 * DESCRIPTION:
 * The tray menus draw with the reading font the reader picked
 * (script.reading_font), from the sfnt faces _shared/ui/fonts/menu_faces.json
 * names, because native menu text cannot load the WOFF2 the windows use. The
 * drivers select a face by the names the manifest declares (GDI by family,
 * AppKit by PostScript name), so a face whose name table says otherwise draws
 * the menu in the system font with no error. This check reads each committed
 * file's sfnt header and name table, without fontTools: the flavour matches the
 * extension, names 1 and 6 match the manifest, the face sits in the folder
 * a11y_prefs.js gives that font, and the manifest covers exactly the feature's
 * non-default values.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const REPO_ROOT = path.resolve(__dirname, '..', '..');
const SHARED = path.join(REPO_ROOT, 'static', 'ergopti_plus', '_shared');
const FONTS = path.join(SHARED, 'ui', 'fonts');
const FLAVOURS = Object.freeze({ '.ttf': 0x00010000, '.otf': 0x4f54544f });

/**
 * Reads one name of an sfnt name table, preferring the Windows Unicode record.
 * @param {Buffer} data The font file.
 * @param {number} nameId The name id (1 family, 6 PostScript).
 * @returns {string|null} The name, null when the table has no such record.
 */
function sfntName(data, nameId) {
	const tables = data.readUInt16BE(4);
	let offset = -1;
	for (let index = 0; index < tables; index += 1) {
		const record = 12 + index * 16;
		if (data.toString('latin1', record, record + 4) === 'name')
			offset = data.readUInt32BE(record + 8);
	}
	assert.ok(offset >= 0, 'the face has a name table');
	const count = data.readUInt16BE(offset + 2);
	const strings = offset + data.readUInt16BE(offset + 4);
	let mac = null;
	for (let index = 0; index < count; index += 1) {
		const record = offset + 6 + index * 12;
		if (data.readUInt16BE(record + 6) !== nameId) continue;
		const platform = data.readUInt16BE(record);
		const start = strings + data.readUInt16BE(record + 10);
		const bytes = data.subarray(start, start + data.readUInt16BE(record + 8));
		if (platform === 3) return Buffer.from(bytes).swap16().toString('utf16le');
		if (platform === 1) mac = bytes.toString('latin1');
	}
	return mac;
}

const manifest = JSON.parse(fs.readFileSync(path.join(FONTS, 'menu_faces.json'), 'utf8'));
const prefsSource = fs.readFileSync(path.join(SHARED, 'ui', 'a11y_prefs.js'), 'utf8');
const folders = Object.fromEntries(
	[...prefsSource.match(/var FONT_FOLDERS = \{([^}]*)\}/)[1].matchAll(/(\w+): '([^']+)'/g)].map(
		(m) => [m[1], m[2]]
	)
);
const menu = JSON.parse(
	fs.readFileSync(path.join(SHARED, 'menu', 'data', 'menu_manifest.json'), 'utf8')
);

/** Finds the menu row bound to a feature path anywhere in the manifest. */
function findRow(node, wanted) {
	if (Array.isArray(node)) {
		for (const child of node) {
			const found = findRow(child, wanted);
			if (found) return found;
		}
	} else if (node && typeof node === 'object') {
		if (node.path === wanted && Array.isArray(node.choices)) return node;
		for (const child of Object.values(node)) {
			const found = findRow(child, wanted);
			if (found) return found;
		}
	}
	return null;
}

const row = findRow(menu, 'script.reading_font');
assert.ok(row, 'the menu manifest has the reading font row');
const values = row.choices.map((choice) => choice.value).filter((value) => value !== 'default');
assert.deepEqual(
	Object.keys(manifest.faces).sort(),
	values.sort(),
	'one face per non-default reading font'
);

for (const [key, face] of Object.entries(manifest.faces)) {
	assert.ok(face.file.startsWith(folders[key] + '/'), `${key}: the face sits in ${folders[key]}/`);
	assert.ok(
		face.source.startsWith(folders[key] + '/'),
		`${key}: the source sits in ${folders[key]}/`
	);
	assert.ok(fs.existsSync(path.join(FONTS, face.source)), `${key}: ${face.source} exists`);
	const data = fs.readFileSync(path.join(FONTS, face.file));
	assert.equal(
		data.readUInt32BE(0),
		FLAVOURS[path.extname(face.file)],
		`${key}: the sfnt flavour matches ${face.file}`
	);
	assert.equal(sfntName(data, 1), face.family, `${key}: name 1 is the family GDI selects`);
	assert.equal(
		sfntName(data, 6),
		face.postscript,
		`${key}: name 6 is the PostScript name AppKit selects`
	);
}

console.log(`PASS test-menu-font-faces (${Object.keys(manifest.faces).length} faces)`);
