// tools/test/test-key-shape.cjs

/**
 * ==============================================================================
 * MODULE: Key Shape Test
 * DESCRIPTION:
 * Pins the ISO Enter's outline on the Studio board (_shared/ui/key_shape.js):
 * one closed SVG path in the shape of an L, its upper row the key's whole
 * width and its lower row starting at the geometry's bottom_col, drawn by the
 * layout editor's board for every key whose geometry is that L. The board
 * drew the ISO Enter as one tall rectangle (maintainer, 2026-11-18: « faut
 * forme de L »).
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { shared } = require('../lib/paths.cjs');

// The pages load it as a classic script: read it the same way.
const context = vm.createContext({});
vm.runInContext(fs.readFileSync(shared('ui', 'key_shape.js'), 'utf8'), context, {
	filename: 'key_shape.js'
});
const KEY_SHAPE = vm.runInContext('KEY_SHAPE', context);
const physical = JSON.parse(
	fs.readFileSync(shared('layouts', 'data', 'keycodes', 'physical_keys.json'), 'utf8')
);
const keys = Array.isArray(physical.keys)
	? physical.keys
	: Object.entries(physical.keys || physical).map(([code, key]) => ({ code, ...key }));

/**
 * The corners of an SVG path made of M, H, V, A and Z commands, in order.
 * @param {string} d
 * @returns {Array<[number, number]>}
 */
function pathPoints(d) {
	const tokens = d.trim().split(/\s+/);
	const points = [];
	let x = 0;
	let y = 0;
	for (let i = 0; i < tokens.length; ) {
		const command = tokens[i++];
		if (command === 'M') [x, y] = [Number(tokens[i++]), Number(tokens[i++])];
		else if (command === 'H') x = Number(tokens[i++]);
		else if (command === 'V') y = Number(tokens[i++]);
		else if (command === 'A') {
			i += 5;
			[x, y] = [Number(tokens[i++]), Number(tokens[i++])];
		} else if (command === 'Z') continue;
		else throw new Error(`unexpected path command ${command}`);
		points.push([x, y]);
	}
	return points;
}

const enter = keys.find((key) => key.code === 'Enter');
assert.ok(enter, 'physical_keys.json has the Enter key');
const iso = enter.geometry.iso;
assert.ok(KEY_SHAPE.isTwoRowL(iso), 'the ISO Enter is a two-row L');
assert.equal(KEY_SHAPE.isTwoRowL(enter.geometry.ansi), false, 'the ANSI Enter is a rectangle');
for (const key of keys)
	if (key.code !== 'Enter')
		for (const [form, geometry] of Object.entries(key.geometry || {}))
			assert.equal(KEY_SHAPE.isTwoRowL(geometry), false, `${key.code} on ${form} is no L`);

const drawing = { gap: 0.08, radius: 0.12 };
const shape = KEY_SHAPE.lPath(iso, drawing);
assert.equal((shape.d.match(/M /g) || []).length, 1, 'one subpath');
assert.ok(shape.d.trim().endsWith('Z'), 'a closed path');
const points = pathPoints(shape.d);
const xs = new Set(points.map(([x]) => x));
const ys = new Set(points.map(([, y]) => y));
assert.equal(shape.width, iso.width - drawing.gap);
assert.equal(shape.height, iso.height - drawing.gap);
assert.ok(xs.has(0) && xs.has(shape.width), 'the upper row spans the whole width');
assert.ok(ys.has(0) && ys.has(shape.height), 'the key spans both rows');
const notch = iso.bottom_col - iso.col;
assert.equal(shape.notchX, notch);
assert.ok(xs.has(notch), 'the lower row starts at bottom_col');
assert.ok(ys.has(1 - drawing.gap), 'the notch ends with the upper row');
// An L has six corners: the path turns at each, so eight distinct x or y edges
// would be a rectangle (four) plus the notch's two edges in each direction.
assert.equal(xs.size >= 4 && ys.size >= 4, true, 'six corners, not four');
// No point of the path lies in the notch (left of bottom_col below the upper row).
for (const [x, y] of points)
	assert.ok(!(x < notch - 1e-9 && y > 1 - drawing.gap + 1e-9), `(${x}, ${y}) is in the notch`);

assert.throws(
	() => KEY_SHAPE.lPath(enter.geometry.ansi, drawing),
	/not a two-row L/,
	'a rectangle key has no L outline'
);

// The board draws it: the editor builds the outline from this module for an L key.
const editor = fs.readFileSync(shared('ui', 'layout_editor', 'editor_page.js'), 'utf8');
assert.match(editor, /KEY_SHAPE\.isTwoRowL\(g\) \? KEY_SHAPE\.lPath\(g, BOARD_DRAWING\)/);
for (const page of ['layout_editor/index.html', 'layout_editor_window/index.html']) {
	const html = fs.readFileSync(shared('ui', ...page.split('/')), 'utf8');
	assert.ok(
		html.indexOf('key_shape.js') >= 0 &&
			html.indexOf('key_shape.js') < html.indexOf('editor_page.js'),
		`${page} loads key_shape.js before the editor`
	);
}

console.log('ok - key shape: the ISO Enter is one L-shaped path on the Studio board');
