// tools/test/test-page-images.cjs

/**
 * ==============================================================================
 * MODULE: Page Images Contract
 * DESCRIPTION:
 * Proves without a browser that tools/test/lib/page-images.cjs refuses an img
 * without alt, a shown svg neither hidden nor named and an element with role
 * img and no name, and passes decorative, named and contained images. The
 * Studio walk (studio-keyboard.playwright.cjs) relies on it.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const { imageProblems } = require('./lib/page-images.cjs');

const picture = (overrides) => ({
	id: 'svg',
	tag: 'svg',
	hidden: false,
	hasAlt: false,
	role: '',
	name: '',
	insideNamedImage: false,
	...overrides
});
assert.deepEqual(
	imageProblems([
		picture({ hidden: true }),
		picture({ role: 'img', name: 'Score chart' }),
		picture({ insideNamedImage: true }),
		picture({ tag: 'img', hasAlt: true })
	]),
	[],
	'decorative, named and contained images pass'
);
for (const [item, expected] of [
	[picture({ tag: 'img' }), /img without alt/],
	[picture({}), /neither hidden as decoration/],
	[picture({ tag: 'div', role: 'img' }), /without a name/]
])
	assert.ok(
		imageProblems([item]).some((problem) => expected.test(problem)),
		`refused: ${expected}`
	);

console.log('PASS test-page-images');
