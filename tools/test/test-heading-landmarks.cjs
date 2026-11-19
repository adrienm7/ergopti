// tools/test/test-heading-landmarks.cjs

/**
 * ==============================================================================
 * MODULE: Heading Order and Landmarks Contract
 * DESCRIPTION:
 * Proves without a browser that tools/test/lib/heading-landmarks.cjs catches
 * each outline failure the Studio walk and the app windows' scan rely on: no
 * h1 or two, a skipped level or a first heading below h1, no main landmark
 * or two, an unnamed navigation, region, complementary, search or form
 * landmark, and two landmarks of one kind under one name; and that a sound
 * outline passes.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const { outlineProblems, NAMED_ROLES } = require('./lib/heading-landmarks.cjs');

const heading = (level, text) => ({ level, text: text || `h${level}` });
const landmark = (role, name, id) => ({ role, name: name || '', id: id || role });
const SOUND = {
	headings: [heading(1), heading(2), heading(3), heading(3), heading(2), heading(4 - 2)],
	landmarks: [
		landmark('banner'),
		landmark('navigation', 'Tabs'),
		landmark('main'),
		landmark('region', 'Results'),
		landmark('region', 'Settings'),
		landmark('complementary', 'Key properties')
	]
};

assert.deepEqual(outlineProblems(SOUND), [], 'a sound outline passes');
// Going back up any number of levels is allowed.
assert.deepEqual(
	outlineProblems({ ...SOUND, headings: [heading(1), heading(2), heading(3), heading(1 + 1)] }),
	[]
);

const cases = [
	[{ headings: [heading(2), heading(3)] }, ['no h1', 'the first heading is h2 (h2)']],
	[{ headings: [heading(1, 'A'), heading(1, 'B')] }, ['2 h1: A | B']],
	[{ headings: [heading(1), heading(3, 'Deep')] }, ['h1 then h3 skips a level (Deep)']],
	[
		{ headings: [heading(1), heading(2), heading(4, 'Deeper')] },
		['h2 then h4 skips a level (Deeper)']
	],
	[{ landmarks: [landmark('region', 'Results')] }, ['0 main landmarks']],
	[{ landmarks: [landmark('main'), landmark('main')] }, ['2 main landmarks']],
	[
		{
			landmarks: [
				landmark('main'),
				landmark('navigation', 'Tabs', 'nav#a'),
				landmark('navigation', 'Tabs', 'nav#b')
			]
		},
		['two navigation landmarks are named « Tabs » (nav#a, nav#b)']
	]
];
for (const role of NAMED_ROLES)
	cases.push([
		{ landmarks: [landmark('main'), landmark(role, '', `x.${role}`)] },
		[`${role} landmark x.${role} has no name`]
	]);
for (const [change, expected] of cases)
	assert.deepEqual(outlineProblems({ ...SOUND, ...change }), expected, JSON.stringify(change));
// banner, contentinfo and main are one of a kind: they need no name.
assert.deepEqual(
	outlineProblems({
		...SOUND,
		landmarks: [landmark('banner'), landmark('main'), landmark('contentinfo')]
	}),
	[]
);

// An open modal dialog is read alone: its headings start at its own level, no main.
const dialog = { modal: true, headings: [heading(2), heading(3)], landmarks: [] };
assert.deepEqual(outlineProblems(dialog), [], 'a dialog starts at its own heading');
assert.deepEqual(
	outlineProblems({ ...dialog, headings: [heading(2), heading(4, 'Deep')] }),
	['h2 then h4 skips a level (Deep)'],
	'a dialog still keeps its levels'
);
assert.deepEqual(
	outlineProblems({ ...dialog, landmarks: [landmark('main')] }),
	['1 main landmarks'],
	'a dialog holds no main'
);

console.log(`PASS test-heading-landmarks (${cases.length + 6} outlines)`);
